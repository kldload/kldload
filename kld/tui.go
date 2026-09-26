// tui.go — the bubbletea model: a rail of eight sections, one table, a
// status line, and the verbs that act on the selected row.
//
// Rendering is a pure function of the model so `kld <section> --print` can
// show the same text without a terminal; the only state is which section,
// which row, and what each collector last returned.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// The calm palette of the web console: one accent, colour only for state.
var (
	stTitle = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("111"))
	stRail  = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	stRailA = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("0")).Background(lipgloss.Color("111"))
	stHead  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("250"))
	stSel   = lipgloss.NewStyle().Foreground(lipgloss.Color("0")).Background(lipgloss.Color("250"))
	stDim   = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	stGood  = lipgloss.NewStyle().Foreground(lipgloss.Color("42"))
	stWarn  = lipgloss.NewStyle().Foreground(lipgloss.Color("214"))
	stBad   = lipgloss.NewStyle().Foreground(lipgloss.Color("203"))
)

type loadedMsg sectionData

type doneMsg struct {
	what string
	err  error
}

type model struct {
	active  int
	row     int
	width   int
	height  int
	data    []*sectionData
	loading []bool
	status  string
	prompt  string // non-empty while a verb waits for typed input
	input   string
	pending func(string) tea.Cmd
	help    bool
}

// newModel with a width is the --print form: no terminal, so no paging (a
// height of 0 lists every row); the TUI learns its real size from the first
// WindowSizeMsg.
func newModel(start, width int) model {
	return model{active: start, width: width,
		data: make([]*sectionData, len(sections)), loading: make([]bool, len(sections))}
}

func (m *model) apply(d sectionData) {
	dd := d
	m.data[d.section] = &dd
	m.loading[d.section] = false
	if m.row >= len(dd.rows) {
		m.row = 0
	}
}

func (m model) Init() tea.Cmd { return m.reload() }

func (m model) reload() tea.Cmd {
	i := m.active
	return func() tea.Msg { return loadedMsg(loadSection(i)) }
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil
	case loadedMsg:
		m.apply(sectionData(msg))
		return m, nil
	case doneMsg:
		if msg.err != nil {
			m.status = stBad.Render(msg.what + ": " + msg.err.Error())
		} else {
			m.status = stGood.Render(msg.what + ": done")
		}
		m.loading[m.active] = true
		return m, m.reload()
	case tea.KeyMsg:
		if m.prompt != "" {
			return m.updatePrompt(msg)
		}
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "?":
			m.help = !m.help
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
			if d := m.data[m.active]; d != nil && m.row < len(d.rows)-1 {
				m.row++
			}
		case "k", "up":
			if m.row > 0 {
				m.row--
			}
		case "r":
			m.loading[m.active] = true
			m.status = "reloading " + sections[m.active]
			return m, m.reload()
		case "enter":
			return m.openDeep()
		case "c":
			return m.verbClone()
		case "s":
			return m.verbSnap()
		case "d":
			return m.verbDelete()
		}
	}
	return m, nil
}

func (m *model) switchTo(i int) {
	m.active, m.row, m.status = i, 0, ""
}

func (m *model) loadIfEmpty() tea.Cmd {
	if m.data[m.active] == nil && !m.loading[m.active] {
		m.loading[m.active] = true
		return m.reload()
	}
	return nil
}

// selected returns the first column of the highlighted row: the machine,
// pool, plane, node, target or MAC a verb acts on.
func (m model) selected() string {
	d := m.data[m.active]
	if d == nil || m.row >= len(d.rows) || len(d.rows[m.row]) == 0 {
		return ""
	}
	return d.rows[m.row][0]
}

// ── verbs: the shipped bash verbs, never a re-implementation ────────────────

func (m model) updatePrompt(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "ctrl+c":
		m.prompt, m.input, m.pending = "", "", nil
		m.status = "cancelled"
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
		m.status = stWarn.Render("clone: pick a machine in Machines first")
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
		m.status = stWarn.Render("snapshot: pick a machine in Machines first")
		return m, nil
	}
	return m, runVerb("kvm-snap "+vm, "kvm-snap", vm)
}

