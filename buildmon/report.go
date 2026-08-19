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
	"context"
	"fmt"
	"os/exec"
	"strings"
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

	// FailedUnits is `systemctl --failed`, and it is in the verdict for a
	// reason. On 2026-08-19 kldload-firstboot died at line 55 of 3698 on a
	// fresh install. The machine still booted, the desktop still came up and
	// NVIDIA still worked, so it looked fine — the operator found it three
	// symptoms later, from icons that had not been pinned. The failure sat in
	// `systemctl --failed` the whole time and nothing put it in front of
	// anyone. A script that fails loudly into a log nobody reads is
	// indistinguishable from one that did not fail at all.
	FailedUnits []string
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
	s.FailedUnits = failedUnits(o.Timeout)
	return s
}

// failedUnits returns the names of systemd units in the failed state.
//
// Returns an empty slice when systemctl is absent, times out, or reports
// nothing — a reading we could not take must not masquerade as a clean bill
// of health, but it must not invent a problem either. The caller reports only
// what is actually listed.
func failedUnits(timeout time.Duration) []string {
	if _, err := exec.LookPath("systemctl"); err != nil {
		return nil
	}
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "systemctl", "--failed",
		"--no-legend", "--plain", "--no-pager").Output()
	if err != nil {
		return nil
	}
	var names []string
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) > 0 && strings.HasSuffix(f[0], ".service") {
			names = append(names, f[0])
		}
	}
	return names
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
	// Ranked directly under audit criticals and above everything else: a unit
	// that failed is a concrete, already-happened fault, whereas an unsettled
	// build is only a fault if it stays that way.
	if n := len(s.FailedUnits); n > 0 {
		return LevelProblem, fmt.Sprintf("%d systemd unit(s) failed — %s",
			n, strings.Join(s.FailedUnits, ", "))
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

// Complete reports whether the build has finished successfully, which is the
// question the progress bar should answer.
//
// It is NOT the same as "every phase file says done". autodeploy writes the
// all-ready marker and then exits, and the final phase file is left saying
// "running" -- so a finished machine showed a headline of "This system is
// ready" above a bar stuck at 6 of 7, 85%, which reads as an install that
// stalled at the last step (reported 2026-08-15). The marker is the
// authority on completion; the phase files are the authority on detail.
func (s Snapshot) Complete() bool {
	lvl, _ := s.Verdict()
	return lvl == LevelReady
}

// Headline is the Verdict sentence alone.
func (s Snapshot) Headline() string { _, msg := s.Verdict(); return msg }
