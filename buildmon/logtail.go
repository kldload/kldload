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
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
