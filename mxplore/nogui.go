//go:build !gui

// nogui.go — the static build's stand-in for the window.
//
// Two binaries come out of this tree: `mx` (GUI, cgo, links the system's
// graphics stack) and `mx-tui` (static, no cgo, runs anywhere). The static one
// is what belongs on a hypervisor, and it must still compile — so RunGUI
// exists here and explains itself rather than the tree failing to build
// without a display stack present. Same arrangement as ztxplore and zxplore.
//
// The message names the binary to use, because "no GUI available" on its own
// sends somebody looking for a missing X server when they are simply running
// the terminal build.

package main

import "fmt"

// RunGUI reports that this binary has no window.
func RunGUI(_ Querier, _ string) error {
	return fmt.Errorf("this is the terminal-only build (mx-tui); " +
		"the windowed explorer is the `mx` binary")
}
