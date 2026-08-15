// =============================================================================
// state.go — what the post-install build is doing right now.
//
// WHAT IT DOES, IN ORDER:
//   1. reads the phase plan kldload-autodeploy declares in
//      /var/lib/kldload/phases (NN-<name> files holding "<state> <epoch>");
//   2. reads the coarse markers — current-phase, firstboot-done, all-ready;
//   3. folds both into a Progress value the UI can paint without further logic.
//
// WHY IT EXISTS:
//   A kldload install reaches a usable desktop long before it is finished.
//   Something on screen has to say "still working, do not reboot" — and say it
//   honestly. The phase plan is the only source that knows the TOTAL, so a
//   percentage is only ever derived from it; when there is no plan we report
//   no percentage rather than invent one.
//
// INPUTS / OUTPUTS:
//   Reads StateDir (default /var/lib/kldload). Writes nothing, ever — this
//   runs as the desktop user and must never mutate root-owned build state.
//
// Notes:
//   - A phase file with an unparseable body is reported as StatePending rather
//     than dropped. A phase that exists is part of the total even when its
//     contents are garbage; silently shrinking the denominator would make the
//     percentage lie in the reassuring direction, which is the wrong one.
//   - all-ready alone does NOT mean success. autodeploy writes it only when
//     every phase finished; a run that gave up leaves it absent while phases
//     sit in "failed". Done and Ok are therefore separate questions.
// =============================================================================

package main

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// DefaultStateDir is where kldload-firstboot and kldload-autodeploy record
// their progress. Overridable so the tests can run against a fixture tree.
const DefaultStateDir = "/var/lib/kldload"

// PhaseState is the vocabulary autodeploy writes into a phase file. It is
// deliberately the same set of words the bash monitor understands, so the two
// displays can never disagree about what a phase file means.
type PhaseState string

const (
	StateDone    PhaseState = "done"
	StateRunning PhaseState = "running"
	StateFailed  PhaseState = "failed"
	StatePending PhaseState = "pending"
)

// phaseFileRe matches the NN-<name> plan files and captures the name. Files
// that do not match are not part of the plan (README, editor droppings) and
// are ignored rather than counted.
var phaseFileRe = regexp.MustCompile(`^([0-9]{2})-(.+)$`)

// Phase is one declared unit of post-install work.
type Phase struct {
	Order   int           // the NN prefix, so display order matches plan order
	Name    string        // "nvidia-driver", "golden-images", ...
	State   PhaseState    //
	Started time.Time     // zero when the file carried no usable epoch
	Elapsed time.Duration // only meaningful while State == StateRunning
}

// Progress is the whole picture, ready to paint.
type Progress struct {
	Phases    []Phase
	Current   string // contents of current-phase; "" when absent
	FirstBoot bool   // firstboot-done exists
	AllReady  bool   // all-ready exists
	HasPlan   bool   // at least one NN-<name> file was found
}

// Done reports how many phases have completed.
func (p Progress) Done() int {
	n := 0
	for _, ph := range p.Phases {
		if ph.State == StateDone {
			n++
		}
	}
	return n
}

// Failed reports how many phases gave up.
func (p Progress) Failed() int {
	n := 0
	for _, ph := range p.Phases {
		if ph.State == StateFailed {
			n++
		}
	}
	return n
}

// Fraction is completion in [0,1]. It returns ok=false when there is no plan,
// because a percentage invented from an unknown total is worse than none —
// the caller must render "working..." instead of a bar in that case.
func (p Progress) Fraction() (f float64, ok bool) {
	if !p.HasPlan || len(p.Phases) == 0 {
		return 0, false
	}
	return float64(p.Done()) / float64(len(p.Phases)), true
}

// Settled reports whether the build has stopped moving — either because
// everything finished or because what remains has failed and nothing is still
// running. A window that closes on all-ready alone hangs forever on a run that
// gave up, which is the case the operator most needs to see.
func (p Progress) Settled() bool {
	if p.AllReady {
		return true
	}
	if !p.HasPlan {
		return false
	}
	for _, ph := range p.Phases {
		if ph.State == StateRunning || ph.State == StatePending {
			return false
		}
	}
	return true
}

// ReadProgress loads the current build state from dir.
//
// Args:
//
//	dir — a state directory; "" means DefaultStateDir.
//	now — the clock, injected so elapsed times are testable.
//
// Returns: a Progress. Never returns an error: this display must degrade to
// "I cannot tell you" rather than fail. A missing directory is a legitimate
// state (an install that predates the phase plan), not an exception.
func ReadProgress(dir string, now time.Time) Progress {
	if dir == "" {
		dir = DefaultStateDir
	}
	p := Progress{
		Current:   strings.TrimSpace(readFileString(filepath.Join(dir, "current-phase"))),
		FirstBoot: fileExists(filepath.Join(dir, "firstboot-done")),
		AllReady:  fileExists(filepath.Join(dir, "all-ready")),
	}

	entries, err := os.ReadDir(filepath.Join(dir, "phases"))
	if err != nil {
		return p
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		m := phaseFileRe.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		order, err := strconv.Atoi(m[1])
		if err != nil {
			continue
		}
		ph := Phase{Order: order, Name: m[2], State: StatePending}

		// Body is "<state> <epoch>". Both halves are optional in practice:
		// a phase can be marked before it has a start time.
		fields := strings.Fields(readFileString(filepath.Join(dir, "phases", e.Name())))
		if len(fields) > 0 {
			switch PhaseState(fields[0]) {
			case StateDone:
				ph.State = StateDone
			case StateRunning:
				ph.State = StateRunning
			case StateFailed:
				ph.State = StateFailed
			}
		}
		if len(fields) > 1 {
			if sec, err := strconv.ParseInt(fields[1], 10, 64); err == nil && sec > 0 {
				ph.Started = time.Unix(sec, 0)
				if ph.State == StateRunning {
					ph.Elapsed = now.Sub(ph.Started)
				}
			}
		}
		p.Phases = append(p.Phases, ph)
	}
	sort.Slice(p.Phases, func(i, j int) bool { return p.Phases[i].Order < p.Phases[j].Order })
	p.HasPlan = len(p.Phases) > 0
	return p
}

// readFileString returns a file's contents, or "" if it cannot be read. The
// error is deliberately dropped: every caller here treats "absent" and
// "unreadable" identically, and this process has no business reporting on
// permissions of state it only observes.
func readFileString(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
