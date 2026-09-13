// =============================================================================
// render.go — drawing a tree in a terminal, with and without colour.
//
// Deliberately stdlib only and deliberately not interactive yet. The model and
// the data path are the parts worth getting right first; a full-screen paned
// interface is the next commit, and picking its library now would be choosing
// before there is anything to choose for.
//
// Colour follows NO_COLOR and an isatty check, because this output ends up in
// install logs and CI as often as on a screen, and escape codes in a log are
// noise somebody has to strip.
// =============================================================================

package main

import (
	"fmt"
	"io"
	"os"
	"strings"
)

// ANSI, kept in one place. The palette matches the kldload console: green for
// healthy, amber for attention, red for broken, blue for structure.
const (
	cReset = "\033[0m"
	cDim   = "\033[2m"
	cBold  = "\033[1m"
	cBlue  = "\033[38;5;75m"
	cGreen = "\033[38;5;84m"
	cAmber = "\033[38;5;215m"
	cRed   = "\033[38;5;203m"
)

// Renderer draws a tree. Colour is decided once, at construction, so no
// drawing code has to ask.
type Renderer struct {
	W     io.Writer
	Color bool
	// MaxDepth stops the walk; 0 means no limit. A wall display wants two
	// levels, an operator hunting a disk wants all of them.
	MaxDepth int
}

// NewRenderer honours NO_COLOR (the de-facto standard) and only colours a
// terminal. os.Stdout.Stat is the isatty that needs no dependency.
func NewRenderer(w io.Writer) *Renderer {
	color := false
	if _, noColor := os.LookupEnv("NO_COLOR"); !noColor {
		if f, ok := w.(*os.File); ok {
			if st, err := f.Stat(); err == nil && (st.Mode()&os.ModeCharDevice) != 0 {
				color = true
			}
		}
	}
	return &Renderer{W: w, Color: color}
}

func (r *Renderer) paint(s, color string) string {
	if !r.Color || color == "" {
		return s
	}
	return color + s + cReset
}

// Render writes the whole tree.
func (r *Renderer) Render(n *Node) {
	fmt.Fprintln(r.W, r.paint(n.Name, cBold+cBlue))
	r.children(n, "", 1)
}

func (r *Renderer) children(n *Node, prefix string, depth int) {
	if r.MaxDepth > 0 && depth > r.MaxDepth {
		return
	}
	for i, c := range n.Children {
		last := i == len(n.Children)-1
		branch, cont := "├─ ", "│  "
		if last {
			branch, cont = "└─ ", "   "
		}
		fmt.Fprintf(r.W, "%s%s%s\n", prefix, r.paint(branch, cDim), r.row(c))
		r.children(c, prefix+r.paint(cont, cDim), depth+1)
	}
}

// row is one line: name, value, and any detail. The value is right-aligned
// into a fixed column so a column of numbers reads as a column.
func (r *Renderer) row(n *Node) string {
	name := n.Name
	switch n.Kind {
	case KindGroup:
		name = r.paint(name, cBold)
	case KindPool, KindGuest, KindNode:
		name = r.paint(name, cBlue)
	}

	var b strings.Builder
	b.WriteString(name)
	if n.Value != "" {
		pad := 30 - visibleLen(n.Name)
		if pad < 1 {
			pad = 1
		}
		b.WriteString(strings.Repeat(" ", pad))
		b.WriteString(r.paint(n.Value, valueColor(n.Value)))
	}
	if n.Detail != "" {
		b.WriteString("  ")
		b.WriteString(r.paint(n.Detail, cRed))
	}
	return b.String()
}

// valueColor is a deliberately small piece of judgement: the words that mean
// trouble get a colour, everything else is left alone. Guessing at thresholds
// for arbitrary numbers would colour things wrong more often than right.
func valueColor(v string) string {
	switch {
	case v == "ONLINE":
		return cGreen
	case strings.HasPrefix(v, "DEGRADED"), strings.HasPrefix(v, "state "):
		return cAmber
	case v == "FAULTED", v == "UNAVAIL", v == "REMOVED", v == "OFFLINE":
		return cRed
	default:
		return ""
	}
}

// visibleLen counts runes outside ANSI escapes, so padding survives colour.
func visibleLen(s string) int {
	n, inEsc := 0, false
	for _, r := range s {
		switch {
		case r == '\033':
			inEsc = true
		case inEsc && r == 'm':
			inEsc = false
		case !inEsc:
			n++
		}
	}
	return n
}
