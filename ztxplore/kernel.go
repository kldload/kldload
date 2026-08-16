// =============================================================================
// kernel.go — the kernel's side of the story.
//
// WHAT IT DOES, IN ORDER:
//   1. Reads the kernel ring buffer, with timestamps, newest last.
//   2. Classifies each line: is it ZFS, is it a taint, is it a splat, is it
//      an oops.
//   3. Follows the buffer live, so a panic that lands mid-test shows up in
//      the pane rather than in a file the operator opens afterwards.
//
// WHY IT EXISTS:
//   For a ZFS developer, dmesg IS the test output. A failing test tells you a
//   case did not pass; `VERIFY3` in the ring buffer tells you which assertion
//   tripped, in which function, and whether the module is now tainted. Making
//   someone leave the console to run dmesg is how that gets missed.
//
// WHY IT FILTERS THE WAY IT DOES:
//   Everything is kept and classified rather than grepped away. A ZFS
//   assertion is often preceded by a block-layer or memory message that is
//   the actual cause, so a pane that only shows lines matching "ZFS" hides
//   the reason. The classification drives colour and a filter the operator
//   can turn on, not what gets read.
//
// Notes:
//   - dmesg needs privilege on most hosts (kernel.dmesg_restrict=1). The
//     reader says so plainly rather than showing an empty pane, because an
//     empty kernel log reads as "nothing wrong".
// =============================================================================

package main

import (
	"bufio"
	"context"
	"fmt"
	"os/exec"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// KernelSeverity is what a line means, not where it came from.
type KernelSeverity int

const (
	KernNormal   KernelSeverity = iota
	KernZFS                     // a ZFS/SPL message worth colouring
	KernWarn                    // taint, hung task, allocation failure
	KernCritical                // assertion, oops, panic, BUG
)

// KernelLine is one ring-buffer entry.
type KernelLine struct {
	Text     string
	Severity KernelSeverity
	IsZFS    bool
}

// Patterns are deliberately literal. A regex that tries to be clever about
// kernel messages ends up matching a test's own output about the word
// "panic" and colouring the pane red for no reason.
var (
	// Subsystem names, AND the kernel thread and function names a ZFS
	// developer actually sees in a hang. "INFO: task txg_sync:1234 blocked
	// for more than 120 seconds" is the classic ZFS stall and contains none
	// of the words above, so a pattern built only from subsystem names files
	// the most important line in the buffer as unrelated.
	zfsRE = regexp.MustCompile(`(?i)(\b(zfs|spl|zpool|zvol|dmu|dsl|arc|zio|vdev|zil|dnode|spa|zed|zthr|dbuf|metaslab|dnbuf|zap|zvol)\b` +
		`|\b(txg_sync|txg_quiesce|spa_sync|arc_prune|arc_reclaim|arc_evict|z_wr_[a-z]+|z_rd_[a-z]+|zvol_[a-z]+|zfs_[a-z_]+|zio_[a-z_]+|dmu_[a-z_]+|dsl_[a-z_]+)\b` +
		// zvol block devices. On a lab box that clones a zvol per test VM
		// these are most of the ZFS traffic in the buffer, and they carry
		// none of the words above — "zd528: p1 p14 p15" was filed as
		// unrelated (fiend, 2026-08-15).
		`|\bzd[0-9]+\b)`)
	// The assertions OpenZFS actually raises, plus the kernel's own worst
	// news. VERIFY/ASSERT are the ones a ZFS developer is hunting.
	critRE = regexp.MustCompile(`(?i)(VERIFY[0-9BFPSU]*\(|ASSERT[0-9]*\(|kernel BUG|BUG:|Oops|general protection fault|kernel panic|PANIC at|call trace:)`)
	warnRE = regexp.MustCompile(`(?i)(taint|hung task|blocked for more than|allocation failure|WARNING:|soft lockup|out of memory|refcount)`)
)

// ClassifyKernelLine sorts one line.
//
// ORDER MATTERS: critical is tested before warning, because "WARNING:" often
// appears in the same block as a call trace and the block as a whole is
// critical news.
func ClassifyKernelLine(text string) KernelLine {
	l := KernelLine{Text: text, IsZFS: zfsRE.MatchString(text)}
	switch {
	case critRE.MatchString(text):
		l.Severity = KernCritical
	case warnRE.MatchString(text):
		l.Severity = KernWarn
	case l.IsZFS:
		l.Severity = KernZFS
	}
	return l
}

// ReadKernelLog reads the current ring buffer.
//
// Args:    lines, how many trailing lines to keep (0 = all).
// Returns: the classified lines, or an error explaining what to do about it.
func ReadKernelLog(lines int, timeout time.Duration) ([]KernelLine, error) {
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	// --ctime for human timestamps, -x to decode facility/level. Both are
	// util-linux dmesg options; a busybox dmesg would reject them, which the
	// error below reports rather than silently showing nothing.
	out, err := runCapture(timeout, "dmesg", "--color=never", "-x", "--ctime")
	if err != nil {
		// The overwhelmingly common cause, and the one with an action.
		return nil, fmt.Errorf("cannot read the kernel log (%w) — "+
			"dmesg is usually restricted to root; run this console with sudo, "+
			"or set kernel.dmesg_restrict=0", err)
	}
	all := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if lines > 0 && len(all) > lines {
		all = all[len(all)-lines:]
	}
	res := make([]KernelLine, 0, len(all))
	for _, t := range all {
		if t == "" {
			continue
		}
		res = append(res, ClassifyKernelLine(t))
	}
	return res, nil
}

// FollowKernelLog streams new kernel messages until ctx is cancelled.
//
// Args:    ctx, the lifetime; out, called per new line.
// Returns: an error if the follow could not be started.
//
// It uses `dmesg --follow`, which blocks on the ring buffer rather than
// polling — a poll loop either misses messages between samples or burns CPU
// during a test run that needs it.
func FollowKernelLog(ctx context.Context, out func(KernelLine)) error {
	if _, err := exec.LookPath("dmesg"); err != nil {
		return fmt.Errorf("dmesg is not installed")
	}
	cmd := exec.CommandContext(ctx, "dmesg", "--color=never", "-x", "--ctime", "--follow")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process != nil {
			return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		}
		return nil
	}
	pipe, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("cannot follow the kernel log: %w — "+
			"dmesg is usually restricted to root", err)
	}
	go func() {
		sc := bufio.NewScanner(pipe)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			out(ClassifyKernelLine(sc.Text()))
		}
		_ = cmd.Wait()
	}()
	return nil
}
