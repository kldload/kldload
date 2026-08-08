// tui.go — the estate TUI: the joined table, live, keyboard-driven.
//
// bubbletea, matching the family. One screen (the headline view from the
// design doc) with foldable estate groups (←/→, headers are cursor stops)
// plus overlays: detail (enter), snapshots (s, with rollback), actions
// (a — the 0.2 verb menu; verbs.go builds and gates the plans),
// confirm/input for the verb flow, help (?). ← (or q) backs out of any
// pane — q quits only from the main view — and esc only aborts the
// confirm/input prompts. Mouse: wheel moves the active cursor, click
// selects, a header click folds, re-clicking the selected row opens
// detail. Interactive externals — `c`
// attaches `virsh console`, `S` opens ssh to the guest's agent-reported
// IP — run under tea.ExecProcess, which suspends the TUI and also
// sidesteps DomainOpenConsoleBidirectional's missing abort handle (design
// risk list) until a native console earns its complexity.
//
// Refresh: libvirt estate every 2s (stats are one bulk RPC); ZFS datasets +
// snapshots every 30s (a 16k-snapshot listing is not a 2s-tick operation).
// CPU%% is the delta of cpu.time between consecutive estate ticks.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// ─── styles / theme ─────────────────────────────────────────────────────────
// One palette drives the whole tool — table, footer, overlays — so it reads
// as one instrument, not a pile of panes. Two sets: dark terminals get the
// bright ANSI variants (8–15) so the estate is vivid; light terminals get
// the deep variants (1–6) that survive a white background. Auto-detected
// from the terminal background; VMX_THEME=dark|light overrides.

var (
	styTitle   lipgloss.Style // app title text
	styGroup   lipgloss.Style // estate group headers (accent, bold)
	styHeader  lipgloss.Style // column header row
	styRunning lipgloss.Style // running rows / ok values
	styOff     lipgloss.Style // shut-off rows / muted values
	styWarn    lipgloss.Style // notes, synthetic rows, warnings
	styCursor  lipgloss.Style // selection bar
	styStatus  lipgloss.Style // status line, hint prose
	styKey     lipgloss.Style // key legends (accent, bold)
	styRule    lipgloss.Style // separator rules
	styCmd     lipgloss.Style // exact commands in the confirm box
	styOverlay lipgloss.Style // overlay border box
)

// applyTheme installs one of the two palettes into the shared styles.
func applyTheme(light bool) {
	accent, ok, warn, dim, hdr := "14", "10", "11", "8", "12"
	if light {
		accent, ok, warn, dim, hdr = "6", "2", "3", "8", "4"
	}
	styTitle = lipgloss.NewStyle().Bold(true)
	styGroup = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color(accent))
	styHeader = lipgloss.NewStyle().Underline(true).Foreground(lipgloss.Color(hdr))
	styRunning = lipgloss.NewStyle().Foreground(lipgloss.Color(ok))
	styOff = lipgloss.NewStyle().Foreground(lipgloss.Color(dim))
	styWarn = lipgloss.NewStyle().Foreground(lipgloss.Color(warn))
	styCursor = lipgloss.NewStyle().Reverse(true).Bold(true)
	styStatus = lipgloss.NewStyle().Faint(true)
	styKey = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color(accent))
	styRule = lipgloss.NewStyle().Foreground(lipgloss.Color(dim))
	styCmd = lipgloss.NewStyle().Foreground(lipgloss.Color(ok))
	styOverlay = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color(accent)).Padding(0, 1)
}

// dark default so non-TUI paths (status messages built before runTUI, tests)
// never see zero styles; runTUI re-applies with detection + $VMX_THEME
func init() { applyTheme(false) }

// ─── messages & model ───────────────────────────────────────────────────────

type estateMsg struct {
	doms []Dom
	cpu  map[string]uint64
	at   time.Time
	err  error
}

type zfsMsg struct {
	dss   map[string]*Dataset
	snaps map[string][]string
	ann   *Annotations
	err   error
}

type estateTickMsg struct{}
type zfsTickMsg struct{}
type execDoneMsg struct{ err error }
type verbDoneMsg struct {
	title string
	err   error
}

type ui struct {
	lv *LV
	rs *Ruleset

	doms  []Dom
	dss   map[string]*Dataset
	snaps map[string][]string
	ann   *Annotations

	groups    []GroupRows
	collapsed map[string]bool // group label → folded (←/→); survives refresh
	cursor    int             // indexes navItems(): group headers AND rows
	scroll    int

	prevCPU map[string]uint64
	prevAt  time.Time
	cpu     map[string]float64

	width, height int
	overlay       string // "" | detail | snaps | help | actions | confirm | input
	status        string
	err           error

	// verb state: a plan awaiting confirmation, the operator's typed buffer
	// (retype gate or input field), and the staged specs value between the
	// two input rounds. snapCursor selects inside the snaps overlay.
	pending    *verbPlan
	typed      string
	inputKind  string // "snap" | "vcpus" | "mem"
	stagedCPUs int
	snapCursor int
}

