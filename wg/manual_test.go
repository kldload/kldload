//go:build gui

// manual_test.go — the embedded manual must render from a temp file whose
// path has a space in it. The renderers used to be `sh -c` strings with
// the path pasted in, so TMPDIR="/some dir" split the operand and every
// renderer failed; the pane then showed raw mdoc source.
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestRenderManualSurvivesATmpdirWithASpace(t *testing.T) {
	if _, err := exec.LookPath("mandoc"); err != nil {
		// Without a renderer the function can only echo the source, so
		// the thing under test is unreachable here. Say so loudly.
		t.Skip("mandoc not installed: the argv path DID NOT RUN")
	}
	dir := filepath.Join(t.TempDir(), "dir with space")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMPDIR", dir)
	got := renderManual()
	if strings.Contains(got, ".Sh NAME") {
		t.Fatalf("manual came back as mdoc source, not rendered text:\n%s", got[:200])
	}
	if !strings.Contains(got, "NAME") {
		t.Fatalf("rendered manual lacks a NAME header:\n%s", got[:200])
	}
	// the temp file is removed on the way out, spaces or not
	left, err := filepath.Glob(filepath.Join(dir, "wgx-man-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 0 {
		t.Fatalf("temp file left behind: %v", left)
	}
}
