// tui.go — the bubbletea model: a rail of eight sections, a table with a
// filter and a sort, a detail pane for the selected row, a status bar with
// the keys, and the verbs that act on the selected row.
//
// Rendering is a pure function of the model. `kld <section> --print` uses
// body(), the plain table with no borders or colour, so scripts and the
// smoke gate read the same text the console shows; View() lays the same
// table out for a terminal.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// The calm palette of the web console: one accent, colour only for state.
var (
	cAccent = lipgloss.Color("111")
	cMuted  = lipgloss.Color("244")
	cBright = lipgloss.Color("255")
	cBorder = lipgloss.Color("238")
	cGood   = lipgloss.Color("42")
	cWarn   = lipgloss.Color("214")
	cBad    = lipgloss.Color("203")

	stBrand  = lipgloss.NewStyle().Bold(true).Foreground(cAccent)
	stTitle  = lipgloss.NewStyle().Bold(true).Foreground(cBright)
	stDim    = lipgloss.NewStyle().Foreground(cMuted)
	stRail   = lipgloss.NewStyle().Foreground(cMuted).Padding(0, 1)
	stRailA  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("0")).Background(cAccent).Padding(0, 1)
	stHead   = lipgloss.NewStyle().Bold(true).Foreground(cBright)
	stSel    = lipgloss.NewStyle().Foreground(lipgloss.Color("0")).Background(lipgloss.Color("250"))
	stGood   = lipgloss.NewStyle().Foreground(cGood)
	stWarn   = lipgloss.NewStyle().Foreground(cWarn)
	stBad    = lipgloss.NewStyle().Foreground(cBad)
	stKey    = lipgloss.NewStyle().Bold(true).Foreground(cBright)
	stPane   = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cBorder).Padding(0, 1)
	stHelpBx = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(cAccent).Padding(1, 2)
)

type loadedMsg sectionData

type doneMsg struct {
	what string
	err  error
}

type tickMsg time.Time

type model struct {
	active   int
	row      int
	width    int
	height   int
	data     []*sectionData
	loading  []bool
	status   string
	statusAt time.Time
	prompt   string // non-empty while a verb waits for typed input
	input    string
	pending  func(string) tea.Cmd
	help     bool
	detail   bool
	filter   textinput.Model
	filterOn bool
	sortCol  int
	sortDesc bool
	spin     spinner.Model
	now      time.Time
}

// newModel with a width is the --print form: no terminal, so no paging (a
// height of 0 lists every row); the TUI learns its real size from the first
// WindowSizeMsg.
func newModel(start, width int) model {
	f := textinput.New()
	f.Prompt = "/"
	f.Placeholder = "filter rows"
	f.CharLimit = 64
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = lipgloss.NewStyle().Foreground(cAccent)
	return model{active: start, width: width, detail: true, sortCol: -1,
		data: make([]*sectionData, len(sections)), loading: make([]bool, len(sections)),
		filter: f, spin: sp, now: time.Now()}
}

