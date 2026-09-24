//go:build gui

// manual.go — the built-in manual, rendered in the GUI's Manual tab.
//
// GUI-ONLY, and the build tag says so. Nothing outside gui.go references
// renderManual, manPage, iconSVG or the two regexes, so without the tag the
// static (nogui) build compiles all six and uses none: staticcheck U1000 on
// every one of them. The standalone wgxplore tree has carried this tag since
// it was written; this copy lost it, and the header comment claiming the file
// was "shared by both consoles" was the reason nobody looked.
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
	if err != nil {
		return string(manPage)
	}
	defer os.Remove(tmp.Name())
	// A short write or a failed close leaves a truncated page on disk; the
	// renderer would format half a manual and the length guard below
	// would wave it through. Fall back to the source instead.
	if _, err := tmp.Write(manPage); err != nil {
		tmp.Close()
		return string(manPage)
	}
	if err := tmp.Close(); err != nil {
		return string(manPage)
	}
	// Each renderer is a fixed argv, never a shell string: the temp path
	// is TMPDIR's to choose, and a TMPDIR with a space in it split the old
	// `sh -c "mandoc ... " + path` into two operands. Output() captures
	// stderr into the error, so a missing renderer says nothing on the
	// terminal.
	for _, argv := range [][]string{
		{"mandoc", "-Tutf8", "-O", "width=100", tmp.Name()},
		{"man", "-l", tmp.Name()},
		// groff and nroff, because a kldload install has neither of the
		// two above and the pane filled with raw ".Sh NAME / .Nm / .Xr"
		// source instead of a manual (fiend, 2026-08-15). groff renders
		// mdoc natively via the -mandoc macro set, and it is already on
		// every one of these boxes.
		//
		// -P -c makes grotty emit classic overstrike pairs rather than
		// ANSI SGR, which is what stripOverstrike below already knows how
		// to remove; without it the pane trades roff source for escape
		// soup.
		{"groff", "-mandoc", "-Tutf8", "-rLL=100n", "-P", "-c", tmp.Name()},
		{"nroff", "-mandoc", tmp.Name()},
	} {
		cmd := exec.Command(argv[0], argv[1:]...)
		if argv[0] == "man" {
			cmd.Env = append(os.Environ(), "MANWIDTH=100")
		}
		if out, err := cmd.Output(); err == nil && len(out) > 200 {
			return stripOverstrike(string(out))
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
