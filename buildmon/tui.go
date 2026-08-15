// =============================================================================
// tui.go — the text view: the same Snapshot, on a terminal.
//
// WHY IT IS DELIBERATELY DUMB:
//   It prints whole frames and lets the terminal scroll. It does NOT home the
//   cursor and overwrite the previous frame, which is what the bash monitor did
//   — and which corrupts irrecoverably the moment a second writer touches the
//   same screen (.145, 2026-08-15: one pane painted by two monitors, duplicated
//   Phase/Elapsed/Progress blocks and a smeared banner). Scrolling output can
//   be interleaved by a second writer, but it can never be *destroyed* by one,
//   and it survives being piped into a file or a log.
//
//   The GUI is the nice one. This exists so a server profile, an SSH session
//   and a machine whose GPU driver is still building all get the same answers.
//
// Notes:
//   - No ANSI at all when stdout is not a terminal, so `kldload-buildmon tui
//     | tee` produces a readable log rather than escape soup.
// =============================================================================

package main

import (
	"fmt"
	"os"
	"strings"
	"time"
)

// ANSI, applied only when stdout is a terminal.
const (
	cReset = "\033[0m"
	cBold  = "\033[1m"
	cGreen = "\033[32m"
	cAmber = "\033[33m"
	cRed   = "\033[31m"
	cDim   = "\033[2m"
)

// colourise reports whether to emit ANSI. A pipe or a file gets none.
func colourise() bool {
	fi, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

type painter struct{ on bool }

func (p painter) wrap(code, s string) string {
	if !p.on {
		return s
	}
	return code + s + cReset
}

// RunTUI prints a frame every few seconds until the build settles.
func RunTUI(opt GatherOpts) error {
	p := painter{on: colourise()}
	for {
		o := opt
		o.SkipDoctor = true
		snap := Gather(o)
		printFrame(p, snap)

		if snap.Progress.Settled() {
			return nil
		}
		time.Sleep(5 * time.Second)
	}
}

func printFrame(p painter, s Snapshot) {
	lvl, msg := s.Verdict()
	col := cAmber
	switch lvl {
	case LevelReady:
		col = cGreen
	case LevelProblem:
		col = cRed
	}

	fmt.Println()
	fmt.Println(p.wrap(cBold+col, "  "+msg))
	if lvl == LevelBuilding {
		fmt.Println(p.wrap(cDim, "  The desktop is ready early on purpose. Do not reboot or power off."))
	}
	fmt.Println()

	if s.Progress.HasPlan {
		fmt.Printf("  %s %d of %d phases complete\n\n",
			p.wrap(cBold, "Progress"), s.Progress.Done(), len(s.Progress.Phases))
		for _, ph := range s.Progress.Phases {
			icon, right, c := "·", "pending", cDim
			switch ph.State {
			case StateDone:
				icon, right, c = "✓", "done", cGreen
			case StateRunning:
				icon, right, c = "▶", fmtDurTUI(ph.Elapsed), cAmber
			case StateFailed:
				icon, right, c = "✗", "FAILED", cRed
			}
			fmt.Printf("    %s %-24s %s\n", p.wrap(c, icon), ph.Name, p.wrap(cDim, right))
		}
		fmt.Println()
	}

	if n := len(s.Findings); n > 0 {
		fmt.Printf("  %s %d finding(s), %d critical\n",
			p.wrap(cBold, "Install audit"), n, s.Criticals())
		shown := 0
		for _, f := range s.Findings {
			if f.Severity != SevCritical {
				continue
			}
			where := f.Source
			if f.Line > 0 {
				where = fmt.Sprintf("%s:%d", f.Source, f.Line)
			}
			fmt.Printf("    %s %s  %s\n", p.wrap(cRed, "✗"), where, f.Message)
			if shown++; shown >= 5 {
				break
			}
		}
		if s.Criticals() > shown {
			fmt.Printf("    %s\n", p.wrap(cDim,
				fmt.Sprintf("… and %d more — run: kldload-buildmon audit", s.Criticals()-shown)))
		}
		fmt.Println()
	}

	if tail := logTail("/var/log/kldload/autodeploy.log", 8); tail != "" {
		fmt.Println(p.wrap(cDim, "  /var/log/kldload/autodeploy.log"))
		for _, l := range strings.Split(strings.TrimRight(tail, "\n"), "\n") {
			fmt.Println("    " + l)
		}
	}
}

func fmtDurTUI(d time.Duration) string {
	if d <= 0 {
		return "running"
	}
	d = d.Round(time.Second)
	return fmt.Sprintf("%dm %02ds", int(d.Minutes()), int(d.Seconds())%60)
}