func newUI(lv *LV, rs *Ruleset) *ui {
	return &ui{lv: lv, rs: rs, cpu: map[string]float64{},
		collapsed: map[string]bool{}, status: "loading estate…"}
}

// navItem is one selectable line of the estate view: a group header
// (row == -1, foldable with ←/→) or a domain row inside an expanded group.
type navItem struct {
	g, row int
}

// navItems lists the selectable lines in render order, honouring folds.
// Rebuilt on demand — the estate is dozens of items, not thousands.
func (m *ui) navItems() []navItem {
	var items []navItem
	for gi, g := range m.groups {
		items = append(items, navItem{gi, -1})
		if m.collapsed[g.Label] {
			continue
		}
		for ri := range g.Rows {
			items = append(items, navItem{gi, ri})
		}
	}
	return items
}

// curRow returns the domain row under the cursor; ok=false when the cursor
// sits on a group header (or the estate is empty). Verbs and overlays that
// need a domain must check ok and complain, not index blindly.
func (m *ui) curRow() (Row, bool) {
	items := m.navItems()
	if m.cursor >= len(items) || items[m.cursor].row < 0 {
		return Row{}, false
	}
	it := items[m.cursor]
	return m.groups[it.g].Rows[it.row], true
}

func (m *ui) Init() tea.Cmd {
	return tea.Batch(m.fetchEstate(), m.fetchZFS())
}

// fetchEstate is the fast tick: libvirt only.
func (m *ui) fetchEstate() tea.Cmd {
	lv := m.lv
	return func() tea.Msg {
		doms, err := lv.Estate()
		if err != nil {
			return estateMsg{err: err}
		}
		cpu := make(map[string]uint64, len(doms))
		for _, d := range doms {
			cpu[d.Name] = d.CPUTimeNs
		}
		return estateMsg{doms: doms, cpu: cpu, at: time.Now()}
	}
}

// fetchZFS is the slow tick: datasets, the 16k-snapshot listing, registers.
func (m *ui) fetchZFS() tea.Cmd {
	return func() tea.Msg {
		msg := zfsMsg{ann: LoadAnnotations()}
		if !HasZFS() {
			return msg
		}
		var err error
		if msg.dss, err = ListDatasets(); err != nil {
			msg.err = err
			return msg
		}
		msg.snaps, err = ListSnapshots()
		msg.err = err
		return msg
	}
}

func after(d time.Duration, msg tea.Msg) tea.Cmd {
	return tea.Tick(d, func(time.Time) tea.Msg { return msg })
}

// rebuild re-joins after any data change, keeping the cursor on the same
// domain — or the same group header — when it still exists.
func (m *ui) rebuild() {
	var selDom, selHeader string
	if items := m.navItems(); m.cursor < len(items) {
		it := items[m.cursor]
		if it.row < 0 {
			selHeader = m.groups[it.g].Label
		} else {
			selDom = m.groups[it.g].Rows[it.row].D.Name
		}
	}
	m.groups = BuildEstate(m.doms, m.dss, m.snaps, m.rs, m.ann)
	m.cursor = 0
	items := m.navItems()
	for i, it := range items {
		if it.row < 0 && m.groups[it.g].Label == selHeader ||
			it.row >= 0 && m.groups[it.g].Rows[it.row].D.Name == selDom {
			m.cursor = i
			break
		}
	}
	// first load (nothing selected yet): land on the first domain row, not
	// the header above it — the verbs expect a row under the cursor, and
	// "launch, press u" must start a VM, not silently hit a header
	if selDom == "" && selHeader == "" {
		for i, it := range items {
			if it.row >= 0 {
				m.cursor = i
				break
			}
		}
	}
}

func (m *ui) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {

	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil

	case estateMsg:
		if msg.err != nil {
			m.err = msg.err
			return m, after(2*time.Second, estateTickMsg{})
		}
		m.err = nil
		m.doms = msg.doms
		if !m.prevAt.IsZero() {
			wall := msg.at.Sub(m.prevAt)
			s1 := msg.cpu
			m.cpu = cpuPercent(m.prevCPU, s1, wall, msg.doms)
		}
		m.prevCPU, m.prevAt = msg.cpu, msg.at
		m.status = fmt.Sprintf("%d domains · rules: %s · %s",
			len(m.doms), m.rs.Source, time.Now().Format("15:04:05"))
		m.rebuild()
		return m, after(2*time.Second, estateTickMsg{})

	case zfsMsg:
		if msg.err != nil {
			m.status = "zfs: " + msg.err.Error()
		} else {
			m.dss, m.snaps = msg.dss, msg.snaps
		}
		m.ann = msg.ann
		m.rebuild()
		return m, after(30*time.Second, zfsTickMsg{})

	case estateTickMsg:
		return m, m.fetchEstate()
	case zfsTickMsg:
		return m, m.fetchZFS()

	case execDoneMsg:
		if msg.err != nil {
			m.status = styWarn.Render(msg.err.Error())
		}
		return m, nil

	case verbDoneMsg:
		if msg.err != nil {
			m.status = styWarn.Render(msg.err.Error())
		} else {
			m.status = "done: " + msg.title
		}
		// mutation happened — refresh both halves now, not on the next tick
		return m, tea.Batch(m.fetchEstate(), m.fetchZFS())

	case tea.KeyMsg:
		return m.key(msg)

	case tea.MouseMsg:
		return m.mouse(msg)
	}
	return m, nil
}

