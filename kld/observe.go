// observe.go — Storage / Observe: one-second samples of a pool judged into
// verdicts, the way zxplore's Observe does it, drawn as a table the TUI
// already knows how to page and filter.
//
// The engine is zxplore's: `zxplore --observe <pool> json` reads the ZFS
// kstats twice a second apart, a `zpool iostat -Hpvly`, the txg history,
// the pool properties and the tunables, and judges them (throttle, txg
// time, ARC hit rate, sync writes without a log, capacity, fragmentation,
// slow leaves, scrub in progress). kld renders that JSON: verdicts first,
// then gauges, the vdevs and the busiest datasets. Nothing is judged twice
// in a second place (rule 2 of the core: never re-implement what exists).
//
// The tab reloads itself every 3 s while it is on screen (a sample costs
// about a second), like the Machines view; o on a pool row opens it on
// that pool, the default is the first pool.
package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

type observeReport struct {
	Sample struct {
		Pool     string
		Seconds  float64
		Rate     map[string]float64
		Props    map[string]string
		Scan     string
		HasLog   bool
		MemTotal int64
		MemAvail int64
		Tunables map[string]int64
		Warnings []string
		Arc      struct {
			V map[string]int64
		}
		Txgs []struct {
			Txg   int64
			State string
			OTime int64
			STime int64
		}
		Vdevs []struct {
			Name                 string
			Alloc, Free          int64
			ROps, WOps, RBw, WBw int64
			TotalR, TotalW       int64
			DiskR, DiskW         int64
			SyncqR, SyncqW       int64
			AsyncqR, AsyncqW     int64
			Scrub, Trim, Rebuild int64 // ops of each in flight this second
		}
		Datasets []struct {
			Name                   string
			Reads, Writes          float64
			NRead, NWritten        float64
			ZilCommits             float64
			ZilNormalBytes         float64
			ZilSlogBytes           float64
			ZilStalls, ZilSuspends int64
		}
	}
	Verdicts []struct {
		Level, Title, Evidence, Fix string
	}
}

