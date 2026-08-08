// model_test.go — the join itself: domains × datasets × snapshots × rules,
// exercised on a miniature copy of the real estate's shape.
package main

import "testing"

func testEstate() ([]Dom, map[string]*Dataset, map[string][]string) {
	doms := []Dom{
		{Name: "klab-blue-fedora", State: "shut off",
			Disks: []Disk{{Target: "vda", Dev: "/dev/zvol/rpool/vms/klab-blue-fedora"}}},
		{Name: "klab-golden-fedora", State: "shut off",
			Disks: []Disk{{Target: "vda", Dev: "/dev/zvol/rpool/vms/klab-golden-fedora"}}},
		{Name: "legacy-qcow", State: "shut off",
			Disks: []Disk{{Target: "vda", File: "/var/lib/libvirt/images/legacy.qcow2"}}},
	}
	dss := map[string]*Dataset{
		"rpool/vms": {Name: "rpool/vms", Type: "filesystem"},
		"rpool/vms/klab-blue-fedora": {Name: "rpool/vms/klab-blue-fedora",
			Type: "volume", Used: 1 << 30,
			Origin: "rpool/vms/klab-golden-fedora@golden"},
		"rpool/vms/klab-golden-fedora": {Name: "rpool/vms/klab-golden-fedora",
			Type: "volume", Used: 2 << 30},
		"rpool/vms/demo-leftover": {Name: "rpool/vms/demo-leftover",
			Type: "volume", Used: 412 << 20},
		"rpool/swap": {Name: "rpool/swap", Type: "volume"},
	}
	snaps := map[string][]string{
		"rpool/vms/klab-blue-fedora":   {"autosnap_1", "autosnap_2", "manual-x"},
		"rpool/vms/klab-golden-fedora": {"golden", "autosnap_1"},
		"rpool/vms/demo-leftover":      {"autosnap_1"},
	}
	return doms, dss, snaps
}

func findRow(t *testing.T, groups []GroupRows, name string) (Row, string) {
	t.Helper()
	for _, g := range groups {
		for _, r := range g.Rows {
			if r.D.Name == name {
				return r, g.Label
			}
		}
	}
	t.Fatalf("row %q not found", name)
	return Row{}, ""
}

func TestBuildEstateJoin(t *testing.T) {
	doms, dss, snaps := testEstate()
	rs := kldloadRS(t)
	groups := BuildEstate(doms, dss, snaps, rs, nil)

	blue, g := findRow(t, groups, "klab-blue-fedora")
	if g != "klab" {
		t.Errorf("klab-blue-fedora grouped %q, want klab", g)
	}
	if blue.Backing != "rpool/vms/klab-blue-fedora" {
		t.Errorf("backing = %q", blue.Backing)
	}
	if blue.Origin != "rpool/vms/klab-golden-fedora@golden" {
		t.Errorf("origin = %q — the lineage edge is the product", blue.Origin)
	}
	if blue.SnapTotal != 3 || blue.SnapHuman != 1 {
		t.Errorf("snaps = %d✎%d, want 3✎1", blue.SnapTotal, blue.SnapHuman)
	}

	if _, g := findRow(t, groups, "klab-golden-fedora"); g != "goldens" {
		t.Errorf("golden grouped %q", g)
	}

	// file-backed domain: no join, but a row all the same (tier 1)
	qcow, g := findRow(t, groups, "legacy-qcow")
	if g != groupUngrouped {
		t.Errorf("legacy-qcow grouped %q", g)
	}
	if qcow.Backing != "/var/lib/libvirt/images/legacy.qcow2" || qcow.DS != nil {
		t.Errorf("file backing wrong: %+v", qcow)
	}
}

func TestBuildEstateOrphanZvol(t *testing.T) {
	doms, dss, snaps := testEstate()
	groups := BuildEstate(doms, dss, snaps, kldloadRS(t), nil)

	orphan, g := findRow(t, groups, "demo-leftover")
	if g != groupUnreconciled {
		t.Errorf("orphan zvol grouped %q, want %q", g, groupUnreconciled)
	}
	if !orphan.Synthetic || orphan.D.State != "no domain" {
		t.Errorf("orphan row wrong: %+v", orphan)
	}

	// rpool/swap shares no parent with VM zvols — must NOT appear
	for _, g := range groups {
		for _, r := range g.Rows {
			if r.Backing == "rpool/swap" {
				t.Error("rpool/swap surfaced as an orphan — parent scoping broken")
			}
		}
	}
}

func TestBuildEstateRegisterDrift(t *testing.T) {
	doms, dss, snaps := testEstate()
	ann := &Annotations{
		HasStateDB: true,
		StateDB:    map[string]bool{"ghost-vm": true, "klab-blue-fedora": true},
		Kspawn:     map[string]string{},
		Markers:    map[string]string{"klab-blue-fedora": "build pending"},
	}
	groups := BuildEstate(doms, dss, snaps, kldloadRS(t), ann)

	ghost, g := findRow(t, groups, "ghost-vm")
	if g != groupUnreconciled || !ghost.Synthetic {
		t.Errorf("state.db ghost not surfaced: group=%q %+v", g, ghost)
	}

	blue, _ := findRow(t, groups, "klab-blue-fedora")
	if len(blue.Notes) != 1 || blue.Notes[0] != "build pending" {
		t.Errorf("marker note missing: %v", blue.Notes)
	}
}

func TestOriginChain(t *testing.T) {
	_, dss, _ := testEstate()
	chain := OriginChain(dss["rpool/vms/klab-blue-fedora"], dss)
	if len(chain) != 1 || chain[0] != "rpool/vms/klab-golden-fedora@golden" {
		t.Errorf("chain = %v", chain)
	}
}