// mouse: wheel moves whichever cursor the active view owns; in the main
// view a left click selects (header click folds, clicking the already-
// selected row drills into detail — the poor man's double click).
func (m *ui) mouse(msg tea.MouseMsg) (tea.Model, tea.Cmd) {
	switch msg.Button {
	case tea.MouseButtonWheelUp, tea.MouseButtonWheelDown:
		d := 1
		if msg.Button == tea.MouseButtonWheelUp {
			d = -1
		}
		switch m.overlay {
		case "":
			if n := len(m.navItems()); n > 0 {
				m.cursor = min(max(m.cursor+d, 0), n-1)
			}
		case "snaps":
			if sel, _ := m.snapSelection(); len(sel) > 0 {
				m.snapCursor = min(max(m.snapCursor+d, 0), len(sel)-1)
			}
		}
		return m, nil
	}
	if msg.Action != tea.MouseActionPress ||
		msg.Button != tea.MouseButtonLeft || m.overlay != "" {
		return m, nil
	}
	idx := m.itemAt(msg.Y)
	if idx < 0 {
		return m, nil
	}
	it := m.navItems()[idx]
	switch {
	case it.row < 0:
		l := m.groups[it.g].Label
		m.collapsed[l] = !m.collapsed[l]
		m.cursor = idx
	case idx == m.cursor:
		m.overlay = "detail"
	default:
		m.cursor = idx
	}
	return m, nil
}

// itemAt maps a screen row (0-based, tea.MouseMsg.Y) to a navItems index,
// or -1 when the click lands outside the table body. Must mirror View's
// layout exactly: title, optional libvirt-error line, column header, then
// the scrolled table — change one, change both.
func (m *ui) itemAt(y int) int {
	top := 2
	if m.err != nil {
		top++
	}
	avail := m.height - 6
	if avail < 3 {
		avail = 3
	}
	if y < top || y-top >= avail {
		return -1
	}
	idx := m.scroll + y - top
	if idx >= len(m.navItems()) {
		return -1
	}
	return idx
}

// key routes keystrokes. The model (operator requests 2026-08-07): ← backs
// out of whatever pane → drilled into, q backs out of panes too and only
// quits from the main view, panes also close on the key that opened them
// (enter/?, s, a) — esc is NOT a menu back-out; it survives only as "abort
// this command prompt" in the confirm/input overlays, where q has to stay
// typeable for domain names.
func (m *ui) key(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch m.overlay {
	case "detail", "help":
		switch msg.String() {
		case "ctrl+c":
			return m, tea.Quit
		case "q", "left", "h", "enter", "?":
			m.overlay = ""
		}
		return m, nil
	case "snaps":
		return m.keySnaps(msg)
	case "actions":
		return m.keyActions(msg)
	case "confirm":
		return m.keyConfirm(msg)
	case "input":
		return m.keyInput(msg)
	}
	items := m.navItems()
	onHeader := m.cursor < len(items) && items[m.cursor].row < 0
	switch msg.String() {
	case "q", "ctrl+c":
		return m, tea.Quit
	case "j", "down":
		if m.cursor < len(items)-1 {
			m.cursor++
		}
	case "k", "up":
		if m.cursor > 0 {
			m.cursor--
		}
	case "g":
		m.cursor = 0
	case "G":
		m.cursor = max(0, len(items)-1)
	case "left", "h":
		// back out: fold the group under the cursor; from a row, first hop
		// up to its header so a second ← folds
		if m.cursor < len(items) {
			it := items[m.cursor]
			if onHeader {
				m.collapsed[m.groups[it.g].Label] = true
			} else {
				for i := m.cursor; i >= 0; i-- {
					if items[i].row < 0 {
						m.cursor = i
						break
					}
				}
			}
		}
	case "right", "l":
		// drill in: unfold a folded group, step into an open one, and on a
		// row → detail (same as enter)
		if m.cursor < len(items) {
			it := items[m.cursor]
			switch {
			case onHeader && m.collapsed[m.groups[it.g].Label]:
				m.collapsed[m.groups[it.g].Label] = false
			case onHeader && len(m.groups[it.g].Rows) > 0:
				m.cursor++
			case !onHeader:
				m.overlay = "detail"
			}
		}
	case "enter":
		if onHeader { // toggle the fold, same as ←/→
			l := m.groups[items[m.cursor].g].Label
			m.collapsed[l] = !m.collapsed[l]
		} else if _, ok := m.curRow(); ok {
			m.overlay = "detail"
		}
	case "s":
		if _, ok := m.curRow(); ok {
			m.overlay = "snaps"
			m.snapCursor = 0
		}
	case "?":
		m.overlay = "help"
	case "a":
		if _, ok := m.curRow(); ok {
			m.overlay = "actions"
		}
	case "c":
		return m, m.execConsole()
	case "S":
		return m, m.execSSH()
	default:
		return m.keyActions(msg) // direct verb keys work without the menu
	}
	return m, nil
}

