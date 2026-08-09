//go:build gui

// gui.go — the native vmxplore surface (Fyne), GUI-first per the operator
// call of 2026-08-07: "the frame for the VM."
//
// What it builds, in order:
//  1. The window — title EXACTLY "vmxplore": GLFW derives the WM_CLASS from
//     the title, and the shell maps WM_CLASS → vmxplore.desktop for the dock
//     icon (the zxplore lesson, verbatim).
//  2. Left pane: the estate list (grouped, filtered by the search box).
//  3. Right-top pane: the serial console — a real terminal widget attached
//     to `virsh console` for the selected domain, in-window.
//  4. Right-bottom pane: details dossier + settings + the verb buttons,
//     driving the SAME plan builders as the TUI (verbs.go): every mutation
//     shows the exact command it runs in the status line and runs it — no
//     confirmation step, including delete; all runs audit-log.
//
// Why: vmxplore is the giveaway KVM console — GUI for the desktop, TUI for
// ssh — that lights up extra powers on kldload/ZFS hosts via capability
// probes only (rules.go). The engine (libvirt.go/zfs.go/verbs.go) is shared;
// this file is presentation only.
//
// Inputs: qemu:///system via the libvirt group (NO sudo re-exec here — root
// cannot reach the user's Wayland display; zfs verbs elevate per-command in
// runPlan). Outputs: none beyond the verbs' own.
package main

import (
	_ "embed"
	"fmt"
	"image/color"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/canvas"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/driver/desktop"
	"fyne.io/fyne/v2/layout"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"
	"github.com/creack/pty"
	fyneterm "github.com/fyne-io/terminal"
)

//go:embed packaging/vmxplore.svg
var iconSVG []byte

// ── theme ──────────────────────────────────────────────────────────────────
// Ported from zxplore's compactTheme so the family shares one look: the
// near-black steel base ("the black space"), card panels lifted a step off
// it, tight list rows, and electric-on-dark / deep-on-light accents. Only
// the brand accent differs — vmxplore's compute red instead of zxplore's
// teal-green (the icon palette: red box, amber LED).

type compactTheme struct{ fyne.Theme }

func (t compactTheme) Size(name fyne.ThemeSizeName) float32 {
	switch name {
	case theme.SizeNameInnerPadding:
		return 2 // tight rows (single-spaced list)
	case theme.SizeNamePadding:
		return 3 // space between panes / regions — small on purpose: this
		// window is mostly other machines' screens, and every margin is
		// drawn at the expense of one
	}
	return t.Theme.Size(name)
}

func (t compactTheme) Color(name fyne.ThemeColorName, v fyne.ThemeVariant) color.Color {
	dark := v == theme.VariantDark
	switch name {
	case theme.ColorNamePrimary, theme.ColorNameHyperlink:
		if dark {
			return acBrand.dark
		}
		return acBrand.light
	case theme.ColorNameSelection:
		if dark {
			return color.NRGBA{R: 0x2a, G: 0x3a, B: 0x48, A: 0xff} // steel-blue highlight
		}
		return color.NRGBA{R: 0xec, G: 0xe2, B: 0xf8, A: 0xff} // soft lavender wash
	case theme.ColorNameBackground:
		if dark {
			return color.NRGBA{R: 0x08, G: 0x09, B: 0x0c, A: 0xff} // very dark steel-black
		}
		return color.NRGBA{R: 0xff, G: 0xff, B: 0xff, A: 0xff}
	case theme.ColorNameInputBackground:
		if dark {
			return color.NRGBA{R: 0x13, G: 0x18, B: 0x20, A: 0xff}
		}
		return color.NRGBA{R: 0xf6, G: 0xf2, B: 0xf1, A: 0xff}
	case theme.ColorNameForeground:
		if dark {
			return color.NRGBA{R: 0xe3, G: 0xe9, B: 0xef, A: 0xff} // crisp steel-white
		}
		return color.NRGBA{R: 0x1e, G: 0x18, B: 0x18, A: 0xff}
	}
	return t.Theme.Color(name, v)
}

// accentPair: ELECTRIC on the near-black dark theme, DEEP-saturated on the
// bright light theme (the zxplore "ANSI BBS, modernized" rule).
type accentPair struct{ dark, light color.NRGBA }

func (a accentPair) at() color.Color {
	if variantDark() {
		return a.dark
	}
	return a.light
}

var (
	// The brand accent IS the details blue (operator call, 2026-08-09 —
	// the purple sat apart from everything else it was next to). One pair,
	// one name each, deliberately aliased rather than duplicated: two
	// literals that must stay equal are two literals that will not.
	//
	// It reaches further than a heading colour. Fyne resolves
	// ColorNamePrimary from it, so every HighImportance control — the
	// Storage / Configure / Build / Estate menus — follows without being
	// told, and so do the estate group names, the page headings and the
	// selected tab.
	acBlue  = accentPair{color.NRGBA{0x4d, 0xa6, 0xff, 0xff}, color.NRGBA{0x14, 0x66, 0xd8, 0xff}}
	acBrand = acBlue
	// red survives ONLY as danger — toned to the icon's compute red
	acRed   = accentPair{color.NRGBA{0xe2, 0x69, 0x5d, 0xff}, color.NRGBA{0xb8, 0x38, 0x28, 0xff}}
	acGold  = accentPair{color.NRGBA{0xff, 0xd0, 0x43, 0xff}, color.NRGBA{0xb0, 0x7d, 0x00, 0xff}} // the icon's LED amber
	acGreen = accentPair{color.NRGBA{0x3d, 0xff, 0x88, 0xff}, color.NRGBA{0x0e, 0x9d, 0x4a, 0xff}} // running
	acOff   = accentPair{color.NRGBA{0x9a, 0x7b, 0x55, 0xff}, color.NRGBA{0x7a, 0x5a, 0x38, 0xff}} // shut off — dull brown, dormant
)

// repaint holds recolor closures for hand-colored canvas objects (cards,
// headings, list rows can't follow the theme on their own); applyPalette
// re-runs them once the GNOME variant is resolved and on every theme flip —
// the zxplore fix for "dark boxes on a white app".
var repaint []func()

func applyPalette() {
	for _, f := range repaint {
		f()
	}
}

func variantDark() bool {
	return fyne.CurrentApp() != nil &&
		fyne.CurrentApp().Settings().ThemeVariant() == theme.VariantDark
}

// cardColor is the panel backdrop — lifted just off the window base.
func cardColor() color.Color {
	if variantDark() {
		return color.NRGBA{R: 0x15, G: 0x1b, B: 0x23, A: 0xff} // dark steel
	}
	return color.NRGBA{R: 0xf7, G: 0xf4, B: 0xf3, A: 0xff}
}

// card wraps a section in a rounded backdrop so the regions read as panels
// floating on the black, with the base showing through the gaps.
func card(content fyne.CanvasObject) fyne.CanvasObject {
	r := canvas.NewRectangle(cardColor())
	r.CornerRadius = 8
	repaint = append(repaint, func() { r.FillColor = cardColor(); r.Refresh() })
	return container.NewStack(r, container.NewPadded(content))
}

// cardTight is card without the inner inset — for the console, where the
// content is a guest's screen and every pixel spent on a margin is a pixel
// not spent on the machine. The rounded backdrop stays, so the pane still
// reads as a card next to the others.
func cardTight(content fyne.CanvasObject) fyne.CanvasObject {
	r := canvas.NewRectangle(cardColor())
	r.CornerRadius = 8
	repaint = append(repaint, func() { r.FillColor = cardColor(); r.Refresh() })
	return container.NewStack(r, content)
}

// heading is a bold accent-colored section title (long-lived surfaces —
// registers for theme-flip repaints).
func heading(text string, a accentPair) *canvas.Text {
	t := canvas.NewText(text, a.at())
	t.TextStyle = fyne.TextStyle{Bold: true}
	t.TextSize = 14
	repaint = append(repaint, func() { t.Color = a.at(); t.Refresh() })
	return t
}

// pageHeading is heading() for surfaces that rebuild on every visit (the
// launcher pages): same look, NO repaint registration — registering would
// leak one closure per page open (the zxplore dialogHeading rule).
func pageHeading(text string, a accentPair) *canvas.Text {
	t := canvas.NewText(text, a.at())
	t.TextStyle = fyne.TextStyle{Bold: true}
	t.TextSize = 14
	return t
}

// brightFg is the row TITLE colour — a notch brighter than the body text
// so the machine name pops: near-white on dark, near-black on light.
func brightFg() color.Color {
	if variantDark() {
		return color.NRGBA{R: 0xff, G: 0xff, B: 0xff, A: 0xff}
	}
	return color.NRGBA{R: 0x0a, G: 0x0a, B: 0x0a, A: 0xff}
}

// rowDetail is the faint second line of an estate row: specs · IP ·
// group · zvol facts — everything a glance should answer without opening
// the dossier. Only present fields render, joined by " · ".
func rowDetail(r Row, group string) string {
	var parts []string
	if r.D.VCPUs > 0 {
		parts = append(parts, fmt.Sprintf("%dvcpu", r.D.VCPUs))
	}
	if mem := memCell(r); mem != "" && mem != "-" {
		parts = append(parts, mem)
	}
	if ip := firstIPv4(r.D.IPs); ip != "" {
		parts = append(parts, ip)
	} else if r.D.State == "running" && !r.D.AgentUp {
		parts = append(parts, "no-agent")
	}
	if group != "" {
		parts = append(parts, group)
	}
	if r.DS != nil {
		z := humanBytes(r.DS.Used)
		if r.SnapTotal > 0 {
			z += fmt.Sprintf(" ×%d", r.SnapTotal)
		}
		if r.Origin != "" {
			z += " ⑂" // a clone — forked from a parent
		}
		parts = append(parts, z)
	}
	if len(r.Notes) > 0 {
		parts = append(parts, strings.Join(r.Notes, "; "))
	}
	return "   " + strings.Join(parts, " · ")
}

// tileColor lifts a launcher tile one more step off the card backdrop.
func tileColor() color.Color {
	if variantDark() {
		return color.NRGBA{R: 0x1c, G: 0x24, B: 0x30, A: 0xff}
	}
	return color.NRGBA{R: 0xee, G: 0xe9, B: 0xe7, A: 0xff}
}

// tapArea makes any canvas object tappable with a pointer cursor — the
// chassis under the launcher tiles (buttons can't hold two-line content).
type tapArea struct {
	widget.BaseWidget
	content fyne.CanvasObject
	onTap   func()
}

func newTapArea(content fyne.CanvasObject, onTap func()) *tapArea {
	t := &tapArea{content: content, onTap: onTap}
	t.ExtendBaseWidget(t)
	return t
}

func (t *tapArea) CreateRenderer() fyne.WidgetRenderer {
	return widget.NewSimpleRenderer(t.content)
}
func (t *tapArea) Tapped(*fyne.PointEvent) { t.onTap() }
func (t *tapArea) Cursor() desktop.Cursor  { return desktop.PointerCursor }

// vmRow is one estate list row: two lines — a bold state-coloured title
// (dot · name · state) over a faint detail line (specs · IP · group · zvol)
// so the left pane reads as a dossier, not a bare name column. Selects on
// tap, opens the verb context menu on right-click.
type vmRow struct {
	widget.BaseWidget
	title    *canvas.Text
	detail   *canvas.Text
	onTap    func() // click the row body → select (drives panes)
	onToggle func() // click the state dot → toggle batch check
	onRange  func() // ctrl/shift-click → check the range from the anchor
	onMenu   func(pos fyne.Position)
	modDown  bool // Ctrl or Shift held on MouseDown, read by the next Tapped
}

// dotZoneW is how wide (px) the leading state-dot hit zone is: clicking
// inside it toggles the batch checkbox, outside it selects the row.
const dotZoneW = 22

// MouseDown records whether Ctrl or Shift was held, so the paired Tapped
// can tell a range-select click from a plain one (Fyne delivers MouseDown
// before Tapped for the same press).
func (r *vmRow) MouseDown(e *desktop.MouseEvent) {
	r.modDown = e.Modifier&(fyne.KeyModifierControl|fyne.KeyModifierShift) != 0
}
func (r *vmRow) MouseUp(*desktop.MouseEvent) {}

// Tree UIDs for the catalog branch. They live outside the "grp/" and "vm/"
// namespaces so no estate lookup can ever collide with a catalog entry.
const (
	applianceBranchUID = "appliances"
	applianceUIDPrefix = "app/"
)

