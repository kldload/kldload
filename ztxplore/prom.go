// =============================================================================
// prom.go — the Grafana ZFS panels, without Grafana.
//
// WHAT IT DOES, IN ORDER:
//   1. Asks the local Prometheus the same PromQL the shipped ZFS dashboards
//      ask.
//   2. Parses the instant-query response into scalars.
//   3. Hands the Metrics pane a list of ready-to-render readings.
//
// WHY IT MIRRORS THE QUERIES AND NOT THE DASHBOARDS:
//   The obvious reading of "put the Grafana panels in the tool" is to embed
//   Grafana. That needs a browser widget this toolkit does not have, and it
//   makes the pane blank whenever Grafana is down — which, on a lab box being
//   hammered by a test run, is exactly when it matters.
//
//   The dashboards' VALUE is their PromQL: somebody already worked out that
//   ARC hit rate is
//     100 * sum(rate(zfs_arcstat{metric="hits"}[5m])) / sum(rate(...))
//   and that compression is logical_used / used. Those expressions are the
//   asset. Asking Prometheus directly reuses them, needs only Prometheus, and
//   leaves the dashboards untouched for the deep dives they are better at.
//
//   It also buys something /proc cannot: rate() and history. arcstats gives a
//   counter since boot, so a hit rate read from it is an average over weeks
//   and barely moves. The 5-minute rate is what shows the ARC collapsing
//   during the run you are watching.
//
// Notes:
//   - Instant queries only. Drawing time series is Grafana's job and it is
//     better at it; the pane answers "what is it doing right now".
//   - Absent Prometheus is reported as a sentence naming the fix, not an
//     error. A lab host without the monitoring stack still gets the /proc
//     readings in metrics.go.
// =============================================================================

package main

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"time"
)

// PromEndpoint is where kldload's Prometheus listens.
const PromEndpoint = "http://127.0.0.1:9090"

// PromReading is one panel's worth of answer.
type PromReading struct {
	Label string  // what it is, in words
	Value float64 // the number
	Unit  Unit    // how to render it
	OK    bool    // false when the query returned nothing
}

// Unit says how a reading should be formatted. Rendering a byte count as a
// percentage is the kind of mistake that costs an hour of confusion.
type Unit int

const (
	UnitRaw Unit = iota
	UnitBytes
	UnitPercent
	UnitRatio
)

// Render formats the value for display.
func (r PromReading) Render() string {
	if !r.OK {
		return "—"
	}
	switch r.Unit {
	case UnitBytes:
		return humanBytes(uint64(r.Value))
	case UnitPercent:
		return fmt.Sprintf("%.1f%%", r.Value)
	case UnitRatio:
		return fmt.Sprintf("%.2fx", r.Value)
	default:
		return fmt.Sprintf("%.0f", r.Value)
	}
}

// promPanel is one query lifted from a shipped dashboard.
type promPanel struct {
	Label string
	Expr  string
	Unit  Unit
	From  string // which dashboard it came from, so the two can be compared
}

