//go:build !gui

// nogui.go — the static build's stand-in for the GUI (the family pattern:
// zxplore/nogui.go is byte-for-byte the same idea).
//
// Built WITHOUT the `gui` tag (CGO_ENABLED=0), vmx is a single static
// TUI-only binary — no cgo, no OpenGL, no X/Wayland — that you can scp to
// any libvirt box. Asking that build for the GUI lands here.
package main

import (
	"fmt"
	"os"
)

func runGUI(rs *Ruleset) {
	fmt.Fprintln(os.Stderr,
		"vmx: this is the static terminal build (no GUI compiled in) — starting the TUI.\n"+
			"     For the native GUI, build with:  make gui   (or: go build -tags gui)")
	runTUIMain(rs)
}
