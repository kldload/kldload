// manual.go — the built-in manual, shared by both consoles.
//
// WHY embedded: an operator reading the estate at 3am should not have to find
// out whether `man` was installed in this image, or whether the package that
// carried the man page made it onto the box. The page ships INSIDE the binary
// (the same file `make install` puts in $MANDIR), so `wgx` always has its own
// documentation — including on a static binary scp'd to a stranger's host.
//
// Rendering: try mandoc, then man(1), and fall back to the raw mdoc source.
// Overstrike pairs (the c\bc bold trick nroff emits) are stripped in Go rather
// than piping through col(1), so nothing external is required for a readable
// result.
package main

import (
	_ "embed"
	"os"
	"os/exec"
	"regexp"
	"strings"
)

//go:embed docs/wgx.1
var manPage []byte

// iconSVG is the brand mark, embedded so the manual front page carries it
// even when no icon theme is installed (a static binary on a foreign host
// still looks like itself).
//
//go:embed assets/wgxplore.svg
var iconSVG []byte

// renderManual returns the manual as plain text, best-effort formatted.
func renderManual() string {
	tmp, err := os.CreateTemp("", "wgx-man-*.1")
	if err == nil {
		_, _ = tmp.Write(manPage)
		tmp.Close()
		defer os.Remove(tmp.Name())
		for _, c := range []string{
			"mandoc -Tutf8 -O width=100 " + tmp.Name() + " 2>/dev/null",
			"MANWIDTH=100 man -l " + tmp.Name() + " 2>/dev/null",
		} {
			if out, err := exec.Command("sh", "-c", c).Output(); err == nil && len(out) > 200 {
				return stripOverstrike(string(out))
			}
		}
	}
	return string(manPage)
}

// overstrikeRE matches one nroff overstrike pair: any rune followed by \b.
var overstrikeRE = regexp.MustCompile(`.\x08`)

// stripOverstrike removes nroff bold/underline overstrikes — the job col -bx
// used to do, done portably. Bold is doubled (c\bc\bc) in some renderers, so
// the pass repeats a few times rather than assuming one.
func stripOverstrike(s string) string {
	for i := 0; i < 4 && strings.Contains(s, "\x08"); i++ {
		s = overstrikeRE.ReplaceAllString(s, "")
	}
	return strings.ReplaceAll(s, "\x08", "")
}

// manHeadRE matches a man SECTION HEADER line (all caps, column 0), which both
// consoles colour as a heading.
var manHeadRE = regexp.MustCompile(`^[A-Z][A-Z0-9 /()-]*$`)