// ZFSPanels are the ZFS readings from the shipped dashboards.
//
// Kept as data, and kept ATTRIBUTED: when a dashboard's expression changes,
// the From field says which file to go and compare against. Two copies of a
// query that silently disagree is worse than one copy in the wrong place.
var ZFSPanels = []promPanel{
	{"ARC hit rate (5m)",
		`100 * sum(rate(zfs_arcstat{metric="hits"}[5m])) / sum(rate(zfs_arcstat{metric=~"hits|misses"}[5m]))`,
		UnitPercent, "storage/zfs-pool-health"},
	{"ARC size", `sum(zfs_arcstat{metric="size"})`, UnitBytes, "storage/zfs-pool-health"},
	{"ARC target", `sum(zfs_arcstat{metric="c"})`, UnitBytes, "storage/zfs-pool-health"},
	{"ARC max", `sum(zfs_arcstat{metric="c_max"})`, UnitBytes, "storage/zfs-pool-health"},
	{"MFU size", `sum(zfs_arcstat{metric="mfu_size"})`, UnitBytes, "storage/zfs-pool-health"},
	{"MRU size", `sum(zfs_arcstat{metric="mru_size"})`, UnitBytes, "storage/zfs-pool-health"},
	{"Pool used", `sum(zfs_pool_allocated_bytes)`, UnitBytes, "storage/zfs-pool-health"},
	{"Pool size", `sum(zfs_pool_size_bytes)`, UnitBytes, "storage/zfs-pool-health"},
	{"Pool full", `100 * sum(zfs_pool_allocated_bytes) / sum(zfs_pool_size_bytes)`,
		UnitPercent, "storage/zfs-pool-health"},
	{"Compression ratio",
		`sum(zfs_dataset_logical_used_bytes) / sum(zfs_dataset_used_bytes)`,
		UnitRatio, "storage/compression-trend"},
	{"Saved by compression",
		`sum(zfs_dataset_logical_used_bytes) - sum(zfs_dataset_used_bytes)`,
		UnitBytes, "storage/compression-trend"},
	// The klab_* family is what the lab's own exporter publishes during a
	// test run, so these move while the matrix is going.
	// x100 because klab_zfs_arc_hit_ratio is a 0-1 RATIO, not a percentage —
	// Grafana renders it with a percentunit axis, which is easy to miss when
	// lifting the expression. Without it a perfectly healthy ARC reported
	// "1.0%" beside the kernel's own reading of 100%.
	{"Lab ARC hit ratio", `100 * avg(klab_zfs_arc_hit_ratio)`, UnitPercent, "observability/zfs-test-live"},
	{"Lab ARC size", `avg(klab_zfs_arc_size_bytes)`, UnitBytes, "observability/zfs-test-live"},
	{"Lab pool compress", `avg(klab_zfs_pool_compress_ratio)`, UnitRatio, "observability/zfs-test-live"},
}

// promResponse is the slice of Prometheus's instant-query reply we need.
type promResponse struct {
	Status string `json:"status"`
	Data   struct {
		ResultType string `json:"resultType"`
		Result     []struct {
			// [ <unix seconds>, "<value as string>" ]
			Value []json.RawMessage `json:"value"`
		} `json:"result"`
	} `json:"data"`
}

// PromQuery runs one instant query.
//
// Args:    expr, the PromQL; timeout, the deadline.
// Returns: the first sample's value, ok=false when the query matched nothing.
//
// "Matched nothing" is not an error: a box with no L2ARC genuinely has no
// l2_hits series, and a pane that errors on that is a pane nobody trusts.
func PromQuery(expr string, timeout time.Duration) (float64, bool) {
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	u := PromEndpoint + "/api/v1/query?query=" + url.QueryEscape(expr)
	out, err := runCapture(timeout, "curl", "-fsS", "--max-time", "4", u)
	if err != nil {
		return 0, false
	}
	var resp promResponse
	if err := json.Unmarshal([]byte(out), &resp); err != nil || resp.Status != "success" {
		return 0, false
	}
	if len(resp.Data.Result) == 0 || len(resp.Data.Result[0].Value) < 2 {
		return 0, false
	}
	// The value is a JSON STRING, not a number — Prometheus encodes it that
	// way so NaN and +Inf survive the round trip.
	var raw string
	if err := json.Unmarshal(resp.Data.Result[0].Value[1], &raw); err != nil {
		return 0, false
	}
	v, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return 0, false // NaN / +Inf: a ratio with a zero denominator
	}
	return v, true
}

// PromAvailable reports whether Prometheus is answering, and why not.
func PromAvailable(timeout time.Duration) (bool, string) {
	if _, err := runCapture(timeout, "curl", "-fsS", "--max-time", "3",
		PromEndpoint+"/-/healthy"); err != nil {
		return false, "Prometheus is not answering on :9090 — these readings come " +
			"from the same queries the Grafana ZFS dashboards use. Start it with: " +
			"systemctl start prometheus"
	}
	return true, ""
}

// ReadZFSPanels runs every panel query.
//
// Returns: one reading per panel, in order, with OK=false on the ones that
// matched nothing. Order is fixed so the pane does not reshuffle between
// refreshes while somebody is reading it.
func ReadZFSPanels(timeout time.Duration) []PromReading {
	out := make([]PromReading, 0, len(ZFSPanels))
	for _, p := range ZFSPanels {
		v, ok := PromQuery(p.Expr, timeout)
		out = append(out, PromReading{Label: p.Label, Value: v, Unit: p.Unit, OK: ok})
	}
	return out
}
