// metrics.go — the Metrics section, drawn from Prometheus, not Grafana.
//
// Grafana is browser-only; Prometheus is an API. Each panel here is one
// PromQL range query over the last thirty minutes (a point a minute), shown
// as a row: the series' name, its value now, a sparkline of the window, and
// the window's low and high. The queries are the ones the shipped dashboards
// use, so the numbers agree with them; the drawing is block glyphs, which
// every terminal has (operator, 2026-09-26: "I don't want a web gui at all").
package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

const promURL = "http://localhost:9090"

type series struct {
	labels map[string]string
	values []float64 // NaN where Prometheus had no sample
}

// promRange runs one range query over the last `window` with `step`.
func promRange(query string, window, step time.Duration) ([]series, error) {
	end := time.Now()
	q := url.Values{}
	q.Set("query", query)
	q.Set("start", strconv.FormatInt(end.Add(-window).Unix(), 10))
	q.Set("end", strconv.FormatInt(end.Unix(), 10))
	q.Set("step", strconv.Itoa(int(step.Seconds())))
	client := http.Client{Timeout: 8 * time.Second}
	resp, err := client.Get(promURL + "/api/v1/query_range?" + q.Encode())
	if err != nil {
		return nil, fmt.Errorf("prometheus: %v", err)
	}
	defer resp.Body.Close()
	var rep struct {
		Status string `json:"status"`
		Error  string `json:"error"`
		Data   struct {
			Result []struct {
				Metric map[string]string `json:"metric"`
				Values [][2]any          `json:"values"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&rep); err != nil {
		return nil, fmt.Errorf("prometheus: %v", err)
	}
	if rep.Status != "success" {
		return nil, fmt.Errorf("prometheus: %s", rep.Error)
	}
	n := int(window/step) + 1
	var out []series
	for _, r := range rep.Data.Result {
		s := series{labels: r.Metric, values: make([]float64, n)}
		for i := range s.values {
			s.values[i] = math.NaN()
		}
		start := end.Add(-window).Unix()
		for _, v := range r.Values {
			ts, _ := v[0].(float64)
			f, err := strconv.ParseFloat(fmt.Sprint(v[1]), 64)
			if err != nil {
				continue
			}
			i := int((int64(ts) - start) / int64(step.Seconds()))
			if i >= 0 && i < n {
				s.values[i] = f
			}
		}
		out = append(out, s)
	}
	return out, nil
}

// sparkline draws values as eight block levels scaled to the window's range;
// a gap in the samples is a space.
func sparkline(vals []float64) string {
	const blocks = "▁▂▃▄▅▆▇█"
	lo, hi := math.Inf(1), math.Inf(-1)
	for _, v := range vals {
		if !math.IsNaN(v) {
			lo, hi = math.Min(lo, v), math.Max(hi, v)
		}
	}
	var b strings.Builder
	for _, v := range vals {
		if math.IsNaN(v) {
			b.WriteByte(' ')
			continue
		}
		level := 0
		if hi > lo {
			level = int((v - lo) / (hi - lo) * 7.999)
		}
		b.WriteRune([]rune(blocks)[level])
	}
	return b.String()
}

func last(vals []float64) float64 {
	for i := len(vals) - 1; i >= 0; i-- {
		if !math.IsNaN(vals[i]) {
			return vals[i]
		}
	}
	return math.NaN()
}

func minMax(vals []float64) (float64, float64) {
	lo, hi := math.Inf(1), math.Inf(-1)
	for _, v := range vals {
		if !math.IsNaN(v) {
			lo, hi = math.Min(lo, v), math.Max(hi, v)
		}
	}
	if math.IsInf(lo, 1) {
		return math.NaN(), math.NaN()
	}
	return lo, hi
}

// units: how a panel's numbers print.
func fmtUnit(v float64, unit string) string {
	if math.IsNaN(v) {
		return "-"
	}
	switch unit {
	case "%":
		return fmt.Sprintf("%.1f%%", v)
	case "bytes":
		return human(int64(v))
	case "bytes/s":
		return human(int64(v)) + "/s"
	case "count":
		return strconv.FormatInt(int64(math.Round(v)), 10)
	}
	return fmt.Sprintf("%.2f", v)
}

// panel is one query and how to name each series it returns.
type panel struct {
	name  string
	query string
	unit  string
	by    string // label that names the series when there are several
}

var metricPanels = map[string][]panel{
	"Host": {
		// busy = 1 - idle/all, never 100 - rate(idle)*100: the latter goes
		// negative when the sample windows drift (Grafana, 2026-08)
		{"cpu busy", `(1 - sum(rate(node_cpu_seconds_total{mode="idle"}[2m])) / sum(rate(node_cpu_seconds_total[2m]))) * 100`, "%", ""},
		{"load (1m)", `node_load1`, "", ""},
		{"memory used", `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100`, "%", ""},
		{"memory available", `node_memory_MemAvailable_bytes`, "bytes", ""},
		{"disk busy", `max(rate(node_disk_io_time_seconds_total{device=~"nvme.*|sd.*"}[2m])) * 100`, "%", ""},
		{"disk read", `sum(rate(node_disk_read_bytes_total{device=~"nvme.*|sd.*"}[2m]))`, "bytes/s", ""},
		{"disk write", `sum(rate(node_disk_written_bytes_total{device=~"nvme.*|sd.*"}[2m]))`, "bytes/s", ""},
		{"net rx", `sum(rate(node_network_receive_bytes_total{device!~"lo|veth.*|vnet.*|virbr.*"}[2m]))`, "bytes/s", ""},
		{"net tx", `sum(rate(node_network_transmit_bytes_total{device!~"lo|veth.*|vnet.*|virbr.*"}[2m]))`, "bytes/s", ""},
	},
	"Storage": {
		{"arc size", `node_zfs_arc_size`, "bytes", ""},
		{"arc hit ratio", `rate(node_zfs_arc_hits[5m]) / (rate(node_zfs_arc_hits[5m]) + rate(node_zfs_arc_misses[5m])) * 100`, "%", ""},
		{"disk busy", `rate(node_disk_io_time_seconds_total{device=~"nvme.*|sd.*"}[2m]) * 100`, "%", "device"},
		{"read", `rate(node_disk_read_bytes_total{device=~"nvme.*|sd.*"}[2m])`, "bytes/s", "device"},
		{"write", `rate(node_disk_written_bytes_total{device=~"nvme.*|sd.*"}[2m])`, "bytes/s", "device"},
	},
	"Machines": {
		{"running", `count(libvirt_domain_info_state == 1)`, "count", ""},
		{"vm cpu", `topk(12, rate(libvirt_domain_info_cpu_time_seconds_total[2m]) * 100)`, "%", "domain"},
		{"vm memory", `topk(12, libvirt_domain_info_memory_usage_bytes)`, "bytes", "domain"},
	},
	"Mesh": {
		{"wg rx", `rate(node_network_receive_bytes_total{device=~"wg.*"}[2m])`, "bytes/s", "device"},
		{"wg tx", `rate(node_network_transmit_bytes_total{device=~"wg.*"}[2m])`, "bytes/s", "device"},
	},
}

// loadMetricPanels fills a section from the panels of its sub-tab.
func loadMetricPanels(d *sectionData, sub string) {
	panels := metricPanels[sub]
	d.columns = []string{"metric", "now", "last 30 min", "low", "high"}
	failed := 0
	for _, p := range panels {
		ss, err := promRange(p.query, 30*time.Minute, time.Minute)
		if err != nil {
			d.rows = append(d.rows, []string{p.name, "-", err.Error(), "", ""})
			failed++
			continue
		}
		if len(ss) == 0 {
			d.rows = append(d.rows, []string{p.name, "-", "no series", "", ""})
			continue
		}
		sort.SliceStable(ss, func(i, j int) bool { return last(ss[i].values) > last(ss[j].values) })
		for _, s := range ss {
			name := p.name
			if p.by != "" && s.labels[p.by] != "" {
				name = p.name + " " + s.labels[p.by]
			}
			lo, hi := minMax(s.values)
			d.rows = append(d.rows, []string{name, fmtUnit(last(s.values), p.unit), sparkline(s.values), fmtUnit(lo, p.unit), fmtUnit(hi, p.unit)})
		}
	}
	d.headline = fmt.Sprintf("%s · Prometheus at %s · a point a minute for 30 minutes", sub, promURL)
	if failed == len(panels) && failed > 0 {
		d.err = "Prometheus did not answer: " + d.rows[0][2]
	}
}

func loadMetricsHost(d *sectionData)     { loadMetricPanels(d, "Host") }
func loadMetricsStorage(d *sectionData)  { loadMetricPanels(d, "Storage") }
func loadMetricsMachines(d *sectionData) { loadMetricPanels(d, "Machines") }
func loadMetricsMesh(d *sectionData)     { loadMetricPanels(d, "Mesh") }
