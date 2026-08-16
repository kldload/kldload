// =============================================================================
// metrics.go — what the machine is doing while the tests run.
//
// WHAT IT DOES, IN ORDER:
//   1. Reads ARC statistics straight from the kernel's kstat file.
//   2. Reads pool I/O from `zpool iostat`.
//   3. Reads block-layer latency from the eBPF exporter when it is running,
//      and says so plainly when it is not.
//
// WHY IT EXISTS:
//   A failing ZFS test tells you THAT something broke. The ARC hit rate
//   collapsing, or read latency going to hundreds of milliseconds at the same
//   moment, tells you WHY — and that correlation is the entire reason to
//   watch metrics beside a test run rather than in another window afterwards.
//
// WHY IT READS kstat DIRECTLY:
//   /proc/spl/kstat/zfs/arcstats is the source every ZFS tool ultimately
//   reads, it needs no helper installed, and it cannot disagree with the
//   kernel. arc_summary is a Python script that may or may not be present and
//   whose output format is not a contract.
//
// Notes:
//   - Every collector degrades to "unavailable, and here is why" rather than
//     an error. A box with no pool imported, or no exporter running, must
//     still show the panes that do work.
//   - Nothing here mutates anything. This file only ever reads.
// =============================================================================

package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// ArcStatsPath is the kernel's own ARC counter file.
const ArcStatsPath = "/proc/spl/kstat/zfs/arcstats"

// ARC is the subset of arcstats worth a pane. The file carries ~150 counters;
// these are the ones that answer "is the cache working and how big is it".
type ARC struct {
	Size     uint64 // bytes currently in the ARC
	Target   uint64 // c — what ZFS is aiming for
	Max      uint64 // c_max — the ceiling
	MFUSize  uint64
	MRUSize  uint64
	Hits     uint64
	Misses   uint64
	L2Hits   uint64
	L2Misses uint64

	Available bool
	Why       string // when Available is false
}

// HitRate returns the ARC hit percentage, or 0 when nothing has been read
// yet. Reported as a float because a lab watches this move.
func (a ARC) HitRate() float64 {
	total := a.Hits + a.Misses
	if total == 0 {
		return 0
	}
	return float64(a.Hits) / float64(total) * 100
}

// L2HitRate is the same for the L2ARC, which is 0/0 on most boxes.
func (a ARC) L2HitRate() float64 {
	total := a.L2Hits + a.L2Misses
	if total == 0 {
		return 0
	}
	return float64(a.L2Hits) / float64(total) * 100
}

// ReadARC parses the kstat file.
//
// Args:    path, "" → ArcStatsPath (tests point it at a fixture).
// Returns: an ARC with Available=false and a reason when ZFS is not loaded,
// which on a test-lab host means the module under test failed to come up —
// itself the most interesting possible reading.
//
// FORMAT: a two-line header, then "name type data" columns.
func ReadARC(path string) ARC {
	if path == "" {
		path = ArcStatsPath
	}
	f, err := os.Open(path)
	if err != nil {
		return ARC{Why: "ZFS kstats not present — the module is not loaded"}
	}
	defer f.Close()

	vals := map[string]uint64{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) != 3 {
			continue // the two header lines
		}
		v, err := strconv.ParseUint(fields[2], 10, 64)
		if err != nil {
			continue
		}
		vals[fields[0]] = v
	}
	if len(vals) == 0 {
		return ARC{Why: "ZFS kstats are empty"}
	}
	return ARC{
		Size:      vals["size"],
		Target:    vals["c"],
		Max:       vals["c_max"],
		MFUSize:   vals["mfu_size"],
		MRUSize:   vals["mru_size"],
		Hits:      vals["hits"],
		Misses:    vals["misses"],
		L2Hits:    vals["l2_hits"],
		L2Misses:  vals["l2_misses"],
		Available: true,
	}
}

// PoolIO is one pool's throughput.
//
// The numbers are parsed rather than kept as strings because `zpool iostat
// -p` reports raw bytes — "alloc 96776441856" is not a number anybody reads,
// and formatting is the renderer's job, not the parser's.
type PoolIO struct {
	Pool        string
	Alloc, Free uint64 // bytes
	ReadOps     uint64 // operations per second
	WriteOps    uint64
	ReadBW      uint64 // bytes per second
	WriteBW     uint64
}

