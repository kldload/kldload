// tui.go — the bubbletea model: a rail of sections, each with sub-tabs; a
// table with a filter and a sort; a detail pane for the selected row; a
// status bar with the keys; a help overlay; and the verbs of verbs.go acting
// on the selected row.
//
// Rendering is a pure function of the model. `kld <section> [sub] --print`
// uses body(), the plain table with no borders or colour, so scripts and the
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
	stSub    = lipgloss.NewStyle().Foreground(cMuted).Padding(0, 1)
	stSubA   = lipgloss.NewStyle().Bold(true).Foreground(cAccent).Underline(true).Padding(0, 1)
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
	sub      []int             // current sub-tab per section
	ctx      map[string]string // "si/sub" -> context (a VM, a dataset)
	row      int
	width    int
	height   int
	data     map[string]*sectionData
	loading  map[string]bool
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
func newModel(start, sub, width int) model {
	f := textinput.New()
	f.Prompt = "/"
	f.Placeholder = "filter rows"
	f.CharLimit = 64
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = lipgloss.NewStyle().Foreground(cAccent)
	m := model{active: start, width: width, detail: true, sortCol: -1,
		sub: make([]int, len(sections)), ctx: map[string]string{},
		data: map[string]*sectionData{}, loading: map[string]bool{},
		filter: f, spin: sp, now: time.Now()}
	m.sub[start] = sub
	return m
}

func (m model) key() string { return fmt.Sprintf("%d/%d", m.active, m.sub[m.active]) }

func (m model) cur() *sectionData { return m.data[m.key()] }

func (m model) subName() string { return sections[m.active].subs[m.sub[m.active]] }

func (m model) verbsHere() []verb { return verbs[sections[m.active].name+"/"+m.subName()] }

func (m *model) apply(d sectionData) {
	dd := d
	k := fmt.Sprintf("%d/%d", d.section, d.sub)
	m.data[k] = &dd
	m.loading[k] = false
	if k == m.key() && m.row >= len(m.rows()) {
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
	si, sub, ctx := m.active, m.sub[m.active], m.ctx[m.key()]
	return func() tea.Msg { return loadedMsg(loadSection(si, sub, ctx)) }
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
		m.loading[m.key()] = true
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
		case "l", "right":
			m.switchTo((m.active+1)%len(sections), -1)
			return m, m.loadIfEmpty()
		case "h", "left":
			m.switchTo((m.active+len(sections)-1)%len(sections), -1)
			return m, m.loadIfEmpty()
		case "tab", "]":
			m.switchTo(m.active, (m.sub[m.active]+1)%len(sections[m.active].subs))
			return m, m.loadIfEmpty()
		case "shift+tab", "[":
			n := len(sections[m.active].subs)
			m.switchTo(m.active, (m.sub[m.active]+n-1)%n)
			return m, m.loadIfEmpty()
		case "1", "2", "3", "4", "5", "6", "7", "8", "9", "0":
			i := int(msg.String()[0] - '1')
			if msg.String() == "0" {
				i = 9
			}
			if i < len(sections) {
				m.switchTo(i, -1)
				return m, m.loadIfEmpty()
			}
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
		case "pgdown", "ctrl+d", "ctrl+f": // ctrl+f/ctrl+b are vmxplore's paging keys; both sets work here
			m.row = min(m.row+m.pageSize(), max(len(m.rows())-1, 0))
		case "pgup", "ctrl+u", "ctrl+b":
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
			m.loading[m.key()] = true
			m.say(stDim.Render("reloading " + sections[m.active].name + " / " + m.subName()))
			return m, m.reload()
		case "esc":
			// esc leaves a context: the VM's snapshots become every VM's
			if m.ctx[m.key()] != "" {
				delete(m.ctx, m.key())
				m.loading[m.key()] = true
				m.row = 0
				return m, m.reload()
			}
		case "enter":
			return m.drill()
		default:
			for _, v := range m.verbsHere() {
				if v.key == msg.String() {
					return m.runVerb(v)
				}
			}
		}
	}
	return m, nil
}

