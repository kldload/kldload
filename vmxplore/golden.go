// golden.go — Make Golden: turn a prepared VM into a sealed, clonable
// template.
//
// What it does, in order:
//  1. Gracefully shuts the domain down (and waits — virsh shutdown is
//     async; snapshotting a running root would capture a dirty image).
//  2. Seals the disk so every clone boots as a fresh machine: kldload-seal
//     on the zvol where present (the kldload host tool), else virt-sysprep
//     on the domain (the generic libguestfs route), else a loud warning —
//     an unsealed golden means clones share machine-id and ssh host keys.
//  3. Snapshots the zvol @golden — the anchor planCloneGolden clones from.
//
// Why: build one VM carefully — cloud image or a hand-run installer —
// seal it once, stamp out clones for free. This is the klab/kimage golden
// workflow generalized to any ZFS+KVM host, capability-probed as always.
//
// Notes: re-goldening destroys the old @golden first; ZFS refuses while
// clones depend on it, which is exactly the protection an operator wants —
// the error names the clones instead of orphaning them.
package main

import (
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// MakeGolden runs the shutdown → seal → snapshot flow. progress gets one
// line per step and may be called from any goroutine.
func MakeGolden(r Row, progress func(string)) error {
	if r.Synthetic {
		return fmt.Errorf("no domain behind this row")
	}
	if r.DS == nil {
		return fmt.Errorf("%s has no zvol — golden templates need ZFS underneath", r.D.Name)
	}
	name, ds := r.D.Name, r.DS.Name

	// 1 — a clean shutdown, waited for
	state := func() string {
		out, _ := exec.Command("virsh", "-c", "qemu:///system",
			"domstate", name).Output()
		return strings.TrimSpace(string(out))
	}
	if state() == "running" {
		if err := runStep(progress, false,
			"virsh", "-c", "qemu:///system", "shutdown", name); err != nil {
			return err
		}
		progress("waiting for " + name + " to shut down…")
		deadline := time.Now().Add(2 * time.Minute)
		for state() != "shut off" {
			if time.Now().After(deadline) {
				return fmt.Errorf("%s did not shut down within 2 minutes — "+
					"force it off and retry", name)
			}
			time.Sleep(2 * time.Second)
		}
	}

	// 2 — seal (capability-probed; warn loudly rather than fake it)
	switch {
	case havePath("kldload-seal"):
		if err := runStep(progress, true, "kldload-seal", "/dev/zvol/"+ds); err != nil {
			return err
		}
	case havePath("virt-sysprep"):
		if err := runStep(progress, true, "virt-sysprep", "-d", name); err != nil {
			return err
		}
	default:
		progress("WARNING: no seal tool (kldload-seal / virt-sysprep) — " +
			"golden keeps this machine's identity; clones will share machine-id " +
			"and ssh host keys")
	}

	// 3 — the @golden anchor (re-golden replaces the old one; ZFS refuses
	// while clones depend on it, naming them — the right failure)
	if exec.Command("zfs", "list", ds+"@golden").Run() == nil {
		if err := runStep(progress, true, "zfs", "destroy", ds+"@golden"); err != nil {
			return fmt.Errorf("%v — existing clones depend on the old golden; "+
				"delete or promote them first", err)
		}
	}
	if err := runStep(progress, true, "zfs", "snapshot", ds+"@golden"); err != nil {
		return err
	}
	progress(name + " is golden — right-click → Clone stamps out instant copies")
	return nil
}

func havePath(tool string) bool {
	_, err := exec.LookPath(tool)
	return err == nil
}

// planCloneGolden clones FROM the @golden anchor: no new snapshot, the
// clone shares the sealed template's blocks. The GUI picks this over
// planClone whenever @golden exists on the source.
func planCloneGolden(r Row, newName string) (verbPlan, error) {
	p, err := planClone(r, newName) // reuse every gate + the virt-clone leg
	if err != nil {
		return p, err
	}
	parent := r.DS.Name
	if i := strings.LastIndexByte(parent, '/'); i >= 0 {
		parent = parent[:i]
	}
	p.title = "clone golden " + r.D.Name + " → " + newName
	p.cmds = [][]string{
		{"zfs", "clone", r.DS.Name + "@golden", parent + "/" + newName},
		p.cmds[2], // the virt-clone leg, unchanged
	}
	p.warn = "clone of the sealed @golden — boots as a fresh machine"
	return p, nil
}
