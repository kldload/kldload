package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The shape ollama left in firstboot.log on fiend 2026-09-14: every frame of
// the pull meter on one line, separated by cursor moves.
func TestFlattenTerminalKeepsTheLastFrame(t *testing.T) {
	in := "pulling 2049f5674b1e:  67% 6.0 GB/9.0 GB\x1b[K\x1b[?25h\x1b[?2026l\x1b[?2026h\x1b[?25l\x1b[A\x1b[1G" +
		"pulling 2049f5674b1e:  68% 6.1 GB/9.0 GB\x1b[K\x1b[?25h\x1b[?2026l"
	if got, want := flattenTerminal(in), "pulling 2049f5674b1e:  68% 6.1 GB/9.0 GB"; got != want {
		t.Errorf("flattenTerminal = %q, want %q", got, want)
	}
	if got, want := flattenTerminal("dnf  45%\r dnf 100%\r"), " dnf 100%"; got != want {
		t.Errorf("carriage returns: got %q, want %q", got, want)
	}
	if got, want := flattenTerminal("[firstboot] plain line"), "[firstboot] plain line"; got != want {
		t.Errorf("plain line changed: %q", got)
	}
}

func TestLogTailFlattensEveryLine(t *testing.T) {
	f := filepath.Join(t.TempDir(), "fb.log")
	body := "one\ntwo 10%\x1b[1Gtwo 90%\x1b[K\nthree\n"
	if err := os.WriteFile(f, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	got := logTail(f, 2)
	if strings.ContainsRune(got, 0x1b) || got != "two 90%\nthree" {
		t.Errorf("logTail = %q", got)
	}
}

// Until first boot is done autodeploy has not started, so its log is either
// absent or stale; the pane must follow first boot.
func TestBuildLogFollowsFirstBootUntilItIsDone(t *testing.T) {
	if got := buildLog(Progress{FirstBoot: false}); got != firstbootLog {
		t.Errorf("during first boot: %q, want %q", got, firstbootLog)
	}
}