func (m model) verbDelete() (tea.Model, tea.Cmd) {
	vm := m.selected()
	if sections[m.active] != "Machines" || vm == "" {
		m.status = stWarn.Render("delete: pick a machine in Machines first")
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
		m.status = "dashboards live in the web console: https://" + hostname() + ":8443/grafana/"
		return m, nil
	}
	if _, err := exec.LookPath(argv[0]); err != nil {
		m.status = stWarn.Render(argv[0] + " is not installed on this host")
		return m, nil
	}
	c := exec.Command("sudo", append([]string{"-n"}, argv...)...)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	what := strings.Join(argv, " ")
	return m, tea.ExecProcess(c, func(err error) tea.Msg { return doneMsg{what: what, err: err} })
}

// ── view ────────────────────────────────────────────────────────────────────

func (m model) View() string {
	if m.width == 0 {
		return ""
	}
	return m.body()
}

func (m model) body() string {
	var b strings.Builder
	b.WriteString(stTitle.Render("kldload") + stDim.Render("  operator console · "+hostname()) + "\n")
	var rail []string
	for i, s := range sections {
		label := fmt.Sprintf(" %d %s ", i+1, s)
		if i == m.active {
			rail = append(rail, stRailA.Render(label))
		} else {
			rail = append(rail, stRail.Render(label))
		}
	}
	b.WriteString(strings.Join(rail, " ") + "\n\n")
	d := m.data[m.active]
	switch {
	case m.loading[m.active] && d == nil:
		b.WriteString(stDim.Render("loading "+sections[m.active]+"…") + "\n")
	case d == nil:
		b.WriteString(stDim.Render("press r to load") + "\n")
	default:
		b.WriteString(m.table(d))
	}
	b.WriteString("\n")
	if m.prompt != "" {
		b.WriteString(stWarn.Render(m.prompt) + m.input + "█\n")
	} else if m.status != "" {
		b.WriteString(m.status + "\n")
	} else if m.help {
		b.WriteString(stDim.Render("1-8/Tab section · j/k row · r reload · Enter open the deep console · c clone · s snapshot · d delete · ? help · q quit") + "\n")
	} else {
		b.WriteString(stDim.Render("? for keys") + "\n")
	}
	return b.String()
}

func (m model) table(d *sectionData) string {
	var b strings.Builder
	if d.err != "" {
		b.WriteString(stBad.Render(d.err) + "\n")
	}
	if d.headline != "" {
		b.WriteString(stHead.Render(d.headline) + "\n")
	}
	if len(d.columns) == 0 {
		return b.String()
	}
	// Column widths from content, capped so one long value (a repair
	// command, a scrape URL) cannot push the rest off the screen.
	width := m.width
	if width <= 0 {
		width = 120
	}
	cap := width / 2
	w := make([]int, len(d.columns))
	for i, c := range d.columns {
		w[i] = len(c)
	}
	for _, r := range d.rows {
		for i := range d.columns {
			if i < len(r) && len(r[i]) > w[i] {
				w[i] = min(len(r[i]), cap)
			}
		}
	}
	line := func(cells []string) string {
		parts := make([]string, len(d.columns))
		for i := range d.columns {
			v := ""
			if i < len(cells) {
				v = cells[i]
			}
			if len(v) > w[i] {
				v = v[:w[i]-1] + "…"
			}
			parts[i] = fmt.Sprintf("%-*s", w[i], v)
		}
		return strings.TrimRight(strings.Join(parts, "  "), " ")
	}
	b.WriteString(stHead.Render(line(d.columns)) + "\n")
	limit := m.height - 8
	if limit < 5 {
		limit = len(d.rows)
	}
	start := 0
	if m.row >= limit {
		start = m.row - limit + 1
	}
	for i := start; i < len(d.rows) && i < start+limit; i++ {
		s := line(d.rows[i])
		switch {
		case i == m.row && m.width > 0:
			s = stSel.Render(s)
		default:
			s = colour(d.rows[i], s)
		}
		b.WriteString(s + "\n")
	}
	if len(d.rows) > limit {
		b.WriteString(stDim.Render(fmt.Sprintf("rows %d-%d of %d", start+1, min(start+limit, len(d.rows)), len(d.rows))) + "\n")
	}
	return b.String()
}

// colour paints a row by the state words the tools use; anything else is
// plain. State is the only thing that gets a colour.
func colour(cells []string, s string) string {
	for _, c := range cells {
		switch strings.ToLower(strings.Fields(c + " x")[0]) {
		case "running", "up", "online", "ok", "active", "ready", "true":
			return stGood.Render(s)
		case "fail", "down", "degraded", "faulted", "absent", "unavailable", "failed":
			return stBad.Render(s)
		case "warn", "unregistered", "stale", "never", "open":
			return stWarn.Render(s)
		}
	}
	return s
}
