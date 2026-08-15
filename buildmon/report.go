// =============================================================================
// report.go — one snapshot of the whole machine, and the single verdict.
//
// WHAT IT DOES:
//   Gathers the four data sources into one Snapshot, and reduces it to one
//   Verdict — the sentence at the top of the window.
//
// WHY IT EXISTS:
//   The four sources answer different questions (what is running, did the
//   install work, is the system healthy, what is installed) and an operator
//   should not have to correlate them. Reducing them to one headline is the
//   whole job: "still building", "ready", or "finished, but something is
//   wrong — here is the worst thing".
//
//   It also keeps the GUI and the terminal fallback honest: both render THIS,
//   so they cannot disagree about the state of the machine.
//
// Notes:
//   - Gather is tolerant by design. A missing kldload-doctor or
//     kldload-component is not an error — it means that helper is not on this
//     profile — and the snapshot simply carries fewer sections.
//   - Verdict ranks a broken install ABOVE a still-running build. A machine
//     with no kernel is not "in progress", however many phases remain.
// =============================================================================

package main

import (
	"fmt"
	"time"
)

// Level is the overall condition, and drives the headline colour.
type Level int

const (
	LevelBuilding Level = iota // work in flight, nothing known-broken
	LevelReady                 // finished, nothing to report
	LevelProblem               // something needs a human
)

// Snapshot is everything the tool knows at one instant.
type Snapshot struct {
	Taken      time.Time
	Progress   Progress
	Findings   []Finding
	Doctor     DoctorReport
	DoctorErr  error
	Components []Component
	CompErr    error
}

// GatherOpts lets tests and the CLI point the collectors somewhere else.
type GatherOpts struct {
	StateDir     string // "" → DefaultStateDir
	Root         string // "" → "/"
	DoctorBin    string // "" → DoctorBin
	ComponentBin string // "" → ComponentBin
	SkipDoctor   bool   // doctor is slow; the progress view refreshes without it
	Timeout      time.Duration
	Now          time.Time
}

// Gather collects one Snapshot.
//
// Returns: a Snapshot, always. Per-section failures are recorded in the
// snapshot (DoctorErr, CompErr) rather than aborting the whole reading — a
// machine where kubectl hangs must still be able to show its build progress.
func Gather(o GatherOpts) Snapshot {
	now := o.Now
	if now.IsZero() {
		now = time.Now()
	}
	s := Snapshot{
		Taken:    now,
		Progress: ReadProgress(o.StateDir, now),
		Findings: Audit(o.Root),
	}
	if !o.SkipDoctor {
		s.Doctor, s.DoctorErr = RunDoctor(o.DoctorBin, o.Timeout)
	}
	s.Components, s.CompErr = ListComponents(o.ComponentBin, o.Timeout)
	return s
}

// Criticals counts audit findings that make the machine broken rather than
// merely imperfect.
func (s Snapshot) Criticals() int {
	n := 0
	for _, f := range s.Findings {
		if f.Severity == SevCritical {
			n++
		}
	}
	return n
}

// Verdict reduces the snapshot to a level and one sentence.
//
// The ORDER of these tests is the design. A broken install outranks a running
// build, because "still working..." on a machine with no kernel is a lie that
// costs the operator hours — which is precisely what happened on 2026-08-15.
func (s Snapshot) Verdict() (Level, string) {
	if n := s.Criticals(); n > 0 {
		worst := ""
		for _, f := range s.Findings {
			if f.Severity == SevCritical {
				worst = f.Message
				break
			}
		}
		return LevelProblem, fmt.Sprintf("%d critical problem(s) with this install — %s", n, worst)
	}
	if s.Progress.Failed() > 0 {
		return LevelProblem, fmt.Sprintf("%d build phase(s) failed — see Progress", s.Progress.Failed())
	}
	if s.DoctorErr == nil && s.Doctor.Count("fail") > 0 {
		return LevelProblem, fmt.Sprintf("%d health check(s) failing — see Doctor", s.Doctor.Count("fail"))
	}
	if !s.Progress.Settled() {
		if s.Progress.HasPlan {
			return LevelBuilding, fmt.Sprintf("Building — %d of %d phases complete. Do not reboot.",
				s.Progress.Done(), len(s.Progress.Phases))
		}
		return LevelBuilding, "Building — do not reboot."
	}
	return LevelReady, "This system is ready."
}

// Headline is the Verdict sentence alone.
func (s Snapshot) Headline() string { _, msg := s.Verdict(); return msg }
