//go:build !gui

// nogui.go — the static build has no GUI. Keeps `wgx` a pure-Go, zero-dep
// binary you can scp to any box (same split zxplore uses: zxplore-tui is
// CGO-free, the GUI needs the GL/X/wayland stack).
package main

import "errors"

// RunGUI is unavailable in the terminal-only build.
func RunGUI() error {
	return errors.New("this build has no GUI (built without -tags gui) — use `wgx tui`")
}