// keyActions maps a verb key to a plan (from the actions overlay or directly
// from the table). Plans that need typed input route through the input
// overlay first; everything else goes straight to confirm.
func (m *ui) keyActions(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	r, ok := m.curRow()
	if !ok {
		// a verb key with a group header under the cursor must say why
		// nothing happened, not swallow the keystroke
		if s := msg.String(); len(s) == 1 && strings.ContainsAny(s, "udKApv") {
			m.status = styWarn.Render(
				"cursor is on a group header — j/k onto a VM row first")
		}
		m.overlay = ""
		return m, nil
	}
	var plan verbPlan
	var err error
	switch msg.String() {
	case "ctrl+c":
		return m, tea.Quit
	case "q", "left", "h", "a":
		m.overlay = ""
		return m, nil
	case "u":
		plan, err = planStart(r)
	case "d":
		plan, err = planShutdown(r)
	case "K":
		plan, err = planForceOff(r)
	case "A":
		plan, err = planAutostart(r)
	case "p":
		if r.DS == nil {
			m.overlay = ""
			m.status = styWarn.Render("no local dataset behind " + r.D.Name)
			return m, nil
		}
		m.overlay, m.inputKind, m.typed = "input", "snap", ""
		return m, nil
	case "v":
		if r.Synthetic {
			m.overlay = ""
			m.status = styWarn.Render("no domain behind this row")
			return m, nil
		}
		m.overlay, m.inputKind, m.typed = "input", "vcpus", ""
		return m, nil
	default:
		return m, nil
	}
	if err != nil {
		m.overlay = ""
		m.status = styWarn.Render(err.Error())
		return m, nil
	}
	m.pending, m.typed, m.overlay = &plan, "", "confirm"
	return m, nil
}

// keyConfirm arms and fires a pending plan: plain verbs on y, retype-gated
// ones only when the typed name matches exactly.
func (m *ui) keyConfirm(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	p := m.pending
	if p == nil {
		m.overlay = ""
		return m, nil
	}
	switch msg.String() {
	case "esc", "ctrl+c":
		m.pending, m.overlay = nil, ""
		m.status = "cancelled"
		return m, nil
	case "q":
		// only when q can't be part of a retyped name; backs out like esc —
		// quitting the app from a prompt was operator-vetoed
		if p.retype == "" {
			m.pending, m.overlay = nil, ""
			m.status = "cancelled"
		}
	case "enter":
		if p.retype != "" && m.typed != p.retype {
			return m, nil // gate not satisfied; keep typing or esc
		}
		return m.firePlan()
	case "y":
		if p.retype == "" {
			return m.firePlan()
		}
	case "backspace":
		if len(m.typed) > 0 {
			m.typed = m.typed[:len(m.typed)-1]
		}
		return m, nil
	}
	if p.retype != "" && len(msg.String()) >= 1 && !strings.HasPrefix(msg.String(), "ctrl") {
		m.typed += msg.String()
	}
	return m, nil
}

// keyInput collects free-text parameters (snapshot suffix, vcpus, memory)
// and hands the finished values to the plan builders.
func (m *ui) keyInput(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	r, ok := m.curRow()
	if !ok {
		m.overlay = ""
		return m, nil
	}
	switch msg.String() {
	case "esc", "ctrl+c":
		m.overlay, m.typed = "", ""
		m.status = "cancelled"
		return m, nil
	case "backspace":
		if len(m.typed) > 0 {
			m.typed = m.typed[:len(m.typed)-1]
		}
		return m, nil
	case "enter":
		switch m.inputKind {
		case "snap":
			plan, err := planSnapshot(r, strings.TrimSpace(m.typed))
			return m.toConfirm(plan, err)
		case "vcpus":
			n, err := strconv.Atoi(strings.TrimSpace(m.typed))
			if err != nil || n < 1 {
				m.status = styWarn.Render("vcpus must be a positive number")
				return m, nil
			}
			m.stagedCPUs, m.inputKind, m.typed = n, "mem", ""
			return m, nil
		case "mem":
			g, err := strconv.Atoi(strings.TrimSpace(m.typed))
			if err != nil || g < 1 {
				m.status = styWarn.Render("memory must be a positive number of GiB")
				return m, nil
			}
			plan, perr := planSpecs(r, m.stagedCPUs, g)
			return m.toConfirm(plan, perr)
		}
		return m, nil
	}
	if s := msg.String(); len(s) >= 1 && !strings.HasPrefix(s, "ctrl") {
		m.typed += s
	}
	return m, nil
}

