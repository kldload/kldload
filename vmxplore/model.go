// model.go — the join. Domains × datasets × snapshots × rules → estate rows.
//
// This is the product (docs/VM-CONSOLE-DESIGN.md "The model"): a row that
// reads "running, cloned from klab-golden-fedora@golden, 604 snapshots
// (1 operator-made), agent up" exists in no other tool. Everything here is
// pure computation over the inputs — no I/O — so it is unit-testable and
// identical for the TUI and --once.
//
// Inputs:  []Dom (libvirt.go), dataset map + snapshot map (zfs.go),
//
//	*Ruleset (rules.go), *Annotations (reconcile.go).
//
// Outputs: []GroupRows, ordered: named groups A→Z, then ungrouped, then
//
//	unreconciled (register drift and orphaned zvols) last.
package main

import (
	"sort"
	"strings"
)

// Row is one line of the estate table. Either a real domain (D.Name set) or
// a synthetic row for storage/register entries with no domain behind them.
type Row struct {
	D         Dom
	Backing   string   // dataset name, file path, or "" when diskless
	DS        *Dataset // nil when Backing is not a local dataset
	Origin    string   // DS.Origin — the lineage edge
	SnapTotal int
	SnapHuman int
	Group     string
	Notes     []string
	Synthetic bool // no libvirt domain behind this row
}

// GroupRows is one estate group in render order.
type GroupRows struct {
	Label string
	Rows  []Row
}

// Labels for the two catch-all groups. "ungrouped" = no rule matched (on a
// rules-bearing host that itself hints at drift); "unreconciled" = rows that
// exist only in a register or only as storage.
const (
	groupUngrouped    = "ungrouped"
	groupUnreconciled = "unreconciled"
)

// BuildEstate joins everything into render-ready groups. Never errors:
// missing inputs (nil maps on a ZFS-less host) degrade to emptier rows.
func BuildEstate(doms []Dom, dss map[string]*Dataset,
	snaps map[string][]string, rs *Ruleset, ann *Annotations) []GroupRows {

	if ann == nil {
		ann = &Annotations{}
	}
	rows := make([]Row, 0, len(doms))
	claimed := make(map[string]bool) // dataset name → backs some domain

	for _, d := range doms {
		r := Row{D: d, Group: rs.GroupFor(d.Name)}
		for _, disk := range d.Disks {
			if ds := zvolDataset(disk.Dev); ds != "" {
				r.Backing = ds
				claimed[ds] = true
				if dset, ok := dss[ds]; ok {
					r.DS = dset
					r.Origin = dset.Origin
				}
				break // first zvol is the system disk by every tool's layout
			}
			if disk.File != "" && r.Backing == "" {
				r.Backing = disk.File
			}
		}
		if r.DS != nil {
			sum := rs.SnapSummary(snaps[r.DS.Name])
			for _, n := range sum {
				r.SnapTotal += n
			}
			r.SnapHuman = sum[SnapHuman]
		}
		if note, ok := ann.Markers[d.Name]; ok {
			r.Notes = append(r.Notes, note)
		}
		rows = append(rows, r)
	}

	// Register drift, the direction worth showing: a register claims a VM
	// libvirt does not have. (The reverse is normal — state.db is partial
	// by construction; see reconcile.go.)
	have := make(map[string]bool, len(doms))
	for _, d := range doms {
		have[d.Name] = true
	}
	for name := range ann.StateDB {
		if !have[name] {
			rows = append(rows, Row{
				D: Dom{Name: name, State: "absent"}, Synthetic: true,
				Group: groupUnreconciled,
				Notes: []string{"in state.db, not in libvirt"},
			})
		}
	}
	for name, cluster := range ann.Kspawn {
		if !have[name] {
			rows = append(rows, Row{
				D: Dom{Name: name, State: "absent"}, Synthetic: true,
				Group: groupUnreconciled,
				Notes: []string{"in kspawn manifest (" + cluster + "), not in libvirt"},
			})
		}
	}

	// Orphaned storage: a volume sitting beside domain-backed zvols (same
	// parent dataset) that no domain references — the classic leftover after
	// an undefine that forgot the zvol. Scoped to VM parents so swap zvols
	// and unrelated volumes elsewhere on the pool stay out of the picture.
	parents := make(map[string]bool)
	for ds := range claimed {
		parents[parentDataset(ds)] = true
	}
	var orphans []string
	for name, ds := range dss {
		if ds.Type == "volume" && !claimed[name] && parents[parentDataset(name)] {
			orphans = append(orphans, name)
		}
	}
	sort.Strings(orphans)
	for _, name := range orphans {
		ds := dss[name]
		r := Row{
			D: Dom{Name: baseName(name), State: "no domain"}, Synthetic: true,
			Backing: name, DS: ds, Origin: ds.Origin,
			Group: groupUnreconciled,
			Notes: []string{"zvol without a domain"},
		}
		sum := rs.SnapSummary(snaps[name])
		for _, n := range sum {
			r.SnapTotal += n
		}
		r.SnapHuman = sum[SnapHuman]
		rows = append(rows, r)
	}

	// Group: named A→Z, ungrouped, unreconciled last.
	byGroup := make(map[string][]Row)
	for _, r := range rows {
		label := r.Group
		if label == "" {
			label = groupUngrouped
		}
		byGroup[label] = append(byGroup[label], r)
	}
	var labels []string
	for l := range byGroup {
		if l != groupUngrouped && l != groupUnreconciled {
			labels = append(labels, l)
		}
	}
	sort.Strings(labels)
	if len(byGroup[groupUngrouped]) > 0 {
		labels = append(labels, groupUngrouped)
	}
	if len(byGroup[groupUnreconciled]) > 0 {
		labels = append(labels, groupUnreconciled)
	}
	out := make([]GroupRows, 0, len(labels))
	for _, l := range labels {
		rs := byGroup[l]
		sort.Slice(rs, func(i, j int) bool { return rs[i].D.Name < rs[j].D.Name })
		out = append(out, GroupRows{Label: l, Rows: rs})
	}
	return out
}

// parentDataset returns the dataset one level up ("" at pool root).
func parentDataset(name string) string {
	for i := len(name) - 1; i >= 0; i-- {
		if name[i] == '/' {
			return name[:i]
		}
	}
	return ""
}

// baseName is the last path element of a dataset name.
func baseName(name string) string {
	for i := len(name) - 1; i >= 0; i-- {
		if name[i] == '/' {
			return name[i+1:]
		}
	}
	return name
}

// OriginChain walks origins golden-ward: clone → its origin dataset → that
// dataset's origin … for the detail view's lineage line. Bounded — a cycle
// would mean corrupt pool metadata, but a UI must not hang on it.
func OriginChain(ds *Dataset, dss map[string]*Dataset) []string {
	var chain []string
	for i := 0; ds != nil && ds.Origin != "" && i < 16; i++ {
		chain = append(chain, ds.Origin)
		parent, _, _ := strings.Cut(ds.Origin, "@")
		ds = dss[parent]
	}
	return chain
}