func (m *model) switchTo(si, sub int) {
	if sub >= 0 {
		m.sub[si] = sub
	}
	m.active, m.row, m.status, m.sortCol = si, 0, "", -1
	m.filter.SetValue("")
}

func (m *model) loadIfEmpty() tea.Cmd {
	if m.cur() == nil && !m.loading[m.key()] {
		m.loading[m.key()] = true
		return m.reload()
	}
	return nil
}

// drill is Enter: on a VM its snapshots, on a dataset its snapshots, on a
// pod its logs would be a verb; anything else opens the detail pane.
func (m model) drill() (tea.Model, tea.Cmd) {
	name := m.selected()
	if name == "" {
		return m, nil
	}
	target := ""
	switch sections[m.active].name + "/" + m.subName() {
	case "Machines/VMs":
		target = "Snapshots"
	case "Storage/Datasets":
		target = "Snapshots"
	case "Ansible/Groups":
		m.switchTo(m.active, subIndex(m.active, "Hosts"))
		m.filter.SetValue(name)
		return m, m.loadIfEmpty()
	}
	if target == "" {
		m.detail = true
		return m, nil
	}
	m.switchTo(m.active, subIndex(m.active, target))
	m.ctx[m.key()] = name
	m.loading[m.key()] = true
	return m, m.reload()
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
	d := m.cur()
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
	d := m.cur()
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
			a, b := col(sorted[i], c), col(sorted[j], c)
			less := false
			fa, ea := strconv.ParseFloat(strings.TrimRight(a, "%BKMGT"), 64)
			fb, eb := strconv.ParseFloat(strings.TrimRight(b, "%BKMGT"), 64)
			switch {
			case ea == nil && eb == nil:
				less = fa < fb
			case ea == nil:
				less = true
			case eb == nil:
				less = false
			default:
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

func (m model) pageSize() int {
	if n := m.height - 10; n > 3 {
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

func (m model) selectedRow() []string {
	rows := m.rows()
	if m.row >= len(rows) {
		return nil
	}
	return rows[m.row]
}

// ── verbs ───────────────────────────────────────────────────────────────────

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

// runVerb resolves what a verb needs — a row, typed input, typed consent —
// and then runs its argv in the background (a doneMsg follows) or in the
// foreground (the terminal is handed over and comes back).
func (m model) runVerb(v verb) (tea.Model, tea.Cmd) {
	row := m.selectedRow()
	if !v.noRow && row == nil {
		m.say(stWarn.Render(v.label + ": nothing is selected"))
		return m, nil
	}
	name := col(row, 0)
	if v.prompt != "" {
		m.prompt = strings.ReplaceAll(v.prompt, "{}", name)
		m.pending = func(in string) tea.Cmd { return m.execVerb(v, row, in) }
		return m, nil
	}
	if v.confirm {
		// the one kind of verb that asks: typing the name is the consent, the
		// way kfire and kvm-delete's own --force gate mean it
		m.prompt = v.label + " " + name + " — type its name to confirm: "
		m.pending = func(typed string) tea.Cmd {
			if strings.TrimSpace(typed) != name {
				return func() tea.Msg { return doneMsg{v.label, fmt.Errorf("name did not match, nothing done")} }
			}
			return m.execVerb(v, row, "")
		}
		return m, nil
	}
	return m, m.execVerb(v, row, "")
}

func (m model) execVerb(v verb, row []string, in string) tea.Cmd {
	argv, err := v.argv(row, in)
	if err != nil {
		return func() tea.Msg { return doneMsg{v.label, err} }
	}
	what := strings.Join(argv, " ")
	if len(what) > 60 {
		what = what[:57] + "…"
	}
	if v.inter {
		if _, err := exec.LookPath(argv[0]); err != nil {
			return func() tea.Msg { return doneMsg{argv[0], fmt.Errorf("not installed on this host")} }
		}
		c := exec.Command("sudo", append([]string{"-n"}, argv...)...)
		c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
		return tea.ExecProcess(c, func(err error) tea.Msg { return doneMsg{what: what, err: err} })
	}
	return func() tea.Msg {
		_, err := run(600*time.Second, argv[0], argv[1:]...)
		return doneMsg{what: what, err: err}
	}
}

// ── view ────────────────────────────────────────────────────────────────────

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
	if m.loading[m.key()] {
		right = m.spin.View() + " " + stDim.Render("loading") + "  " + right
	}
	b.WriteString(padBetween(left, right, w) + "\n")
	// rail
	var rail []string
	for i, s := range sections {
		n := i + 1
		if n == 10 {
			n = 0
		}
		label := fmt.Sprintf("%d %s", n, s.name)
		if i == m.active {
			rail = append(rail, stRailA.Render(label))
		} else {
			rail = append(rail, stRail.Render(label))
		}
	}
	b.WriteString(strings.Join(rail, "") + "\n")
	// sub-tabs, with the context when one is set
	var subs []string
	for j, s := range sections[m.active].subs {
		if j == m.sub[m.active] {
			subs = append(subs, stSubA.Render(s))
		} else {
			subs = append(subs, stSub.Render(s))
		}
	}
	subline := strings.Join(subs, "")
	if c := m.ctx[m.key()]; c != "" {
		subline += stDim.Render("  › ") + stTitle.Render(c) + stDim.Render("  (esc: all)")
	}
	b.WriteString(subline + "\n")
	b.WriteString(stDim.Render(strings.Repeat("─", w)) + "\n")
	d := m.cur()
	// headline (the tool's summary, or its error)
	switch {
	case d == nil && m.loading[m.key()]:
		b.WriteString(stDim.Render("loading "+sections[m.active].name+" / "+m.subName()+"…") + "\n")
	case d == nil:
		b.WriteString(stDim.Render("press r to load") + "\n")
	default:
		if d.err != "" {
			b.WriteString(stBad.Render(truncate(d.err, w)) + "\n")
		} else if d.headline != "" {
			b.WriteString(stTitle.Render(truncate(d.headline, w)) + "\n")
		} else {
			b.WriteString("\n")
		}
	}
	// table + detail
	bodyH := m.height - 7 // title, rail, subs, rule, headline, status, one spare
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
		sl = m.keyHints()
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
	b.WriteString(padBetween(truncate(sl, w-lipgloss.Width(sr)-2), stDim.Render(sr), w))
	return b.String()
}

func (m model) keyHints() string {
	k := func(key, what string) string { return stKey.Render(key) + stDim.Render(" "+what) }
	parts := []string{k("1-0", "section"), k("tab", m.subName()), k("j/k", "row"), k("/", "filter"), k("o", "sort")}
	switch sections[m.active].name + "/" + m.subName() {
	case "Machines/VMs", "Storage/Datasets":
		parts = append(parts, k("enter", "snapshots"))
	}
	for _, v := range m.verbsHere() {
		parts = append(parts, k(v.key, v.label))
	}
	parts = append(parts, k("?", "help"), k("q", "quit"))
	return strings.Join(parts, "  ")
}

// tableView lays the rows out in width w and height h: header, then the page
// that holds the selection. Numeric columns are right-aligned; the state
// word in a cell is coloured, the rest of the row is not.
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
			v := truncate(col(cells, i), widths[i])
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
		b.WriteString(stDim.Render("nothing here") + "\n")
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
	r := m.selectedRow()
	if r == nil {
		return stDim.Render("no row")
	}
	kw := 0
	for _, c := range d.columns {
		kw = max(kw, len(c))
	}
	var lines []string
	lines = append(lines, stTitle.Render(truncate(col(r, 0), w)), "")
	for i, c := range d.columns {
		v := col(r, i)
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
	for _, v := range m.verbsHere() {
		if v.noRow {
			continue
		}
		if argv, err := v.argv(r, "…"); err == nil {
			cmd := strings.Join(argv, " ")
			if v.inter {
				cmd = "(terminal) " + cmd
			}
			lines = append(lines, stKey.Render(v.key)+"  "+stDim.Render(truncate(cmd, w-3)))
		} else {
			lines = append(lines, stKey.Render(v.key)+"  "+stDim.Render(v.label))
		}
	}
	if len(lines) > h {
		lines = lines[:h]
	}
	return strings.Join(lines, "\n")
}

func (m model) helpView() string {
	k := func(key, what string) string { return "  " + stKey.Render(fmt.Sprintf("%-10s", key)) + what }
	lines := []string{
		stTitle.Render("kld " + versionFull() + " — keys"),
		"",
		k("1-9, 0", "switch section   ·   h / l previous / next section"),
		k("tab, [ ]", "next / previous sub-tab of the section"),
		k("j / k", "move down / up   (g, G first / last · ctrl+f, ctrl+b page)"),
		k("enter", "drill in: a VM's or a dataset's snapshots, a group's hosts"),
		k("esc", "leave a drill-in (back to every VM / dataset)"),
		k("/", "filter rows; enter keeps it, esc clears it"),
		k("o", "sort: next column, then descending, then the tool's order"),
		k("i", "show or hide the detail pane"),
		k("r", "reload the sub-tab"),
		"",
		stTitle.Render(sections[m.active].name + " / " + m.subName()),
	}
	vs := m.verbsHere()
	if len(vs) == 0 {
		lines = append(lines, stDim.Render("  no verbs here — this tab is read-only"))
	}
	for _, v := range vs {
		what := v.label
		switch {
		case v.confirm:
			what += "   (asks for the name to be typed)"
		case v.prompt != "":
			what += "   (asks)"
		}
		if v.inter {
			what += "   (takes the terminal)"
		}
		lines = append(lines, k(v.key, what))
	}
	lines = append(lines, "", k("?", "this help   ·   any key closes it"), k("q", "quit"))
	box := stHelpBx.Render(strings.Join(lines, "\n"))
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, box)
}

// body is the --print form: the same headline and table, plain, every row.
func (m model) body() string {
	var b strings.Builder
	b.WriteString("kldload  operator console · " + hostname() + "\n")
	var rail []string
	for i, s := range sections {
		n := i + 1
		if n == 10 {
			n = 0
		}
		// the active section in brackets, every name still framed by spaces
		// so a script (and tests/smoke-console.sh) can grep " Provision "
		if i == m.active {
			rail = append(rail, fmt.Sprintf("[ %d %s ]", n, s.name))
		} else {
			rail = append(rail, fmt.Sprintf(" %d %s ", n, s.name))
		}
	}
	b.WriteString(strings.Join(rail, " ") + "\n")
	b.WriteString("  " + sections[m.active].name + " / " + m.subName())
	if c := m.ctx[m.key()]; c != "" {
		b.WriteString(" › " + c)
	}
	b.WriteString("\n\n")
	d := m.cur()
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
			parts[i] = fmt.Sprintf("%-*s", widths[i], col(cells, i))
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
			w[i] = max(w[i], lipgloss.Width(col(r, i)))
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
			v := col(r, i)
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
	if len(r) <= w {
		return s
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
	case "running", "up", "online", "ok", "active", "ready", "true", "install", "deployed", "succeeded":
		return stGood.Render(rendered)
	case "fail", "down", "degraded", "faulted", "absent", "unavailable", "failed", "unreachable", "crashloopbackoff", "error":
		return stBad.Render(rendered)
	case "warn", "unregistered", "stale", "never", "open", "pending", "inactive", "paused":
		return stWarn.Render(rendered)
	}
	return rendered
}
