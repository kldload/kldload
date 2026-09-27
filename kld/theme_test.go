package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// The spelling the operator asked for, 2026-09-27: "(s)tart", not "S start".
func TestMnemonic(t *testing.T) {
	cases := []struct{ key, label, want string }{
		{"S", "start", "(S)tart"},
		{"s", "snapshot", "(s)napshot"},
		{"T", "shutdown", "shu(T)down"},
		{"K", "force off", "(K) force off"},
		{"b", "rollback to the newest snapshot", "roll(b)ack to the newest snapshot"},
		{"s", "set a snapshot", "(s)et a snapshot"},
		{"e", "enrol on the mesh", "(e)nrol on the mesh"},
		{"+", "grow the root disk", "(+) grow the root disk"},
		{"enter", "snapshots", "(enter) snapshots"},
		{"o", "sort", "s(o)rt"},
		{"g", "make golden", "make (g)olden"}, // a later word's start beats no match in the first
	}
	for _, c := range cases {
		if got := ansi.Strip(mnemonic(c.key, c.label, false)); got != c.want {
			t.Errorf("mnemonic(%q, %q) = %q, want %q", c.key, c.label, got, c.want)
		}
	}
}

func TestShortLabel(t *testing.T) {
	if got := shortLabel("make golden (shut down, seal, @golden)"); got != "make golden" {
		t.Errorf("shortLabel cut = %q", got)
	}
	if got := shortLabel("rollback to the newest snapshot"); got != "rollback" {
		t.Errorf("shortLabel long = %q, want %q", got, "rollback")
	}
	if got := shortLabel("reconcile an unreconciled row"); got != "reconcile" {
		t.Errorf("shortLabel = %q, want %q", got, "reconcile")
	}
}

func TestIsDanger(t *testing.T) {
	for _, l := range []string{"delete VM + zvol", "force off", "destroy snapshot", "roll back (the root goes through a boot environment)"} {
		if !isDanger(l) {
			t.Errorf("%q should be a danger verb", l)
		}
	}
	for _, l := range []string{"start", "snapshot", "clone", "screen (video console)"} {
		if isDanger(l) {
			t.Errorf("%q should not be a danger verb", l)
		}
	}
}

// The name column keeps its width; other columns drop off instead.
func TestColumnWidthsKeepsTheName(t *testing.T) {
	cols := []string{"vm", "group", "state", "cpu", "boot", "vcpus", "memory", "address", "clone of", "snaps", "mesh", "role", "notes"}
	rows := [][]string{{"app-jellyfin-on-zfs", "apps", "shut off", "-", "off", "2", "2.0G", "192.168.122.14", "klab-golden-debian", "10", "150", "vm", "-"}}
	w := columnWidths(cols, rows, 70)
	if w[0] != len("app-jellyfin-on-zfs") {
		t.Errorf("name column = %d, want %d", w[0], len("app-jellyfin-on-zfs"))
	}
	total, n := 0, 0
	for _, x := range w {
		if x > 0 {
			total += x
			n++
		}
	}
	if total+2*(n-1) > 70 {
		t.Errorf("columns take %d cells, more than 70", total+2*(n-1))
	}
	if w[len(w)-1] != 0 {
		t.Errorf("the last column should have been dropped at 70 cells, got %d", w[len(w)-1])
	}
}

func TestPackMenuFitsWidth(t *testing.T) {
	var items []string
	for _, l := range []string{"start", "shutdown", "reboot", "force off", "clone", "snapshot", "delete VM + zvol", "suspend", "resume"} {
		items = append(items, mnemonic(string(l[0]), l, false))
	}
	for _, w := range []int{60, 90, 120} {
		for _, line := range packMenu(items, w) {
			if got := menuTargetW + 2 + ansi.StringWidth(strings.Join(line, "  ")); got > w {
				t.Errorf("width %d: a menu line takes %d", w, got)
			}
		}
	}
}

// The frame never changes height or moves its menu when a refresh brings
// longer values: the old right-hand pane wrapped a long value, grew, and
// pushed the menu down (the operator, 2026-09-27: "the menu part jumps
// around"). Rendered twice, short values then very long ones.
func TestViewHeightStableAcrossRefresh(t *testing.T) {
	frame := func(long bool) []string {
		m := newModel(1, 0, 120) // Machines / VMs
		m.height = 40
		v := "2.0G"
		extra := []string{"disks", "vda\t/dev/zvol/rpool/vms/app"}
		if long {
			v = strings.Repeat("9", 90)
			extra = append(extra, "nics", "52:54:00:62:19:02\t"+strings.Repeat("default (virtio) ", 12))
		}
		m.data[m.key()] = &sectionData{headline: "1 machine",
			columns: []string{"vm", "group", "state", "memory", "notes"},
			rows:    [][]string{{"app-jellyfin", "apps", "running", v, v}}}
		m.details[m.key()+"\x00app-jellyfin"] = extra
		return strings.Split(m.View(), "\n")
	}
	ruleRow := func(lines []string) int {
		r := -1
		for i, l := range lines {
			if strings.HasPrefix(ansi.Strip(l), strings.Repeat("─", 40)) {
				r = i
			}
		}
		return r
	}
	short, long := frame(false), frame(true)
	if len(short) != 40 || len(long) != 40 {
		t.Fatalf("frame heights %d and %d, want 40 both", len(short), len(long))
	}
	if a, b := ruleRow(short), ruleRow(long); a != b || a < 0 {
		t.Errorf("menu rule at row %d with short values, %d with long", a, b)
	}
	for i, l := range long {
		if w := ansi.StringWidth(l); w > 120 {
			t.Errorf("line %d is %d cells wide, over 120", i, w)
		}
	}
}