func newVMRow() *vmRow {
	r := &vmRow{
		title:  canvas.NewText("", theme.Color(theme.ColorNameForeground)),
		detail: canvas.NewText("", theme.Color(theme.ColorNameForeground)),
	}
	r.title.TextStyle = fyne.TextStyle{Monospace: true, Bold: true}
	r.detail.TextStyle = fyne.TextStyle{Monospace: true}
	r.detail.TextSize = theme.TextSize() * 0.85
	r.ExtendBaseWidget(r)
	return r
}

func (r *vmRow) CreateRenderer() fyne.WidgetRenderer {
	// tight two-line stack; the detail sits just under the title
	box := container.New(&rowLayout{}, r.title, r.detail)
	return widget.NewSimpleRenderer(box)
}

// rowLayout stacks the title and detail with a small gap, sizing to both —
// VBox padding was too airy for a dense list.
type rowLayout struct{}

func (rowLayout) MinSize(o []fyne.CanvasObject) fyne.Size {
	t, d := o[0].MinSize(), o[1].MinSize()
	w := t.Width
	if d.Width > w {
		w = d.Width
	}
	return fyne.NewSize(w, t.Height+d.Height+2)
}

func (rowLayout) Layout(o []fyne.CanvasObject, sz fyne.Size) {
	t := o[0].MinSize()
	o[0].Move(fyne.NewPos(0, 0))
	o[0].Resize(fyne.NewSize(sz.Width, t.Height))
	o[1].Move(fyne.NewPos(0, t.Height+2))
	o[1].Resize(fyne.NewSize(sz.Width, o[1].MinSize().Height))
}

func (r *vmRow) Tapped(e *fyne.PointEvent) {
	// ctrl/shift-click anywhere → range-check from the anchor to here
	if r.modDown && r.onRange != nil {
		r.onRange()
		return
	}
	// the leading dot is the batch checkbox; the rest of the row selects
	if e.Position.X < dotZoneW && r.onToggle != nil {
		r.onToggle()
		return
	}
	if r.onTap != nil {
		r.onTap()
	}
}

func (r *vmRow) TappedSecondary(e *fyne.PointEvent) {
	if r.onMenu != nil {
		r.onMenu(e.AbsolutePosition)
	}
}

// newTile is one launcher card: icon + bold coloured title + a faint
// wrapped description — big enough that a screenshot of the grid explains
// the product on its own (the operator's ask, verbatim).
func newTile(icon fyne.Resource, title, desc string, col color.Color, onTap func()) fyne.CanvasObject {
	bg := canvas.NewRectangle(tileColor())
	bg.CornerRadius = 8
	tt := canvas.NewText(title, col)
	tt.TextStyle = fyne.TextStyle{Bold: true}
	tt.TextSize = 15
	d := widget.NewLabel(desc)
	d.Wrapping = fyne.TextWrapWord
	content := container.NewVBox(
		container.NewHBox(widget.NewIcon(icon), tt), d)
	return newTapArea(container.NewStack(bg, container.NewPadded(content)), onTap)
}

// guiState is everything the refresh goroutine and the widgets share. All
// mutation happens inside fyne.Do — the ticker computes off-thread and
// applies on-thread, so there is no lock.
type guiState struct {
	lv      *LV
	rs      *Ruleset
	groups  []GroupRows
	rows    []Row // flat, filtered — what the list renders
	filter  string
	dss     map[string]*Dataset
	snaps   map[string][]string
	ann     *Annotations
	prevCPU map[string]uint64
	prevAt  time.Time
	cpu     map[string]float64
	selName string // selection survives refresh by domain name

	// console plumbing: the exec'd virsh console + its pty, killed on
	// re-attach, detach and window close so no console outlives its pane
	conCmd  *exec.Cmd
	conPty  interface{ Close() error }
	conName string
}

// visibleRows flattens groups → rows honouring the search filter.
func (g *guiState) visibleRows() []Row {
	var out []Row
	q := strings.ToLower(strings.TrimSpace(g.filter))
	for _, gr := range g.groups {
		for _, r := range gr.Rows {
			if q == "" || strings.Contains(strings.ToLower(r.D.Name), q) {
				out = append(out, r)
			}
		}
	}
	return out
}

func (g *guiState) selected() (Row, bool) {
	for _, r := range g.rows {
		if r.D.Name == g.selName {
			return r, true
		}
	}
	return Row{}, false
}

// dossierSegs renders the details pane — the GUI twin of the TUI's
// detailText, same colour language via theme colours: accent labels,
// green running, warnings amber. RichText named colours follow the theme
// variant for free.
func (g *guiState) dossierSegs(r Row) []widget.RichTextSegment {
	mono := widget.RichTextStyle{
		Inline: true, TextStyle: fyne.TextStyle{Monospace: true}}
	title := mono
	title.TextStyle.Bold = true
	title.ColorName = theme.ColorNamePrimary
	label := mono
	label.ColorName = theme.ColorNamePrimary
	good := mono
	good.ColorName = theme.ColorNameSuccess
	warn := mono
	warn.ColorName = theme.ColorNameWarning
	segs := []widget.RichTextSegment{
		&widget.TextSegment{Text: r.D.Name + "\n\n", Style: title}}
	add := func(k string, sty widget.RichTextStyle, v string) {
		segs = append(segs,
			&widget.TextSegment{Text: fmt.Sprintf("%-9s ", k), Style: label},
			&widget.TextSegment{Text: v + "\n", Style: sty})
	}
	stateSty := mono
	if r.D.State == "running" {
		stateSty = good
	}
	add("state", stateSty, r.D.State)
	if !r.Synthetic {
		add("uuid", mono, r.D.UUID)
		add("vcpu/mem", mono, fmt.Sprintf("%d / %s", r.D.VCPUs, memCell(r)))
		auto := "no"
		if r.D.Autostart {
			auto = "yes"
		}
		if r.D.Persistent {
			add("config", mono, "autostart "+auto+" · persistent")
		} else {
			add("config", warn, "autostart "+auto+" · TRANSIENT — gone after destroy")
		}
		for _, d := range r.D.Disks {
			add("disk", mono, d.Target+" → "+cellOr(d.Dev, d.File))
		}
		if len(r.D.IPs) > 0 {
			add("ip", mono, strings.Join(r.D.IPs, ", "))
		}
	}
	if r.DS != nil {
		add("dataset", mono, fmt.Sprintf("%s  (used %s, refer %s)",
			r.DS.Name, humanBytes(r.DS.Used), humanBytes(r.DS.Refer)))
		if chain := OriginChain(r.DS, g.dss); len(chain) > 0 {
			add("lineage", mono, strings.Join(chain, " ← "))
		}
		if all := g.snaps[r.DS.Name]; len(all) > 0 {
			byClass := map[string]int{}
			for _, s := range all {
				byClass[g.rs.ClassifySnap(s)]++
			}
			classes := make([]string, 0, len(byClass))
			for c := range byClass {
				classes = append(classes, c)
			}
			sort.Strings(classes)
			parts := make([]string, 0, len(classes))
			for _, c := range classes {
				parts = append(parts, fmt.Sprintf("%d %s", byClass[c], c))
			}
			add("snaps", mono, fmt.Sprintf("%d  (%s)",
				len(all), strings.Join(parts, " · ")))
		}
	}
	for _, n := range r.Notes {
		add("note", warn, n)
	}
	return segs
}

// guiStatus, if set, gets a one-line note when a verb fires — the exact
// command still surfaces (teach-the-CLI), in the status bar rather than a
// modal. Set once in runGUI.
var guiStatus func(string)

// pickPubKey returns the operator's ssh public key for prefilling the
// guest-login field, or "" when there is none to offer. It walks a
// preference order and then falls back to any *.pub, because hardcoding
// one filename silently offered nothing on a host whose only key is an
// id_kldload or an id_rsa — and an empty key box next to an empty password
// box is how a VM gets built that nobody can log into.
func pickPubKey() string {
	dir := os.Getenv("HOME") + "/.ssh/"
	for _, n := range []string{"id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"} {
		if b, err := os.ReadFile(dir + n); err == nil {
			return strings.TrimSpace(string(b))
		}
	}
	names, _ := filepath.Glob(dir + "*.pub")
	for _, n := range names {
		if b, err := os.ReadFile(n); err == nil {
			return strings.TrimSpace(string(b))
		}
	}
	return ""
}

// firePlan runs a plan and reports it. There is no confirmation step of any
// kind, including for delete.
//
// WHY (operator call, 2026-08-09): these are cattle, not pets. A VM here is
// a thing you make in seconds from a golden and remake just as fast, and
// every dialog between the click and the deed was taxing the common case to
// insure against a rare one. Clicking delete IS the confirmation.
//
// What remains of the safety net is deliberate and worth knowing: every
// command lands in the audit log (runPlan → /var/log/kldload/vmx.log) with
// who ran it and its exit code, and the command itself shows in the status
// bar as it fires. WARN: `zfs destroy -r` takes the dataset's snapshots
// with it, so sanoid history on that zvol is not a recovery path — only
// replication to another pool or host is.
func firePlan(w fyne.Window, p verbPlan, after func()) {
	if guiStatus != nil {
		note := "· " + strings.TrimSpace(strings.TrimPrefix(
			strings.TrimSpace(p.cmdLines()), "$"))
		if p.warn != "" {
			note += "  ⚠ " + p.warn
		}
		guiStatus(note)
	}
	go func() {
		err := runPlan(p)
		fyne.Do(func() {
			if err != nil {
				dialog.ShowError(err, w)
			}
			after()
		})
	}()
}