// keySnaps drives the snapshot pane: j/k over the visible non-noise list,
// R plans a rollback of the selected snapshot.
func (m *ui) keySnaps(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	sel, all := m.snapSelection()
	switch msg.String() {
	case "ctrl+c":
		return m, tea.Quit
	case "q", "left", "h", "s":
		m.overlay = ""
		return m, nil
	case "j", "down":
		if m.snapCursor < len(sel)-1 {
			m.snapCursor++
		}
	case "k", "up":
		if m.snapCursor > 0 {
			m.snapCursor--
		}
	case "R":
		r, ok := m.curRow()
		if !ok || m.snapCursor >= len(sel) {
			return m, nil
		}
		target := sel[m.snapCursor]
		newer := 0
		for i, s := range all {
			if s == target {
				newer = len(all) - i - 1
				break
			}
		}
		plan, err := planRollback(r, target, newer)
		return m.toConfirm(plan, err)
	}
	return m, nil
}

func (m *ui) toConfirm(plan verbPlan, err error) (tea.Model, tea.Cmd) {
	if err != nil {
		m.overlay, m.typed = "", ""
		m.status = styWarn.Render(err.Error())
		return m, nil
	}
	m.pending, m.typed, m.overlay = &plan, "", "confirm"
	return m, nil
}

// firePlan runs the pending plan in a Cmd goroutine; the result lands as a
// verbDoneMsg which also forces an immediate estate refresh.
func (m *ui) firePlan() (tea.Model, tea.Cmd) {
	p := *m.pending
	m.pending, m.overlay, m.typed = nil, "", ""
	m.status = "running: " + p.title
	return m, func() tea.Msg { return verbDoneMsg{title: p.title, err: runPlan(p)} }
}

// ─── external verbs ─────────────────────────────────────────────────────────
// Both print their exact command in the status line — the TUI teaches the
// CLI, never hides it (design: "vmx must never fight virsh").

func (m *ui) execConsole() tea.Cmd {
	r, ok := m.curRow()
	if !ok {
		return nil
	}
	if r.Synthetic {
		m.status = styWarn.Render("no domain behind this row")
		return nil
	}
	if _, err := exec.LookPath("virsh"); err != nil {
		m.status = styWarn.Render("virsh not found — install libvirt-client")
		return nil
	}
	m.status = "→ virsh console " + r.D.Name + "   (exit: ctrl+])"
	// pinned URI: bare virsh as a group member lands in qemu:///session
	v := virsh("console", r.D.Name)
	c := exec.Command(v[0], v[1:]...)
	return tea.ExecProcess(c, func(err error) tea.Msg { return execDoneMsg{err} })
}

// execSSH connects to the guest's first agent-reported IP. User picked from
// $VMX_SSH_USER; on kldload the installed default is admin.
func (m *ui) execSSH() tea.Cmd {
	r, ok := m.curRow()
	if !ok {
		return nil
	}
	ip := firstIPv4(r.D.IPs)
	if ip == "" {
		m.status = styWarn.Render("no guest IP (agent down?) — cannot ssh")
		return nil
	}
	user := os.Getenv("VMX_SSH_USER")
	if user == "" && IsKldload() {
		user = "admin"
	}
	dest := ip
	if user != "" {
		dest = user + "@" + ip
	}
	m.status = "→ ssh " + dest
	c := exec.Command("ssh", dest)
	return tea.ExecProcess(c, func(err error) tea.Msg { return execDoneMsg{err} })
}

func firstIPv4(ips []string) string {
	for _, ip := range ips {
		if !strings.Contains(ip, ":") {
			return ip
		}
	}
	if len(ips) > 0 {
		return ips[0]
	}
	return ""
}

// ─── view ───────────────────────────────────────────────────────────────────

func (m *ui) View() string {
	if m.width == 0 {
		return "loading…"
	}
	var b strings.Builder
	// short semantic version only — the full build stamp lives in --version
	// (operator: the long form in the title bar is obnoxious)
	title := styKey.Render("vmxplore") + styTitle.Render(" v"+version+" — VM estate")
	if tools := KldloadTools(); len(tools) > 0 {
		title += styStatus.Render("  ·  kldload")
	}
	b.WriteString(title + "\n")
	if m.err != nil {
		b.WriteString(styWarn.Render("libvirt: "+m.err.Error()) + "\n")
	}

	header := fmt.Sprintf("  %-*s %-13s %6s %11s  %-*s %-*s %8s %5s %s",
		nameW, "DOMAIN", "STATE", "CPU", "MEM", backW, "BACKING",
		origW, "CLONE OF", "SNAPS", "AGENT", "NOTES")
	b.WriteString(styHeader.Render(truncate(header, m.width)) + "\n")

	lines, cursorLine := m.tableLines()
	avail := m.height - 6 // title + header + blank + rule + status + spare
	if avail < 3 {
		avail = 3
	}
	if cursorLine < m.scroll {
		m.scroll = cursorLine
	}
	if cursorLine >= m.scroll+avail {
		m.scroll = cursorLine - avail + 1
	}
	end := min(len(lines), m.scroll+avail)
	for _, l := range lines[m.scroll:end] {
		b.WriteString(l + "\n")
	}

	// Mirror the top of the frame: a blank line and a rule set the menu off
	// from the table the same way the underlined header sets off the title.
	b.WriteString("\n" + styRule.Render(strings.Repeat("─", m.width)) + "\n")
	b.WriteString(m.footerLine())

	if m.overlay != "" {
		return m.renderOverlay(b.String())
	}
	return b.String()
}

