//go:build gui

// fleet.go — the one-click fleet: build a golden image, then stamp N clones
// off it. The "EZ build/clone" button.
//
// What it does, in order:
//  1. BuildNewVM to create the source (cloud image + optional post-install,
//     or an installer ISO the operator has already provisioned).
//  2. Waits for cloud-init to settle, then MakeGolden (seal + @golden).
//  3. Stamps count clones off @golden via planCloneGolden + runPlan,
//     each an instant zero-copy ZFS clone.
//
// Why: this is the whole value proposition in one gesture — "give me five
// Fedora boxes." The primitives already exist and are each tested; this is
// the orchestration that turns them into a fleet. Cloud mode only: a golden
// must be a finished system, which an unattended cloud image is and a
// half-run ISO installer is not.
//
// Notes: the settle wait is a fixed pause, not a probe — cloud-init has no
// host-visible "done" without a guest agent round-trip; 90s covers a base
// image plus a short post-install. A longer post-install just means the
// first clones boot a little earlier in its tail; the golden is still sealed
// from a shut-down disk, so they are consistent.
package main

import (
	"fmt"
	"time"
)

// BuildFleet runs source → golden → N clones. progress streams one line per
// step. Clone names are <base>-1..<base>-N. Returns the first error; clones
// already made stay made (each is independent).
func BuildFleet(spec NewVMSpec, count int, zfsParent string, progress func(string)) error {
	if spec.install() {
		return fmt.Errorf("fleet needs a cloud image (a golden must be a finished system)")
	}
	if count < 1 || count > 64 {
		return fmt.Errorf("clone count must be 1–64")
	}
	if zfsParent == "" {
		return fmt.Errorf("fleet needs a ZFS home for VMs (clones are zvol clones)")
	}

	progress(fmt.Sprintf("[1/3] building golden source %q…", spec.Name))
	if err := BuildNewVM(spec, zfsParent, progress); err != nil {
		return fmt.Errorf("build source: %w", err)
	}

	// let the base image (and any post-install) settle before sealing
	progress("[2/3] letting first boot settle (90s), then sealing golden…")
	time.Sleep(90 * time.Second)
	src := Row{
		D:  Dom{Name: spec.Name, State: "running"},
		DS: &Dataset{Name: zfsParent + "/" + spec.Name},
	}
	if err := MakeGolden(src, progress); err != nil {
		return fmt.Errorf("make golden: %w", err)
	}

	progress(fmt.Sprintf("[3/3] stamping %d clones off the golden…", count))
	for i := 1; i <= count; i++ {
		cn := fmt.Sprintf("%s-%d", spec.Name, i)
		plan, err := planCloneGolden(src, cn)
		if err != nil {
			return fmt.Errorf("plan clone %s: %w", cn, err)
		}
		progress(fmt.Sprintf("  clone %d/%d → %s", i, count, cn))
		if err := runPlan(plan); err != nil {
			return fmt.Errorf("clone %s: %w", cn, err)
		}
	}
	progress(fmt.Sprintf("fleet ready: %s (golden) + %d clones", spec.Name, count))
	return nil
}
