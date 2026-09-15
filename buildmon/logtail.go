// logtail.go — read the last N lines of a log without reading the whole file.
//
// The autodeploy log grows to hundreds of KB during a build and the display
// refreshes every couple of seconds, so reading it end-to-end each tick is
// wasteful on a box that is already starved for I/O — which, during a golden
// build, it certainly is. This seeks to a bounded window off the end instead.

package main

import (
	"io"
	"os"
	"regexp"
	"strings"
)

// tailWindow is how far back to seek. Generous enough that 200 lines of
// autodeploy output fit comfortably; small enough to stay cheap.
const tailWindow = 256 * 1024

// logTail returns the last n lines of path, or "" if it cannot be read.
//
// Args: path — a log file; n — how many lines.
// Returns: the lines joined by "\n", oldest first. Never returns an error:
// a display must degrade to showing nothing rather than failing.
func logTail(path string, n int) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()

	fi, err := f.Stat()
	if err != nil {
		return ""
	}
	start := int64(0)
	if fi.Size() > tailWindow {
		start = fi.Size() - tailWindow
	}
	if _, err := f.Seek(start, io.SeekStart); err != nil {
		return ""
	}
	b, err := io.ReadAll(f)
	if err != nil {
		return ""
	}

	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	// A mid-line seek leaves a partial first line; drop it rather than show a
	// fragment that looks like a truncated log message.
	if start > 0 && len(lines) > 1 {
		lines = lines[1:]
	}
	for i, l := range lines {
		lines[i] = flattenTerminal(l)
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// Log paths the Progress tab can show. First boot writes one, autodeploy the
// other, and they run one after the other.
const (
	firstbootLog  = "/var/log/kldload/firstboot.log"
	autodeployLog = "/var/log/kldload/autodeploy.log"
)

// buildLog picks the log that is moving right now.
//
// This used to be autodeploy.log unconditionally, but autodeploy waits for
// first boot, so for the first several minutes of every install (the AI model
// pull, the whisper build) the pane was empty under a 0% bar and the window
// looked hung. fiend 2026-09-14, 5-desktop.
func buildLog(p Progress) string {
	if p.FirstBoot && fileExists(autodeployLog) {
		return autodeployLog
	}
	return firstbootLog
}

// csiRe matches one ANSI control sequence (ESC [ params intermediates final).
var csiRe = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]`)

// flattenTerminal turns a line a progress meter painted into the text a person
// would have seen last.
//
// ollama and dnf redraw in place: a carriage return, or a cursor-up (CSI A) or
// column move (CSI G) followed by the new frame. Written to a log, one "line"
// is every frame of the meter glued together behind escape codes, which a
// text widget renders as a wall of noise. So a redraw starts the line over,
// and every other control sequence is dropped.
func flattenTerminal(l string) string {
	l = csiRe.ReplaceAllStringFunc(l, func(seq string) string {
		switch seq[len(seq)-1] {
		case 'A', 'G':
			return "\r"
		}
		return ""
	})
	if i := strings.LastIndexByte(strings.TrimRight(l, "\r"), '\r'); i >= 0 {
		l = l[i+1:]
	}
	return strings.TrimRight(l, "\r")
}