const (
	nameW = 22
	backW = 26
	origW = 28
)

// footerLine renders the status + verb menu with the keys coloured (cyan like
// the group headers, labels faint). Styled output can't go through the
// byte-based truncate(), so when the full line is wider than the terminal it
// falls back to the plain truncated form instead of emitting torn ANSI.
func (m *ui) footerLine() string {
	hints := [...][2]string{
		{"enter", "detail"}, {"←→", "fold"}, {"s", "snaps"}, {"a", "actions"},
		{"c", "console"}, {"S", "ssh"}, {"?", "help"}, {"q", "quit"},
	}
	plain := m.status + "  "
	styled := styStatus.Render(m.status) + "  "
	for _, h := range hints {
		plain += " [" + h[0] + "]" + h[1]
		styled += " " + styKey.Render("["+h[0]+"]") + styStatus.Render(h[1])
	}
	if lipgloss.Width(styled) > m.width {
		return styStatus.Render(truncate(plain, m.width))
	}
	return styled
}

// tableLines renders the nav items (group headers + rows of expanded groups)
// to styled lines and reports which line the cursor landed on (for
// scrolling). Headers carry the fold arrow: ▾ open, ▸ folded.
func (m *ui) tableLines() ([]string, int) {
	var lines []string
	cursorLine := 0
	for i, it := range m.navItems() {
		var line string
		sty := lipgloss.NewStyle()
		if it.row < 0 {
			g := m.groups[it.g]
			arrow := "▾"
			suffix := ""
			if m.collapsed[g.Label] {
				arrow = "▸"
				if n := runningIn(g); n > 0 {
					suffix = fmt.Sprintf(" · %d running", n)
				}
			}
			line = fmt.Sprintf("%s %s (%d)%s", arrow, g.Label, len(g.Rows), suffix)
			sty = styGroup
		} else {
			r := m.groups[it.g].Rows[it.row]
			line = fmt.Sprintf("  %-*s %-13s %6s %11s  %-*s %-*s %8s %5s %s",
				nameW, truncate(r.D.Name, nameW), r.D.State,
				cpuCell(m.cpu, r), memCell(r),
				backW, truncate(cellOr(r.Backing, "-"), backW),
				origW, truncate(cellOr(shortOrigin(r.Origin), "-"), origW),
				snapCell(r), agentCell(r), strings.Join(r.Notes, "; "))
			switch {
			case r.Synthetic || len(r.Notes) > 0:
				sty = styWarn
			case r.D.State == "running":
				sty = styRunning
			case r.D.State == "shut off":
				sty = styOff
			}
		}
		line = truncate(line, m.width)
		if i == m.cursor {
			cursorLine = len(lines)
			line = styCursor.Render(line)
		} else {
			line = sty.Render(line)
		}
		lines = append(lines, line)
	}
	return lines, cursorLine
}

// runningIn counts running domains in a group — shown on folded headers so
// a collapsed group never hides live workload.
func runningIn(g GroupRows) int {
	n := 0
	for _, r := range g.Rows {
		if r.D.State == "running" {
			n++
		}
	}
	return n
}

func (m *ui) renderOverlay(base string) string {
	var content string
	switch m.overlay {
	case "detail":
		content = m.detailText()
	case "snaps":
		content = m.snapsText()
	case "help":
		content = helpText()
	case "actions":
		content = m.actionsText()
	case "confirm":
		content = m.confirmText()
	case "input":
		content = m.inputText()
	}
	box := styOverlay.Width(min(m.width-4, 76)).Render(content)
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center,
		box, lipgloss.WithWhitespaceChars(" "))
}

// keyHint renders "key text · key text" overlay-footer hints in the shared
// palette: accent keys, faint prose. Args alternate key, text.
func keyHint(pairs ...string) string {
	var parts []string
	for i := 0; i+1 < len(pairs); i += 2 {
		parts = append(parts,
			styKey.Render(pairs[i])+" "+styStatus.Render(pairs[i+1]))
	}
	return strings.Join(parts, styStatus.Render(" · "))
}

// detailLine is one "label value" row of the detail pane: the attribute
// name in the accent colour so it stands out (operator ask), the value
// muted to match the main window — bright default-white read as glare next
// to the styled table. Pre-styled values (state, warnings) pass through.
func detailLine(label, val string) string {
	if !strings.Contains(val, "\x1b") {
		val = styOff.Render(val)
	}
	return styKey.Render(fmt.Sprintf("%-8s", label)) + " " + val + "\n"
}