func (m *model) apply(d sectionData) {
	dd := d
	m.data[d.section] = &dd
	m.loading[d.section] = false
	if m.row >= len(m.rows()) {
		m.row = 0
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(m.reload(), m.spin.Tick, tickEvery())
}

func tickEvery() tea.Cmd {
	return tea.Tick(time.Second, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m model) reload() tea.Cmd {
	i := m.active
	return func() tea.Msg { return loadedMsg(loadSection(i)) }
}

func (m *model) say(s string) {
	m.status, m.statusAt = s, time.Now()
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil
	case tickMsg:
		m.now = time.Time(msg)
		// a status line outlives its moment: eight seconds, then the keys return
		if m.status != "" && time.Since(m.statusAt) > 8*time.Second {
			m.status = ""
		}
		return m, tickEvery()
	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		return m, cmd
	case loadedMsg:
		m.apply(sectionData(msg))
		return m, nil
	case doneMsg:
		if msg.err != nil {
			m.say(stBad.Render(msg.what + ": " + msg.err.Error()))
		} else {
			m.say(stGood.Render(msg.what + ": done"))
		}
		m.loading[m.active] = true
		return m, m.reload()
	case tea.KeyMsg:
		if m.prompt != "" {
			return m.updatePrompt(msg)
		}
		if m.filterOn {
			return m.updateFilter(msg)
		}
		if m.help {
			m.help = false
			return m, nil
		}
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "?":
			m.help = true
		case "tab", "l", "right":
			m.switchTo((m.active + 1) % len(sections))
			return m, m.loadIfEmpty()
		case "shift+tab", "h", "left":
			m.switchTo((m.active + len(sections) - 1) % len(sections))
			return m, m.loadIfEmpty()
		case "1", "2", "3", "4", "5", "6", "7", "8":
			m.switchTo(int(msg.String()[0] - '1'))
			return m, m.loadIfEmpty()
		case "j", "down":
			if m.row < len(m.rows())-1 {
				m.row++
			}
		case "k", "up":
			if m.row > 0 {
				m.row--
			}
		case "g", "home":
			m.row = 0
		case "G", "end":
			if n := len(m.rows()); n > 0 {
				m.row = n - 1
			}
		case "pgdown", "ctrl+d":
			m.row = min(m.row+m.pageSize(), max(len(m.rows())-1, 0))
		case "pgup", "ctrl+u":
			m.row = max(m.row-m.pageSize(), 0)
		case "/":
			m.filterOn = true
			m.filter.Focus()
			return m, textinput.Blink
		case "o":
			m.cycleSort()
		case "i":
			m.detail = !m.detail
		case "r":
			m.loading[m.active] = true
			m.say(stDim.Render("reloading " + sections[m.active]))
			return m, m.reload()
		case "enter":
			return m.openDeep()
		case "c":
			return m.verbClone()
		case "s":
			return m.verbSnap()
		case "d":
			return m.verbDelete()
		case "a":
			return m.verbArm()
		case "x":
			return m.verbDisarm()
		}
	}
	return m, nil
}

func (m *model) switchTo(i int) {
	m.active, m.row, m.status, m.sortCol = i, 0, "", -1
	m.filter.SetValue("")
}

func (m *model) loadIfEmpty() tea.Cmd {
	if m.data[m.active] == nil && !m.loading[m.active] {
		m.loading[m.active] = true
		return m.reload()
	}
	return nil
}

func (m model) updateFilter(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.filter.SetValue("")
		fallthrough
	case "enter":
		m.filterOn = false
		m.filter.Blur()
		m.row = 0
		return m, nil
	}
	var cmd tea.Cmd
	m.filter, cmd = m.filter.Update(msg)
	m.row = 0
	return m, cmd
}

// cycleSort moves the sort through the columns and back to the tool's own
// order: unsorted -> col 0 asc -> col 0 desc -> col 1 asc -> … -> unsorted.
func (m *model) cycleSort() {
	d := m.data[m.active]
	if d == nil || len(d.columns) == 0 {
		return
	}
	switch {
	case m.sortCol < 0:
		m.sortCol, m.sortDesc = 0, false
	case !m.sortDesc:
		m.sortDesc = true
	case m.sortCol+1 < len(d.columns):
		m.sortCol, m.sortDesc = m.sortCol+1, false
	default:
		m.sortCol, m.sortDesc = -1, false
	}
	m.row = 0
}

// rows is what the table shows: the section's rows through the filter and
// the sort. Numeric-looking cells sort as numbers so "9" sits before "10".
func (m model) rows() [][]string {
	d := m.data[m.active]
	if d == nil {
		return nil
	}
	out := d.rows
	if q := strings.ToLower(strings.TrimSpace(m.filter.Value())); q != "" {
		out = nil
		for _, r := range d.rows {
			if strings.Contains(strings.ToLower(strings.Join(r, " ")), q) {
				out = append(out, r)
			}
		}
	}
	if m.sortCol >= 0 && m.sortCol < len(d.columns) {
		c := m.sortCol
		sorted := append([][]string(nil), out...)
		sort.SliceStable(sorted, func(i, j int) bool {
			a, b := cell(sorted[i], c), cell(sorted[j], c)
			less := false
			if fa, ea := strconv.ParseFloat(a, 64); ea == nil {
				if fb, eb := strconv.ParseFloat(b, 64); eb == nil {
					less = fa < fb
				} else {
					less = true
				}
			} else if _, eb := strconv.ParseFloat(b, 64); eb == nil {
				less = false
			} else {
				less = a < b
			}
			if m.sortDesc {
				return !less && a != b
			}
			return less
		})
		out = sorted
	}
	return out
}

