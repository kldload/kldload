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

import (
	"fmt"
	"os"
)

// RunGUI reports that this binary has no window. main falls back to the TUI.
func RunGUI(resultsDir string) error {
	return fmt.Errorf("this is the terminal-only build (ztx-tui); " +
		"the windowed console is the `ztx` binary")
}

// runGUIOrFallback goes straight to the text view: this binary has no window.
//
// Same two lines on stderr the GUI build prints when its window fails, kept
// byte-identical on purpose — an operator who sees them in a log should not
// have to work out which binary produced them.
func runGUIOrFallback(resultsDir string) {
	fmt.Fprintln(os.Stderr, "ztx: no GUI available:", RunGUI(resultsDir))
	fmt.Fprintln(os.Stderr, "ztx: falling back to the text view")
	os.Exit(RunTUI(resultsDir))
}
