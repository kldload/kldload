//go:build gui

// manual.go — the manual, shipped inside the binary.
//
// What it does, in order:
//  1. Embeds docs/ztxplore.1 so the page travels with the executable.
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

//go:embed docs/ztxplore.1
var manPage []byte

// renderManual formats the embedded page for display. Best effort by
// design: a host with neither renderer still gets readable mdoc rather
// than an empty pane.
func renderManual() string {
	tmp, err := os.CreateTemp("", "ztxplore-man-*.1")
	if err == nil {
		_, _ = tmp.Write(manPage)
		tmp.Close()
		defer os.Remove(tmp.Name())
		for _, c := range []string{
			"mandoc -Tutf8 -O width=100 " + tmp.Name() + " 2>/dev/null",
			"MANWIDTH=100 man -l " + tmp.Name() + " 2>/dev/null",
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
			"groff -mandoc -Tutf8 -rLL=100n -P -c " + tmp.Name() + " 2>/dev/null",
			"nroff -mandoc " + tmp.Name() + " 2>/dev/null",
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
// manTokenRE matches the things worth colouring inside a line: URLs first
// (they contain slashes), then absolute paths, then flags, then the names of
// the commands this page documents.
var manTokenRE = regexp.MustCompile(
	`https?://[^\s,]+` +
		`|/(?:etc|var|root|usr|dev|tmp)[A-Za-z0-9_./<>-]*` +
		`|(?:^|\s)--?[a-z][a-z-]*` +
		`|\b(?:kzfs-test|ztxplore|ztx|zfs-tests\.sh|virsh|virt-install|zfs|zpool|mandoc)\b`)

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

	// Colour carries meaning, so the eye can find things without reading:
	//
	//	section headers  accent, bold   the map of the page
	//	commands         success        what you type
	//	flags            warning        how you change it
	//	paths and URLs   hyperlink      where things are
	//
	// A manual rendered in one colour is a wall, and a wall is what people
	// close. The other consoles in the family colour theirs the same way.
	var out []widget.RichTextSegment
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimRight(line, " ")

		// Whole-line: a section header owns its line.
		if trimmed != "" && manHeadRE.MatchString(trimmed) {
			out = append(out, seg(line, theme.ColorNamePrimary, true))
			out = append(out, seg("\n", theme.ColorNameForeground, false))
			continue
		}

		// Inline: walk the line and colour the tokens that mean something.
		// Order matters — URLs contain slashes, so they must match before
		// the path pattern gets a chance at them.
		rest := line
		for rest != "" {
			loc := manTokenRE.FindStringIndex(rest)
			if loc == nil {
				out = append(out, seg(rest, theme.ColorNameForeground, false))
				break
			}
			if loc[0] > 0 {
				out = append(out, seg(rest[:loc[0]], theme.ColorNameForeground, false))
			}
			tok := rest[loc[0]:loc[1]]
			switch {
			case strings.HasPrefix(tok, "http"):
				out = append(out, seg(tok, theme.ColorNameHyperlink, false))
			case strings.HasPrefix(tok, "-"):
				out = append(out, seg(tok, theme.ColorNameWarning, false))
			case strings.HasPrefix(tok, "/"):
				out = append(out, seg(tok, theme.ColorNameHyperlink, false))
			default:
				out = append(out, seg(tok, theme.ColorNameSuccess, true))
			}
			rest = rest[loc[1]:]
		}
		out = append(out, seg("\n", theme.ColorNameForeground, false))
	}
	return out
}