func cell(r []string, i int) string {
	if i < len(r) {
		return r[i]
	}
	return ""
}

func (m model) pageSize() int {
	if n := m.height - 9; n > 3 {
		return n
	}
	return 10
}

// selected returns the first column of the highlighted row: the machine,
// pool, plane, node, target or MAC a verb acts on.
func (m model) selected() string {
	rows := m.rows()
	if m.row >= len(rows) || len(rows[m.row]) == 0 {
		return ""
	}
	return rows[m.row][0]
}

// ── verbs: the shipped bash verbs, never a re-implementation ────────────────

func (m model) updatePrompt(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "ctrl+c":
		m.prompt, m.input, m.pending = "", "", nil
		m.say(stDim.Render("cancelled"))
	case "enter":
		cmd := m.pending(m.input)
		m.prompt, m.input, m.pending = "", "", nil
		return m, cmd
	case "backspace":
		if len(m.input) > 0 {
			m.input = m.input[:len(m.input)-1]
		}
	default:
		// A paste (or tmux send-keys) arrives as ONE KeyRunes event carrying
		// the whole string; taking only single-character events dropped
		// every pasted name and the verb saw "" (onyx, 2026-09-26).
		if msg.Type == tea.KeyRunes || msg.Type == tea.KeySpace {
			m.input += string(msg.Runes)
		}
	}
	return m, nil
}

func runVerb(what string, args ...string) tea.Cmd {
	return func() tea.Msg {
		_, err := run(600e9, args[0], args[1:]...)
		return doneMsg{what: what, err: err}
	}
}

func (m model) verbClone() (tea.Model, tea.Cmd) {
	src := m.selected()
	if sections[m.active] != "Machines" || src == "" {
		m.say(stWarn.Render("clone: pick a machine in Machines first"))
		return m, nil
	}
	m.prompt = "clone " + src + " as: "
	m.pending = func(name string) tea.Cmd {
		name = strings.TrimSpace(name)
		if !nameOK(name) {
			return func() tea.Msg { return doneMsg{"clone", fmt.Errorf("%q is not a VM name", name)} }
		}
		// kvm-clone registers the clone; the enrol sweep (or `kldload-enroll
		// NAME`) puts it on the mesh once it has an address.
		return runVerb("kvm-clone "+src+" "+name, "kvm-clone", src, name)
	}
	return m, nil
}

func (m model) verbSnap() (tea.Model, tea.Cmd) {
	vm := m.selected()
	if sections[m.active] != "Machines" || vm == "" {
		m.say(stWarn.Render("snapshot: pick a machine in Machines first"))
		return m, nil
	}
	return m, runVerb("kvm-snap "+vm, "kvm-snap", vm)
}

func (m model) verbDelete() (tea.Model, tea.Cmd) {
	vm := m.selected()
	if sections[m.active] != "Machines" || vm == "" {
		m.say(stWarn.Render("delete: pick a machine in Machines first"))
		return m, nil
	}
	// The one verb that asks: typing the name is the confirmation, the way
	// kfire and kvm-delete's own --force gate mean it.
	m.prompt = "delete " + vm + " and its zvol — type its name to confirm: "
	m.pending = func(typed string) tea.Cmd {
		if strings.TrimSpace(typed) != vm {
			return func() tea.Msg { return doneMsg{"delete", fmt.Errorf("name did not match, nothing deleted")} }
		}
		return runVerb("kvm-delete "+vm, "kvm-delete", vm, "--force")
	}
	return m, nil
}