func runGUI(rs *Ruleset) {
	a := app.NewWithID("dev.vmxplore")
	a.Settings().SetTheme(compactTheme{theme.DefaultTheme()})
	a.SetIcon(fyne.NewStaticResource("vmxplore.svg", iconSVG))
	// Title EXACTLY "vmxplore" — WM_CLASS ← title ← dock icon (see banner).
	w := a.NewWindow("vmxplore")
	w.Resize(fyne.NewSize(1600, 1000))
	w.CenterOnScreen()

	lv, err := ConnectSystem()
	if err != nil {
		// no estate, no app — one clear dialog then exit; sudo can't help a
		// GUI (Wayland), the fix is the libvirt group
		errLabel := widget.NewLabel(fmt.Sprintf(
			"libvirt: %v\n\nqemu:///system needs membership in the libvirt\n"+
				"group (log out/in after adding) — or run `vmx --tui` under sudo.", err))
		w.SetContent(container.NewCenter(errLabel))
		w.ShowAndRun()
		return
	}

	st := &guiState{lv: lv, rs: rs, cpu: map[string]float64{}}
	// checked = the batch set (click a row's state dot to toggle). Batch
	// verbs act on every checked VM at once. refreshBatchBar is wired below.
	checked := map[string]bool{}
	checkAnchor := "" // last dot-toggled VM; ctrl/shift-click ranges from it
	var refreshBatchBar func()

	// ── left: the estate tree ────────────────────────────────────────────
	// Groups are collapsible branches (the accordion), VMs are two-line
	// leaves. viewGroups is st.groups after the search filter; the tree and
	// st.rows both read it so selection, filtering and the flat helpers
	// stay in sync. uid scheme: "grp/<label>" branch, "vm/<name>" leaf.
	var viewGroups []GroupRows
	rebuildView := func() {
		q := strings.ToLower(strings.TrimSpace(st.filter))
		viewGroups = viewGroups[:0]
		st.rows = st.rows[:0]
		for _, g := range st.groups {
			var rows []Row
			for _, r := range g.Rows {
				if q == "" || strings.Contains(strings.ToLower(r.D.Name), q) {
					rows = append(rows, r)
				}
			}
			if len(rows) > 0 {
				viewGroups = append(viewGroups, GroupRows{Label: g.Label, Rows: rows})
				st.rows = append(st.rows, rows...)
			}
		}
	}
	rowByUID := func(uid string) (Row, bool) {
		name := strings.TrimPrefix(uid, "vm/")
		for _, g := range viewGroups {
			for _, r := range g.Rows {
				if r.D.Name == name {
					return r, true
				}
			}
		}
		return Row{}, false
	}
	groupStats := func(label string) (n, run int) {
		for _, g := range viewGroups {
			if g.Label == label {
				n = len(g.Rows)
				for _, r := range g.Rows {
					if r.D.State == "running" {
						run++
					}
				}
			}
		}
		return
	}

	var tree *widget.Tree
	var rowMenuAt func(r Row, pos fyne.Position) // wired after the verbs exist
	// openAppliance is wired once the dialog exists, further down. The tree
	// is built before it, so the catalog branch reaches it through this.
	var openAppliance func(name string)
	childUIDs := func(uid string) []string {
		if uid == "" {
			out := make([]string, 0, len(viewGroups)+1)
			for _, g := range viewGroups {
				out = append(out, "grp/"+g.Label)
			}
			// The catalog sits last and closed: it is a menu of things to
			// build, not estate, so it must never push the running VMs
			// down the pane.
			return append(out, applianceBranchUID)
		}
		if uid == applianceBranchUID {
			out := make([]string, 0, len(Appliances()))
			for _, n := range ApplianceNames() {
				out = append(out, applianceUIDPrefix+n)
			}
			return out
		}
		if label, ok := strings.CutPrefix(uid, "grp/"); ok {
			for _, g := range viewGroups {
				if g.Label == label {
					out := make([]string, 0, len(g.Rows))
					for _, r := range g.Rows {
						out = append(out, "vm/"+r.D.Name)
					}
					return out
				}
			}
		}
		return nil
	}
	isBranch := func(uid string) bool {
		return uid == "" || uid == applianceBranchUID ||
			strings.HasPrefix(uid, "grp/")
	}
	tree = widget.NewTree(childUIDs, isBranch,
		func(branch bool) fyne.CanvasObject {
			if branch {
				t := canvas.NewText("", acBrand.at())
				t.TextStyle = fyne.TextStyle{Bold: true}
				return t
			}
			return newVMRow()
		},
		func(uid string, branch bool, o fyne.CanvasObject) {
			if branch {
				t := o.(*canvas.Text)
				if uid == applianceBranchUID {
					t.Text = fmt.Sprintf("Apps  (%d)", len(Appliances()))
					t.Color = acBrand.at()
					t.Refresh()
					return
				}
				label := strings.TrimPrefix(uid, "grp/")
				n, run := groupStats(label)
				s := fmt.Sprintf("%s  (%d)", label, n)
				if run > 0 {
					s += fmt.Sprintf("  ·  %d running", run)
				}
				t.Text = s
				t.Color = acBrand.at()
				t.Refresh()
				return
			}
			// A catalog leaf is a thing to build, not a thing that exists,
			// so it borrows the row widget but none of its estate gestures.
			// Every callback is reassigned because Fyne recycles leaf
			// widgets — a stale closure here would aim a VM verb at an
			// appliance.
			if name, ok := strings.CutPrefix(uid, applianceUIDPrefix); ok {
				a, found := ApplianceByName(name)
				if !found {
					return
				}
				row := o.(*vmRow)
				row.title.Text = "＋ " + a.Name
				row.title.Color = acBrand.at()
				row.detail.Text = fmt.Sprintf("%s   ·   %d vCPU, %d MB, %d GB",
					a.Summary, a.VCPUs, a.RAMMB, a.DiskGB)
				row.detail.Color = theme.Color(theme.ColorNameForeground)
				row.onTap = func() {
					if openAppliance != nil {
						openAppliance(a.Name)
					}
				}
				row.onToggle = func() {}
				row.onRange = func() {}
				row.onMenu = func(fyne.Position) {}
				row.title.Refresh()
				row.detail.Refresh()
				return
			}
			r, ok := rowByUID(uid)
			if !ok {
				return
			}
			// title colour is the state at a glance: green running, dull
			// brown shut-off (dormant), amber warned, bright-white for the
			// in-between states (paused, shutting down); the stats line
			// sits at full foreground, one notch below the title
			dot, col := "◆", brightFg()
			switch {
			case r.Synthetic || len(r.Notes) > 0:
				dot, col = "!", acGold.at()
			case r.D.State == "running":
				dot, col = "●", acGreen.at()
			case r.D.State == "shut off":
				dot, col = "○", acOff.at()
			}
			// batch-checked → the dot becomes a filled check in the brand
			// colour, so the selection is unmistakable
			if checked[r.D.Name] {
				dot, col = "☑", acBrand.at()
			}
			cpu := ""
			if c, ok := st.cpu[r.D.Name]; ok && r.D.State == "running" {
				cpu = fmt.Sprintf("   %.0f%% cpu", c)
			}
			row := o.(*vmRow)
			row.title.Text = fmt.Sprintf("%s %s   %s%s",
				dot, r.D.Name, r.D.State, cpu)
			row.title.Color = col
			row.detail.Text = rowDetail(r, "") // group is the branch above
			row.detail.Color = theme.Color(theme.ColorNameForeground)
			// the leaf widget consumes taps, so it must drive selection
			// itself — the tree never sees the click otherwise
			leafUID := uid
			name := r.D.Name
			row.onTap = func() { tree.Select(leafUID) }
			row.onToggle = func() {
				if checked[name] {
					delete(checked, name)
				} else {
					checked[name] = true
				}
				checkAnchor = name // range select measures from here
				tree.RefreshItem(leafUID)
				if refreshBatchBar != nil {
					refreshBatchBar()
				}
			}
			// ctrl/shift-click → check every VM between the anchor and
			// this one, in visible order (the file-manager range gesture)
			row.onRange = func() {
				if checkAnchor == "" {
					row.onToggle()
					return
				}
				lo, hi := -1, -1
				for i, rr := range st.rows {
					if rr.D.Name == checkAnchor {
						lo = i
					}
					if rr.D.Name == name {
						hi = i
					}
				}
				if lo < 0 || hi < 0 {
					return
				}
				if lo > hi {
					lo, hi = hi, lo
				}
				for i := lo; i <= hi; i++ {
					checked[st.rows[i].D.Name] = true
				}
				tree.Refresh()
				if refreshBatchBar != nil {
					refreshBatchBar()
				}
			}
			row.onMenu = func(pos fyne.Position) {
				if rowMenuAt != nil {
					rowMenuAt(r, pos)
				}
			}
			row.title.Refresh()
			row.detail.Refresh()
		},
	)

	// ── right-top: the console pane ──────────────────────────────────────
	// Zero-interaction contract (operator ask): selecting a running VM
	// attaches its serial console here; moving the selection swaps it;
	// selecting a stopped VM detaches. Click into the pane to type.
	conPlaceholder := func(msg string) fyne.CanvasObject {
		return container.NewCenter(widget.NewLabel(msg))
	}
	consoleHost := container.NewStack(conPlaceholder(
		"select a running VM — its serial console attaches here"))
	detachConsole := func() {
		if st.conCmd != nil && st.conCmd.Process != nil {
			_ = st.conCmd.Process.Kill()
		}
		if st.conPty != nil {
			_ = st.conPty.Close()
		}
		st.conCmd, st.conPty, st.conName = nil, nil, ""
	}
	attachConsole := func(name string) {
		if st.conName == name && st.conCmd != nil {
			return // already on this VM's console
		}
		detachConsole()
		// virsh console through a pty; the terminal widget speaks to the
		// pty directly, so virsh's own errors land visibly in the pane
		v := virsh("console", name)
		cmd := exec.Command(v[0], v[1:]...)
		p, err := pty.Start(cmd)
		if err != nil {
			consoleHost.Objects = []fyne.CanvasObject{
				conPlaceholder("console: " + err.Error())}
			consoleHost.Refresh()
			return
		}
		st.conCmd, st.conPty, st.conName = cmd, p, name
		term := fyneterm.New()
		go func() {
			_ = term.RunWithConnection(p, p)
		}()
		// no focus steal: arrowing through the list must stay in the list —
		// clicking the pane focuses the terminal when you want to type
		consoleHost.Objects = []fyne.CanvasObject{term}
		consoleHost.Refresh()
	}
	// Screen pane: the native RFB viewer (vnc.go) — same auto-follow
	// contract as serial. Loopback makes eager attach cheap.
	vncHost := container.NewStack(conPlaceholder(
		"select a running VM — its graphical console renders here"))
	var vncConn *rfbConn
	vncName := ""
	// curVNC is the live viewer, so a control outside the pane (the paste
	// button in the console header) can drive the session the pane owns.
	// Nil whenever nothing is attached.
	var curVNC *vncViewer
	detachVNC := func() {
		curVNC = nil
		if vncConn != nil {
			vncConn.Close()
		}
		vncConn, vncName = nil, ""
	}
	attachVNC := func(name string) {
		if vncName == name && vncConn != nil {
			return
		}
		detachVNC()
		port, err := vncPort(lv, name)
		if err != nil {
			vncHost.Objects = []fyne.CanvasObject{conPlaceholder(err.Error())}
			vncHost.Refresh()
			return
		}
		conn, err := dialRFB(fmt.Sprintf("%s:%d", vncDialHost(), port))
		if err != nil {
			vncHost.Objects = []fyne.CanvasObject{
				conPlaceholder("vnc: " + err.Error())}
			vncHost.Refresh()
			return
		}
		vncConn, vncName = conn, name
		// guest clipboard → host clipboard (ServerCutText)
		conn.onCutText = func(s string) {
			fyne.Do(func() { w.Clipboard().SetContent(s) })
		}
		v := newVNCViewer(conn)
		curVNC = v
		vncHost.Objects = []fyne.CanvasObject{v}
		vncHost.Refresh()
	}

	// ── kldload extras: the tier-3 surface ───────────────────────────────
	// The k-tools are interactive CLIs, and this app embeds a terminal —
	// so Extras run right in the console card ("all 1 app"). The launched
	// tool drops into a shell afterwards so wizards and follow-ups work.
	// On a generic host the same menu pitches the OS instead — the
	// promote-through-the-app strategy, capability-probed as always.
	ktools := KldloadTools()
	toolsHost := container.NewStack()
	var toolCmd *exec.Cmd
	var toolPty interface{ Close() error }
	var selectToolsTab func()  // set once the tab bar exists below
	var selectScreenTab func() // ditto — where a new VM's first boot shows
	var showToolTiles func()
	stopTool := func() {
		if toolCmd != nil && toolCmd.Process != nil {
			_ = toolCmd.Process.Kill()
		}
		if toolPty != nil {
			_ = toolPty.Close()
		}
		toolCmd, toolPty = nil, nil
	}
	runArgv := func(argv []string) {
		stopTool()
		// exec directly (fixed argv, no shell wrapper): the exit is the
		// pty EOF that returns the pane to the tiles — quitting a tool
		// must land on the launcher, not a stray prompt (operator). The
		// "shell" tile exists for when a prompt IS what you want.
		cmd := exec.Command(argv[0], argv[1:]...)
		if argv[0] == "shell" {
			cmd = exec.Command("bash", "-i")
		}
		label := strings.Join(argv, " ")
		cmd.Env = append(os.Environ(), "TERM=xterm-256color")
		p, err := pty.Start(cmd)
		if err != nil {
			toolsHost.Objects = []fyne.CanvasObject{
				conPlaceholder(label + ": " + err.Error())}
			toolsHost.Refresh()
			return
		}
		toolCmd, toolPty = cmd, p
		term := fyneterm.New()
		barLabel := widget.NewLabel(label)
		start := time.Now()
		go func() {
			_ = term.RunWithConnection(p, p)
			fyne.Do(func() {
				if toolCmd != cmd {
					return // the pane already moved on to another tool
				}
				// a tool that exits within seconds just printed usage or an
				// error — KEEP it on screen so the operator can read it
				// (kube-cluster taught this); a real session's exit returns
				// to the launcher
				if time.Since(start) < 3*time.Second {
					stopTool()
					barLabel.SetText(label + " — exited; output above, ← tools to go back")
					return
				}
				stopTool()
				showToolTiles()
			})
		}()
		back := widget.NewButtonWithIcon("tools", theme.NavigateBackIcon(),
			func() { stopTool(); showToolTiles() })
		bar := container.NewBorder(nil, nil,
			back, nil, barLabel)
		toolsHost.Objects = []fyne.CanvasObject{
			container.NewBorder(bar, nil, nil, nil, term)}
		toolsHost.Refresh()
		if selectToolsTab != nil {
			selectToolsTab()
		}
		w.Canvas().Focus(term)
	}
	// toolIcon picks a themed glyph by what the tool does — the tiles read
	// as a launcher, not a wall of identical buttons.
	toolIcon := func(name string) fyne.Resource {
		switch {
		case name == "kvm-create" || name == "kspawn":
			return theme.ContentAddIcon()
		case name == "kvm-clone":
			return theme.ContentCopyIcon()
		case name == "kvm-delete":
			return theme.DeleteIcon()
		case name == "kvm-snap" || name == "ksnap":
			return theme.StorageIcon()
		case name == "kvm-list":
			return theme.ListIcon()
		case name == "kimage":
			return theme.DownloadIcon()
		case name == "kexport":
			return theme.UploadIcon()
		case strings.HasPrefix(name, "kube-"):
			return theme.GridIcon()
		case strings.HasSuffix(name, "-demo"):
			return theme.MediaPlayIcon()
		}
		return theme.ComputerIcon()
	}
	// toolAccent colours a tile by what the tool DOES, so the launcher is
	// scannable before a single label is read — the same colour language
	// the verb tiles already speak inside a tool (green makes, red
	// destroys, steel reads), lifted one level up to the tools themselves.
	//
	//	green  builds or creates something new
	//	blue   storage: snapshots, images, the ZFS consoles
	//	gold   read-only — looking, never touching
	//	red    destroys, and cannot be undone
	//	purple guided demos (the brand accent: these are the showpieces)
	//
	// Unknown tools fall through to gold rather than a neutral grey: a new
	// k-tool nobody has classified yet is, at worst, safe to look at.
	toolAccent := func(name string) accentPair {
		switch {
		case strings.HasSuffix(name, "-demo"):
			return acBrand
		case name == "kvm-delete":
			return acRed
		case name == "kvm-snap" || name == "ksnap" || name == "kexport" ||
			name == "kimage" || name == "zxplore":
			return acBlue
		case name == "kvm-list" || name == "kst":
			return acGold
		case name == "klab" || name == "kube-cluster" || name == "kspawn" ||
			name == "kvm-create" || name == "kvm-clone" || name == "kvm-win" ||
			name == "kzfs-lab":
			return acGreen
		case name == "shell":
			return acOff // a plain prompt: no verb, no colour to earn
		}
		return acGold
	}
	// ── the action catalog ───────────────────────────────────────────────
	// Curated from each tool's REAL usage banner (2026-08-07 sweep) —
	// most k-tools are `tool <subcommand>` CLIs, so a bare tile just
	// prints usage. Tapping a cataloged tile opens a second tile page of
	// its verbs; prompts collect the argument, %SEL% is the selected VM.
	// WARN: several tools treat argv[1] as a VM name (kvm-create built a
	// zvol called "--help" in testing) — argv here is exact and curated,
	// prompt text is field-split, nothing passes through a shell.
	type toolAction struct {
		label   string
		desc    string   // one line under the title — the tile explains itself
		argv    []string // %SEL% → selected VM name
		prompt  string   // non-empty: ask, append the fields to argv
		confirm bool     // destructive: show the exact argv first
		builds  bool     // creates something — tile renders green
	}
	toolActions := map[string][]toolAction{
		"kube-cluster": {
			{label: "status", desc: "nodes, versions, IPs — the cluster right now", argv: []string{"kube-cluster", "status"}},
			{label: "bootstrap…", desc: "golden image + full cluster, one shot", builds: true, argv: []string{"kube-cluster", "bootstrap"},
				prompt: "options (e.g. --workers 3, empty = defaults)"},
			{label: "golden", desc: "build the golden image only", builds: true, argv: []string{"kube-cluster", "golden"}},
			{label: "scale…", desc: "add worker nodes to the running cluster", builds: true, argv: []string{"kube-cluster", "scale"},
				prompt: "how many workers to add"},
			{label: "destroy", desc: "tear down the cluster — VMs and zvols", argv: []string{"kube-cluster", "destroy"},
				confirm: true},
		},
		// The OpenZFS Lab is a whole workflow, not one command: build
		// goldens once, clone them into a blue site, run the suite, stage
		// changes in green and promote when they pass. The verbs are
		// grouped in that order so the tile grid reads as the process.
		"kzfs-lab": {
			{label: "status", desc: "every VM, site and snapshot in the lab", argv: []string{"kzfs-lab", "status"}},
			{label: "health…", desc: "system health dashboard for a site", argv: []string{"kzfs-lab", "health"},
				prompt: "site (blue/green, empty = blue)"},
			{label: "build…", desc: "golden images with the ZFS dev tools baked in", builds: true, argv: []string{"kzfs-lab", "build"},
				prompt: "distro or all (centos rocky fedora debian ubuntu arch)"},
			{label: "deploy blue", desc: "clone the goldens into the blue site", builds: true, argv: []string{"kzfs-lab", "deploy", "blue"}},
			{label: "deploy green", desc: "clone the goldens into green — the staging site", builds: true, argv: []string{"kzfs-lab", "deploy", "green"}},
			{label: "test…", desc: "quick ZFS tests across the site's VMs", argv: []string{"kzfs-lab", "test"},
				prompt: "distro or all"},
			{label: "test-full…", desc: "the complete zfs-tests.sh suite — slow", argv: []string{"kzfs-lab", "test-full"},
				prompt: "distro (empty = all)"},
			{label: "ebpf-latency…", desc: "I/O latency across the site, measured with eBPF", argv: []string{"kzfs-lab", "ebpf-latency"},
				prompt: "site (empty = blue)"},
			{label: "ebpf-arc…", desc: "ARC hit/miss ratios across the site", argv: []string{"kzfs-lab", "ebpf-arc"},
				prompt: "site (empty = blue)"},
			{label: "snapshot…", desc: "tag every lab VM at once", argv: []string{"kzfs-lab", "snapshot"},
				prompt: "tag (empty = timestamp)"},
			{label: "promote green", desc: "green becomes blue — blue is snapshotted first", argv: []string{"kzfs-lab", "promote", "green"},
				confirm: true},
			{label: "rollback", desc: "revert blue to its previous snapshot", argv: []string{"kzfs-lab", "rollback"},
				confirm: true},
			{label: "destroy…", desc: "tear down a site; goldens are preserved", argv: []string{"kzfs-lab", "destroy"},
				prompt: "blue, green, all or goldens", confirm: true},
		},
		"kspawn": {
			{label: "list", desc: "every spawned cluster", argv: []string{"kspawn", "list"}},
			{label: "spawn…", desc: "instant multi-node cluster from klab goldens", builds: true, argv: []string{"kspawn", "spawn"},
				prompt: "flags (see kspawn spawn -h; empty = defaults)"},
			{label: "status…", desc: "one cluster's live state", argv: []string{"kspawn", "status"},
				prompt: "cluster name"},
			{label: "ssh…", desc: "straight into a cluster node", argv: []string{"kspawn", "ssh"},
				prompt: "cluster [node N]"},
			{label: "destroy…", desc: "cluster and all its zvols, gone", argv: []string{"kspawn", "destroy"},
				prompt: "cluster name", confirm: true},
		},
		"kimage": {
			{label: "build", desc: "prep this system as a cloud-init golden", builds: true, argv: []string{"kimage", "build"}},
			{label: "export qcow2", desc: "golden as qcow2", builds: true, argv: []string{"kimage", "export", "qcow2"}},
			{label: "export raw", desc: "golden as raw disk", builds: true, argv: []string{"kimage", "export", "raw"}},
			{label: "export vhd", desc: "golden as VHD", builds: true, argv: []string{"kimage", "export", "vhd"}},
			{label: "export vmdk", desc: "golden as VMDK", builds: true, argv: []string{"kimage", "export", "vmdk"}},
			{label: "export all", desc: "golden in every format", builds: true, argv: []string{"kimage", "export", "all"}},
			{label: "deploy…", desc: "stamp N VMs out of an image", builds: true, argv: []string{"kimage", "deploy"},
				prompt: "<image> <count>"},
			{label: "full…", desc: "build + export + deploy, one shot", builds: true, argv: []string{"kimage", "full"},
				prompt: "[count] (empty = 1)"},
		},
		// kexport takes a raw disk — for the selected VM that's its zvol
		// (%DS% → /dev/zvol/<dataset>), so every format is one click.
		// Sealed by default (portable golden: no machine-id/host keys).
		"kexport": {
			{label: "VM → qcow2 (KVM/Proxmox)", desc: "KVM / Proxmox / OpenStack, compressed", builds: true, argv: []string{"kexport", "%DS%", "qcow2"}},
			{label: "VM → raw (dd)", desc: "dd-ready sparse disk image", builds: true, argv: []string{"kexport", "%DS%", "raw"}},
			{label: "VM → vhd (Azure/Hyper-V)", desc: "Azure / Hyper-V", builds: true, argv: []string{"kexport", "%DS%", "vhd"}},
			{label: "VM → vmdk (VMware)", desc: "VMware ESXi / vSphere", builds: true, argv: []string{"kexport", "%DS%", "vmdk"}},
			{label: "VM → ova (portable)", desc: "VMware / VirtualBox portable", builds: true, argv: []string{"kexport", "%DS%", "ova"}},
			{label: "VM → oci (docker/podman)", desc: "docker load / podman load tarball", builds: true, argv: []string{"kexport", "%DS%", "oci"}},
			{label: "VM → lxc template", desc: "LXC template tarball", builds: true, argv: []string{"kexport", "%DS%", "lxc"}},
			{label: "VM → firecracker", desc: "kernel + rootfs + config.json", builds: true, argv: []string{"kexport", "%DS%", "firecracker"}},
			{label: "VM → ALL VM formats", desc: "qcow2+raw+vhd+vmdk+ova in one run", builds: true, argv: []string{"kexport", "%DS%", "all"}},
		},
		"kvm-win": {
			{label: "golden win11", desc: "unattended EVAL install → sealed golden", builds: true, argv: []string{"kvm-win", "golden", "win11"}},
			{label: "golden win11 + WSL", desc: "Win11 golden with WSL2 baked in", builds: true, argv: []string{"kvm-win", "golden", "win11", "--wsl"}},
			{label: "golden server", desc: "Windows Server golden", builds: true, argv: []string{"kvm-win", "golden", "server"}},
			{label: "create…", desc: "instant clone of a Windows golden", builds: true, argv: []string{"kvm-win", "create"},
				prompt: "NAME --os win11|server [--ram MB] [--cpus N]"},
		},
		"ksnap": {
			{label: "snapshot all", desc: "snapshot all key datasets now", builds: true, argv: []string{"ksnap"}},
			{label: "list", desc: "every snapshot on the host", argv: []string{"ksnap", "list"}},
			{label: "rollback…", desc: "path back to its last snapshot", argv: []string{"ksnap", "rollback"},
				prompt: "path", confirm: true},
			{label: "destroy…", desc: "drop one snapshot", argv: []string{"ksnap", "destroy"},
				prompt: "snapshot name", confirm: true},
		},
		"kvm-clone": {
			{label: "clone selected VM…", desc: "zero-copy — shares blocks until it diverges", builds: true, argv: []string{"kvm-clone", "%SEL%"},
				prompt: "name for the new VM"},
		},
		"kvm-create": {
			{label: "create…", desc: "fresh zvol + virt-install", builds: true, argv: []string{"kvm-create"},
				prompt: "new VM name"},
		},
		"kvm-snap": {
			{label: "snapshot selected VM", desc: "crash-consistent zvol snapshot", builds: true, argv: []string{"kvm-snap", "%SEL%"}},
		},
		"kvm-delete": {
			{label: "delete selected VM", desc: "undefine the domain, remove its storage", argv: []string{"kvm-delete", "%SEL%"},
				confirm: true},
		},
	} // kvm-demo and kube-demo are their own interactive menus — bare tiles

	// toolDesc is the one-liner on each top-level tile — a screenshot of
	// this grid should explain the product on its own.
	toolDesc := map[string]string{
		"klab":         "multi-distro lab VMs from goldens — interactive",
		"kube-cluster": "Kubernetes on ZFS: bootstrap, scale, status",
		"kspawn":       "instant multi-node clusters from ZFS clones",
		"kvm-create":   "new VM on a fresh zvol",
		"kvm-clone":    "instant copy-on-write clone of a VM",
		"kvm-delete":   "remove a VM and its storage",
		"kvm-snap":     "snapshot a VM's zvol",
		"kvm-list":     "every VM with state, RAM and ZFS usage",
		"kimage":       "golden cloud-init images: build, export, deploy",
		"kexport":      "ship the selected VM anywhere — 9 formats, sealed",
		"kvm-win":      "Windows goldens: unattended, virtio, TPM, WSL",
		"ksnap":        "host-level ZFS snapshots and rollback",
		"kvm-demo":     "guided KVM / ZFS / GPU showcase",
		"kube-demo":    "guided Kubernetes-on-ZFS showcase",
		"kzfs-lab":     "OpenZFS Lab: goldens, blue/green sites, ZFS tests, eBPF",
		"zxplore":      "the ZFS console: pools, datasets, snapshots, clones",
		"kst":          "this host at a glance: pool health, capacity, build",
		"shell":        "a plain bash prompt, right here",
	}

	var showToolActions func(tool string)
	fire := func(act toolAction, extra string) {
		argv := make([]string, 0, len(act.argv)+2)
		for _, aa := range act.argv {
			switch aa {
			case "%SEL%":
				r, ok := st.selected()
				if !ok {
					dialog.ShowInformation(act.argv[0],
						"select a VM in the estate list first", w)
					return
				}
				aa = r.D.Name
			case "%DS%":
				r, ok := st.selected()
				if !ok || r.DS == nil {
					dialog.ShowInformation(act.argv[0],
						"select a VM with a local zvol first", w)
					return
				}
				aa = "/dev/zvol/" + r.DS.Name
			}
			argv = append(argv, aa)
		}
		argv = append(argv, strings.Fields(extra)...)
		if act.confirm {
			dialog.ShowConfirm(act.argv[0],
				"run:  "+strings.Join(argv, " "), func(ok bool) {
					if ok {
						runArgv(argv)
					}
				}, w)
			return
		}
		runArgv(argv)
	}
	showToolActions = func(tool string) {
		acts := toolActions[tool]
		tiles := make([]fyne.CanvasObject, 0, len(acts))
		for _, act := range acts {
			act := act
			// colour says what a verb does before you read it, in the
			// same language as the tools grid one level up: green
			// builds, red destroys, gold reads. Nothing is left neutral
			// — a grey tile reads as disabled, not as safe.
			col := acGold.at()
			switch {
			case act.confirm:
				col = acRed.at()
			case act.builds:
				col = acGreen.at()
			}
			tiles = append(tiles, newTile(toolIcon(tool), act.label,
				act.desc, col, func() {
					if act.prompt == "" {
						fire(act, "")
						return
					}
					entry := widget.NewEntry()
					entry.SetPlaceHolder(act.prompt)
					dialog.ShowCustomConfirm(tool+" "+act.label, "Run", "Cancel",
						entry, func(ok bool) {
							if ok {
								fire(act, entry.Text)
							}
						}, w)
				}))
		}
		back := widget.NewButtonWithIcon("tools", theme.NavigateBackIcon(),
			func() { showToolTiles() })
		bar := container.NewBorder(nil, nil, back, nil,
			container.NewCenter(pageHeading(tool, acGold)))
		grid := container.NewGridWrap(fyne.NewSize(250, 96), tiles...)
		toolsHost.Objects = []fyne.CanvasObject{container.NewBorder(
			bar, nil, nil, nil,
			container.NewVScroll(container.NewPadded(grid)))}
		toolsHost.Refresh()
	}
	openTool := func(tool string) {
		if _, ok := toolActions[tool]; ok {
			showToolActions(tool)
			return
		}
		runArgv([]string{tool})
	}

	showToolTiles = func() {
		if len(ktools) == 0 {
			// the promotion surface on generic hosts — tier 3, sold not faked
			get := widget.NewButtonWithIcon(
				"Get kldload — unlock the estate extras", theme.ComputerIcon(),
				func() {
					u, _ := url.Parse("https://kldload.com")
					_ = a.OpenURL(u)
				})
			toolsHost.Objects = []fyne.CanvasObject{container.NewCenter(
				container.NewVBox(widget.NewLabel(
					"kldload hosts grow a tool launcher here —\n"+
						"cluster builds, golden images, demos, one click."), get))}
			toolsHost.Refresh()
			return
		}
		tiles := make([]fyne.CanvasObject, 0, len(ktools)+1)
		for _, t := range append(append([]string{}, ktools...), "shell") {
			t := t
			tiles = append(tiles, newTile(toolIcon(t), t, toolDesc[t],
				toolAccent(t).at(), func() { openTool(t) }))
		}
		// The legend is spelled out because a colour language nobody
		// explains is decoration. One line, once, at the top.
		legend := widget.NewLabel(
			"green builds · blue storage · gold reads · red destroys · purple demos")
		legend.TextStyle = fyne.TextStyle{Italic: true}
		head := container.NewVBox(
			pageHeading("kldload tools", acBrand),
			widget.NewLabel("clusters, goldens, clones, demos — they run right here"),
			legend)
		grid := container.NewGridWrap(fyne.NewSize(250, 96), tiles...)
		toolsHost.Objects = []fyne.CanvasObject{container.NewBorder(
			container.NewPadded(head), nil, nil, nil,
			container.NewVScroll(container.NewPadded(grid)))}
		toolsHost.Refresh()
	}
	showToolTiles()

	// conName/conState remember what the panes are actually attached TO,
	// as opposed to what is merely selected — the refresh loop compares
	// against these to notice a machine that changed underneath a standing
	// attachment. conLast* are the previous poll's sample, which is what
	// makes a restart detectable at all (see the refresh loop).
	var conName, conState, conLastName string
	var conCPU uint64

	// followConsole keeps both panes in lock-step with the selection.
	followConsole := func(r Row) {
		conName, conState = r.D.Name, r.D.State
		if r.D.State == "running" && !r.Synthetic {
			attachConsole(r.D.Name)
			attachVNC(r.D.Name)
			return
		}
		detachConsole()
		detachVNC()
		msg := r.D.Name + " is " + r.D.State + " — console attaches when it runs"
		consoleHost.Objects = []fyne.CanvasObject{conPlaceholder(msg)}
		consoleHost.Refresh()
		vncHost.Objects = []fyne.CanvasObject{conPlaceholder(msg)}
		vncHost.Refresh()
	}

	// ── right-bottom: dossier + verbs ────────────────────────────────────
	dossier := widget.NewRichText(&widget.TextSegment{
		Text:  "select a VM — everything about it lives here",
		Style: widget.RichTextStyle{TextStyle: fyne.TextStyle{Monospace: true}}})
	dossier.Wrapping = fyne.TextWrapWord // lineage/disk lines run long
	renderDossier := func(r Row) {
		dossier.Segments = st.dossierSegs(r)
		dossier.Refresh()
	}
	status := widget.NewLabel(fmt.Sprintf("vmxplore %s · rules: %s",
		versionFull(), rs.Source))
	// every verb fires without a dialog and reports here
	guiStatus = func(s string) { fyne.Do(func() { status.SetText(s) }) }

	// ── the verb toolbar ─────────────────────────────────────────────────
	// Two tiers, mirroring how operators think: the power verbs are
	// always-visible icon buttons; everything else lives behind labelled
	// dropdown menus (Storage / Configure / Build / Estate) so the pane
	// stays organized as verbs accumulate. Every path funnels through the
	// same plan builders as the TUI, fired the same way.
	var refreshNow func()
	withSel := func(f func(Row)) func() {
		return func() {
			if r, ok := st.selected(); ok {
				f(r)
			}
		}
	}
	verb := func(build func(Row) (verbPlan, error)) func() {
		return withSel(func(r Row) {
			p, err := build(r)
			if err != nil {
				dialog.ShowError(err, w)
				return
			}
			firePlan(w, p, func() { refreshNow() })
		})
	}

	// name-input dialogs share this shape: label, entry, plan on confirm
	nameDialog := func(title, placeholder string, plan func(Row, string) (verbPlan, error)) func() {
		return withSel(func(r Row) {
			entry := widget.NewEntry()
			entry.SetPlaceHolder(placeholder)
			dialog.ShowCustomConfirm(title, "Next", "Cancel", entry,
				func(ok bool) {
					if !ok {
						return
					}
					p, err := plan(r, strings.TrimSpace(entry.Text))
					if err != nil {
						dialog.ShowError(err, w)
						return
					}
					firePlan(w, p, func() { refreshNow() })
				}, w)
		})
	}

	rollbackDialog := withSel(func(r Row) {
		if r.DS == nil {
			dialog.ShowInformation("rollback", "no local dataset behind this VM", w)
			return
		}
		all := st.snaps[r.DS.Name]
		if len(all) == 0 {
			dialog.ShowInformation("rollback", "no snapshots on "+r.DS.Name, w)
			return
		}
		// newest last, like the TUI snaps pane; selecting computes how many
		// newer snapshots -r will destroy — the plan's warning carries it
		opts := make([]string, len(all))
		for i, s := range all {
			opts[len(all)-1-i] = s // newest first for the dropdown
		}
		sel := widget.NewSelect(opts, nil)
		sel.PlaceHolder = "snapshot…"
		dialog.ShowCustomConfirm("rollback "+r.DS.Name, "Next", "Cancel",
			sel, func(ok bool) {
				if !ok || sel.Selected == "" {
					return
				}
				newer := 0
				for i, s := range all {
					if s == sel.Selected {
						newer = len(all) - i - 1
						break
					}
				}
				p, err := planRollback(r, sel.Selected, newer)
				if err != nil {
					dialog.ShowError(err, w)
					return
				}
				firePlan(w, p, func() { refreshNow() })
			}, w)
	})

	specsDialog := withSel(func(r Row) {
		vcpus := widget.NewEntry()
		vcpus.SetText(fmt.Sprint(r.D.VCPUs))
		mem := widget.NewEntry()
		mem.SetText(fmt.Sprint(r.D.MaxMemKiB / (1024 * 1024)))
		form := container.NewVBox(
			widget.NewLabel("vCPUs:"), vcpus,
			widget.NewLabel("memory (GiB):"), mem)
		dialog.ShowCustomConfirm("vCPU / memory — "+r.D.Name+" (applies next start)",
			"Next", "Cancel", form, func(ok bool) {
				if !ok {
					return
				}
				var c, g int
				if _, err := fmt.Sscanf(strings.TrimSpace(vcpus.Text), "%d", &c); err != nil || c < 1 {
					dialog.ShowError(fmt.Errorf("vcpus must be a positive number"), w)
					return
				}
				if _, err := fmt.Sscanf(strings.TrimSpace(mem.Text), "%d", &g); err != nil || g < 1 {
					dialog.ShowError(fmt.Errorf("memory must be a positive number of GiB"), w)
					return
				}
				p, err := planSpecs(r, c, g)
				if err != nil {
					dialog.ShowError(err, w)
					return
				}
				firePlan(w, p, func() { refreshNow() })
			}, w)
	})

	// menuButton drops a popup menu under the button — the submenu chrome.
	menuButton := func(label string, icon fyne.Resource, items ...*fyne.MenuItem) *widget.Button {
		var b *widget.Button
		b = widget.NewButtonWithIcon(label, icon, func() {
			m := widget.NewPopUpMenu(fyne.NewMenu("", items...), w.Canvas())
			pos := fyne.CurrentApp().Driver().AbsolutePositionForObject(b)
			m.ShowAtPosition(pos.Add(fyne.NewPos(0, b.Size().Height)))
		})
		return b
	}
	soon := func(what, when string) func() {
		return func() {
			dialog.ShowInformation(what,
				what+" lands in "+when+" — designed, not built yet.\n"+
					"The kldload webui does this today.", w)
		}
	}

	// The action row speaks one language, in two families.
	//
	// Lifecycle verbs are traffic lights — green runs it, amber stops it
	// politely, red pulls the plug — so the consequence is legible before
	// the label is read. Everything else is a MENU rather than an act, and
	// those all carry the brand accent so they read as one family and never
	// as something that is about to happen to a machine.
	//
	// The palette is Fyne's Importance rather than hand-painted colour:
	// Success/Warning/Danger/High are the four the theme already resolves
	// per light and dark variant, so the row stays right when GNOME flips
	// and nothing here has to be repainted by applyPalette.
	btnStart := widget.NewButtonWithIcon("Start", theme.MediaPlayIcon(), verb(planStart))
	btnStart.Importance = widget.SuccessImportance
	btnStop := widget.NewButtonWithIcon("Shut down", theme.MediaStopIcon(), verb(planShutdown))
	btnStop.Importance = widget.WarningImportance
	btnKill := widget.NewButtonWithIcon("Force off", theme.ErrorIcon(), verb(planForceOff))
	btnKill.Importance = widget.DangerImportance

	snapAct := nameDialog("zfs snapshot @manual-…",
		"suffix (empty = timestamp)", planSnapshot)

	// New VM: the native cloud-image pipeline (newvm.go). The dialog is a
	// form; the pipeline streams its exact commands into the status bar
	// and the estate refreshes when the domain lands.
	newVMDialog := func() {
		name := widget.NewEntry()
		name.SetPlaceHolder("vm name")
		// build mode: a cloud image (fast — cloud-init, preset user) or an
		// installer ISO (boot the distro's own installer in the Screen
		// tab, run apt/dnf/pacman the normal way; any ISO — Debian, Fedora,
		// an Arch live ISO, a RHEL DVD)
		mode := widget.NewSelect([]string{"cloud image", "installer ISO"}, nil)
		mode.SetSelected("cloud image")
		distro := widget.NewSelect(append(CloudDistros(), "custom image…"), nil)
		distro.SetSelected("fedora")
		imgPath := widget.NewEntry()
		imgPath.SetPlaceHolder("/path/to/image.qcow2 (custom only)")
		imgPath.Hide()
		isoPath := widget.NewEntry()
		isoPath.SetPlaceHolder("/path/to/installer.iso")
		vcpus := widget.NewEntry()
		vcpus.SetText("2")
		ram := widget.NewEntry()
		ram.SetText("2048")
		diskGB := widget.NewEntry()
		diskGB.SetText("20")
		// Prefilled, not placeholdered: an empty password box and an
		// empty key box build a VM with no way in, and a grey hint is
		// too easy to read as "already handled".
		user := widget.NewEntry()
		user.SetText("admin")
		pass := widget.NewEntry()
		pass.SetText(DefaultGuestPassword)
		key := widget.NewEntry()
		key.SetPlaceHolder("ssh public key (optional)")
		key.SetText(pickPubKey())
		// the custom post-installer: bash run as root on first boot. This
		// is "build your own image" — install packages, drop configs, then
		// Make Golden → Clone. A Load… button reuses a script from disk.
		post := widget.NewMultiLineEntry()
		post.SetPlaceHolder("# post-install bash — runs once, as root, on first boot\n" +
			"# e.g.  dnf install -y nginx && systemctl enable --now nginx")
		post.SetMinRowsVisible(5)
		loadPost := widget.NewButtonWithIcon("Load…", theme.FolderOpenIcon(),
			func() {
				fd := dialog.NewFileOpen(func(rc fyne.URIReadCloser, err error) {
					if err != nil || rc == nil {
						return
					}
					defer rc.Close()
					if b, e := os.ReadFile(rc.URI().Path()); e == nil {
						post.SetText(string(b))
					}
				}, w)
				fd.Show()
			})
		// cloud-only fields hide in installer mode (the guest's installer
		// collects user/packages/layout itself)
		// NVIDIA mode, offered only where it could possibly work.
		//
		// The tool tiers itself by what the host can DO — the same probe
		// rule the kldload toolset follows — so this checkbox exists only
		// when the hypervisor actually has an NVIDIA card in it. On a
		// machine with no GPU it would be several hundred megabytes of
		// driver, ten minutes of build, and nothing to drive.
		//
		// The label says what it does AND what it does not: installing the
		// driver is the guest half. Handing the card to the guest is a
		// host-side passthrough job that this checkbox does not do.
		gpus := HostGPUs()
		nvidia := widget.NewCheck("NVIDIA drivers in the guest", nil)
		nvidiaRow := container.NewVBox(nvidia)
		if NVIDIAHost(gpus) {
			what := "an NVIDIA card"
			for _, g := range gpus {
				if g.IsNVIDIA() && g.Model != "" {
					what = g.Model
					break
				}
			}
			note := widget.NewLabel("host has " + what +
				" — the guest still needs the card passed through to use it")
			if !IOMMUEnabled() {
				note.SetText("host has " + what +
					" — but the IOMMU is off, so no card can be passed to a guest yet")
			}
			note.Wrapping = fyne.TextWrapWord
			note.TextStyle = fyne.TextStyle{Italic: true}
			nvidiaRow.Add(note)
		} else {
			nvidiaRow.Hide()
		}
		cloudOnly := container.NewVBox(
			widget.NewLabel("distro"), distro, imgPath,
			widget.NewLabel("user"), user,
			widget.NewLabel("password"), pass,
			widget.NewLabel("ssh key"), key,
			nvidiaRow,
			container.NewBorder(nil, nil,
				widget.NewLabel("post-install"), loadPost),
			post)
		isoRow := container.NewVBox(widget.NewLabel("installer ISO"), isoPath)
		isoRow.Hide()
		distro.OnChanged = func(s string) {
			if s == "custom image…" {
				imgPath.Show()
			} else {
				imgPath.Hide()
			}
		}
		mode.OnChanged = func(s string) {
			if s == "installer ISO" {
				cloudOnly.Hide()
				isoRow.Show()
			} else {
				cloudOnly.Show()
				isoRow.Hide()
			}
		}
		form := container.NewVBox(
			widget.NewLabel("name"), name,
			widget.NewLabel("source"), mode,
			isoRow,
			cloudOnly,
			container.NewGridWithColumns(3,
				container.NewVBox(widget.NewLabel("vCPUs"), vcpus),
				container.NewVBox(widget.NewLabel("RAM (MB)"), ram),
				container.NewVBox(widget.NewLabel("disk (GB)"), diskGB)),
		)
		d := dialog.NewCustomConfirm("New VM — cloud image or installer ISO",
			"Create", "Cancel", container.NewVScroll(form), func(ok bool) {
				if !ok {
					return
				}
				var c, m, g int
				fmt.Sscanf(strings.TrimSpace(vcpus.Text), "%d", &c)
				fmt.Sscanf(strings.TrimSpace(ram.Text), "%d", &m)
				fmt.Sscanf(strings.TrimSpace(diskGB.Text), "%d", &g)
				spec := NewVMSpec{
					Name:  strings.TrimSpace(name.Text),
					VCPUs: c, RAMMB: m, DiskGB: g,
				}
				if mode.Selected == "installer ISO" {
					spec.ISOPath = strings.TrimSpace(isoPath.Text)
				} else {
					spec.User = strings.TrimSpace(user.Text)
					spec.Password = pass.Text
					spec.SSHKey = strings.TrimSpace(key.Text)
					spec.PostInst = post.Text
					// Composed, not merged: the driver layer runs first
					// and reboots, and cloud-init resumes the operator's
					// own script on the way back up.
					if nvidia.Checked {
						spec.PostInst = nvidiaGuestScript + "\n" + post.Text
					}
					if distro.Selected == "custom image…" {
						spec.ImagePath = strings.TrimSpace(imgPath.Text)
					} else {
						spec.Distro = distro.Selected
					}
				}
				done := "created — cloud-init finishes the first boot"
				if spec.install() {
					done = "created — open the Screen tab and run the installer"
				}
				parent := ZFSVMParent(st.visibleRows())
				// Focus the machine being built, and show it. Selection
				// follows the domain BY NAME across refreshes (see the
				// refresh loop), so naming it here means the estate list
				// jumps to the new VM the moment it first appears; the tab
				// switch means the operator is looking at its first boot
				// rather than at the form they just submitted. That boot is
				// the part worth watching and it is over before the build
				// call returns.
				st.selName = spec.Name
				if selectScreenTab != nil {
					selectScreenTab()
				}
				go func() {
					err := BuildNewVM(spec, parent, func(line string) {
						fyne.Do(func() { status.SetText(line) })
					})
					fyne.Do(func() {
						if err != nil {
							dialog.ShowError(err, w)
							return
						}
						refreshNow()
						// The status line, not a modal: the VM is already
						// built and in the list by now, so a popup asking to
						// be dismissed is pure friction between the operator
						// and the machine they just made.
						status.SetText(spec.Name + " " + done)
					})
				}()
			}, w)
		d.Resize(fyne.NewSize(460, 560))
		d.Show()
	}

	// Appliances: the catalog (appliances.go) as a button. Picking an entry
	// fixes the distro and sizing and supplies the post-install script, so
	// the only things left to answer are app-specific — which is the whole
	// point: "give me a blog" instead of "give me a Debian VM, then follow
	// a writeup." The build path is the ordinary New VM pipeline.
	// preselect names the catalog entry to open on; empty picks the first.
	// The left-tree catalog branch passes the entry that was clicked.
	applianceDialog := func(preselect string) {
		catalog := Appliances()
		if len(catalog) == 0 {
			dialog.ShowInformation("Applications", "The catalog is empty.", w)
			return
		}
		if _, ok := ApplianceByName(preselect); !ok {
			preselect = catalog[0].Name
		}
		name := widget.NewEntry()
		name.SetPlaceHolder("vm name")
		pick := widget.NewSelect(ApplianceNames(), nil)
		summary := widget.NewLabel("")
		summary.Wrapping = fyne.TextWrapWord
		notes := widget.NewLabel("")
		notes.Wrapping = fyne.TextWrapWord
		notes.TextStyle = fyne.TextStyle{Italic: true}
		// fields is rebuilt on every pick; entries indexes the live widgets
		// by field key so the submit handler can read them back.
		fields := container.NewVBox()
		entries := map[string]*widget.Entry{}
		current := catalog[0]

		// The VM's own account, and prefilled for the same reason as New
		// VM: this dialog carries TWO credential pairs — the app's admin
		// login above and the machine's login here — and the machine's
		// were the easy ones to leave blank.
		user := widget.NewEntry()
		user.SetText("admin")
		pass := widget.NewEntry()
		pass.SetText(DefaultGuestPassword)
		key := widget.NewEntry()
		key.SetPlaceHolder("ssh public key (optional)")
		key.SetText(pickPubKey())

		rebuild := func(appName string) {
			a, ok := ApplianceByName(appName)
			if !ok {
				return
			}
			current = a
			summary.SetText(fmt.Sprintf("%s — %s\n%s · %s · %d vCPU, %d MB, %d GB",
				a.Name, a.Summary, a.License, a.Distro, a.VCPUs, a.RAMMB, a.DiskGB))
			notes.SetText(a.Notes)
			fields.RemoveAll()
			entries = map[string]*widget.Entry{}
			for _, f := range a.Fields {
				var e *widget.Entry
				if f.Secret {
					e = widget.NewPasswordEntry()
				} else {
					e = widget.NewEntry()
				}
				e.SetText(f.Default)
				e.SetPlaceHolder(f.Placeholder)
				entries[f.Key] = e
				fields.Add(widget.NewLabel(f.Label))
				fields.Add(e)
			}
			fields.Refresh()
		}
		pick.OnChanged = rebuild
		pick.SetSelected(preselect)

		// The two credential blocks are labelled as a pair of opposites
		// on purpose. Filling the app's login and leaving the machine's
		// blank is the mistake this dialog invites, and the result used
		// to be a VM that served its app perfectly and could not be
		// logged into at all.
		appHead := widget.NewLabel("the app's own login — you sign into the website with this")
		appHead.TextStyle = fyne.TextStyle{Bold: true}
		vmHead := widget.NewLabel("the machine's login — console and ssh, not the app")
		vmHead.TextStyle = fyne.TextStyle{Bold: true}
		form := container.NewVBox(
			widget.NewLabel("appliance"), pick, summary,
			widget.NewSeparator(),
			widget.NewLabel("vm name"), name,
			appHead,
			fields,
			widget.NewSeparator(),
			vmHead,
			user, pass, key,
			widget.NewSeparator(),
			notes,
		)
		d := dialog.NewCustomConfirm("Application — a configured app in one shot",
			"Build", "Cancel", container.NewVScroll(form), func(ok bool) {
				if !ok {
					return
				}
				vals := map[string]string{}
				for k, e := range entries {
					vals[k] = e.Text
				}
				a := current
				spec, err := a.Spec(name.Text, user.Text, pass.Text, key.Text, vals)
				if err != nil {
					// Field validation lives in the catalog entry, so a bad
					// value is reported here rather than 90 seconds later in
					// the guest's cloud-init log.
					dialog.ShowError(err, w)
					return
				}
				parent := ZFSVMParent(st.visibleRows())
				// Focus the machine being built, and show it. Selection
				// follows the domain BY NAME across refreshes (see the
				// refresh loop), so naming it here means the estate list
				// jumps to the new VM the moment it first appears; the tab
				// switch means the operator is looking at its first boot
				// rather than at the form they just submitted. That boot is
				// the part worth watching and it is over before the build
				// call returns.
				st.selName = spec.Name
				if selectScreenTab != nil {
					selectScreenTab()
				}
				go func() {
					err := BuildNewVM(spec, parent, func(line string) {
						fyne.Do(func() { status.SetText(line) })
					})
					fyne.Do(func() {
						if err != nil {
							dialog.ShowError(err, w)
							return
						}
						refreshNow()
						// No modal: the build already narrated itself here,
						// ending with the appliance's real URL, and the
						// catalog entry's notes carry the rest. Where it
						// lands is the one thing worth repeating.
						// The machine login goes in the line too: the
						// app's credentials are in the guest's /root/,
						// but you need to get in to read them.
						status.SetText(fmt.Sprintf(
							"%s — %s ready · %s · machine login %s/%s · "+
								"app credentials in /root/ inside the guest",
							spec.Name, a.Name, a.LandsOn,
							spec.User, spec.Password))
					})
				}()
			}, w)
		d.Resize(fyne.NewSize(480, 620))
		d.Show()
	}
	// close the forward reference the catalog branch in the tree holds
	openAppliance = applianceDialog

	// EZ Fleet: one dialog → build a golden + N clones. The whole value
	// proposition in a gesture ("give me 5 Fedora boxes").
	fleetDialog := func() {
		name := widget.NewEntry()
		name.SetText("fleet")
		distro := widget.NewSelect(CloudDistros(), nil)
		distro.SetSelected("fedora")
		count := widget.NewEntry()
		count.SetText("5")
		ram := widget.NewEntry()
		ram.SetText("2048")
		diskGB := widget.NewEntry()
		diskGB.SetText("20")
		post := widget.NewMultiLineEntry()
		post.SetPlaceHolder("# optional post-install bash — baked into every clone")
		post.SetMinRowsVisible(4)
		form := container.NewVBox(
			widget.NewLabel("base name (clones: name-1…name-N)"), name,
			widget.NewLabel("distro"), distro,
			container.NewGridWithColumns(3,
				container.NewVBox(widget.NewLabel("clones"), count),
				container.NewVBox(widget.NewLabel("RAM (MB)"), ram),
				container.NewVBox(widget.NewLabel("disk (GB)"), diskGB)),
			widget.NewLabel("post-install (optional)"), post,
		)
		d := dialog.NewCustomConfirm("EZ Fleet — golden + clones in one shot",
			"Build", "Cancel", container.NewVScroll(form), func(ok bool) {
				if !ok {
					return
				}
				var n, m, g int
				fmt.Sscanf(strings.TrimSpace(count.Text), "%d", &n)
				fmt.Sscanf(strings.TrimSpace(ram.Text), "%d", &m)
				fmt.Sscanf(strings.TrimSpace(diskGB.Text), "%d", &g)
				spec := NewVMSpec{
					Name: strings.TrimSpace(name.Text), Distro: distro.Selected,
					VCPUs: 2, RAMMB: m, DiskGB: g,
					User: "admin", Password: "kldload", PostInst: post.Text,
				}
				parent := ZFSVMParent(st.visibleRows())
				// the golden appears first; the clones land under it
				st.selName = spec.Name
				if selectScreenTab != nil {
					selectScreenTab()
				}
				go func() {
					err := BuildFleet(spec, n, parent, func(line string) {
						fyne.Do(func() { status.SetText(line) })
					})
					fyne.Do(func() {
						if err != nil {
							dialog.ShowError(err, w)
							return
						}
						refreshNow()
						status.SetText(fmt.Sprintf(
							"%s golden + %d clones ready", spec.Name, n))
					})
				}()
			}, w)
		d.Resize(fyne.NewSize(460, 520))
		d.Show()
	}

	// Make Golden: shutdown → seal → @golden snapshot (golden.go). Then
	// clones boot as fresh machines.
	goldenAct := func() {
		r, ok := st.selected()
		if !ok {
			return
		}
		dialog.ShowConfirm("Make Golden",
			"Seal "+r.D.Name+" and snapshot it @golden?\n"+
				"It will be shut down, sysprepped, and become a clone template.",
			func(ok bool) {
				if !ok {
					return
				}
				go func() {
					err := MakeGolden(r, func(line string) {
						fyne.Do(func() { status.SetText(line) })
					})
					fyne.Do(func() {
						if err != nil {
							dialog.ShowError(err, w)
							return
						}
						refreshNow()
					})
				}()
			}, w)
	}
	// cloneAny picks the golden clone when a @golden anchor exists, else a
	// fresh-snapshot clone — one menu entry, right behaviour each time.
	cloneAny := func() {
		r, ok := st.selected()
		if !ok {
			return
		}
		plan := planClone
		if r.DS != nil && exec.Command("zfs", "list",
			r.DS.Name+"@golden").Run() == nil {
			plan = planCloneGolden
		}
		nameDialog("clone — name for the new VM", "new VM name", plan)()
	}
	mStorage := menuButton("Storage", theme.StorageIcon(),
		fyne.NewMenuItem("Snapshot…", snapAct),
		fyne.NewMenuItem("Rollback…", rollbackDialog))
	mConfig := menuButton("Configure", theme.SettingsIcon(),
		fyne.NewMenuItem("vCPU / memory…", specsDialog),
		fyne.NewMenuItem("Autostart on/off", verb(planAutostart)))
	mBuild := menuButton("Build", theme.ContentAddIcon(),
		fyne.NewMenuItem("New VM…", newVMDialog),
		fyne.NewMenuItem("Application — a configured app…",
			func() { applianceDialog("") }),
		fyne.NewMenuItem("EZ Fleet — golden + N clones…", fleetDialog),
		fyne.NewMenuItem("Clone…", cloneAny),
		fyne.NewMenuItem("Make Golden…", goldenAct))
	mEstate := menuButton("Estate", theme.ComputerIcon(),
		fyne.NewMenuItem("Migrate to host…", soon("Migrate (teleport)", "0.3")))

	// the right-click menu on an estate row: every verb, zero travel —
	// selects the row first so the verbs aim at what you clicked
	rowMenuAt = func(r Row, pos fyne.Position) {
		tree.Select("vm/" + r.D.Name)
		m := widget.NewPopUpMenu(fyne.NewMenu("",
			fyne.NewMenuItem("Start", verb(planStart)),
			fyne.NewMenuItem("Reboot", verb(planReboot)),
			fyne.NewMenuItem("Suspend", verb(planSuspend)),
			fyne.NewMenuItem("Resume", verb(planResume)),
			fyne.NewMenuItem("Shut down", verb(planShutdown)),
			fyne.NewMenuItem("Force off…", verb(planForceOff)),
			fyne.NewMenuItemSeparator(),
			fyne.NewMenuItem("Snapshot…", snapAct),
			fyne.NewMenuItem("Rollback…", rollbackDialog),
			fyne.NewMenuItem("Clone…", cloneAny),
			fyne.NewMenuItem("Make Golden…", goldenAct),
			fyne.NewMenuItemSeparator(),
			fyne.NewMenuItem("vCPU / memory…", specsDialog),
			fyne.NewMenuItem("Autostart on/off", verb(planAutostart)),
			fyne.NewMenuItemSeparator(),
			// no ellipsis: nothing opens, it deletes
			fyne.NewMenuItem("Delete", verb(planDelete)),
		), w.Canvas())
		m.ShowAtPosition(pos)
	}

	// ── batch bar: verbs over the checked set ────────────────────────────
	// Appears only when ≥1 VM is checked (dot-click). Every verb fires
	// across the set immediately — checking the rows and pressing the
	// button is the deliberate act; a dialog asking again is not.
	checkedRows := func() []Row {
		var rows []Row
		for _, g := range st.groups {
			for _, r := range g.Rows {
				if checked[r.D.Name] {
					rows = append(rows, r)
				}
			}
		}
		return rows
	}
	clearChecked := func() {
		for k := range checked {
			delete(checked, k)
		}
		tree.Refresh()
		refreshBatchBar()
	}
	// batchRun builds each row's plan and runs it — no confirmation step
	// once for the whole set. Per-VM errors are collected, not fatal — one
	// bad VM must not abort the rest of a 40-VM sweep.
	batchRun := func(label string, build func(Row) (verbPlan, error)) {
		rows := checkedRows()
		if len(rows) == 0 {
			return
		}
		fire := func() {
			go func() {
				var failed []string
				for _, r := range rows {
					p, err := build(r)
					if err == nil {
						err = runPlan(p)
					}
					if err != nil {
						failed = append(failed, r.D.Name+": "+err.Error())
					}
				}
				fyne.Do(func() {
					if len(failed) > 0 {
						dialog.ShowError(fmt.Errorf("%s — %d failed:\n%s",
							label, len(failed), strings.Join(failed, "\n")), w)
					}
					clearChecked()
					refreshNow()
				})
			}()
		}
		// No confirm, destructive or not: the operator picked the rows and
		// pressed the button, which is the same two deliberate acts a
		// dialog would have asked for again. Failures still surface, and
		// every command is in the audit log.
		fire()
	}
	batchBar := container.NewHBox()
	refreshBatchBar = func() {
		n := len(checkedRows())
		if n == 0 {
			batchBar.Hide()
			return
		}
		lbl := pageHeading(fmt.Sprintf("%d selected", n), acBrand)
		bStart := widget.NewButtonWithIcon("Start", theme.MediaPlayIcon(),
			func() { batchRun("Start", planStart) })
		bStart.Importance = widget.SuccessImportance
		bReboot := widget.NewButtonWithIcon("Reboot", theme.ViewRefreshIcon(),
			func() { batchRun("Reboot", planReboot) })
		bReboot.Importance = widget.HighImportance
		bStop := widget.NewButtonWithIcon("Shut down", theme.MediaStopIcon(),
			func() { batchRun("Shut down", planShutdown) })
		bStop.Importance = widget.WarningImportance
		bKill := widget.NewButtonWithIcon("Force off", theme.ErrorIcon(),
			func() { batchRun("Force off", planForceOff) })
		bKill.Importance = widget.DangerImportance
		bDel := widget.NewButtonWithIcon("Delete", theme.DeleteIcon(),
			func() { batchRun("Delete", planDelete) })
		bDel.Importance = widget.DangerImportance
		bClear := widget.NewButtonWithIcon("", theme.CancelIcon(), clearChecked)
		batchBar.Objects = []fyne.CanvasObject{
			lbl, bStart, bReboot, bStop, bKill, bDel, bClear}
		batchBar.Refresh()
		batchBar.Show()
	}
	batchBar.Hide()

	// NewPadded around every control: the bare HBox packs buttons at
	// theme padding (~4px) which reads cramped — this doubles the gutters
	// and floats the row off the dossier above it
	pad := func(o fyne.CanvasObject) fyne.CanvasObject {
		return container.NewPadded(o)
	}
	for _, m := range []*widget.Button{mStorage, mConfig, mBuild, mEstate} {
		m.Importance = widget.HighImportance
	}
	// Centred, not flush left: the row used to run off the right edge with
	// no margin left on it, which reads as truncated rather than as a row
	// that ended. The trailing gap is a fixed 20px rather than more theme
	// padding, because it is doing a different job — theme padding scales
	// with the theme, this is a deliberate margin at the end of a row of
	// buttons so the last one is never the last pixel.
	endGap := canvas.NewRectangle(color.Transparent)
	endGap.SetMinSize(fyne.NewSize(20, 1))
	buttons := container.NewPadded(container.NewCenter(container.NewHBox(
		pad(btnStart), pad(btnStop), pad(btnKill),
		widget.NewSeparator(),
		pad(mStorage), pad(mConfig), pad(mBuild), pad(mEstate), endGap)))

	// ── selection → panes ────────────────────────────────────────────────
	// A branch (group header) toggles its own fold; a leaf drives the panes.
	tree.OnSelected = func(uid string) {
		if isBranch(uid) {
			if tree.IsBranchOpen(uid) {
				tree.CloseBranch(uid)
			} else {
				tree.OpenBranch(uid)
			}
			tree.Unselect(uid)
			return
		}
		// A catalog leaf is an action, not a selection: opening the build
		// dialog is the whole point, and leaving it selected would strand
		// the dossier and console panes on a VM that does not exist yet.
		// (The leaf's own tap handler covers mouse clicks; this is the
		// path keyboard navigation takes.)
		if name, ok := strings.CutPrefix(uid, applianceUIDPrefix); ok {
			tree.Unselect(uid)
			if openAppliance != nil {
				openAppliance(name)
			}
			return
		}
		r, ok := rowByUID(uid)
		if !ok {
			return
		}
		st.selName = r.D.Name
		renderDossier(r)
		followConsole(r)
	}

	search := widget.NewEntry()
	search.SetPlaceHolder("filter VMs…")
	search.OnChanged = func(q string) {
		st.filter = q
		rebuildView()
		tree.Refresh()
	}

	// foldOffGroups: on first paint, collapse groups with nothing running —
	// "off doesn't need to be expanded" (operator). Runs once so it never
	// fights a manual toggle later.
	didFold := false
	foldOffGroups := func() {
		for _, g := range viewGroups {
			if _, run := groupStats(g.Label); run == 0 {
				tree.CloseBranch("grp/" + g.Label)
			} else {
				tree.OpenBranch("grp/" + g.Label)
			}
		}
	}

	// ── refresh: estate every 2s, ZFS every 30s (the TUI cadence) ────────
	apply := func(doms []Dom, cpuRaw map[string]uint64, at time.Time) {
		if !st.prevAt.IsZero() {
			st.cpu = cpuPercent(st.prevCPU, cpuRaw, at.Sub(st.prevAt), doms)
		}
		st.prevCPU, st.prevAt = cpuRaw, at
		st.groups = BuildEstate(doms, st.dss, st.snaps, st.rs, st.ann)
		rebuildView()
		tree.Refresh()
		if !didFold && len(viewGroups) > 0 {
			foldOffGroups()
			didFold = true
		}
		// selection follows the DOMAIN across refreshes (Select on the
		// already-selected id is a no-op, so no event loop)
		if st.selName != "" {
			if _, ok := rowByUID("vm/" + st.selName); ok {
				tree.Select("vm/" + st.selName)
			}
		}
		status.SetText(fmt.Sprintf("%d domains · rules: %s · %s · vmxplore %s",
			len(doms), st.rs.Source, at.Format("15:04:05"), versionFull()))
		if r, ok := st.selected(); ok {
			renderDossier(r)
			// The console is attached to a PROCESS, not to a name. A domain
			// that stopped and started again is a new qemu with a new
			// serial pty and a new VNC port, so the standing attachment is
			// a dead pipe over stale pixels — and nothing noticed, because
			// this only ever ran on a click. The operator's workaround was
			// to select another VM and come back.
			//
			// Three things mean "re-follow": a different domain, a
			// different power state, or a cumulative CPU counter that went
			// BACKWARDS. That last one is what catches an off-and-on cycle
			// completed between two polls, where the state reads "running"
			// both times and only the counter reveals that the process
			// behind the name was replaced. A reboot from inside the guest
			// keeps the same qemu, keeps counting up, and correctly does
			// not disturb the attachment.
			restarted := r.D.Name == conLastName && r.D.CPUTimeNs < conCPU
			if r.D.Name != conName || r.D.State != conState || restarted {
				followConsole(r)
			}
			conLastName, conCPU = r.D.Name, r.D.CPUTimeNs
		}
	}
	fetchEstate := func() {
		doms, err := lv.Estate()
		if err != nil {
			fyne.Do(func() { status.SetText("libvirt: " + err.Error()) })
			return
		}
		cpuRaw := make(map[string]uint64, len(doms))
		for _, d := range doms {
			cpuRaw[d.Name] = d.CPUTimeNs
		}
		at := time.Now()
		fyne.Do(func() { apply(doms, cpuRaw, at) })
	}
	fetchZFS := func() {
		ann := LoadAnnotations()
		var dss map[string]*Dataset
		var snaps map[string][]string
		if HasZFS() {
			dss, _ = ListDatasets()
			snaps, _ = ListSnapshots()
		}
		fyne.Do(func() { st.dss, st.snaps, st.ann = dss, snaps, ann })
	}
	refreshNow = func() { go fetchEstate() }
	go func() {
		fetchZFS()
		fetchEstate()
		fast := time.NewTicker(2 * time.Second)
		slow := time.NewTicker(30 * time.Second)
		defer fast.Stop()
		defer slow.Stop()
		for {
			select {
			case <-fast.C:
				fetchEstate()
			case <-slow.C:
				fetchZFS()
			}
		}
	}()

	// ── assembly: the frame ──────────────────────────────────────────────
	// Three card panels floating on the steel-black base (the zxplore
	// layered look), each with its accent heading: ESTATE red (brand),
	// CONSOLE amber (the LED), DETAILS blue.
	// container.NewPadded around every card = the black gutters: the base
	// shows through between panels and around the window edge, uniformly.
	gap := func(o fyne.CanvasObject) fyne.CanvasObject {
		return container.NewPadded(o)
	}
	// Connect: switch hypervisors by re-execing with --connect. A live
	// reconnect would have to rebuild every pane's state; a clean re-exec
	// is simpler and correct — the new window comes up pointed at the host.
	connectBtn := widget.NewButtonWithIcon(target.Host, theme.ComputerIcon(),
		func() {
			e := widget.NewEntry()
			e.SetPlaceHolder("host, user@host, or qemu+ssh://host/system (empty = local)")
			if target.SSHHost != "" {
				e.SetText(target.SSHHost)
			}
			dialog.ShowCustomConfirm("Connect to a hypervisor", "Connect",
				"Cancel", container.NewVBox(
					widget.NewLabel("Drives a remote host over ssh — same key as your shell."),
					e), func(ok bool) {
					if !ok {
						return
					}
					exe, _ := os.Executable()
					argv := []string{exe}
					if d := strings.TrimSpace(e.Text); d != "" {
						argv = append(argv, "--connect", d)
					}
					// hand off: replace this process with one aimed at the host
					_ = reexec(exe, argv)
				}, w)
		})
	estateHead := container.NewBorder(nil, nil,
		heading("ESTATE", acBrand), connectBtn)
	left := gap(card(container.NewBorder(
		container.NewVBox(estateHead, search, batchBar), nil, nil, nil,
		tree)))
	// The build surfaces are tabs in the console card, not menu items,
	// because the tile grid the kldload tab already uses reads as a menu
	// you can see: every way to make a VM is one glance, and a tile opens
	// the dialog that collects its details. Same layout in all three tabs
	// so the pane behaves identically wherever you are.
	tileGrid := func(tiles ...fyne.CanvasObject) fyne.CanvasObject {
		return container.NewVScroll(container.NewPadded(
			container.NewGridWrap(fyne.NewSize(250, 96), tiles...)))
	}
	vmsHost := container.NewBorder(
		container.NewCenter(pageHeading("NEW VM", acBrand)), nil, nil, nil,
		// Same colour language as the tools grid: the three that end with
		// a new machine are green; Make Golden is blue because it seals
		// storage rather than creating a VM.
		tileGrid(
			newTile(theme.ContentAddIcon(), "New VM",
				"cloud image, or boot an installer ISO",
				acGreen.at(), newVMDialog),
			newTile(theme.ViewRefreshIcon(), "EZ Fleet",
				"a golden plus N clones, one shot",
				acGreen.at(), fleetDialog),
			newTile(theme.ContentCopyIcon(), "Clone",
				"instant zero-copy ZFS clone of the selected VM",
				acGreen.at(), cloneAny),
			newTile(theme.ConfirmIcon(), "Make Golden",
				"seal the selected VM into a clone template",
				acBlue.at(), goldenAct),
		))

	// One tile per catalog entry (appliances.go). The catalog is data, so
	// this grid grows on its own as entries are added — nothing here to
	// edit per app.
	appTiles := make([]fyne.CanvasObject, 0, len(Appliances()))
	for _, ap := range Appliances() {
		ap := ap // the tile closure outlives the loop iteration
		appTiles = append(appTiles, newTile(theme.StorageIcon(), ap.Name,
			ap.Summary, acGreen.at(), func() { applianceDialog(ap.Name) }))
	}
	appliancesHost := container.NewBorder(
		container.NewCenter(pageHeading("APPS", acGreen)), nil, nil, nil,
		tileGrid(appTiles...))

	// The tab order is the order of the work: look at the machine you have
	// (Serial, Screen), then make one — an Applications entry if somebody
	// already solved it, a bare VM if not — and the kldload toolset last,
	// since it is the only tab that isn't there on every host.
	//
	// The tabs share the console card; ⛶ toggles the card full-window (and
	// back) for real console work.
	screenTab := container.NewTabItem("Screen", vncHost)
	tabs := container.NewAppTabs(
		container.NewTabItem("Serial", consoleHost),
		screenTab,
		container.NewTabItem("Apps", appliancesHost),
		container.NewTabItem("VM", vmsHost))
	// this one exists on every host too, but says different things: the
	// tools launcher on kldload, the get-kldload pitch elsewhere
	toolsTab := container.NewTabItem("kldload", toolsHost)
	tabs.Append(toolsTab)
	// Select by tab, never by index: the index form silently pointed at
	// whatever had moved into slot 2 the first time these were reordered.
	selectToolsTab = func() { tabs.Select(toolsTab) }
	selectScreenTab = func() { tabs.Select(screenTab) }
	// Screen, not Serial, is where the work happens: it shows the same
	// console plus everything graphical, so it is the right landing tab.
	// Serial stays for the case Screen cannot cover — a guest with no
	// video, or one whose X is broken, where it is the only way in.
	tabs.Select(screenTab)
	var mainContent fyne.CanvasObject
	consoleCard := cardTight(container.NewBorder(nil, nil, nil, nil, tabs))

	// ⛶ — nothing but the guest, in the window you already have.
	//
	// It used to hand over the console CARD — tab bar, padding and card
	// border included. On a 2560x1440 guest that chrome is the difference
	// between reading the screen and squinting at it, and every pixel of it
	// shows controls nobody is using while they look at a machine. Now the
	// selected tab's content goes edge to edge with the restore control
	// floated over the top-right corner instead of given a row of its own.
	//
	// WHY it does NOT call SetFullScreen, which is the obvious thing:
	// because on a multi-monitor desktop it moves the window to the WRONG
	// display. Fyne picks the target itself and offers no way to say which;
	// read getMonitorForWindow in its glfw driver — under Wayland it skips
	// the geometry search outright, and even on X11 a miss falls through to
	// GetPrimaryMonitor. Observed here on a three-head desktop: ⛶ threw the
	// console onto monitor 1 from a window that was on another.
	//
	// Filling the window is a smaller promise that is always kept. The
	// window manager already does true fullscreen correctly and on the
	// right monitor — its own shortcut composes with this, and the result
	// is the guest occupying the whole display with no furniture at all.
	//
	// WARN: the restore button is the ONLY way back out of this mode.
	// Escape cannot be the escape — the VNC widget owns the keyboard and
	// forwards it to the guest, so anything that wants Escape (vi, a
	// firmware menu, the editor in the writing appliance) would eat it.
	// Small and cornered, never hidden.
	// Paste, as a button you can see.
	//
	// Ctrl+V already worked — TypedShortcut sends the host clipboard as RFB
	// cut text AND types it as keystrokes, so it lands in a guest whether or
	// not that guest runs a clipboard agent. Nobody knew, because a keyboard
	// shortcut inside a pane that swallows the keyboard is invisible. This
	// is the same code path with a control attached to it.
	//
	// Not a right-click menu: right-click belongs to the guest. A guest is
	// exactly the place where stealing the secondary button breaks real work.
	pasteBtn := widget.NewButtonWithIcon("", theme.ContentPasteIcon(), func() {
		if curVNC == nil {
			guiStatus("paste: no screen attached — select a running VM")
			return
		}
		text := w.Clipboard().Content()
		if text == "" {
			guiStatus("paste: the host clipboard is empty")
			return
		}
		curVNC.pasteText(text)
		guiStatus(fmt.Sprintf("pasted %d characters into the guest", len(text)))
	})

	restoreBtn := widget.NewButtonWithIcon("", theme.ViewRestoreIcon(), func() {
		w.SetPadded(true) // the window's own margin comes back with the chrome
		w.SetContent(mainContent)
		// the borrowed pane is going back into its tab: Fyne needs telling
		// that the tab's content moved parents and back again
		tabs.Refresh()
	})
	restoreBtn.Importance = widget.LowImportance
	fullBtn := widget.NewButtonWithIcon("", theme.ViewFullScreenIcon(), func() {
		pane := tabs.Selected().Content
		// SetPadded(false) is the last of the border: Fyne insets window
		// content by a theme margin, which on a maximised window is a
		// visible frame around a guest that should be reaching the edges.
		w.SetPadded(false)
		// The two controls stack vertically rather than sitting side by
		// side, so they cost one button of width instead of two — the
		// difference is guest pixels, which is the entire point of the mode.
		w.SetContent(container.NewStack(
			pane,
			container.NewVBox(container.NewHBox(layout.NewSpacer(),
				container.NewVBox(pasteBtn, restoreBtn)))))
	})
	consoleHead := container.NewBorder(nil, nil,
		heading("CONSOLE", acGold),
		container.NewHBox(pasteBtn, fullBtn))
	consolePane := gap(container.NewBorder(consoleHead, nil, nil, nil,
		consoleCard))
	rightBottom := gap(card(container.NewBorder(
		heading("DETAILS & ACTIONS", acBlue), buttons, nil, nil,
		container.NewScroll(dossier))))
	// console dominates by default (operator: the screen is the point);
	// details keep a slim strip — the splitter drags when you want more
	right := container.NewVSplit(consolePane, rightBottom)
	right.SetOffset(0.78)
	body := container.NewHSplit(left, right)
	body.SetOffset(0.38)
	mainContent = container.NewBorder(nil, status, nil, nil, gap(body))
	w.SetContent(mainContent)
	w.SetOnClosed(func() { detachConsole(); detachVNC(); stopTool(); lv.Close() })

	// The GNOME light/dark variant may not be resolved while the widgets
	// were built — repaint the hand-colored canvas objects once shortly
	// after show, and again on every theme change (the zxplore fix).
	settingsCh := make(chan fyne.Settings, 1)
	a.Settings().AddChangeListener(settingsCh)
	go func() {
		time.Sleep(500 * time.Millisecond)
		fyne.Do(applyPalette)
		for range settingsCh {
			fyne.Do(applyPalette)
		}
	}()
	w.ShowAndRun()
}
