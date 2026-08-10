// manual.go — the manual, shipped inside the binary.
//
// What it does, in order:
//  1. Embeds docs/vmxplore.1 so the page travels with the executable.
//  2. Renders it through mandoc or man when either is installed, and falls
//     back to the mdoc source when neither is.
//  3. Strips the nroff overstrike pairs that make rendered man output look
//     like line noise in anything that is not a terminal.
//  4. Colours the result for RichText: section headers in the accent,
//     body in the foreground, everything monospace.
//
// Why: a static binary copied onto a stranger's box must not be
// undocumented. zxplore and wgxplore both carry their page this way, and
// the front page they render it on is the same in all three — the family
// looks like one product from the first screen a new user opens.
//
// Notes: no col(1) in the pipeline. Overstrikes are stripped in Go, so the
// only external dependency is mandoc OR man, and neither is required.
package main

import (
	_ "embed"
	"os"
	"os/exec"
	"regexp"
	"strings"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
)

//go:embed docs/vmxplore.1
var manPage []byte

// renderManual formats the embedded page for display. Best effort by
// design: a host with neither renderer still gets readable mdoc rather
// than an empty pane.
func renderManual() string {
	tmp, err := os.CreateTemp("", "vmxplore-man-*.1")
	if err == nil {
		_, _ = tmp.Write(manPage)
		tmp.Close()
		defer os.Remove(tmp.Name())
		for _, c := range []string{
			"mandoc -Tutf8 -O width=100 " + tmp.Name() + " 2>/dev/null",
			"MANWIDTH=100 man -l " + tmp.Name() + " 2>/dev/null",
		} {
			// the length guard rejects a renderer that "succeeded" with a
			// usage message or an empty buffer
			if out, err := exec.Command("sh", "-c", c).Output(); err == nil && len(out) > 200 {
				return stripOverstrike(string(out))
			}
		}
	}
	return string(manPage)
}

// stripOverstrike removes nroff bold/underline overstrike pairs (c\bc,
// _\bc) — the job col -bx used to do, done portably and without a pipe.
var overstrikeRE = regexp.MustCompile(`.\x08`)

func stripOverstrike(s string) string {
	for i := 0; i < 4 && strings.Contains(s, "\x08"); i++ {
		s = overstrikeRE.ReplaceAllString(s, "")
	}
	return strings.ReplaceAll(s, "\x08", "") // stray leading backspaces
}

// manHeadRE matches a man SECTION HEADER line: all caps, column zero.
var manHeadRE = regexp.MustCompile(`^[A-Z][A-Z0-9 /()-]*$`)

// manualSegments colours the rendered manual for RichText.
//
// WARN: the segments must be Inline, with a SEPARATE newline segment. A
// non-inline segment is a PARAGRAPH block and RichText puts paragraph
// spacing between blocks — one block per line doubles the leading and the
// same manual reads half as dense as its sibling's beside it.
func manualSegments(text string) []widget.RichTextSegment {
	mono := fyne.TextStyle{Monospace: true}
	seg := func(s string, cn fyne.ThemeColorName, bold bool) *widget.TextSegment {
		st := mono
		st.Bold = bold
		return &widget.TextSegment{Text: s, Style: widget.RichTextStyle{
			Inline: true, TextStyle: st, ColorName: cn}}
	}
	var out []widget.RichTextSegment
	for _, line := range strings.Split(text, "\n") {
		if line != "" && manHeadRE.MatchString(strings.TrimRight(line, " ")) {
			out = append(out, seg(line, theme.ColorNamePrimary, true))
		} else {
			out = append(out, seg(line, theme.ColorNameForeground, false))
		}
		out = append(out, seg("\n", theme.ColorNameForeground, false))
	}
	return out
}
