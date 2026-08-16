//go:build !gui

// nogui.go — the static build's stand-in for the window.
//
// Two binaries come out of this tree: `ztx` (GUI, cgo, links against the
// system's graphics stack) and `ztx-tui` (static, no cgo, runs anywhere).
// The static one is what goes on a hypervisor, and it must still build — so
// RunGUI exists here and explains itself rather than the tree failing to
// compile without a display stack present.
//
// The message names the fix, because "no GUI available" on its own sends
// somebody looking for a missing X server when they are simply running the
// terminal build.

package main

import "fmt"

// RunGUI reports that this binary has no window. main falls back to the TUI.
func RunGUI(resultsDir string) error {
	return fmt.Errorf("this is the terminal-only build (ztx-tui); " +
		"the windowed console is the `ztx` binary")
}
