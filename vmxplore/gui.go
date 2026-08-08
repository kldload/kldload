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
//     driving the SAME plan builders and gates as the TUI (verbs.go): every
//     mutation shows its exact commands and confirms first; destructive
//     verbs require retyping the domain name; all runs audit-log.
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
	"sort"
	"strings"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/canvas"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/driver/desktop"
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
		return 3 // tight rows (single-spaced list)
	case theme.SizeNamePadding:
		return 6 // space between panes / regions
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
	// brand accent: light purple (operator call — the bright red glared);
	// the zxplore acPurple pair, lavender on dark / deep violet on light
	acBrand = accentPair{color.NRGBA{0xc7, 0x7d, 0xff, 0xff}, color.NRGBA{0x7a, 0x2f, 0xe0, 0xff}}
	// red survives ONLY as danger — toned to the icon's compute red
	acRed   = accentPair{color.NRGBA{0xe2, 0x69, 0x5d, 0xff}, color.NRGBA{0xb8, 0x38, 0x28, 0xff}}
	acGold  = accentPair{color.NRGBA{0xff, 0xd0, 0x43, 0xff}, color.NRGBA{0xb0, 0x7d, 0x00, 0xff}} // the icon's LED amber
	acGreen = accentPair{color.NRGBA{0x3d, 0xff, 0x88, 0xff}, color.NRGBA{0x0e, 0x9d, 0x4a, 0xff}} // running
	acBlue  = accentPair{color.NRGBA{0x4d, 0xa6, 0xff, 0xff}, color.NRGBA{0x14, 0x66, 0xd8, 0xff}} // details
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

// vmRow is one estate list row: a state-coloured monospace line that
// selects on tap and opens the verb context menu on right-click.
type vmRow struct {
	widget.BaseWidget
	text   *canvas.Text
	onTap  func()
	onMenu func(pos fyne.Position)
}

func newVMRow() *vmRow {
	r := &vmRow{text: canvas.NewText("", theme.Color(theme.ColorNameForeground))}
	r.text.TextStyle = fyne.TextStyle{Monospace: true}
	r.ExtendBaseWidget(r)
	return r
}

func (r *vmRow) CreateRenderer() fyne.WidgetRenderer {
	return widget.NewSimpleRenderer(r.text)
}

