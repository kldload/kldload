// =============================================================================
// reattach.go — find a test run that is already going, and adopt it.
//
// WHAT IT DOES:
//   Answers two questions at startup: is a kzfs-test run in flight, and which
//   directory is it writing to. The GUI uses that to reattach — stream the
//   live logs and offer a working Stop — instead of opening blank.
//
// WHY IT EXISTS:
//   The runs are long. A full matrix is hours, and the operator does not sit
//   in front of it: they start it, close the console, and come back. Closing
//   the window does not kill the run — the process is reparented to systemd
//   and keeps going — but reopening showed an empty console with no status,
//   no output and a Stop that controlled nothing, on a machine the operator
//   could literally hear working (fiend, 2026-08-16).
//
//   The web UI already had this idea as `detached_reattach`; this is the same
//   contract for the console.
//
// Notes:
//   - Detection is by PROCESS, not by a pidfile: a pidfile outlives a crash
//     and would claim a run was live when it was not.
//   - The run directory comes from the `latest` symlink the runner publishes,
//     so this agrees with klab-exporter rather than guessing a second way.
// =============================================================================

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// ActiveRun describes a kzfs-test run that is executing right now.
type ActiveRun struct {
	PIDs  []int    // the kzfs-test processes, worst case more than one
	Dir   string   // run directory, e.g. /root/kzfs-test/20260816-201611
	RunID string   // basename of Dir
	Logs  []string // per-distro .log files present in Dir
}

// Active reports whether anything was found.
func (a ActiveRun) Active() bool { return len(a.PIDs) > 0 }

// DetectActiveRun looks for an in-flight `kzfs-test run`.
//
// Returns a zero ActiveRun when nothing is running. Never errors: "no run" and
// "cannot tell" are the same answer to the caller, which is to open normally.
func DetectActiveRun(resultsDir string, timeout time.Duration) ActiveRun {
	var out ActiveRun

	// pgrep -f, matched on the subcommand so a `golden` build is not mistaken
	// for a test run — they are different operations with different output.
	// runCapture returns (stdout, error) — pgrep exits non-zero when it
	// matches nothing, which is the ordinary "no run" case, not a fault.
	s, err := runCapture(timeout, "pgrep", "-f", "kzfs-test run")
	if err != nil || strings.TrimSpace(s) == "" {
		return out
	}
	for _, line := range strings.Split(s, "\n") {
		if p, err := strconv.Atoi(strings.TrimSpace(line)); err == nil && p > 0 {
			out.PIDs = append(out.PIDs, p)
		}
	}
	if len(out.PIDs) == 0 {
		return out
	}

	// The runner publishes `latest` -> the current run directory. Same source
	// klab-exporter reads, deliberately: two ways of finding "the current run"
	// is two ways to disagree.
	if resultsDir == "" {
		resultsDir = "/root/kzfs-test"
	}
	if d, err := filepath.EvalSymlinks(filepath.Join(resultsDir, "latest")); err == nil {
		out.Dir = d
		out.RunID = filepath.Base(d)
		if entries, err := os.ReadDir(d); err == nil {
			for _, e := range entries {
				if strings.HasSuffix(e.Name(), ".log") {
					out.Logs = append(out.Logs, filepath.Join(d, e.Name()))
				}
			}
		}
	}
	return out
}

// Summary is a one-line description for the status bar.
func (a ActiveRun) Summary() string {
	if !a.Active() {
		return ""
	}
	if a.RunID == "" {
		return "a test run is already in progress — reattached"
	}
	return "reattached to run " + a.RunID + " (" + strconv.Itoa(len(a.Logs)) + " distro log(s))"
}

// StopPID signals a detached run's process group.
//
// A run adopted at startup is not a child of this process, so the Runner's own
// cancellation cannot reach it. Signal the group, not the pid: kzfs-test
// spawns ssh and per-distro workers, and killing only the parent leaves those
// running against guests nobody is watching.
func StopPID(pid int) error {
	// Negative pid = the process group. TERM first; the runner traps it and
	// tears its guests down, which SIGKILL would skip.
	_, err := runCapture(10*time.Second, "kill", "-TERM", "--", "-"+strconv.Itoa(pid))
	if err != nil {
		// Not in its own group (started from a shell without setsid): fall
		// back to the single process rather than doing nothing.
		_, err = runCapture(10*time.Second, "kill", "-TERM", strconv.Itoa(pid))
	}
	return err
}

// TailRunLogs streams the run's per-distro logs into a sink until they stop
// growing. Blocks, so callers run it on their own goroutine.
func TailRunLogs(a ActiveRun, sink func(string)) {
	if len(a.Logs) == 0 {
		return
	}
	args := append([]string{"-n", "40", "-F"}, a.Logs...)
	cmd := exec.Command("tail", args...)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return
	}
	// pump is the same reader the Runner uses, so a reattached run's output is
	// line-split and size-capped exactly like a run this console started.
	pump(stdout, sink)
	_ = cmd.Wait()
}