// ReadPoolIO samples pool throughput.
//
// It asks for a 1-second interval and takes the SECOND report: the first one
// zpool prints is an average since boot, which on a long-lived box is a flat
// line that never moves and looks like a broken pane.
func ReadPoolIO(timeout time.Duration) ([]PoolIO, error) {
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	out, err := runCapture(timeout, "zpool", "iostat", "-Hp", "1", "2")
	if err != nil {
		return nil, fmt.Errorf("zpool iostat: %w", err)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")

	// Keep only the last report: one line per pool, and the tail of the
	// output is the interval sample rather than the since-boot average.
	var pools []PoolIO
	seen := map[string]bool{}
	for i := len(lines) - 1; i >= 0; i-- {
		f := strings.Fields(lines[i])
		if len(f) < 7 {
			continue
		}
		if seen[f[0]] {
			break // wrapped into the previous report
		}
		seen[f[0]] = true
		// A dash means "no reading this interval", which parses to 0 — the
		// honest value for a pool that did nothing.
		pools = append([]PoolIO{{
			Pool: f[0], Alloc: u64(f[1]), Free: u64(f[2]),
			ReadOps: u64(f[3]), WriteOps: u64(f[4]),
			ReadBW: u64(f[5]), WriteBW: u64(f[6]),
		}}, pools...)
	}
	if len(pools) == 0 {
		return nil, fmt.Errorf("no pools imported")
	}
	return pools, nil
}

// ─── Block-layer latency, via eBPF ───────────────────────────────────
//
// kldload ships ebpf_exporter with biolatency and bio-trace probes already
// compiled and a systemd unit to run them. Reading its Prometheus endpoint
// is far better than shelling out to a BCC tool per refresh: the histogram
// is already being maintained, and scraping it costs one HTTP GET.

// EBPFEndpoint is where kldload's ebpf_exporter listens.
const EBPFEndpoint = "http://127.0.0.1:9435/metrics"

// LatencyBucket is one bucket of a block-latency histogram.
type LatencyBucket struct {
	LE    string // upper bound exactly as the exporter labelled it
	Count uint64
}

// Bound renders the bucket's upper bound the way a storage person reads one.
//
// WHY: the exporter publishes Prometheus-native SECONDS as floats, so the
// raw labels come out "1e-06", "2e-06", "4e-06" — a latency pane in
// scientific notation, in the units nobody measures disks in. This turns
// them into µs/ms/s. A label that is already an integer (some exporters
// publish plain microseconds) is passed through with a unit appended rather
// than converted, since converting it would be wrong by a million.
func (b LatencyBucket) Bound() string {
	if b.LE == "+Inf" {
		return "over"
	}
	secs, err := strconv.ParseFloat(b.LE, 64)
	if err != nil {
		return b.LE
	}
	// A bound of 1 or more "seconds" that is a whole number is almost
	// certainly already microseconds; a real 1-second disk bucket is
	// vanishingly rare and would be the top bucket anyway.
	if secs >= 1 && secs == float64(int64(secs)) {
		return fmt.Sprintf("%dµs", int64(secs))
	}
	switch {
	case secs < 1e-3:
		return fmt.Sprintf("%gµs", secs*1e6)
	case secs < 1:
		return fmt.Sprintf("%gms", secs*1e3)
	default:
		return fmt.Sprintf("%gs", secs)
	}
}

// Latency is the block-layer picture.
type Latency struct {
	Buckets   []LatencyBucket
	Available bool
	Why       string
}

// ReadLatency scrapes the eBPF exporter's biolatency histogram.
//
// Returns: a Latency with Available=false and an actionable reason when the
// exporter is not running — "start ebpf_exporter" is something an operator
// can do, where a bare error is not.
func ReadLatency(timeout time.Duration) Latency {
	if timeout <= 0 {
		timeout = 3 * time.Second
	}
	// curl rather than net/http: the static build has no cgo resolver, the
	// endpoint is a literal loopback address, and this keeps one dependency
	// story for every external reading in the tool.
	out, err := runCapture(timeout, "curl", "-fsS", "--max-time", "2", EBPFEndpoint)
	if err != nil {
		return Latency{Why: "eBPF exporter is not answering on :9435 — " +
			"start it with: systemctl start ebpf_exporter"}
	}
	l := Latency{Available: true}
	for _, line := range strings.Split(out, "\n") {
		if !strings.HasPrefix(line, "ebpf_exporter_bio_latency") &&
			!strings.HasPrefix(line, "bio_latency") {
			continue
		}
		le := metricLabel(line, "le")
		if le == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		v, err := strconv.ParseFloat(fields[len(fields)-1], 64)
		if err != nil {
			continue
		}
		l.Buckets = append(l.Buckets, LatencyBucket{LE: le, Count: uint64(v)})
	}
	if len(l.Buckets) == 0 {
		l.Available = false
		l.Why = "the exporter is up but publishes no bio_latency histogram — " +
			"check /etc/ebpf_exporter/biolatency.yaml is loaded"
	}
	return l
}

// metricLabel pulls one label value out of a Prometheus sample line.
func metricLabel(line, key string) string {
	open := strings.IndexByte(line, '{')
	close := strings.IndexByte(line, '}')
	if open < 0 || close < open {
		return ""
	}
	for _, part := range strings.Split(line[open+1:close], ",") {
		k, v, ok := strings.Cut(part, "=")
		if ok && strings.TrimSpace(k) == key {
			return strings.Trim(strings.TrimSpace(v), `"`)
		}
	}
	return ""
}

// runCapture runs a command with a deadline and returns its stdout.
//
// Every external reading in this file goes through here so one timeout
// policy covers them all: a wedged zpool command must not freeze a pane
// that is refreshing on a timer.
func runCapture(timeout time.Duration, name string, args ...string) (string, error) {
	if _, err := exec.LookPath(name); err != nil {
		return "", fmt.Errorf("%s is not installed", name)
	}
	cmd := exec.Command(name, args...)
	done := make(chan error, 1)
	var out strings.Builder
	cmd.Stdout = &out
	if err := cmd.Start(); err != nil {
		return "", err
	}
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return out.String(), err
	case <-time.After(timeout):
		_ = cmd.Process.Kill()
		<-done
		return "", fmt.Errorf("%s timed out after %s", name, timeout)
	}
}

// u64 parses a zpool field, treating "-" and anything unparseable as zero.
func u64(s string) uint64 {
	v, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		return 0
	}
	return v
}
