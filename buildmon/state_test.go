package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// writePhases lays down a fixture phase plan. Body is written verbatim so the
// tests can feed malformed content on purpose.
func writePhases(t *testing.T, dir string, files map[string]string) {
	t.Helper()
	pd := filepath.Join(dir, "phases")
	if err := os.MkdirAll(pd, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(pd, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestReadProgressOrdersByPrefixAndCounts(t *testing.T) {
	dir := t.TempDir()
	now := time.Unix(1000, 0)
	writePhases(t, dir, map[string]string{
		"30-cluster": "pending 0",
		"10-ai":      "done 900",
		"20-goldens": "running 940",
	})

	p := ReadProgress(dir, now)

	if !p.HasPlan {
		t.Fatal("expected a plan")
	}
	if got, want := len(p.Phases), 3; got != want {
		t.Fatalf("phases = %d, want %d", got, want)
	}
	// Plan order, not directory order.
	for i, want := range []string{"ai", "goldens", "cluster"} {
		if p.Phases[i].Name != want {
			t.Errorf("phase[%d] = %q, want %q", i, p.Phases[i].Name, want)
		}
	}
	if got := p.Done(); got != 1 {
		t.Errorf("Done() = %d, want 1", got)
	}
	// A running phase reports how long it has been going, from the injected clock.
	if got, want := p.Phases[1].Elapsed, 60*time.Second; got != want {
		t.Errorf("Elapsed = %v, want %v", got, want)
	}
	if f, ok := p.Fraction(); !ok || f != 1.0/3.0 {
		t.Errorf("Fraction() = %v, %v; want 1/3, true", f, ok)
	}
}

// A percentage invented from an unknown total is worse than no percentage —
// with no plan on disk, Fraction must refuse rather than report 0%.
func TestFractionRefusesWithoutAPlan(t *testing.T) {
	p := ReadProgress(t.TempDir(), time.Now())
	if p.HasPlan {
		t.Fatal("expected no plan")
	}
	if _, ok := p.Fraction(); ok {
		t.Error("Fraction() reported ok with no plan; it must refuse")
	}
}

// A garbage phase file must still count toward the total. Dropping it would
// shrink the denominator and make the percentage lie in the reassuring
// direction, which is exactly the wrong direction.
func TestUnparseablePhaseStillCountsAsPending(t *testing.T) {
	dir := t.TempDir()
	writePhases(t, dir, map[string]string{
		"10-ai":      "done 900",
		"20-goldens": "\x00garbage",
		"30-cluster": "",
	})

	p := ReadProgress(dir, time.Unix(1000, 0))

	if got, want := len(p.Phases), 3; got != want {
		t.Fatalf("phases = %d, want %d — a phase that exists is part of the total", got, want)
	}
	if p.Phases[1].State != StatePending {
		t.Errorf("garbage phase state = %q, want %q", p.Phases[1].State, StatePending)
	}
	if f, _ := p.Fraction(); f != 1.0/3.0 {
		t.Errorf("Fraction() = %v, want 1/3", f)
	}
}

// Files that are not NN-<name> are not part of the plan.
func TestNonPlanFilesIgnored(t *testing.T) {
	dir := t.TempDir()
	writePhases(t, dir, map[string]string{
		"10-ai":     "done 1",
		"README":    "not a phase",
		"notes.swp": "junk",
		"5-short":   "done 1", // single digit: not the NN- form
	})

	p := ReadProgress(dir, time.Unix(1000, 0))

	if got, want := len(p.Phases), 1; got != want {
		t.Fatalf("phases = %d, want %d", got, want)
	}
}

// The case that matters most: a run that gave up. all-ready is absent, so a
// display gated on it alone would spin forever — but nothing is still moving,
// so the build has in fact settled and the operator needs to be told.
func TestSettledWhenFailedAndNothingRunning(t *testing.T) {
	dir := t.TempDir()
	writePhases(t, dir, map[string]string{
		"10-ai":      "done 1",
		"20-goldens": "failed 2",
	})

	p := ReadProgress(dir, time.Unix(1000, 0))

	if p.AllReady {
		t.Fatal("fixture should not have all-ready")
	}
	if !p.Settled() {
		t.Error("Settled() = false; a run with no running phases has stopped, even without all-ready")
	}
	if got := p.Failed(); got != 1 {
		t.Errorf("Failed() = %d, want 1", got)
	}
}

func TestNotSettledWhileAPhaseRuns(t *testing.T) {
	dir := t.TempDir()
	writePhases(t, dir, map[string]string{
		"10-ai":      "done 1",
		"20-goldens": "running 2",
	})
	if ReadProgress(dir, time.Unix(1000, 0)).Settled() {
		t.Error("Settled() = true while a phase is running")
	}
}

func TestAllReadySettlesEvenWithoutAPlan(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "all-ready"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	p := ReadProgress(dir, time.Unix(1000, 0))
	if !p.AllReady || !p.Settled() {
		t.Error("all-ready must settle the display")
	}
}

// fiend 2026-09-14, 5-desktop: autodeploy had nothing to do, so it wrote no
// plan and no all-ready, and the window said "Building — do not reboot"
// indefinitely. A skipped autodeploy after first boot is a finished build.
func TestSkippedAutodeploySettlesOnceFirstBootIsDone(t *testing.T) {
	dir := t.TempDir()
	for _, f := range []string{"autodeploy-skipped", "firstboot-done"} {
		if err := os.WriteFile(filepath.Join(dir, f), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "current-phase"), []byte("nothing-requested\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	p := ReadProgress(dir, time.Unix(1000, 0))
	if !p.Skipped || !p.Settled() {
		t.Fatalf("Skipped=%v Settled=%v; want both true", p.Skipped, p.Settled())
	}
	if lvl, msg := (Snapshot{Progress: p}).Verdict(); lvl != LevelReady {
		t.Errorf("Verdict = %v %q; want LevelReady", lvl, msg)
	}
}

// ...but not while first boot is still running: the skip marker only speaks
// for autodeploy.
func TestSkippedAutodeployDoesNotSettleDuringFirstBoot(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "autodeploy-skipped"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if ReadProgress(dir, time.Unix(1000, 0)).Settled() {
		t.Error("Settled() = true before firstboot-done")
	}
}

func TestMarkersAndCurrentPhase(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "current-phase"), []byte("  goldens \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "firstboot-done"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	p := ReadProgress(dir, time.Unix(1000, 0))
	if p.Current != "goldens" {
		t.Errorf("Current = %q, want %q", p.Current, "goldens")
	}
	if !p.FirstBoot {
		t.Error("FirstBoot = false, want true")
	}
	if p.AllReady {
		t.Error("AllReady = true, want false")
	}
}
