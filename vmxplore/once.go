// once.go — `vmx --once`: print the joined estate table and exit.
//
// Exists for three consumers: smoke tests (tests/smoke-*.sh grep this
// output), scripts, and verifying the join non-interactively over SSH. It is
// the same BuildEstate the TUI renders — one code path, two surfaces.
//
// Output: the headline view from the design doc — group headers, one row per
// domain: NAME STATE CPU MEM BACKING CLONE-OF SNAPS AGENT NOTES. CPU%% comes
// from two cpu.time samples 600ms apart (a single sample cannot yield a rate).
package main

import (
	"fmt"
	"os"
	"strings"
	"text/tabwriter"
	"time"
)

// runOnce gathers one full estate and prints it. Returns an exit code so
// main can stay the only caller of os.Exit.
func runOnce(rs *Ruleset) int {
	lv, err := ConnectSystem()
	if err != nil {
		fmt.Fprintf(os.Stderr, "vmx: libvirt: %v\n", err)
		return 1
	}
	defer lv.Close()

	s0, t0, _ := lv.CPUSample()
	time.Sleep(600 * time.Millisecond)

	doms, err := lv.Estate()
	if err != nil {
		fmt.Fprintf(os.Stderr, "vmx: %v\n", err)
		return 1
	}

	var dss map[string]*Dataset
	var snaps map[string][]string
	if HasZFS() {
		if dss, err = ListDatasets(); err != nil {
			fmt.Fprintf(os.Stderr, "vmx: warning: %v — join disabled\n", err)
		}
		if snaps, err = ListSnapshots(); err != nil {
			fmt.Fprintf(os.Stderr, "vmx: warning: %v\n", err)
		}
	}

	cpu := map[string]float64{}
	if s1, t1, err := lv.CPUSample(); err == nil && !t0.IsZero() {
		cpu = cpuPercent(s0, s1, t1.Sub(t0), doms)
	}

	groups := BuildEstate(doms, dss, snaps, rs, LoadAnnotations())

	w := tabwriter.NewWriter(os.Stdout, 2, 4, 2, ' ', 0)
	fmt.Fprintln(w, "  DOMAIN\tSTATE\tCPU\tMEM\tBACKING\tCLONE OF\tSNAPS\tAGENT\tNOTES")
	for _, g := range groups {
		fmt.Fprintf(w, "▸ %s (%d)\t\t\t\t\t\t\t\t\n", g.Label, len(g.Rows))
		for _, r := range g.Rows {
			fmt.Fprintf(w, "  %s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
				r.D.Name, r.D.State, cpuCell(cpu, r), memCell(r),
				cellOr(r.Backing, "-"), cellOr(shortOrigin(r.Origin), "-"),
				snapCell(r), agentCell(r), strings.Join(r.Notes, "; "))
		}
	}
	w.Flush()
	return 0
}

// cpuPercent turns two cumulative cpu.time samples into guest-CPU%% (delta
// normalized by the domain's vCPU count, virt-top convention).
func cpuPercent(s0, s1 map[string]uint64, wall time.Duration,
	doms []Dom) map[string]float64 {
	vcpus := make(map[string]uint64, len(doms))
	for _, d := range doms {
		vcpus[d.Name] = d.VCPUs
	}
	out := make(map[string]float64, len(s1))
	if wall <= 0 {
		return out
	}
	for name, ns1 := range s1 {
		ns0, ok := s0[name]
		if !ok || ns1 < ns0 {
			continue
		}
		n := vcpus[name]
		if n == 0 {
			n = 1
		}
		out[name] = float64(ns1-ns0) / float64(wall.Nanoseconds()) / float64(n) * 100
	}
	return out
}

// ─── cell renderers, shared with the TUI ────────────────────────────────────

func cellOr(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}

func cpuCell(cpu map[string]float64, r Row) string {
	if r.D.State != "running" {
		return "-"
	}
	return fmt.Sprintf("%.1f%%", cpu[r.D.Name])
}

func memCell(r Row) string {
	if r.Synthetic {
		if r.DS != nil {
			return humanBytes(r.DS.Used)
		}
		return "-"
	}
	if r.D.State == "running" && r.D.CurMemKiB > 0 {
		return humanBytes(r.D.CurMemKiB*1024) + "/" + humanBytes(r.D.MaxMemKiB*1024)
	}
	if r.D.MaxMemKiB > 0 {
		return humanBytes(r.D.MaxMemKiB * 1024)
	}
	return "-"
}

// snapCell renders "605✎3" — total snapshots, of which 3 operator-made.
// The collapse that makes a 16k-snapshot host readable.
func snapCell(r Row) string {
	if r.DS == nil {
		return "-"
	}
	if r.SnapHuman > 0 {
		return fmt.Sprintf("%d✎%d", r.SnapTotal, r.SnapHuman)
	}
	return fmt.Sprintf("%d", r.SnapTotal)
}

func agentCell(r Row) string {
	switch {
	case r.D.AgentUp:
		return "up"
	case r.D.State == "running":
		return "down"
	}
	return "-"
}

// shortOrigin trims the pool path from an origin for column width:
// rpool/vms/klab-golden-fedora@golden → klab-golden-fedora@golden.
func shortOrigin(origin string) string {
	if i := strings.LastIndex(origin, "/"); i >= 0 {
		return origin[i+1:]
	}
	return origin
}