// Provision verbs: the consent tokens kldload-netboot-server keeps per MAC.
// `a` arms one machine (or "any" for open mode) with an answers file; `x`
// removes the selected machine's token so it boots its own disk again.
func (m model) verbArm() (tea.Model, tea.Cmd) {
	if sections[m.active] != "Provision" {
		m.say(stWarn.Render("arm: open Provision first"))
		return m, nil
	}
	m.prompt = "arm-install <mac|any> <answers.env>: "
	m.pending = func(typed string) tea.Cmd {
		f := strings.Fields(typed)
		if len(f) != 2 || !macOrAny(f[0]) || strings.HasPrefix(f[1], "-") {
			return func() tea.Msg { return doneMsg{"arm-install", fmt.Errorf("need a MAC (or any) and an answers file")} }
		}
		return runVerb("arm-install "+f[0], "kldload-netboot-server", "arm-install", f[0], f[1])
	}
	return m, nil
}

func (m model) verbDisarm() (tea.Model, tea.Cmd) {
	mac := m.selected()
	if sections[m.active] != "Provision" || !macOrAny(mac) {
		m.say(stWarn.Render("disarm: pick an armed machine in Provision first"))
		return m, nil
	}
	return m, runVerb("disarm "+mac, "kldload-netboot-server", "disarm", mac)
}