func (r *vmRow) Tapped(*fyne.PointEvent) {
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

// confirmPlan is the GUI twin of the TUI confirm overlay: exact commands,
// the warning, and — for retype-gated plans — an entry that must match the
// domain name before OK arms. Same contract, different chrome.
// guiStatus, if set, gets a one-line note when a verb fires without a
// dialog — the exact command still surfaces (teach-the-CLI), just in the
// status bar instead of a modal. Set once in runGUI.
var guiStatus func(string)

func confirmPlan(w fyne.Window, p verbPlan, after func()) {
	cmds := widget.NewLabel(strings.TrimRight(p.cmdLines(), "\n"))
	cmds.TextStyle = fyne.TextStyle{Monospace: true}
	items := []fyne.CanvasObject{cmds}
	if p.warn != "" {
		warn := widget.NewLabel("⚠ " + p.warn)
		warn.Importance = widget.WarningImportance
		items = append(items, warn)
	}
	run := func() {
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
	// No retype gate → a safe, reversible verb (start/stop/reboot/snapshot/
	// clone/…): just run it. Prompting on every routine action is friction
	// the operator explicitly waived; the audit log keeps the record and
	// the destructive trio below still arms by retype.
	if p.retype == "" {
		if guiStatus != nil {
			guiStatus("· " + strings.TrimSpace(strings.TrimPrefix(
				strings.TrimSpace(p.cmdLines()), "$")))
		}
		run()
		return
	}
	entry := widget.NewEntry()
	entry.SetPlaceHolder(p.retype)
	items = append(items,
		widget.NewLabel("type the name "+p.retype+" to arm:"), entry)
	d := dialog.NewCustomConfirm(p.title, "Run", "Cancel",
		container.NewVBox(items...), func(ok bool) {
			if !ok {
				return
			}
			if entry.Text != p.retype {
				dialog.ShowInformation(p.title,
					"not armed — the typed name did not match", w)
				return
			}
			run()
		}, w)
	d.Show()
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

	// ── left: the estate list ────────────────────────────────────────────
	// One row per domain: state dot, name, group, cpu. Grouping shows as a
	// column (not separator rows) so filtering stays trivial; the search
	// box narrows by name.
	groupOf := func(r Row) string {
		for _, gr := range st.groups {
			for _, rr := range gr.Rows {
				if rr.D.Name == r.D.Name {
					return gr.Label
				}
			}
		}
		return ""
	}
	// Rows carry the state colour on the whole line — the same language
	// as the TUI table: green running, muted off, amber warned. vmRow
	// adds tap-select and the right-click verb menu.
	var list *widget.List
	var rowMenu func(i int, pos fyne.Position) // wired after the verbs exist
	list = widget.NewList(
		func() int { return len(st.rows) },
		func() fyne.CanvasObject { return newVMRow() },
		func(i widget.ListItemID, o fyne.CanvasObject) {
			if i >= len(st.rows) {
				return
			}
			r := st.rows[i]
			// stopped rows keep full foreground (readable in both
			// variants); colour is reserved for meaning — electric green
			// running, LED-amber warned (the accentPair palette)
			dot := "○"
			col := theme.Color(theme.ColorNameForeground)
			switch {
			case r.Synthetic || len(r.Notes) > 0:
				dot = "!"
				col = acGold.at()
			case r.D.State == "running":
				dot = "●"
				col = acGreen.at()
			}
			cpu := ""
			if c, ok := st.cpu[r.D.Name]; ok && r.D.State == "running" {
				cpu = fmt.Sprintf(" %5.1f%%", c)
			}
			row := o.(*vmRow)
			row.text.Text = fmt.Sprintf("%s %-24s %-12s %-14s%s",
				dot, r.D.Name, r.D.State, groupOf(r), cpu)
			row.text.Color = col
			row.onTap = func() { list.Select(i) }
			row.onMenu = func(pos fyne.Position) {
				if rowMenu != nil {
					rowMenu(i, pos)
				}
			}
			row.text.Refresh()
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
	// Graphics pane: the native RFB viewer (vnc.go) — same auto-follow
	// contract as serial. Loopback makes eager attach cheap.
	vncHost := container.NewStack(conPlaceholder(
		"select a running VM — its graphical console renders here"))
	var vncConn *rfbConn
	vncName := ""
	detachVNC := func() {
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
		vncHost.Objects = []fyne.CanvasObject{newVNCViewer(conn)}
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
	var selectToolsTab func() // set once the tab bar exists below
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
			// colour says what a verb does before you read it: green
			// builds, red destroys, steel reads
			col := theme.Color(theme.ColorNameForeground)
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
			col := theme.Color(theme.ColorNameForeground)
			if strings.HasSuffix(t, "-demo") {
				col = acBrand.at() // demos pop in the brand purple
			}
			tiles = append(tiles, newTile(toolIcon(t), t, toolDesc[t], col,
				func() { openTool(t) }))
		}
		head := container.NewVBox(
			pageHeading("kldload tools", acBrand),
			widget.NewLabel("clusters, goldens, clones, demos — they run right here"))
		grid := container.NewGridWrap(fyne.NewSize(250, 96), tiles...)
		toolsHost.Objects = []fyne.CanvasObject{container.NewBorder(
			container.NewPadded(head), nil, nil, nil,
			container.NewVScroll(container.NewPadded(grid)))}
		toolsHost.Refresh()
	}
	showToolTiles()

	// followConsole keeps both panes in lock-step with the selection.
	followConsole := func(r Row) {
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
	// non-retype verbs fire without a dialog and report here
	guiStatus = func(s string) { fyne.Do(func() { status.SetText(s) }) }

	// ── the verb toolbar ─────────────────────────────────────────────────
	// Two tiers, mirroring how operators think: the power verbs are
	// always-visible icon buttons; everything else lives behind labelled
	// dropdown menus (Storage / Configure / Build / Estate) so the pane
	// stays organized as verbs accumulate. Every path funnels through the
	// same plan builders + confirmPlan gates as the TUI.
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
			confirmPlan(w, p, func() { refreshNow() })
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
					confirmPlan(w, p, func() { refreshNow() })
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
				confirmPlan(w, p, func() { refreshNow() })
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
				confirmPlan(w, p, func() { refreshNow() })
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

	btnStart := widget.NewButtonWithIcon("Start", theme.MediaPlayIcon(), verb(planStart))
	btnStart.Importance = widget.SuccessImportance
	btnStop := widget.NewButtonWithIcon("Shut down", theme.MediaStopIcon(), verb(planShutdown))
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
		// installer ISO (boot the distro's own installer in the Graphics
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
		user := widget.NewEntry()
		user.SetText("admin")
		pass := widget.NewEntry()
		pass.SetPlaceHolder("password (optional if key given)")
		key := widget.NewEntry()
		key.SetPlaceHolder("ssh public key (optional)")
		if b, err := os.ReadFile(os.Getenv("HOME") + "/.ssh/id_ed25519.pub"); err == nil {
			key.SetText(strings.TrimSpace(string(b)))
		}
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
		cloudOnly := container.NewVBox(
			widget.NewLabel("distro"), distro, imgPath,
			widget.NewLabel("user"), user,
			widget.NewLabel("password"), pass,
			widget.NewLabel("ssh key"), key,
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
					if distro.Selected == "custom image…" {
						spec.ImagePath = strings.TrimSpace(imgPath.Text)
					} else {
						spec.Distro = distro.Selected
					}
				}
				done := "created — cloud-init finishes the first boot"
				if spec.install() {
					done = "created — open the Graphics tab and run the installer"
				}
				parent := ZFSVMParent(st.visibleRows())
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
						dialog.ShowInformation("New VM", spec.Name+" "+done, w)
					})
				}()
			}, w)
		d.Resize(fyne.NewSize(460, 560))
		d.Show()
	}

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
						dialog.ShowInformation("EZ Fleet",
							fmt.Sprintf("%s golden + %d clones ready", spec.Name, n), w)
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
		fyne.NewMenuItem("EZ Fleet — golden + N clones…", fleetDialog),
		fyne.NewMenuItem("Clone…", cloneAny),
		fyne.NewMenuItem("Make Golden…", goldenAct))
	mEstate := menuButton("Estate", theme.ComputerIcon(),
		fyne.NewMenuItem("Migrate to host…", soon("Migrate (teleport)", "0.3")))

	// the right-click menu on an estate row: every verb, zero travel —
	// selects the row first so the verbs aim at what you clicked
	rowMenu = func(i int, pos fyne.Position) {
		list.Select(i)
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
			fyne.NewMenuItem("Delete…", verb(planDelete)),
		), w.Canvas())
		m.ShowAtPosition(pos)
	}

	// NewPadded around every control: the bare HBox packs buttons at
	// theme padding (~4px) which reads cramped — this doubles the gutters
	// and floats the row off the dossier above it
	pad := func(o fyne.CanvasObject) fyne.CanvasObject {
		return container.NewPadded(o)
	}
	buttons := container.NewPadded(container.NewHBox(
		pad(btnStart), pad(btnStop), pad(btnKill),
		widget.NewSeparator(),
		pad(mStorage), pad(mConfig), pad(mBuild), pad(mEstate)))

	// ── selection → panes ────────────────────────────────────────────────
	list.OnSelected = func(i widget.ListItemID) {
		if i >= len(st.rows) {
			return
		}
		st.selName = st.rows[i].D.Name
		renderDossier(st.rows[i])
		followConsole(st.rows[i])
	}

	search := widget.NewEntry()
	search.SetPlaceHolder("filter VMs…")
	search.OnChanged = func(q string) {
		st.filter = q
		st.rows = st.visibleRows()
		list.Refresh()
	}

	// ── refresh: estate every 2s, ZFS every 30s (the TUI cadence) ────────
	apply := func(doms []Dom, cpuRaw map[string]uint64, at time.Time) {
		if !st.prevAt.IsZero() {
			st.cpu = cpuPercent(st.prevCPU, cpuRaw, at.Sub(st.prevAt), doms)
		}
		st.prevCPU, st.prevAt = cpuRaw, at
		st.groups = BuildEstate(doms, st.dss, st.snaps, st.rs, st.ann)
		st.rows = st.visibleRows()
		list.Refresh()
		// selection follows the DOMAIN, not the row index — refreshes
		// reorder rows and the highlight must not drift onto a neighbour
		// (Select on the already-selected id is a no-op, so no event loop)
		for i, r := range st.rows {
			if r.D.Name == st.selName {
				list.Select(i)
				break
			}
		}
		status.SetText(fmt.Sprintf("%d domains · rules: %s · %s · vmxplore %s",
			len(doms), st.rs.Source, at.Format("15:04:05"), versionFull()))
		if r, ok := st.selected(); ok {
			renderDossier(r)
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
		container.NewVBox(estateHead, search), nil, nil, nil,
		list)))
	// Serial | Graphics tabs share the console card; ⛶ toggles the card
	// full-window (and back) for real console work.
	tabs := container.NewAppTabs(
		container.NewTabItem("Serial", consoleHost),
		container.NewTabItem("Graphics", vncHost))
	// the tab exists on every host: tools launcher on kldload, the
	// get-kldload pitch elsewhere
	tabs.Append(container.NewTabItem("kldload", toolsHost))
	selectToolsTab = func() { tabs.SelectIndex(2) }
	var mainContent fyne.CanvasObject
	consoleCard := card(container.NewBorder(nil, nil, nil, nil, tabs))
	restoreBtn := widget.NewButtonWithIcon("", theme.ViewRestoreIcon(), func() {
		w.SetContent(mainContent)
	})
	fullBtn := widget.NewButtonWithIcon("", theme.ViewFullScreenIcon(), func() {
		// the console card alone, edge to edge, with its own way back
		w.SetContent(container.NewBorder(
			container.NewBorder(nil, nil, nil, restoreBtn), nil, nil, nil,
			gap(consoleCard)))
	})
	consoleHead := container.NewBorder(nil, nil,
		heading("CONSOLE", acGold), fullBtn)
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
