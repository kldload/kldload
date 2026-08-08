// tui.go — the estate TUI: the joined table, live, keyboard-driven.
//
// bubbletea, matching the family. One screen (the headline view from the
// design doc) plus overlays: detail (enter), snapshots (s, with rollback),
// actions (a — the 0.2 verb menu; verbs.go builds and gates the plans),
// confirm/input for the verb flow, help (?). Interactive externals — `c`
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

// ─── styles ─────────────────────────────────────────────────────────────────

var (
	styTitle   = lipgloss.NewStyle().Bold(true)
	styGroup   = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
	styHeader  = lipgloss.NewStyle().Faint(true).Underline(true)
	styRunning = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	styOff     = lipgloss.NewStyle().Faint(true)
	styWarn    = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	styCursor  = lipgloss.NewStyle().Reverse(true)
	styStatus  = lipgloss.NewStyle().Faint(true)
	styKey     = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
	styRule    = lipgloss.NewStyle().Faint(true)
	styOverlay = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).Padding(0, 1)
)

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

	groups []GroupRows
	rows   []Row // flattened in render order; cursor indexes this
	cursor int
	scroll int

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
		status: "loading estate…"}
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

// rebuild re-joins and re-flattens after any data change, keeping the cursor
// on the same domain when it still exists.
func (m *ui) rebuild() {
	var selected string
	if m.cursor < len(m.rows) {
		selected = m.rows[m.cursor].D.Name
	}
	m.groups = BuildEstate(m.doms, m.dss, m.snaps, m.rs, m.ann)
	m.rows = m.rows[:0]
	for _, g := range m.groups {
		m.rows = append(m.rows, g.Rows...)
	}
	m.cursor = 0
	for i, r := range m.rows {
		if r.D.Name == selected {
			m.cursor = i
			break
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
	}
	return m, nil
}

func (m *ui) key(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch m.overlay {
	case "detail", "help":
		switch msg.String() {
		case "q", "esc", "enter", "?":
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
	switch msg.String() {
	case "q", "ctrl+c":
		return m, tea.Quit
	case "j", "down":
		if m.cursor < len(m.rows)-1 {
			m.cursor++
		}
	case "k", "up":
		if m.cursor > 0 {
			m.cursor--
		}
	case "g":
		m.cursor = 0
	case "G":
		m.cursor = max(0, len(m.rows)-1)
	case "r":
		return m, tea.Batch(m.fetchEstate(), m.fetchZFS())
	case "enter":
		if len(m.rows) > 0 {
			m.overlay = "detail"
		}
	case "s":
		if len(m.rows) > 0 {
			m.overlay = "snaps"
			m.snapCursor = 0
		}
	case "?":
		m.overlay = "help"
	case "a":
		if len(m.rows) > 0 {
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
	if m.cursor >= len(m.rows) {
		m.overlay = ""
		return m, nil
	}
	r := m.rows[m.cursor]
	var plan verbPlan
	var err error
	switch msg.String() {
	case "q", "esc":
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
	if m.cursor >= len(m.rows) {
		m.overlay = ""
		return m, nil
	}
	r := m.rows[m.cursor]
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
	case "q", "esc", "s":
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
		if m.cursor >= len(m.rows) || m.snapCursor >= len(sel) {
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
		plan, err := planRollback(m.rows[m.cursor], target, newer)
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
	if m.cursor >= len(m.rows) {
		return nil
	}
	r := m.rows[m.cursor]
	if r.Synthetic {
		m.status = styWarn.Render("no domain behind this row")
		return nil
	}
	if _, err := exec.LookPath("virsh"); err != nil {
		m.status = styWarn.Render("virsh not found — install libvirt-client")
		return nil
	}
	m.status = "→ virsh console " + r.D.Name + "   (exit: ctrl+])"
	c := exec.Command("virsh", "console", r.D.Name)
	return tea.ExecProcess(c, func(err error) tea.Msg { return execDoneMsg{err} })
}

// execSSH connects to the guest's first agent-reported IP. User picked from
// $VMX_SSH_USER; on kldload the installed default is admin.
func (m *ui) execSSH() tea.Cmd {
	if m.cursor >= len(m.rows) {
		return nil
	}
	r := m.rows[m.cursor]
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
	title := "vmxplore v" + versionString() + " — VM estate"
	if tools := KldloadTools(); len(tools) > 0 {
		title += "  ·  kldload"
	}
	b.WriteString(styTitle.Render(title) + "\n")
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
		{"enter", "detail"}, {"s", "snaps"}, {"a", "actions"},
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

// tableLines renders groups+rows to styled lines and reports which line the
// cursor row landed on (for scrolling).
func (m *ui) tableLines() ([]string, int) {
	var lines []string
	cursorLine := 0
	idx := 0
	for _, g := range m.groups {
		lines = append(lines, styGroup.Render(truncate(
			fmt.Sprintf("▸ %s (%d)", g.Label, len(g.Rows)), m.width)))
		for _, r := range g.Rows {
			line := fmt.Sprintf("  %-*s %-13s %6s %11s  %-*s %-*s %8s %5s %s",
				nameW, truncate(r.D.Name, nameW), r.D.State,
				cpuCell(m.cpu, r), memCell(r),
				backW, truncate(cellOr(r.Backing, "-"), backW),
				origW, truncate(cellOr(shortOrigin(r.Origin), "-"), origW),
				snapCell(r), agentCell(r), strings.Join(r.Notes, "; "))
			line = truncate(line, m.width)
			switch {
			case idx == m.cursor:
				line = styCursor.Render(line)
				cursorLine = len(lines)
			case r.Synthetic || len(r.Notes) > 0:
				line = styWarn.Render(line)
			case r.D.State == "running":
				line = styRunning.Render(line)
			case r.D.State == "shut off":
				line = styOff.Render(line)
			}
			lines = append(lines, line)
			idx++
		}
	}
	return lines, cursorLine
}

func (m *ui) renderOverlay(base string) string {
	var content string
	switch m.overlay {
	case "detail":
		content = m.detailText()
	case "snaps":
		content = m.snapsText()
	case "help":
		content = helpText
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

func (m *ui) detailText() string {
	r := m.rows[m.cursor]
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n\n", styTitle.Render(r.D.Name))
	fmt.Fprintf(&b, "state    %s\n", r.D.State)
	if !r.Synthetic {
		fmt.Fprintf(&b, "uuid     %s\n", r.D.UUID)
		fmt.Fprintf(&b, "vcpu/mem %d / %s\n", r.D.VCPUs, memCell(r))
		auto, pers := "no", "persistent"
		if r.D.Autostart {
			auto = "yes"
		}
		if !r.D.Persistent {
			pers = "TRANSIENT — gone after destroy"
		}
		fmt.Fprintf(&b, "config   autostart %s · %s\n", auto, pers)
		for _, d := range r.D.Disks {
			fmt.Fprintf(&b, "disk     %s → %s\n", d.Target, cellOr(d.Dev, d.File))
		}
		if len(r.D.IPs) > 0 {
			fmt.Fprintf(&b, "ip       %s\n", strings.Join(r.D.IPs, ", "))
		}
	}
	if r.DS != nil {
		fmt.Fprintf(&b, "dataset  %s  (used %s, refer %s)\n",
			r.DS.Name, humanBytes(r.DS.Used), humanBytes(r.DS.Refer))
		if chain := OriginChain(r.DS, m.dss); len(chain) > 0 {
			fmt.Fprintf(&b, "lineage  %s\n", strings.Join(chain, " ← "))
		}
	}
	for _, n := range r.Notes {
		fmt.Fprintf(&b, "note     %s\n", styWarn.Render(n))
	}
	b.WriteString("\n" + styStatus.Render("esc/enter to close"))
	return b.String()
}

// snapSelection returns the selectable (visible, non-noise) snapshots for
// the current row in render order, plus the dataset's FULL snapshot list in
// creation order — the latter is what rollback's "destroys N newer" math
// must count, noise included.
func (m *ui) snapSelection() (sel []string, all []string) {
	if m.cursor >= len(m.rows) || m.rows[m.cursor].DS == nil {
		return nil, nil
	}
	all = m.snaps[m.rows[m.cursor].DS.Name]
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
	r := m.rows[m.cursor]
	if r.DS == nil {
		// nil dss = the slow ZFS tick hasn't returned yet; don't claim
		// "no dataset" when the truth is "not looked yet"
		if m.dss == nil {
			return "ZFS data still loading…\n\n" +
				styStatus.Render("esc to close")
		}
		return "no local dataset behind this row\n\n" +
			styStatus.Render("esc to close")
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
	fmt.Fprintf(&b, "%s — %d snapshots\n\n",
		styTitle.Render(r.DS.Name), len(all))
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
		fmt.Fprintf(&b, "\n%s (%d)\n", styTitle.Render(c), len(list))
		shown := list
		if len(shown) > snapCapPerClass {
			shown = shown[len(shown)-snapCapPerClass:]
			fmt.Fprintf(&b, "  … %d older omitted\n", len(list)-snapCapPerClass)
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
	b.WriteString("\n" + styStatus.Render("j/k select · R rollback · esc close"))
	return b.String()
}

// actionsText is the verb menu for the selected row.
func (m *ui) actionsText() string {
	r := m.rows[m.cursor]
	var b strings.Builder
	fmt.Fprintf(&b, "%s — actions\n\n", styTitle.Render(r.D.Name))
	auto := "off"
	if r.D.Autostart {
		auto = "on"
	}
	fmt.Fprintf(&b, "  u  start\n")
	fmt.Fprintf(&b, "  d  shut down (graceful)\n")
	fmt.Fprintf(&b, "  K  force off (retype-gated)\n")
	fmt.Fprintf(&b, "  p  snapshot (zfs, manual-*)\n")
	fmt.Fprintf(&b, "  v  edit vcpu/memory (next start)\n")
	fmt.Fprintf(&b, "  A  autostart toggle (now: %s)\n", auto)
	b.WriteString("\n" + styStatus.Render(
		"rollback lives in the snapshot pane (s, then R) · esc close"))
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
	fmt.Fprintf(&b, "%s\n\n%s", styTitle.Render(p.title), p.cmdLines())
	if p.warn != "" {
		fmt.Fprintf(&b, "\n%s\n", styWarn.Render("⚠ "+p.warn))
	}
	if p.retype != "" {
		fmt.Fprintf(&b, "\ntype the name %s to arm, then enter:\n  > %s",
			styTitle.Render(p.retype), m.typed)
	} else {
		b.WriteString("\n" + styStatus.Render("y to run · esc to cancel"))
	}
	return b.String()
}

// inputText is the parameter prompt for snapshot / specs.
func (m *ui) inputText() string {
	r := m.rows[m.cursor]
	var prompt string
	switch m.inputKind {
	case "snap":
		prompt = fmt.Sprintf("snapshot %s@manual-<suffix>\nsuffix (empty = timestamp):",
			r.DS.Name)
	case "vcpus":
		prompt = fmt.Sprintf("new vCPU count for %s (now %d):", r.D.Name, r.D.VCPUs)
	case "mem":
		prompt = fmt.Sprintf("new memory for %s in GiB (now %s):",
			r.D.Name, humanBytes(r.D.MaxMemKiB*1024))
	}
	return prompt + "\n  > " + m.typed + "\n\n" +
		styStatus.Render("enter to continue · esc to cancel")
}

const helpText = `vmxplore — keys

  j/k ↑/↓   move        g/G  top/bottom
  enter     domain detail (disks, IPs, ZFS lineage)
  s         snapshots, classified (noise collapsed; R rolls back)
  a         actions menu — or press the verb key directly:
  u         start            d   shut down (graceful)
  K         force off        p   snapshot (zfs, manual-*)
  v         edit vcpu/mem    A   autostart toggle
  c         serial console (virsh console; exit ctrl+])
  S         ssh to guest (agent IP; $VMX_SSH_USER)
  r         refresh now      q   quit

Every mutation shows its exact virsh/zfs command and asks first;
force-off and rollback require retyping the domain name. All runs
land in the audit log (/var/log/kldload/vmx.log).`

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
	p := tea.NewProgram(newUI(lv, rs), tea.WithAltScreen())
	_, err := p.Run()
	return err
}