// macOrAny accepts aa:bb:cc:dd:ee:ff, the aa-bb-… form the token files use,
// or the word any; nothing else reaches the tool's argv.
func macOrAny(s string) bool {
	if s == "any" {
		return true
	}
	if len(s) != 17 {
		return false
	}
	for i, c := range s {
		if i%3 == 2 {
			if c != ':' && c != '-' {
				return false
			}
		} else if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}

func nameOK(s string) bool {
	if s == "" || len(s) > 63 || s[0] == '-' {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

// openDeep hands the terminal to the section's own console and reloads
// when it returns. Each is looked up on PATH first so a missing one is a
// status line, not a crash.
func (m model) openDeep() (tea.Model, tea.Cmd) {
	var argv []string
	switch sections[m.active] {
	case "Machines", "Overview":
		argv = []string{"vmxplore", "--tui"}
	case "Storage":
		argv = []string{"zxplore", "--tui"}
	case "Network":
		argv = []string{"wgx", "tui"}
	case "Cluster":
		argv = []string{"k9s"}
	case "Estate":
		argv = []string{"kldload-doctor"}
	case "Provision":
		argv = []string{"kldload-netboot-server", "status"}
	case "Metrics":
		m.say("dashboards live in the web console: https://" + hostname() + ":8443/grafana/")
		return m, nil
	}
	if _, err := exec.LookPath(argv[0]); err != nil {
		m.say(stWarn.Render(argv[0] + " is not installed on this host"))
		return m, nil
	}
	c := exec.Command("sudo", append([]string{"-n"}, argv...)...)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	what := strings.Join(argv, " ")
	return m, tea.ExecProcess(c, func(err error) tea.Msg { return doneMsg{what: what, err: err} })
}

// ── view ────────────────────────────────────────────────────────────────────

// deepFor names the console Enter opens, for the detail pane and the help.
func deepFor(section string) string {
	switch section {
	case "Machines", "Overview":
		return "vmxplore"
	case "Storage":
		return "zxplore"
	case "Network":
		return "wgx"
	case "Cluster":
		return "k9s"
	case "Estate":
		return "kldload-doctor"
	case "Provision":
		return "kldload-netboot-server status"
	}
	return ""
}

func (m model) View() string {
	if m.width == 0 {
		return ""
	}
	if m.help {
		return m.helpView()
	}
	w := m.width
	var b strings.Builder
	// title bar: brand · host on the left, the clock and a spinner on the right
	left := stBrand.Render("kldload") + stDim.Render("  operator console · "+hostname())
	right := stDim.Render(m.now.Format("15:04:05"))
	if m.loading[m.active] {
		right = m.spin.View() + " " + stDim.Render("loading") + "  " + right
	}
	b.WriteString(padBetween(left, right, w) + "\n")
	// rail
	var rail []string
	for i, s := range sections {
		label := fmt.Sprintf("%d %s", i+1, s)
		if i == m.active {
			rail = append(rail, stRailA.Render(label))
		} else {
			rail = append(rail, stRail.Render(label))
		}
	}
	b.WriteString(strings.Join(rail, "") + "\n")
	b.WriteString(stDim.Render(strings.Repeat("─", w)) + "\n")
	d := m.data[m.active]
	// headline (the tool's summary, or its error)
	switch {
	case d == nil && m.loading[m.active]:
		b.WriteString(stDim.Render("loading "+sections[m.active]+"…") + "\n")
	case d == nil:
		b.WriteString(stDim.Render("press r to load") + "\n")
	default:
		if d.err != "" {
			b.WriteString(stBad.Render(d.err) + "\n")
		}
		if d.headline != "" {
			b.WriteString(stTitle.Render(truncate(d.headline, w)) + "\n")
		}
	}
	// table + detail
	bodyH := m.height - 6 // title, rail, rule, headline, status, one spare
	if bodyH < 4 {
		bodyH = 4
	}
	// The detail pane is a quarter of a wide terminal, never more than 44
	// cells: at a third it squeezed the table until the first column — the
	// machine name, the one thing a row is for — read as "app-adguard-…"
	// (onyx, 150 columns, 2026-09-26).
	detailW := 0
	if m.detail && w >= 120 {
		detailW = min(44, w/4)
	}
	tableW := w - detailW
	table := m.tableView(d, tableW, bodyH)
	if detailW > 0 {
		det := m.detailView(d, detailW-4, bodyH-2)
		b.WriteString(lipgloss.JoinHorizontal(lipgloss.Top, table, stPane.Width(detailW-2).Height(bodyH-2).Render(det)) + "\n")
	} else {
		b.WriteString(table + "\n")
	}
	// status bar
	var sl string
	switch {
	case m.prompt != "":
		sl = stWarn.Render(m.prompt) + m.input + "█"
	case m.filterOn:
		sl = m.filter.View() + stDim.Render("   enter keep · esc clear")
	case m.status != "":
		sl = m.status
	default:
		sl = keyHints(sections[m.active])
	}
	rows := m.rows()
	var sr string
	if d != nil {
		sr = fmt.Sprintf("%d rows", len(rows))
		if q := m.filter.Value(); q != "" {
			sr = fmt.Sprintf("/%s · %d of %d", q, len(rows), len(d.rows))
		}
		if m.sortCol >= 0 && m.sortCol < len(d.columns) {
			arrow := "↑"
			if m.sortDesc {
				arrow = "↓"
			}
			sr += " · sort " + d.columns[m.sortCol] + arrow
		}
		if !d.loadedAt.IsZero() {
			sr += " · " + d.loadedAt.Format("15:04:05")
		}
	}
	b.WriteString(padBetween(sl, stDim.Render(sr), w))
	return b.String()
}

func keyHints(section string) string {
	k := func(key, what string) string { return stKey.Render(key) + stDim.Render(" "+what) }
	parts := []string{k("1-8", "section"), k("j/k", "row"), k("/", "filter"), k("o", "sort"), k("r", "reload")}
	if deep := deepFor(section); deep != "" {
		parts = append(parts, k("enter", deep))
	}
	switch section {
	case "Machines":
		parts = append(parts, k("c", "clone"), k("s", "snapshot"), k("d", "delete"))
	case "Provision":
		parts = append(parts, k("a", "arm"), k("x", "disarm"))
	}
	parts = append(parts, k("?", "help"), k("q", "quit"))
	return strings.Join(parts, "  ")
}

// tableView lays the rows out in width w and height h: header, then the page
// that holds the selection. Numeric columns are right-aligned; the state
// word in a row is coloured, the rest of the row is not.
func (m model) tableView(d *sectionData, w, h int) string {
	if d == nil || len(d.columns) == 0 {
		return strings.Repeat("\n", max(h-1, 0))
	}
	rows := m.rows()
	widths := columnWidths(d.columns, rows, w-1)
	numeric := numericColumns(rows, len(d.columns))
	line := func(cells []string, sel bool) string {
		parts := make([]string, len(d.columns))
		for i := range d.columns {
			v := truncate(cell(cells, i), widths[i])
			if numeric[i] {
				parts[i] = fmt.Sprintf("%*s", widths[i], v)
			} else {
				parts[i] = fmt.Sprintf("%-*s", widths[i], v)
			}
			if !sel {
				parts[i] = colourCell(parts[i], v)
			}
		}
		s := strings.Join(parts, "  ")
		if sel {
			return stSel.Render(fmt.Sprintf("%-*s", w-1, s))
		}
		return s
	}
	var b strings.Builder
	b.WriteString(stHead.Render(line(d.columns, false)) + "\n")
	limit := h - 1
	if limit < 1 {
		limit = 1
	}
	start := 0
	if m.row >= limit {
		start = m.row - limit + 1
	}
	n := 0
	for i := start; i < len(rows) && i < start+limit; i++ {
		b.WriteString(line(rows[i], i == m.row) + "\n")
		n++
	}
	if len(rows) == 0 {
		b.WriteString(stDim.Render("nothing matches") + "\n")
		n++
	}
	for ; n < limit; n++ {
		b.WriteString("\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

// detailView is the selected row as key/value, then what Enter and the
// verbs would do to it.
func (m model) detailView(d *sectionData, w, h int) string {
	if d == nil || len(d.columns) == 0 {
		return stDim.Render("no row")
	}
	rows := m.rows()
	if m.row >= len(rows) {
		return stDim.Render("no row")
	}
	r := rows[m.row]
	kw := 0
	for _, c := range d.columns {
		kw = max(kw, len(c))
	}
	var lines []string
	lines = append(lines, stTitle.Render(truncate(cell(r, 0), w)), "")
	for i, c := range d.columns {
		v := cell(r, i)
		if v == "" || v == "-" {
			continue
		}
		// long values (a repair command, a scrape URL) wrap on their own lines
		vw := w - kw - 2
		if vw < 12 || len(v) <= vw {
			lines = append(lines, stDim.Render(fmt.Sprintf("%-*s", kw, c))+"  "+colourCell(truncate(v, max(vw, 1)), v))
		} else {
			lines = append(lines, stDim.Render(c))
			for len(v) > 0 {
				n := min(len(v), w)
				lines = append(lines, "  "+v[:n])
				v = v[n:]
			}
		}
	}
	lines = append(lines, "")
	if deep := deepFor(sections[m.active]); deep != "" {
		lines = append(lines, stKey.Render("enter")+stDim.Render("  open in "+deep))
	}
	switch sections[m.active] {
	case "Machines":
		lines = append(lines, stKey.Render("c")+stDim.Render("  kvm-clone "+cell(r, 0)+" <name>"),
			stKey.Render("s")+stDim.Render("  kvm-snap "+cell(r, 0)),
			stKey.Render("d")+stDim.Render("  kvm-delete "+cell(r, 0)+" --force"))
	case "Provision":
		lines = append(lines, stKey.Render("x")+stDim.Render("  disarm "+cell(r, 0)))
	}
	if len(lines) > h {
		lines = lines[:h]
	}
	return strings.Join(lines, "\n")
}

func (m model) helpView() string {
	k := func(key, what string) string { return "  " + stKey.Render(fmt.Sprintf("%-10s", key)) + what }
	body := strings.Join([]string{
		stTitle.Render("kld " + versionFull() + " — keys"),
		"",
		k("1-8, tab", "switch section"),
		k("j / k", "move down / up   (g, G first / last · ctrl+d, ctrl+u page)"),
		k("/", "filter rows; enter keeps it, esc clears it"),
		k("o", "sort: next column, then descending, then the tool's order"),
		k("i", "show or hide the detail pane"),
		k("r", "reload the section"),
		k("enter", "open the deep console: vmxplore, zxplore, wgx, k9s"),
		"",
		k("c", "Machines: clone the selected machine (kvm-clone)"),
		k("s", "Machines: snapshot it (kvm-snap)"),
		k("d", "Machines: delete it and its zvol; type its name to confirm"),
		k("a", "Provision: arm a MAC (or any) with an answers file"),
		k("x", "Provision: disarm the selected machine"),
		"",
		k("?", "this help   ·   any key closes it"),
		k("q", "quit"),
	}, "\n")
	box := stHelpBx.Render(body)
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, box)
}

// body is the --print form: the same headline and table, plain, every row.
func (m model) body() string {
	var b strings.Builder
	b.WriteString("kldload  operator console · " + hostname() + "\n")
	var rail []string
	for i, s := range sections {
		if i == m.active {
			rail = append(rail, fmt.Sprintf("[%d %s]", i+1, s))
		} else {
			rail = append(rail, fmt.Sprintf(" %d %s ", i+1, s))
		}
	}
	b.WriteString(strings.Join(rail, " ") + "\n\n")
	d := m.data[m.active]
	if d == nil {
		return b.String()
	}
	if d.err != "" {
		b.WriteString(d.err + "\n")
	}
	if d.headline != "" {
		b.WriteString(d.headline + "\n")
	}
	if len(d.columns) == 0 {
		return b.String()
	}
	widths := columnWidths(d.columns, d.rows, 0)
	line := func(cells []string) string {
		parts := make([]string, len(d.columns))
		for i := range d.columns {
			parts[i] = fmt.Sprintf("%-*s", widths[i], cell(cells, i))
		}
		return strings.TrimRight(strings.Join(parts, "  "), " ")
	}
	b.WriteString(line(d.columns) + "\n")
	for _, r := range d.rows {
		b.WriteString(line(r) + "\n")
	}
	return b.String()
}

// ── layout helpers ──────────────────────────────────────────────────────────

// columnWidths sizes each column to its content; with a total to fit, the
// widest columns give way first so one long value (a repair command, a
// scrape URL) cannot push the rest off the screen.
func columnWidths(cols []string, rows [][]string, total int) []int {
	w := make([]int, len(cols))
	for i, c := range cols {
		w[i] = len(c)
	}
	for _, r := range rows {
		for i := range cols {
			w[i] = max(w[i], lipgloss.Width(cell(r, i)))
		}
	}
	if total <= 0 {
		return w
	}
	gaps := 2 * (len(cols) - 1)
	for sum(w)+gaps > total {
		// the first column is the row's name and gives way last
		widest := -1
		for i := 1; i < len(w); i++ {
			if w[i] > 6 && (widest < 0 || w[i] > w[widest]) {
				widest = i
			}
		}
		if widest < 0 {
			if w[0] <= 6 {
				break
			}
			widest = 0
		}
		w[widest]--
	}
	return w
}

func numericColumns(rows [][]string, n int) []bool {
	num := make([]bool, n)
	for i := 0; i < n; i++ {
		seen := false
		num[i] = true
		for _, r := range rows {
			v := cell(r, i)
			if v == "" || v == "-" {
				continue
			}
			seen = true
			if _, err := strconv.ParseFloat(strings.TrimRight(v, "%BKMGT"), 64); err != nil {
				num[i] = false
				break
			}
		}
		num[i] = num[i] && seen
	}
	return num
}

func sum(xs []int) int {
	t := 0
	for _, x := range xs {
		t += x
	}
	return t
}

func truncate(s string, w int) string {
	if w <= 0 {
		return ""
	}
	if lipgloss.Width(s) <= w {
		return s
	}
	r := []rune(s)
	if w == 1 {
		return "…"
	}
	return string(r[:w-1]) + "…"
}

func padBetween(left, right string, w int) string {
	gap := w - lipgloss.Width(left) - lipgloss.Width(right)
	if gap < 1 {
		gap = 1
	}
	return left + strings.Repeat(" ", gap) + right
}

// colourCell paints a cell by the state word it carries; anything else is
// plain. State is the only thing that gets a colour.
func colourCell(rendered, raw string) string {
	switch strings.ToLower(strings.Fields(raw + " x")[0]) {
	case "running", "up", "online", "ok", "active", "ready", "true", "install":
		return stGood.Render(rendered)
	case "fail", "down", "degraded", "faulted", "absent", "unavailable", "failed", "unreachable":
		return stBad.Render(rendered)
	case "warn", "unregistered", "stale", "never", "open":
		return stWarn.Render(rendered)
	}
	return rendered
}
