package main

import (
	"strings"
	"testing"
)

// navigationKeys are taken by the console itself; a verb on one of them
// would never fire (h and k were hold and bookmark for an afternoon and
// went to "previous section" and "row up" instead, 2026-09-26).
var navigationKeys = map[string]bool{
	"q": true, "?": true, "l": true, "h": true, "tab": true, "[": true, "]": true,
	"1": true, "2": true, "3": true, "4": true, "5": true, "6": true, "7": true, "8": true, "9": true, "0": true,
	"j": true, "k": true, "g": true, "G": true, "/": true, "o": true, "i": true, "r": true, "esc": true, "enter": true, " ": true,
}

func TestVerbKeysDoNotCollideWithNavigation(t *testing.T) {
	for tab, vs := range verbs {
		seen := map[string]bool{}
		for _, v := range vs {
			if navigationKeys[v.key] {
				t.Errorf("%s: verb %q uses navigation key %q", tab, v.label, v.key)
			}
			if seen[v.key] {
				t.Errorf("%s: key %q is bound twice", tab, v.key)
			}
			seen[v.key] = true
			// a picker is a verb's action too: it opens entries that each run
			// (the guided build, the clone wizard)
			if v.argv == nil && v.ctxArgv == nil && v.rowCtxArgv == nil && v.argvs == nil && v.console == conNone && v.picker == nil {
				t.Errorf("%s: verb %q builds no command", tab, v.label)
			}
		}
	}
}

func TestEveryTabHasACollector(t *testing.T) {
	for _, s := range sections {
		for _, sub := range s.subs {
			if _, ok := collectors[s.name+"/"+sub]; !ok {
				t.Errorf("%s/%s has no collector", s.name, sub)
			}
		}
	}
	for key := range verbs {
		sec, sub, _ := strings.Cut(key, "/")
		i := sectionIndex(sec)
		if i < 0 || subIndex(i, sub) < 0 {
			t.Errorf("verbs for %q, which is not a tab", key)
		}
	}
}

// Every X example is a value X itself accepts: an example that fails its
// own validation would be worse than an empty prompt.
func TestBuildArgExamplesPassX(t *testing.T) {
	var x *verb
	for i, v := range verbs["Machines/Build"] {
		if v.key == "X" {
			x = &verbs["Machines/Build"][i]
		}
	}
	if x == nil || x.example == nil {
		t.Fatal("Machines/Build has no X verb with an example")
	}
	for _, kind := range []string{"distro", "format", "workers", "moreworkers", "cps", "golden", "vm"} {
		row := []string{"row", "", "", "", "klab golden all", kind}
		hint, val := x.example(row)
		if hint == "" || val == "" {
			t.Errorf("%s: no hint or no value (%q, %q)", kind, hint, val)
			continue
		}
		if _, err := x.argvs(row, val); err != nil {
			t.Errorf("%s: example %q fails X's validation: %v", kind, val, err)
		}
	}
}

// Rollback on a VM row is refused while the VM runs (kvm-snap would kill it),
// before any prompt, and asks for the name otherwise; the snapshot-row
// rollback, which also destroys every newer snapshot, asks for the name too.
func TestRollbackIsGuarded(t *testing.T) {
	find := func(tab, key string) verb {
		for _, v := range verbs[tab] {
			if v.key == key {
				return v
			}
		}
		t.Fatalf("%s has no %q", tab, key)
		return verb{}
	}
	vm := find("Machines/VMs", "b")
	if !vm.confirm || vm.refuse == nil {
		t.Fatalf("VMs b: confirm=%v refuse set=%v, want both", vm.confirm, vm.refuse != nil)
	}
	if err := vm.refuse([]string{"web1", "g", "running"}); err == nil {
		t.Error("VMs b: a running VM was not refused")
	}
	if err := vm.refuse([]string{"web1", "g", "shut off"}); err != nil {
		t.Errorf("VMs b: a shut-off VM was refused: %v", err)
	}
	if snap := find("Machines/Snapshots", "b"); !snap.confirm {
		t.Error("Snapshots b: rolls back and destroys newer snapshots without a typed confirm")
	}
}
