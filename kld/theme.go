package main

// theme.go — every colour kld draws with, and the one way a verb is spelled.
//
// Defined once so the rail, the menu, the tables, the vitals pane and the help
// all agree: a key letter is always the same colour, a destructive verb is
// always red, a property name never looks like its value. The operator's ask
// (2026-09-27): "all of the menus are just black and white", properties "used
// black and gray", and "S virsh start name" should read "(S)tart NAME".
//
// NO_COLOR is honoured by lipgloss itself (termenv drops every colour under
// it); the one thing that would then vanish is the selected row, which is a
// background colour, so under NO_COLOR it is drawn reversed instead.

import (
	"os"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

var noColor = os.Getenv("NO_COLOR") != ""

// 256-colour palette. One blue accent for place (brand, the active section),
// warm orange for keys, lavender for headings, steel blue for property names,
// and colour for state only in the table itself.
var (
	cAccent = lipgloss.Color("69")  // brand, active section, active sub-tab
	cKey    = lipgloss.Color("215") // a key the operator can press
	cHead   = lipgloss.Color("147") // headings: table header, pane sections
	cPropK  = lipgloss.Color("110") // a property's name
	cPropV  = lipgloss.Color("254") // a property's value
	cText   = lipgloss.Color("252") // ordinary text: labels, cells
	cMuted  = lipgloss.Color("245") // secondary: hints, separators, clocks
	cBright = lipgloss.Color("255")
	cBorder = lipgloss.Color("60")
	cGood   = lipgloss.Color("78")  // running, ok, ready
	cWarn   = lipgloss.Color("221") // paused, pending, stale
	cBad    = lipgloss.Color("203") // failed, and every destructive verb
	cOff    = lipgloss.Color("67")  // shut off, stopped: present, not wrong
	cSelBg  = lipgloss.Color("24")

	stBrand  = lipgloss.NewStyle().Bold(true).Foreground(cAccent)
	stTitle  = lipgloss.NewStyle().Bold(true).Foreground(cBright)
	stDim    = lipgloss.NewStyle().Foreground(cMuted)
	stText   = lipgloss.NewStyle().Foreground(cText)
	stRail   = lipgloss.NewStyle().Foreground(cText).Padding(0, 1)
	stRailA  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("231")).Background(cAccent).Padding(0, 1)
	stSub    = lipgloss.NewStyle().Foreground(cMuted).Padding(0, 1)
	stSubA   = lipgloss.NewStyle().Bold(true).Foreground(cAccent).Underline(true).Padding(0, 1)
	stHead   = lipgloss.NewStyle().Bold(true).Foreground(cHead)
	stSel    = selStyle()
	stGood   = lipgloss.NewStyle().Foreground(cGood)
	stWarn   = lipgloss.NewStyle().Foreground(cWarn)
	stBad    = lipgloss.NewStyle().Foreground(cBad)
	stOff    = lipgloss.NewStyle().Foreground(cOff)
	stKey    = lipgloss.NewStyle().Bold(true).Foreground(cKey)
	stKeyBad = lipgloss.NewStyle().Bold(true).Foreground(cBad)
	stPropK  = lipgloss.NewStyle().Foreground(cPropK)
	stPropV  = lipgloss.NewStyle().Foreground(cPropV)
	stRule   = lipgloss.NewStyle().Foreground(cBorder)
	stPane   = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cBorder).Padding(0, 1)
	stHelpBx = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cAccent).Padding(1, 2)
)

func selStyle() lipgloss.Style {
	if noColor {
		return lipgloss.NewStyle().Reverse(true)
	}
	return lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("231")).Background(cSelBg)
}

// dangerWords mark a verb that removes, overwrites or cuts something off.
// Red is a promise that the key does damage, so the list is words, not keys.
var dangerWords = []string{"delete", "destroy", "force off", "roll", "unload", "uninstall",
	"disarm", "drain", "offline", "power the cluster off", "restore this version over", "cancel"}

func isDanger(label string) bool {
	l := strings.ToLower(label)
	for _, w := range dangerWords {
		if strings.Contains(l, w) {
			return true
		}
	}
	return false
}

// shortLabel is a verb's label as the menu shows it: the part before any
// parenthesis, cut on a word boundary at 22 cells. The help and the palette
// keep the full label.
func shortLabel(label string) string {
	if i := strings.Index(label, " ("); i > 0 {
		label = label[:i]
	}
	if len(label) <= 22 {
		return label
	}
	cut := strings.LastIndex(label[:22], " ")
	if cut < 8 {
		cut = 22
	}
	// never end on a joining word: "rollback to the" reads as broken,
	// "rollback" does not
	words := strings.Fields(label[:cut])
	for len(words) > 1 && stopWord[words[len(words)-1]] {
		words = words[:len(words)-1]
	}
	return strings.Join(words, " ")
}

var stopWord = map[string]bool{"a": true, "an": true, "the": true, "to": true, "of": true, "on": true,
	"as": true, "and": true, "or": true, "into": true, "with": true, "for": true, "in": true, "at": true, "from": true}

// mnemonic spells a key and its label as one word with the key marked:
//
//	S start      -> (S)tart
//	b rollback   -> roll(b)ack
//	K force off  -> (K) force off     the key is not in the label
//	enter watch  -> (enter) watch     keys longer than a letter stand apart
//
// The key keeps ITS case, since S and s are different verbs. A letter at the
// start of a word is preferred over one inside a word ("s" in "set a
// snapshot" marks "(s)et", not "(s)napshot"), and the first word is searched
// before the rest so the mark lands where the eye starts.
func mnemonic(key, label string, danger bool) string {
	ks, ls := stKey, stText
	if danger {
		ks, ls = stKeyBad, stBad
	}
	if len([]rune(key)) != 1 {
		return ks.Render("("+key+")") + ls.Render(" "+label)
	}
	i := mnemonicAt(key, label)
	if i < 0 {
		return ks.Render("("+key+")") + ls.Render(" "+label)
	}
	return ls.Render(label[:i]) + ks.Render("("+key+")") + ls.Render(label[i+1:])
}

// mnemonicAt is the byte index in label of the letter mnemonic marks, or -1.
func mnemonicAt(key, label string) int {
	k := strings.ToLower(key)
	if k < "a" || k > "z" {
		return -1
	}
	lower := strings.ToLower(label)
	// word starts, in order
	for i := 0; i < len(lower); i++ {
		if (i == 0 || lower[i-1] == ' ') && lower[i:i+1] == k {
			return i
		}
	}
	// then anywhere in the first word
	first := lower
	if j := strings.IndexByte(first, ' '); j > 0 {
		first = first[:j]
	}
	return strings.Index(first, k)
}

// prop renders one "name  value" line of the vitals pane at name width kw.
func prop(name string, kw int, value string) string {
	return stPropK.Render(padRight(name, kw)) + "  " + value
}

func padRight(s string, w int) string {
	if n := lipgloss.Width(s); n < w {
		return s + strings.Repeat(" ", w-n)
	}
	return s
}