// loadObserve runs one sample of the pool in the context (or the first
// pool) and lays the report out as rows: verdicts, gauges, vdevs, datasets.
func loadObserve(d *sectionData) {
	pool := d.ctx
	if pool == "" {
		out, err := run(10*time.Second, "zpool", "list", "-H", "-o", "name")
		if err != nil || strings.TrimSpace(out) == "" {
			d.err = "no pool to observe"
			return
		}
		pool = strings.Fields(out)[0]
	}
	if !nameOK(pool) {
		d.err = "not a pool name: " + pool
		return
	}
	// the sample itself: not elevated by zxplore (only its events verb is),
	// but run() adds sudo -n so the zpool events line is read too
	out, err := run(30*time.Second, "zxplore", "--observe", pool, "json")
	if err != nil {
		d.err = err.Error()
		return
	}
	var r observeReport
	if err := json.Unmarshal([]byte(out), &r); err != nil {
		d.err = "observe: " + err.Error()
		return
	}
	s := &r.Sample
	d.columns = []string{"kind", "item", "value", "detail"}
	// verdicts, red first (zxplore sorts them; keep its order)
	red, gold := 0, 0
	for _, v := range r.Verdicts {
		switch v.Level {
		case "red":
			red++
		case "gold":
			gold++
		}
		d.rows = append(d.rows, []string{"verdict " + v.Level, v.Title, v.Evidence, "fix: " + v.Fix})
	}
	// gauges
	arc := s.Arc.V
	hitPct := 0.0
	if h, m := s.Rate["arc.hits"], s.Rate["arc.misses"]; h+m > 0 {
		hitPct = h / (h + m) * 100
	}
	d.rows = append(d.rows,
		[]string{"gauge", "ARC", fmt.Sprintf("%.0f%% hit · %s of %s", hitPct, human(arc["size"]), human(arc["c_max"])), fmt.Sprintf("%.0f hits/s, %.0f misses/s", s.Rate["arc.hits"], s.Rate["arc.misses"])},
		[]string{"gauge", "pool", fmt.Sprintf("%s · %s%% full · frag %s%%", s.Props["health"], s.Props["capacity"], s.Props["fragmentation"]), fmt.Sprintf("%s of %s allocated · dedup %s · ashift %s", humanStr(s.Props["allocated"]), humanStr(s.Props["size"]), s.Props["dedupratio"], s.Props["ashift"])},
		[]string{"gauge", "throttle", fmt.Sprintf("delay %.0f/s · hard %.0f/s", s.Rate["dmu_tx.dmu_tx_dirty_delay"], s.Rate["dmu_tx.dmu_tx_dirty_throttle"]), fmt.Sprintf("dirty_data_max %s · memory reclaim %.0f/s", human(s.Tunables["zfs_dirty_data_max"]), s.Rate["dmu_tx.dmu_tx_memory_reclaim"])},
	)
	if n := len(s.Txgs); n > 0 {
		var sum int64
		worst := int64(0)
		for _, t := range s.Txgs {
			sum += t.STime
			if t.STime > worst {
				worst = t.STime
			}
		}
		d.rows = append(d.rows, []string{"gauge", "txg sync", fmt.Sprintf("avg %.0f ms · worst %.0f ms over %d", float64(sum)/float64(n)/1e6, float64(worst)/1e6, n), fmt.Sprintf("zfs_txg_timeout %ds", s.Tunables["zfs_txg_timeout"])})
	}
	logNote := "no log vdev"
	if s.HasLog {
		logNote = "log vdev present"
	}
	d.rows = append(d.rows,
		[]string{"gauge", "ZIL", fmt.Sprintf("%.0f commits/s · %s/s pool · %s/s slog", s.Rate["zil.zil_commit_count"], human(int64(s.Rate["zil.zil_itx_metaslab_normal_bytes"])), human(int64(s.Rate["zil.zil_itx_metaslab_slog_bytes"]))), logNote},
		[]string{"gauge", "memory", fmt.Sprintf("%s available of %s", human(s.MemAvail), human(s.MemTotal)), fmt.Sprintf("zfs_arc_max %s", human(s.Tunables["zfs_arc_max"]))},
		[]string{"gauge", "scan", orDash(strings.TrimSpace(s.Scan)), ""},
	)
	// vdevs
	for _, v := range s.Vdevs {
		state := ""
		for name, n := range map[string]int64{"scrub": v.Scrub, "trim": v.Trim, "rebuild": v.Rebuild} {
			if n > 0 {
				state += fmt.Sprintf("%s %d ", name, n)
			}
		}
		lat := func(ns int64) string {
			if ns < 0 {
				return "-"
			}
			return fmt.Sprintf("%.1fms", float64(ns)/1e6)
		}
		d.rows = append(d.rows, []string{"vdev", v.Name,
			fmt.Sprintf("r %d/s %s/s · w %d/s %s/s", v.ROps, human(v.RBw), v.WOps, human(v.WBw)),
			fmt.Sprintf("wait r %s w %s · disk r %s w %s · q sync %d/%d async %d/%d %s", lat(v.TotalR), lat(v.TotalW), lat(v.DiskR), lat(v.DiskW), v.SyncqR, v.SyncqW, v.AsyncqR, v.AsyncqW, strings.TrimSpace(state))})
	}
	// busiest datasets this second: top 10 by bytes moved
	ds := append([]struct {
		Name                   string
		Reads, Writes          float64
		NRead, NWritten        float64
		ZilCommits             float64
		ZilNormalBytes         float64
		ZilSlogBytes           float64
		ZilStalls, ZilSuspends int64
	}(nil), s.Datasets...)
	sort.Slice(ds, func(i, j int) bool { return ds[i].NRead+ds[i].NWritten > ds[j].NRead+ds[j].NWritten })
	shown := 0
	for _, x := range ds {
		if x.NRead+x.NWritten == 0 && x.ZilCommits == 0 {
			continue
		}
		d.rows = append(d.rows, []string{"dataset", x.Name,
			fmt.Sprintf("r %.0f/s %s/s · w %.0f/s %s/s", x.Reads, human(int64(x.NRead)), x.Writes, human(int64(x.NWritten))),
			fmt.Sprintf("zil %.0f commits/s %s/s · stalls %d", x.ZilCommits, human(int64(x.ZilNormalBytes+x.ZilSlogBytes)), x.ZilStalls)})
		shown++
		if shown == 10 {
			break
		}
	}
	if shown == 0 {
		d.rows = append(d.rows, []string{"dataset", "-", "no dataset moved a byte this second", ""})
	}
	for _, w := range s.Warnings {
		d.rows = append(d.rows, []string{"warning", "not read", w, ""})
	}
	d.headline = fmt.Sprintf("%s — %d verdict(s): %d red, %d gold · sampled %s · reloads every 3 s while shown (o on a pool row observes it)", pool, len(r.Verdicts), red, gold, time.Now().Format("15:04:05"))
}

// humanStr is human() for a number that arrived as a string.
func humanStr(s string) string {
	var n int64
	if _, err := fmt.Sscan(s, &n); err != nil {
		return orDash(s)
	}
	return human(n)
}
