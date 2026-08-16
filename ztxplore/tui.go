// =============================================================================
// tui.go — the whole console as text.
//
// WHAT IT DOES:
//   Prints one frame carrying every section the window has — lab status,
//   the latest matrix, ARC and pool metrics, and the kernel's recent ZFS
//   messages — then refreshes it on a timer.
//
// WHY IT EXISTS:
//   The lab runs on a hypervisor, and hypervisors are headless. A developer
//   watching a matrix run over ssh needs the same answers as one sitting at
//   the desktop, and "run six different commands instead" is exactly the
//   scattering this application exists to end.
//
// WHY IT SCROLLS RATHER THAN REPAINTS:
//   It prints whole frames and lets the terminal scroll, instead of homing
//   the cursor and overwriting. In-place repainting corrupts irrecoverably
//   the moment a second writer touches the same screen, and during a test run
//   there is always a second writer. Scrolling output can be interleaved but
//   never destroyed, and it survives being piped to a file.
//
// Notes:
//   - No ANSI when stdout is not a terminal, so `ztx --tui | tee` is a log
//     rather than escape soup.
// =============================================================================

package main

import (
	"fmt"
	"os"
	"strings"
	"time"
)

const (
	cReset = "\033[0m"
	cBold  = "\033[1m"
	cGreen = "\033[32m"
	cAmber = "\033[33m"
	cRed   = "\033[31m"
	cDim   = "\033[2m"
	cCyan  = "\033[36m"
)

// tuiColour reports whether to emit ANSI. A pipe or a file gets none.
func tuiColour() bool {
	fi, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

type paint struct{ on bool }

func (p paint) w(code, s string) string {
	if !p.on {
		return s
	}
	return code + s + cReset
}

// RunTUI prints frames until interrupted. Returns a process exit status.
func RunTUI(resultsDir string) int {
	p := paint{on: tuiColour()}
	for {
		printTUIFrame(p, resultsDir)
		// Long enough that a test run's own output stays readable between
		// frames, short enough to watch metrics move.
		time.Sleep(10 * time.Second)
	}
}

func printTUIFrame(p paint, resultsDir string) {
	fmt.Println()
	fmt.Println(p.w(cBold+cCyan, "  OpenZFS Test Lab"))
	fmt.Println(p.w(cDim, "  "+time.Now().Format("2006-01-02 15:04:05")))
	fmt.Println()

	// ── the matrix ──
	fmt.Println(p.w(cBold, "  Latest run"))
	run, err := LatestRun(resultsDir)
	if err != nil {
		fmt.Println("    " + p.w(cDim, err.Error()))
	} else {
		col := cGreen
		if run.Failed() > 0 {
			col = cRed
		} else if run.Incomplete() > 0 {
			col = cAmber
		}
		fmt.Printf("    %s  %s\n", run.ID, p.w(col, run.Verdict()))
		for _, d := range run.Results {
			mark, c := "✓", cGreen
			switch {
			case d.Incomplete:
				mark, c = "?", cAmber
			case d.Fail > 0:
				mark, c = "✗", cRed
			}
			fmt.Printf("      %s %-12s %6d pass %6d fail %6d skip\n",
				p.w(c, mark), d.Distro, d.Pass, d.Fail, d.Skip)
		}
	}
	fmt.Println()

	// ── ARC ──
	fmt.Println(p.w(cBold, "  ARC"))
	arc := ReadARC("")
	if !arc.Available {
		fmt.Println("    " + p.w(cAmber, arc.Why))
	} else {
		fmt.Printf("    size %s / target %s (max %s)\n",
			humanBytes(arc.Size), humanBytes(arc.Target), humanBytes(arc.Max))
		hr := arc.HitRate()
		c := cGreen
		if hr < 80 {
			c = cAmber
		}
		fmt.Printf("    hit rate %s   mfu %s  mru %s\n",
			p.w(c, fmt.Sprintf("%.1f%%", hr)),
			humanBytes(arc.MFUSize), humanBytes(arc.MRUSize))
	}
	fmt.Println()

	// ── pools ──
	fmt.Println(p.w(cBold, "  Pool I/O"))
	if pools, err := ReadPoolIO(5 * time.Second); err != nil {
		fmt.Println("    " + p.w(cDim, err.Error()))
	} else {
		for _, pl := range pools {
			fmt.Printf("    %-12s read %d ops %s/s   write %d ops %s/s   (%s free)\n",
				pl.Pool, pl.ReadOps, humanBytes(pl.ReadBW),
				pl.WriteOps, humanBytes(pl.WriteBW), humanBytes(pl.Free))
		}
	}
	fmt.Println()

	// ── the kernel ──
	// Only the classified lines: on a busy host the full buffer would push
	// everything above it off the screen, and the ZFS lines are the reason
	// this section exists.
	fmt.Println(p.w(cBold, "  Kernel — ZFS, warnings and worse"))
	lines, err := ReadKernelLog(400, 5*time.Second)
	if err != nil {
		fmt.Println("    " + p.w(cAmber, err.Error()))
	} else {
		shown := 0
		for i := len(lines) - 1; i >= 0 && shown < 12; i-- {
			l := lines[i]
			if l.Severity == KernNormal {
				continue
			}
			c := cCyan
			switch l.Severity {
			case KernCritical:
				c = cRed
			case KernWarn:
				c = cAmber
			}
			fmt.Println("    " + p.w(c, truncate(l.Text, 150)))
			shown++
		}
		if shown == 0 {
			fmt.Println("    " + p.w(cDim, "nothing from ZFS in the recent buffer"))
		}
	}
	fmt.Println()
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return strings.TrimSpace(s[:n]) + "…"
}