func (m *ui) detailText() string {
	r, ok := m.curRow()
	if !ok {
		return keyHint("←/enter", "close")
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n\n", styGroup.Render(r.D.Name))
	state := r.D.State
	switch state {
	case "running":
		state = styRunning.Render(state)
	case "shut off":
		state = styOff.Render(state)
	}
	b.WriteString(detailLine("state", state))
	if !r.Synthetic {
		b.WriteString(detailLine("uuid", r.D.UUID))
		b.WriteString(detailLine("vcpu/mem",
			fmt.Sprintf("%d / %s", r.D.VCPUs, memCell(r))))
		auto, pers := "no", "persistent"
		if r.D.Autostart {
			auto = styRunning.Render("yes")
		}
		if !r.D.Persistent {
			pers = styWarn.Render("TRANSIENT — gone after destroy")
		}
		b.WriteString(detailLine("config", "autostart "+auto+" · "+pers))
		for _, d := range r.D.Disks {
			b.WriteString(detailLine("disk",
				d.Target+" → "+cellOr(d.Dev, d.File)))
		}
		if len(r.D.IPs) > 0 {
			b.WriteString(detailLine("ip", strings.Join(r.D.IPs, ", ")))
		}
	}
	if r.DS != nil {
		b.WriteString(detailLine("dataset", fmt.Sprintf("%s  (used %s, refer %s)",
			r.DS.Name, humanBytes(r.DS.Used), humanBytes(r.DS.Refer))))
		if chain := OriginChain(r.DS, m.dss); len(chain) > 0 {
			b.WriteString(detailLine("lineage", strings.Join(chain, " ← ")))
		}
	}
	for _, n := range r.Notes {
		b.WriteString(detailLine("note", styWarn.Render(n)))
	}
	b.WriteString("\n" + keyHint("←/enter", "close"))
	return b.String()
}

// snapSelection returns the selectable (visible, non-noise) snapshots for
// the current row in render order, plus the dataset's FULL snapshot list in
// creation order — the latter is what rollback's "destroys N newer" math
// must count, noise included.
func (m *ui) snapSelection() (sel []string, all []string) {
	r, ok := m.curRow()
	if !ok || r.DS == nil {
		return nil, nil
	}
	all = m.snaps[r.DS.Name]
	byClass := make(map[string][]string)
	for _, s := range all {
		c := m.rs.ClassifySnap(s)
		byClass[c] = append(byClass[c], s)
	}
	classes := make([]string, 0, len(byClass))
	for c := range byClass {
		if c != SnapNoise {
			classes = append(classes, c)
		}
	}
	sort.Strings(classes)
	for _, c := range classes {
		list := byClass[c]
		if len(list) > snapCapPerClass {
			list = list[len(list)-snapCapPerClass:]
		}
		sel = append(sel, list...)
	}
	return sel, all
}

const snapCapPerClass = 12

// snapsText is the classified snapshot pane: noise collapsed to one line,
// every other class listed (newest last, capped for the box), cursor-
// selectable for rollback.
func (m *ui) snapsText() string {
	r, ok := m.curRow()
	if !ok || r.DS == nil {
		// nil dss = the slow ZFS tick hasn't returned yet; don't claim
		// "no dataset" when the truth is "not looked yet"
		if m.dss == nil {
			return "ZFS data still loading…\n\n" + keyHint("←/s", "close")
		}
		return "no local dataset behind this row\n\n" + keyHint("←/s", "close")
	}
	sel, all := m.snapSelection()
	if m.snapCursor >= len(sel) {
		m.snapCursor = max(0, len(sel)-1)
	}
	byClass := make(map[string][]string)
	for _, s := range all {
		c := m.rs.ClassifySnap(s)
		byClass[c] = append(byClass[c], s)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%s%s\n\n", styGroup.Render(r.DS.Name),
		styStatus.Render(fmt.Sprintf(" — %d snapshots", len(all))))
	if n := len(byClass[SnapNoise]); n > 0 {
		fmt.Fprintf(&b, "%s\n", styStatus.Render(
			fmt.Sprintf("%d automated (noise) — collapsed", n)))
	}
	classes := make([]string, 0, len(byClass))
	for c := range byClass {
		if c != SnapNoise {
			classes = append(classes, c)
		}
	}
	sort.Strings(classes)
	idx := 0
	for _, c := range classes {
		list := byClass[c]
		fmt.Fprintf(&b, "\n%s\n", styGroup.Render(fmt.Sprintf("▾ %s (%d)", c, len(list))))
		shown := list
		if len(shown) > snapCapPerClass {
			shown = shown[len(shown)-snapCapPerClass:]
			b.WriteString(styStatus.Render(fmt.Sprintf(
				"  … %d older omitted", len(list)-snapCapPerClass)) + "\n")
		}
		for _, s := range shown {
			line := "  @" + s
			if idx == m.snapCursor {
				line = styCursor.Render(line)
			}
			b.WriteString(line + "\n")
			idx++
		}
	}
	b.WriteString("\n" + keyHint("j/k", "select", "R", "rollback", "←/s", "close"))
	return b.String()
}

// actionsText is the verb menu for the selected row.
func (m *ui) actionsText() string {
	r, ok := m.curRow()
	if !ok {
		return keyHint("←/a", "close")
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%s%s\n\n", styGroup.Render(r.D.Name),
		styStatus.Render(" — actions"))
	auto := styOff.Render("off")
	if r.D.Autostart {
		auto = styRunning.Render("on")
	}
	verb := func(key, desc string) {
		b.WriteString("  " + styKey.Render(key) + "  " + desc + "\n")
	}
	verb("u", "start")
	verb("d", "shut down (graceful)")
	verb("K", "force off "+styWarn.Render("(retype-gated)"))
	verb("p", "snapshot (zfs, manual-*)")
	verb("v", "edit vcpu/memory (next start)")
	verb("A", "autostart toggle (now: "+auto+")")
	b.WriteString("\n" + styStatus.Render("rollback lives in the snapshot pane (s, then R) · ") +
		keyHint("←/a", "close"))
	return b.String()
}

// confirmText shows the pending plan: the exact commands, the warning, and
// the gate — this box IS the "prints its exact command first" contract.
func (m *ui) confirmText() string {
	p := m.pending
	if p == nil {
		return ""
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n\n%s", styGroup.Render(p.title),
		styCmd.Render(strings.TrimRight(p.cmdLines(), "\n"))+"\n")
	if p.warn != "" {
		fmt.Fprintf(&b, "\n%s\n", styWarn.Render("⚠ "+p.warn))
	}
	if p.retype != "" {
		fmt.Fprintf(&b, "\ntype the name %s to arm, then enter (esc cancels):\n%s %s",
			styWarn.Render(p.retype), styKey.Render("  >"), m.typed)
	} else {
		b.WriteString("\n" + keyHint("y", "run", "esc/q", "cancel"))
	}
	return b.String()
}

// inputText is the parameter prompt for snapshot / specs.
func (m *ui) inputText() string {
	r, ok := m.curRow()
	if !ok {
		return keyHint("esc", "cancel")
	}
	var prompt string
	switch m.inputKind {
	case "snap":
		prompt = fmt.Sprintf("snapshot %s@manual-<suffix>\nsuffix (empty = timestamp):",
			styTitle.Render(r.DS.Name))
	case "vcpus":
		prompt = fmt.Sprintf("new vCPU count for %s (now %d):",
			styTitle.Render(r.D.Name), r.D.VCPUs)
	case "mem":
		prompt = fmt.Sprintf("new memory for %s in GiB (now %s):",
			styTitle.Render(r.D.Name), humanBytes(r.D.MaxMemKiB*1024))
	}
	return prompt + "\n" + styKey.Render("  >") + " " + m.typed + "\n\n" +
		keyHint("enter", "continue", "esc", "cancel")
}

// helpText builds the ?-overlay: sectioned like the estate table, keys in
// the same accent as the footer menu so the whole tool reads as one palette.
func helpText() string {
	var b strings.Builder
	section := func(name string) {
		b.WriteString(styGroup.Render("▾ "+name) + "\n")
	}
	k := func(key, desc string) {
		b.WriteString("  " + styKey.Render(fmt.Sprintf("%-9s", key)) +
			" " + desc + "\n")
	}
	b.WriteString(styKey.Render("vmxplore") +
		styTitle.Render(" v"+version+" — keys") + "\n\n")
	section("navigate")
	k("j/k ↑/↓", "move (group headers select too)")
	k("← →", "fold / unfold the group under the cursor")
	k("g/G", "top / bottom")
	k("mouse", "wheel scrolls · click selects · header click folds ·")
	k("", "clicking the selected row opens detail")
	k("r", "refresh now")
	k("q", "quit — main view only; inside a pane it backs out")
	b.WriteString("\n")
	section("inspect")
	k("enter", "domain detail (disks, IPs, ZFS lineage)")
	k("s", "snapshots, classified (noise collapsed; R rolls back)")
	k("c", "serial console (virsh console; exit ctrl+])")
	k("S", "ssh to guest (agent IP; $VMX_SSH_USER)")
	b.WriteString("\n")
	section("act — a opens the menu, or press the verb key directly")
	k("u", "start")
	k("d", "shut down (graceful)")
	k("K", "force off "+styWarn.Render("(retype-gated)"))
	k("p", "snapshot (zfs, manual-*)")
	k("v", "edit vcpu/mem (next start)")
	k("A", "autostart toggle")
	b.WriteString("\n" + styStatus.Render(
		"Panes close with ← / q / the key that opened them; esc only\n"+
			"aborts a command prompt. Every mutation shows its exact\n"+
			"virsh/zfs command and asks first; all runs land in the audit\n"+
			"log (/var/log/kldload/vmx.log).") + "\n\n" +
		keyHint("←/?", "close"))
	return b.String()
}

func truncate(s string, w int) string {
	if w <= 0 || len(s) <= w {
		return s
	}
	if w <= 1 {
		return s[:w]
	}
	return s[:w-1] + "…"
}

func runTUI(lv *LV, rs *Ruleset) error {
	light := !lipgloss.HasDarkBackground()
	switch os.Getenv("VMX_THEME") {
	case "light":
		light = true
	case "dark":
		light = false
	}
	applyTheme(light)
	p := tea.NewProgram(newUI(lv, rs), tea.WithAltScreen(),
		tea.WithMouseCellMotion())
	_, err := p.Run()
	return err
}
