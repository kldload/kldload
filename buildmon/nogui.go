//go:build !gui

// nogui.go — the terminal-only build has no window.
//
// Same split zxplore, wgx and vmx use: the static binary is pure Go with no
// cgo, so it runs on a server profile with no GL/X11/wayland stack at all,
// and the GUI is a separate build tag. main() falls back to RunTUI when this
// version of RunGUI reports itself unavailable, so the terminal-only binary is
// fully functional rather than merely non-crashing.

package main

import "errors"

// RunGUI is unavailable in this build.
func RunGUI(GatherOpts) error {
	return errors.New("this build has no GUI (built without -tags gui)")
}
