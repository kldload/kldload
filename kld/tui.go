// tui.go — the bubbletea model: a rail of sections, each with sub-tabs; a
// table with a filter and a sort; the vitals pane on its left for the
// selected row; the menu of verbs and keys below it, then a status line; a
// help overlay; and the verbs of verbs.go acting on the selected row. The
// colours and the (S)tart spelling are theme.go's.
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
	"path"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// Colours and styles live in theme.go.

type loadedMsg sectionData

type doneMsg struct {
	what string
	err  error
}

type tickMsg time.Time

// detailMsg carries a detailer's lines for one row of one tab.
type detailMsg struct {
	key, name string
	lines     []string
}

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
	secret   bool   // the prompt's input is a passphrase: masked on screen
	input    string
	pending  func(string) tea.Cmd
	help     bool
	detail   bool
	marks    map[string]bool     // marked row names, per section/sub key + name
	details  map[string][]string // detailer lines, per section/sub key + name
	asked    map[string]bool     // detailers already fired, same key
	filter   textinput.Model
	filterOn bool
	sortCol  int
	sortDesc bool
	spin     spinner.Model
	now      time.Time
	con      *console   // an open in-TUI console (screen, serial, ssh, job); nil otherwise
	jobs     []*console // every job started this session, oldest first
	nav      []navFrame // where Enter came from: Backspace (or Esc with nothing to clear) pops
	// refreshing is a background reload of the visible table (the live
	// Machines view every 3 s): no spinner, the rows stay until replaced
	refreshing bool
	armed      string // a running machine whose delete was pressed once
	armedAt    time.Time
	// the command palette (:): a filter over every tab and every verb here
	palette bool
	palIn   textinput.Model
	palRow  int
	// pick, when set, is what the palette lists instead of every tab and
	// verb: a picker a verb opens (verb.picker), titled pickTitle.
	pick      []palEntry
	pickTitle string
}

// palEntry is one line of the palette: what it says and what it does.
type palEntry struct {
	text  string
	run   func(m model) (tea.Model, tea.Cmd)
	shown string // how the overlay draws it; text is what the filter matches
}

// palEntries lists the tabs of every section as "go" entries and the verbs
// of the current tab, filtered by the typed text (every word must match).
func (m model) palEntries() []palEntry {
	all := m.pick
	for si, s := range sections {
		if m.pick != nil {
			break
		}
		for sj, sub := range s.subs {
			si, sj := si, sj
			all = append(all, palEntry{text: fmt.Sprintf("go   %s / %s", s.name, sub), run: func(m model) (tea.Model, tea.Cmd) {
				m.switchTo(si, sj)
				return m, m.loadIfEmpty()
			}})
		}
	}
	for _, v := range m.verbsHere() {
		if m.pick != nil {
			break
		}
		v := v
		all = append(all, palEntry{text: fmt.Sprintf("%-4s %s", v.key, v.label), shown: mnemonic(v.key, v.label, isDanger(v.label)),
			run: func(m model) (tea.Model, tea.Cmd) { return m.runVerb(v) }})
	}
	words := strings.Fields(strings.ToLower(m.palIn.Value()))
	if len(words) == 0 {
		return all
	}
	var out []palEntry
	for _, e := range all {
		lt := strings.ToLower(e.text)
		ok := true
		for _, w := range words {
			if !strings.Contains(lt, w) {
				ok = false
				break
			}
		}
		if ok {
			out = append(out, e)
		}
	}
	return out
}

func (m model) updatePalette(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "ctrl+c":
		m.palette = false
		m.pick, m.pickTitle = nil, ""
		m.palIn.Blur()
		return m, nil
	case "enter":
		es := m.palEntries()
		m.palette = false
		m.pick, m.pickTitle = nil, ""
		m.palIn.Blur()
		if m.palRow < len(es) {
			return es[m.palRow].run(m)
		}
		return m, nil
	case "down", "ctrl+n", "tab":
		if n := len(m.palEntries()); n > 0 {
			m.palRow = (m.palRow + 1) % n
		}
		return m, nil
	case "up", "ctrl+p", "shift+tab":
		if n := len(m.palEntries()); n > 0 {
			m.palRow = (m.palRow + n - 1) % n
		}
		return m, nil
	}
	var cmd tea.Cmd
	m.palIn, cmd = m.palIn.Update(msg)
	m.palRow = 0
	return m, cmd
}

// paletteView is the overlay: the typed filter and up to fourteen matches,
// the selected one highlighted.
func (m model) paletteView() string {
	es := m.palEntries()
	var b strings.Builder
	if m.pickTitle != "" {
		b.WriteString(stKey.Render(m.pickTitle) + "  " + m.palIn.View() + "\n\n")
	} else {
		b.WriteString(stKey.Render(":") + " " + m.palIn.View() + "\n\n")
	}
	start := 0
	if m.palRow >= 14 {
		start = m.palRow - 13
	}
	for i := start; i < len(es) && i < start+14; i++ {
		line := es[i].text
		if i == m.palRow {
			line = stSel.Render(" " + line + " ")
		} else if es[i].shown != "" {
			line = "  " + es[i].shown
		} else {
			line = "  " + stText.Render(line)
		}
		b.WriteString(line + "\n")
	}
	if len(es) == 0 {
		b.WriteString(stDim.Render("  nothing matches") + "\n")
	}
	foot := fmt.Sprintf("%d of %d · enter runs · esc closes · a tab is \"go section / tab\", a verb is its key and label", min(m.palRow+1, len(es)), len(es))
	if m.pickTitle != "" {
		foot = fmt.Sprintf("%d of %d · ↑↓ choose · enter picks · type to filter · esc closes", min(m.palRow+1, len(es)), len(es))
	}
	b.WriteString("\n" + stDim.Render(foot))
	box := stPane.Padding(1, 2).Render(b.String())
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, box)
}

// navFrame is one place the operator drilled from: section, sub-tab, its
// context, the row and the filter, so going back lands exactly there.
type navFrame struct {
	active, sub int
	ctx         string
	hasCtx      bool
	row         int
	filter      string
}

// push records the current view before a drill; pop restores the last one.
func (m *model) push() {
	c, ok := m.ctx[m.key()]
	m.nav = append(m.nav, navFrame{active: m.active, sub: m.sub[m.active], ctx: c, hasCtx: ok, row: m.row, filter: m.filter.Value()})
	if len(m.nav) > 64 {
		m.nav = m.nav[1:]
	}
}

// afterPop reloads when the cached table was built for another context:
// the data cache is per tab, so /etc's listing sat under the Explorer key
// after Backspace restored the context to / (caught on the first run).
func (m *model) afterPop() tea.Cmd {
	d := m.cur()
	if d == nil || d.ctx != m.ctx[m.key()] {
		m.loading[m.key()] = true
		return m.reload()
	}
	return nil
}

func (m *model) pop() bool {
	if len(m.nav) == 0 {
		return false
	}
	f := m.nav[len(m.nav)-1]
	m.nav = m.nav[:len(m.nav)-1]
	m.switchTo(f.active, f.sub)
	if f.hasCtx {
		m.ctx[m.key()] = f.ctx
	} else {
		delete(m.ctx, m.key())
	}
	m.filter.SetValue(f.filter)
	m.row = f.row
	return true
}

// jobStartMsg asks Update to open a job pane for a verb's command.
type jobStartMsg struct {
	label  string
	asUser bool       // run as the operator, not under sudo (verb.asUser)
	argv   []string   // one command …
	argvs  [][]string // … or several, run in order in one pane
}

// conBodyTop is the first row of a console's body: title, rail, sub-tabs.
const conBodyTop = 3

// conBodyH is how many rows the console gets: everything but the header
// and the status line.
func (m model) conBodyH() int { return max(m.height-conBodyTop-1, 1) }

// newModel with a width is the --print form: no terminal, so no paging (a
// height of 0 lists every row); the TUI learns its real size from the first
// WindowSizeMsg.
func newModel(start, sub, width int) model {
	f := textinput.New()
	f.Prompt = "/"
	f.Placeholder = "filter rows"
	f.CharLimit = 64
	pi := textinput.New()
	pi.Prompt = ""
	pi.Placeholder = "type a tab or a verb"
	pi.CharLimit = 64
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = lipgloss.NewStyle().Foreground(cAccent)
	m := model{active: start, width: width, detail: true, sortCol: -1,
		sub: make([]int, len(sections)), ctx: map[string]string{},
		data: map[string]*sectionData{}, loading: map[string]bool{}, marks: map[string]bool{},
		details: map[string][]string{}, asked: map[string]bool{},
		filter: f, spin: sp, now: time.Now(), palIn: pi}
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
	was := ""
	if k == m.key() {
		was = m.selected()
	}
	m.data[k] = &dd
	m.loading[k] = false
	m.refreshing = false
	if k == m.key() {
		// the cursor follows the row's name across a reload, not its index:
		// a VM that started moves within its group and the cursor went with
		// the index, onto the neighbour
		if was != "" {
			for i, r := range m.rows() {
				if col(r, 0) == was {
					m.row = i
					break
				}
			}
		}
		if m.row >= len(m.rows()) {
			m.row = 0
		}
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(m.reload(), m.spin.Tick, tickEvery())
}

func tickEvery() tea.Cmd {
	return tea.Tick(time.Second, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m model) reload() tea.Cmd {
	for k := range m.details {
		if strings.HasPrefix(k, m.key()+"\x00") {
			delete(m.details, k)
			delete(m.asked, k)
		}
	}
	si, sub, ctx := m.active, m.sub[m.active], m.ctx[m.key()]
	return func() tea.Msg { return loadedMsg(loadSection(si, sub, ctx)) }
}

// detailCmd fires the tab's detailer for the selected row once.
func (m *model) detailCmd() tea.Cmd {
	f, ok := detailers[sections[m.active].name+"/"+m.subName()]
	row := m.selectedRow()
	if !ok || row == nil {
		return nil
	}
	k := m.key() + "\x00" + col(row, 0)
	if m.asked[k] {
		return nil
	}
	m.asked[k] = true
	key, name := m.key(), col(row, 0)
	return func() tea.Msg { return detailMsg{key, name, f(row)} }
}

func (m *model) say(s string) {
	m.status, m.statusAt = s, time.Now()
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		if m.con != nil {
			m.con.resize(m.width, m.conBodyH())
		}
	case activityMsg:
		m.loading[m.key()] = true
		return m, m.reload()
	case conTickMsg:
		// jobs that finished since the last tick are reported once and the
		// table reloaded, whether or not their pane is showing
		var cmds []tea.Cmd
		for _, j := range m.jobs {
			if !j.running() && !j.reported {
				j.reported = true
				if p := j.exit.Load(); p != nil && !strings.HasSuffix((*p).Error(), " ended") {
					m.say(stBad.Render(j.vm + ": " + (*p).Error()))
				} else {
					m.say(stGood.Render(j.vm + ": done in " + j.finished.Sub(j.started).Truncate(time.Second).String()))
				}
				m.loading[m.key()] = true
				cmds = append(cmds, m.reload())
			}
		}
		// a job that succeeded while its pane was showing gives the operator
		// a moment to read the tail, then returns to the table on its own;
		// the output stays under ctrl+j. A failed job keeps its pane until
		// it is read. (The first clone batch left the operator staring at
		// a finished pane wondering how to get back, 2026-09-26.)
		if c := m.con; c != nil && c.kind == conJob && !c.follow && !c.running() && jobSucceeded(c) && time.Since(c.finished) > 1500*time.Millisecond {
			m.con = nil
			m.say(stGood.Render(c.vm + ": done in " + c.finished.Sub(c.started).Truncate(time.Second).String() + " (ctrl+j shows the output)"))
		}
		if m.con != nil || m.runningJobs() > 0 {
			cmds = append(cmds, conTick())
		}
		return m, tea.Batch(cmds...)
	case pickerMsg:
		return m.openPicker(msg.title, msg.entries)
	case jobStartMsg:
		argvs := msg.argvs
		if len(argvs) == 0 {
			argvs = [][]string{msg.argv}
		}
		var c *console
		var err error
		if msg.asUser && len(argvs) == 1 {
			c, err = openJobAsUser(msg.label, argvs[0], m.width, m.conBodyH())
		} else {
			c, err = openJobSeq(msg.label, argvs, m.width, m.conBodyH())
		}
		if err != nil {
			m.say(stBad.Render(msg.label + ": " + err.Error()))
			return m, nil
		}
		m.jobs = append(m.jobs, c)
		if len(m.jobs) > 20 { // the pane list, not a log: the oldest finished ones go
			for i, j := range m.jobs {
				if !j.running() {
					m.jobs = append(m.jobs[:i], m.jobs[i+1:]...)
					break
				}
			}
		}
		if m.con != nil && m.con.kind != conJob {
			m.con.close()
		}
		m.con = c
		c.resize(m.width, m.conBodyH())
		return m, tea.Batch(conTick(), tea.DisableMouse)
	case tea.MouseMsg:
		if m.con != nil {
			m.con.mouse(msg, conBodyTop)
		}
		return m, nil
	case tickMsg:
		m.now = time.Time(msg)
		// a status line outlives its moment: eight seconds, then the keys return
		if m.status != "" && time.Since(m.statusAt) > 8*time.Second {
			m.status = ""
		}
		// the live views: Machines/VMs refreshes itself every 3 s (CPU%,
		// state) while it is on screen and nothing else is going on; the
		// Overview picks up the doctor's result when it lands
		if m.con == nil && m.prompt == "" && !m.filterOn && !m.loading[m.key()] && !m.refreshing {
			if d := m.cur(); d != nil {
				here := sections[m.active].name + "/" + m.subName()
				switch {
				case here == "Machines/VMs" && time.Since(d.loadedAt) >= 3*time.Second,
					here == "Storage/Observe" && time.Since(d.loadedAt) >= 3*time.Second,
					here == "Overview/Summary" && doctorFresherThan(d.loadedAt):
					m.refreshing = true
					return m, tea.Batch(tickEvery(), m.reload())
				}
			}
		}
		return m, tickEvery()
	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		return m, cmd
	case loadedMsg:
		if msg.section == 0 && msg.sub == subIndex(0, "Activity") {
			d := &msg
			// the kld jobs of this session sit above the host's units
			var rows [][]string
			for i := len(m.jobs) - 1; i >= 0; i-- {
				j := m.jobs[i]
				state, since := "running", time.Since(j.started).Truncate(time.Second).String()
				if !j.running() {
					state, since = "done", j.finished.Sub(j.started).Truncate(time.Second).String()
					if p := j.exit.Load(); p != nil && !strings.HasSuffix((*p).Error(), " ended") {
						state = "failed"
					}
				}
				rows = append(rows, []string{j.vm, "job", state, since, strings.Join(j.argv, " ")})
			}
			d.rows = append(rows, d.rows...)
		}
		m.apply(sectionData(msg))
		return m, m.detailCmd()
	case detailMsg:
		m.details[msg.key+"\x00"+msg.name] = msg.lines
		return m, nil
	case doneMsg:
		invalidateSnapCounts()
		if msg.err != nil {
			m.say(stBad.Render(msg.what + ": " + msg.err.Error()))
		} else {
			m.say(stGood.Render(msg.what + ": done"))
		}
		m.loading[m.key()] = true
		return m, m.reload()
	case tea.KeyMsg:
		if m.con != nil {
			return m.updateConsole(msg)
		}
		if m.palette {
			return m.updatePalette(msg)
		}
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
			// on a pool row, observe it; everywhere else o cycles the sort
			if sections[m.active].name+"/"+m.subName() == "Storage/Pools" && m.selected() != "" {
				pool := m.selected()
				m.push()
				m.switchTo(m.active, subIndex(m.active, "Observe"))
				m.ctx[m.key()] = pool
				m.loading[m.key()] = true
				return m, m.reload()
			}
			m.cycleSort()
		case ":":
			// the command palette: every tab and every verb here, by name
			m.palIn.Placeholder = "type a tab or a verb"
			m.palette, m.palRow = true, 0
			m.palIn.SetValue("")
			m.palIn.Focus()
			return m, nil
		case "i":
			m.detail = !m.detail
		case "r":
			m.loading[m.key()] = true
			m.say(stDim.Render("reloading " + sections[m.active].name + " / " + m.subName()))
			return m, m.reload()
		case " ":
			// marks: space toggles the row, verbs then act on every marked
			// row of this tab (vmxplore's marks + batch, 2026-09-26)
			if name := m.selected(); name != "" {
				k := m.key() + "\x00" + name
				if m.marks[k] {
					delete(m.marks, k)
				} else {
					m.marks[k] = true
				}
				if m.row < len(m.rows())-1 {
					m.row++
				}
			}
		case "ctrl+a":
			all := true
			for _, r := range m.rows() {
				if !m.marks[m.key()+"\x00"+col(r, 0)] {
					all = false
				}
			}
			for _, r := range m.rows() {
				k := m.key() + "\x00" + col(r, 0)
				if all {
					delete(m.marks, k)
				} else {
					m.marks[k] = true
				}
			}
		case "backspace":
			// back to where Enter (or x) came from; nothing to go back to
			// means nothing happens, on every tab the same way
			if m.pop() {
				return m, m.afterPop()
			}
		case "esc":
			// esc clears the marks first, then leaves a context
			if n := m.markedRows(); len(n) > 0 {
				for k := range m.marks {
					if strings.HasPrefix(k, m.key()+"\x00") {
						delete(m.marks, k)
					}
				}
				return m, nil
			}
			// then an applied filter: "(backspace: back)" promises that, and it
			// used to jump straight to leaving the context instead
			if m.filter.Value() != "" {
				m.filter.SetValue("")
				m.row = 0
				return m, nil
			}
			// then back to where the drill came from
			if m.pop() {
				return m, m.afterPop()
			}
			// esc leaves a context: the VM's snapshots become every VM's
			if m.ctx[m.key()] != "" {
				delete(m.ctx, m.key())
				m.loading[m.key()] = true
				m.row = 0
				return m, m.reload()
			}
		case "ctrl+t":
			// a terminal on this host, inside the TUI (ctrl+] d comes back)
			return m.openConsole(conShell, "host", "")
		case "ctrl+j":
			// the job panes: newest first
			if len(m.jobs) == 0 {
				m.say(stDim.Render("no jobs this session"))
				return m, nil
			}
			m.con = m.jobs[len(m.jobs)-1]
			m.con.resize(m.width, m.conBodyH())
			return m, conTick()
		case "enter":
			return m.drill()
		case "x":
			// explore a dataset's files (Datasets) — a drill, not a verb
			if sections[m.active].name+"/"+m.subName() == "Storage/Datasets" && m.selected() != "" {
				ds := m.selected()
				m.push()
				m.switchTo(m.active, subIndex(m.active, "Explorer"))
				m.ctx[m.key()] = ds + ":/"
				m.loading[m.key()] = true
				return m, m.reload()
			}
			for _, v := range m.verbsHere() {
				if v.key == "x" {
					return m.runVerb(v)
				}
			}
		case "v":
			if sections[m.active].name+"/"+m.subName() == "Storage/Explorer" {
				return m.drill()
			}
			for _, v := range m.verbsHere() {
				if v.key == "v" {
					return m.runVerb(v)
				}
			}
		default:
			for _, v := range m.verbsHere() {
				if v.key == msg.String() {
					return m.runVerb(v)
				}
			}
		}
		return m, m.detailCmd()
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
// pod its logs would be a verb; anything else opens the vitals pane.
func (m model) drill() (tea.Model, tea.Cmd) {
	name := m.selected()
	if name == "" {
		return m, nil
	}
	target := ""
	here := sections[m.active].name + "/" + m.subName()
	if here == "Overview/Activity" {
		return m.openActivity()
	}
	if here != "Machines/Snapshots" {
		m.push()
	}
	switch here {
	case "Machines/VMs":
		target = "Snapshots"
	case "Storage/Datasets":
		target = "Snapshots"
	case "Storage/Pools":
		target = "Pool"
	case "Storage/Explorer":
		r := m.selectedRow()
		ds, rel := splitExplorerCtx(m.ctx[m.key()])
		switch col(r, 1) {
		case "up":
			m.ctx[m.key()] = ds + ":" + path.Dir(rel)
		case "dir":
			m.ctx[m.key()] = ds + ":" + path.Join(rel, col(r, 0))
		default:
			m.switchTo(m.active, subIndex(m.active, "Versions"))
			m.ctx[m.key()] = ds + ":" + path.Join(rel, col(r, 0))
		}
		// a new directory is a new table: the filter that found the row
		// must not hide everything in it (caught on the first probe run)
		m.filter.SetValue("")
		m.loading[m.key()] = true
		m.row = 0
		return m, m.reload()
	case "Cluster/Pods":
		r := m.selectedRow()
		m.switchTo(m.active, subIndex(m.active, "Logs"))
		m.ctx[m.key()] = col(r, 1) + "/" + col(r, 0)
		m.loading[m.key()] = true
		return m, m.reload()
	case "Cluster/Nodes", "Cluster/Deployments", "Cluster/Services":
		r := m.selectedRow()
		kind := map[string]string{"Cluster/Nodes": "node", "Cluster/Deployments": "deployment", "Cluster/Services": "service"}[sections[m.active].name+"/"+m.subName()]
		ref := col(r, 0)
		if kind != "node" {
			ref = col(r, 1) + "/" + col(r, 0)
		}
		m.switchTo(m.active, subIndex(m.active, "Describe"))
		m.ctx[m.key()] = kind + " " + ref
		m.loading[m.key()] = true
		return m, m.reload()
	case "Ansible/Groups":
		m.switchTo(m.active, subIndex(m.active, "Hosts"))
		m.filter.SetValue(name)
		return m, m.loadIfEmpty()
	}
	if target == "" {
		m.nav = m.nav[:len(m.nav)-1] // nothing was left; the vitals pane is not a place
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

// markedRows are the marked rows of the current tab, in table order.
func (m model) markedRows() [][]string {
	var out [][]string
	for _, r := range m.rows() {
		if m.marks[m.key()+"\x00"+col(r, 0)] {
			out = append(out, r)
		}
	}
	return out
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
		m.prompt, m.input, m.pending, m.secret = "", "", nil, false
		m.say(stDim.Render("cancelled"))
	case "enter":
		cmd := m.pending(m.input)
		m.prompt, m.input, m.pending, m.secret = "", "", nil, false
		return m, cmd
	case "backspace":
		if len(m.input) > 0 {
			m.input = m.input[:len(m.input)-1]
		}
	case "ctrl+u":
		// the whole line: a prefilled example the operator does not want
		// is one key to clear, not a held backspace
		m.input = ""
	case "ctrl+w":
		t := strings.TrimRight(m.input, " ")
		if i := strings.LastIndex(t, " "); i >= 0 {
			m.input = t[:i+1]
		} else {
			m.input = ""
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
// openPicker shows es in the palette overlay under title: arrows choose,
// typing filters, enter runs the entry.
func (m model) openPicker(title string, es []palEntry) (tea.Model, tea.Cmd) {
	m.pick, m.pickTitle = es, title
	m.palIn.Placeholder = "type to filter"
	m.palette, m.palRow = true, 0
	m.palIn.SetValue("")
	m.palIn.Focus()
	return m, nil
}

func (m model) runVerb(v verb) (tea.Model, tea.Cmd) {
	if v.picker != nil {
		title, es := v.picker(m)
		return m.openPicker(title, es)
	}
	// A batch: the verb runs once per marked row, in table order, one
	// after another; a destructive batch asks for the count to be typed.
	// Verbs that ask or take the terminal run on the selection only.
	if marked := m.markedRows(); len(marked) > 1 && !v.noRow && !v.inter && v.prompt == "" && v.argv != nil && v.console == conNone {
		if v.confirm {
			m.prompt = fmt.Sprintf("%s %d marked rows — type %d to confirm: ", v.label, len(marked), len(marked))
			m.pending = func(typed string) tea.Cmd {
				if strings.TrimSpace(typed) != strconv.Itoa(len(marked)) {
					return func() tea.Msg { return doneMsg{v.label, fmt.Errorf("count did not match, nothing done")} }
				}
				return m.execBatch(v, marked)
			}
			return m, nil
		}
		return m, m.execBatch(v, marked)
	}
	row := m.selectedRow()
	if !v.noRow && row == nil {
		m.say(stWarn.Render(v.label + ": nothing is selected"))
		return m, nil
	}
	name := col(row, 0)
	if v.console != conNone {
		return m.openConsole(v.console, name, m.colNamed(row, "address"))
	}
	// a delete on a RUNNING machine takes the key twice within three
	// seconds; one stray d deleted a live control plane (onyx, 2026-09-26).
	// A stopped machine still deletes on the single key.
	if v.key == "d" && sections[m.active].name == "Machines" && m.colNamed(row, "state") == "running" {
		if m.armed != name || time.Since(m.armedAt) > 3*time.Second {
			m.armed, m.armedAt = name, time.Now()
			m.say(stWarn.Render(name + " is running — d again within 3 s deletes it, T shuts it down"))
			return m, nil
		}
		m.armed = ""
	}
	if v.prompt != "" {
		m.prompt = strings.ReplaceAll(v.prompt, "{}", name)
		if v.example != nil {
			hint, val := v.example(row)
			if hint != "" {
				m.prompt = strings.TrimSuffix(strings.TrimSpace(m.prompt), ":") + " — " + hint + " (enter runs, ctrl+u clears): "
			}
			m.input = val
		}
		m.secret = v.secret
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
	m.say(stDim.Render(v.label + ": running"))
	return m, m.execVerb(v, row, "")
}

// execBatch runs one verb over marked rows sequentially and reports how
// many succeeded and which failed — a count against what it was given.
func (m model) execBatch(v verb, rows [][]string) tea.Cmd {
	if v.job {
		// every marked row's command in one pane, in order, stopping at
		// the first failure: fifteen clones are one job, not fifteen
		var cmds [][]string
		for _, r := range rows {
			argv, err := v.argv(r, "")
			if err != nil {
				return func() tea.Msg { return doneMsg{v.label + " " + col(r, 0), err} }
			}
			cmds = append(cmds, argv)
		}
		label := fmt.Sprintf("%s x%d", v.label, len(cmds))
		return func() tea.Msg { return jobStartMsg{label: label, argvs: cmds} }
	}
	return func() tea.Msg {
		ok, failed := 0, []string{}
		for _, r := range rows {
			argv, err := v.argv(r, "")
			if err == nil {
				_, err = run(600*time.Second, argv[0], argv[1:]...)
				if benign(err) != "" {
					err = nil
				}
			}
			if err != nil {
				failed = append(failed, col(r, 0)+": "+err.Error())
			} else {
				ok++
			}
		}
		what := fmt.Sprintf("%s: %d of %d", v.label, ok, len(rows))
		if len(failed) > 0 {
			return doneMsg{what, fmt.Errorf("%s", strings.Join(failed, "; "))}
		}
		return doneMsg{what: what}
	}
}

func (m model) execVerb(v verb, row []string, in string) tea.Cmd {
	var argv []string
	var err error
	if v.argvs != nil {
		argvs, err := v.argvs(row, in)
		if err != nil {
			return func() tea.Msg { return doneMsg{v.label, err} }
		}
		label := v.label + " " + col(row, 0)
		return func() tea.Msg { return jobStartMsg{label: label, argvs: argvs} }
	}
	if v.names != nil {
		// refuse a name the table already shows — a domain, a DB ghost or
		// an orphan zvol — before anything starts
		have := map[string]bool{}
		if d := m.cur(); d != nil {
			for _, r := range d.rows {
				have[col(r, 0)] = true
			}
		}
		var taken []string
		for _, n := range v.names(row, in) {
			if have[n] {
				taken = append(taken, n)
			}
		}
		if len(taken) > 0 {
			return func() tea.Msg {
				return doneMsg{v.label, fmt.Errorf("already here: %s — pick another name (delete it first if it is the one you mean)", strings.Join(taken, ", "))}
			}
		}
	}
	switch {
	case v.rowCtxArgv != nil:
		argv, err = v.rowCtxArgv(row, m.ctx[m.key()])
	case v.argv == nil && v.ctxArgv != nil:
		argv, err = v.ctxArgv(m.ctx[m.key()])
	default:
		argv, err = v.argv(row, in)
	}
	if err != nil {
		return func() tea.Msg { return doneMsg{v.label, err} }
	}
	what := strings.Join(argv, " ")
	if len(what) > 60 {
		what = what[:57] + "…"
	}
	if v.job || v.inter {
		if _, err := exec.LookPath(argv[0]); err != nil {
			return func() tea.Msg { return doneMsg{argv[0], fmt.Errorf("not installed on this host")} }
		}
	}
	if v.job {
		label := v.label
		if name := col(row, 0); name != "" && !v.noRow {
			label += " " + name
		}
		return func() tea.Msg { return jobStartMsg{label: label, argv: argv, asUser: v.asUser} }
	}
	if v.inter {
		c := exec.Command("sudo", append([]string{"-n"}, argv...)...)
		c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
		return tea.ExecProcess(c, func(err error) tea.Msg { return doneMsg{what: what, err: err} })
	}
	if v.stdin {
		// the input goes to the command's stdin (a passphrase for zfs
		// load-key), never onto argv where ps would show it
		return func() tea.Msg {
			err := runStdin(600*time.Second, in+"\n", argv[0], argv[1:]...)
			return doneMsg{what: what, err: err}
		}
	}
	return func() tea.Msg {
		_, err := run(600*time.Second, argv[0], argv[1:]...)
		if note := benign(err); note != "" {
			return doneMsg{what: what + ": " + note}
		}
		return doneMsg{what: what, err: err}
	}
}

// benign turns the virsh answers that mean "nothing to do" into a note
// instead of an error: force off on a machine that is off, start on one
// that runs. The operator read four of them as failed deletes
// (2026-09-26); vmxplore treats "domain is not running" as success too.
func benign(err error) string {
	if err == nil {
		return ""
	}
	s := err.Error()
	switch {
	case strings.Contains(s, "domain is not running"):
		return "already off"
	case strings.Contains(s, "domain is already active"), strings.Contains(s, "Domain is already active"):
		return "already running"
	case strings.Contains(s, "domain is not paused"), strings.Contains(s, "domain is already paused"):
		return "already in that state"
	}
	return ""
}

// ── view ────────────────────────────────────────────────────────────────────

func (m model) View() string {
	if m.width == 0 {
		return ""
	}
	if m.help {
		return m.helpView()
	}
	if m.palette {
		return m.paletteView()
	}
	w := m.width
	var b strings.Builder
	// title bar: brand · host on the left, the clock and a spinner on the right
	left := stBrand.Render("kldload") + stDim.Render("  operator console · "+hostname())
	right := stDim.Render(m.now.Format("15:04:05"))
	if m.loading[m.key()] && !m.refreshing {
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
			if noColor {
				label = "[" + label + "]"
			}
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
			if noColor {
				s = "[" + s + "]"
			}
			subs = append(subs, stSubA.Render(s))
		} else {
			subs = append(subs, stSub.Render(s))
		}
	}
	subline := strings.Join(subs, "")
	if m.con != nil {
		// a console owns the body: header, the machine's screen or
		// terminal, its own status line
		b.WriteString(subline + "\n")
		body := m.con.view(w, m.conBodyH())
		lines := strings.Split(body, "\n")
		for len(lines) < m.conBodyH() {
			lines = append(lines, "")
		}
		b.WriteString(strings.Join(lines[:m.conBodyH()], "\n") + "\n")
		b.WriteString(truncate(m.con.status(), w))
		return b.String()
	}
	if c := m.ctx[m.key()]; c != "" {
		subline += stDim.Render("  › ") + stTitle.Render(c) + stDim.Render("  (backspace: back)")
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
	// Layout, top to bottom: five fixed lines above, the body, the menu,
	// the status line. Every height here comes from the terminal size and
	// the tab's verb set -- never from what a refresh brought -- so nothing
	// moves while the 3 s refresh runs (the operator: "the menu part jumps
	// around", 2026-09-27; the vitals pane wrapped its long values and grew).
	menu := m.menuLines(w)
	bodyH := max(m.height-6-len(menu), 3)
	vitW := m.vitalsWidth(w)
	table := m.tableView(d, w-vitW, bodyH)
	if vitW > 0 {
		vit := m.vitalsView(d, vitW, bodyH)
		tl := strings.Split(table, "\n")
		for i := 0; i < bodyH; i++ {
			t := ""
			if i < len(tl) {
				t = tl[i]
			}
			b.WriteString(vit[i] + t + "\n")
		}
	} else {
		b.WriteString(table + "\n")
	}
	for _, l := range menu {
		b.WriteString(l + "\n")
	}
	// status bar
	var sl string
	switch {
	case m.prompt != "":
		shown := m.input
		if m.secret {
			shown = strings.Repeat("•", len(m.input))
		}
		// The input and its cursor are the part that must be seen: the line
		// used to be cut from the right to fit the row count, and a long
		// prompt pushed the value off a 100-column screen -- typing showed
		// nothing, and esc was the only key that seemed to do anything
		// (onyx, 2026-09-28). So the PROMPT gives way, never the input,
		// and an input wider than the line shows its end, where the cursor is.
		tail := shown + "█"
		if tw := lipgloss.Width(tail); tw > w-14 {
			r := []rune(tail)
			tail = "…" + string(r[len(r)-(w-15):])
		}
		sl = stWarn.Render(truncate(m.prompt, w-lipgloss.Width(tail)-3)) + tail
	case m.filterOn:
		sl = m.filter.View() + stDim.Render("   enter keep · esc clear")
	case m.status != "":
		sl = m.status
	}
	rows := m.rows()
	var sr string
	if d != nil {
		sr = fmt.Sprintf("%d rows", len(rows))
		if q := m.filter.Value(); q != "" {
			sr = fmt.Sprintf("/%s · %d of %d", q, len(rows), len(d.rows))
		}
		if n := len(m.markedRows()); n > 0 {
			sr = fmt.Sprintf("%d marked · ", n) + sr
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
	if n := m.runningJobs(); n > 0 {
		sr = fmt.Sprintf("%d job(s) running (ctrl+j) · ", n) + sr
	}
	if m.prompt != "" {
		sr = "" // the whole line is the prompt's while the operator types
	}
	b.WriteString(padBetween(truncate(sl, w-lipgloss.Width(sr)-2), stDim.Render(sr), w))
	return b.String()
}

// menuTargetW is the fixed width of the name the verbs act on, at the start
// of the menu: fixed so moving the cursor never reflows the verbs.
const menuTargetW = 22

// menuItems is this tab's verbs as the menu spells them.
func (m model) menuItems() []string {
	var items []string
	for _, v := range m.verbsHere() {
		items = append(items, mnemonic(v.key, shortLabel(v.label), isDanger(v.label)))
	}
	return items
}

// packMenu fills lines of width w with items two spaces apart, every line
// starting after the name column.
func packMenu(items []string, w int) [][]string {
	var lines [][]string
	var cur []string
	used := menuTargetW + 2
	for _, it := range items {
		iw := lipgloss.Width(it)
		if len(cur) > 0 && used+2+iw > w {
			lines = append(lines, cur)
			cur, used = nil, menuTargetW+2
		}
		if len(cur) > 0 {
			used += 2
		}
		cur = append(cur, it)
		used += iw
	}
	if len(cur) > 0 {
		lines = append(lines, cur)
	}
	return lines
}

// menuHeight is how many verb lines the menu takes at width w: every verb,
// capped at four lines (two on a short terminal). It depends on the tab and
// the width only, so a refresh never changes it.
func (m model) menuHeight(w int) int {
	top := 4
	if m.height < 35 {
		top = 2
	}
	return min(max(len(packMenu(m.menuItems(), w)), 1), top)
}

// menuLines is the bottom menu: a rule, the verbs of this tab after the name
// they act on ("app-jellyfin   (S)tart  shu(T)down  ..."), then the keys that
// move around. Destructive verbs are red. What does not fit ends in
// "(?) more", and ? lists everything.
func (m model) menuLines(w int) []string {
	out := []string{stRule.Render(strings.Repeat("─", w))}
	vh := m.menuHeight(w)
	target := ""
	if r := m.selectedRow(); r != nil {
		target = col(r, 0)
	}
	if n := len(m.markedRows()); n > 0 {
		target = fmt.Sprintf("%d marked", n)
	}
	name := stTitle.Render(padRight(ansi.Truncate(target, menuTargetW, "…"), menuTargetW)) + "  "
	indent := strings.Repeat(" ", menuTargetW+2)
	packed := packMenu(m.menuItems(), w)
	if len(packed) > vh {
		last := packed[vh-1]
		more := mnemonic("?", "more", false)
		for len(last) > 1 && menuTargetW+2+lipgloss.Width(strings.Join(last, "  "))+2+lipgloss.Width(more) > w {
			last = last[:len(last)-1]
		}
		packed = append(packed[:vh-1], append(last, more))
	}
	for i := 0; i < vh; i++ {
		pre := indent
		if i == 0 {
			pre = name
		}
		line := pre
		switch {
		case i < len(packed):
			line += strings.Join(packed[i], "  ")
		case i == 0:
			line += stDim.Render("nothing to run here: this tab only shows")
		}
		out = append(out, ansi.Truncate(line, w, ""))
	}
	return append(out, ansi.Truncate(m.navLine(), w, ""))
}

// navLine is the keys that move around, the same on every tab except for
// what enter and backspace do here.
func (m model) navLine() string {
	k := func(key, what string) string { return mnemonic(key, what, false) }
	// always shown: where tab goes, the filter, what enter and backspace do
	parts := []string{k("tab", m.subName()), k("/", "filter")}
	switch sections[m.active].name + "/" + m.subName() {
	case "Machines/VMs", "Storage/Datasets":
		parts = append(parts, k("enter", "snapshots"))
	case "Storage/Pools":
		parts = append(parts, k("enter", "open the pool"))
	case "Storage/Explorer":
		parts = append(parts, k("enter", "open"))
	case "Overview/Activity":
		parts = append(parts, k("enter", "watch"))
	case "Cluster/Pods":
		parts = append(parts, k("enter", "logs"))
	case "Cluster/Nodes", "Cluster/Deployments", "Cluster/Services":
		parts = append(parts, k("enter", "describe"))
	}
	if len(m.nav) > 0 {
		parts = append(parts, k("backspace", "back"))
	}
	if len(m.jobs) > 0 {
		parts = append(parts, k("ctrl+j", "jobs"))
	}
	// then as many of these as fit, most useful first; ? and q never give
	// way, and ? lists everything that did
	extra := []string{k("1-0", "section"), k("j/k", "row"), k("o", "sort"), k(":", "palette"),
		k("r", "reload"), k("i", "vitals"), k("space", "mark"), k("ctrl+t", "terminal")}
	tail := []string{k("?", "help"), k("q", "quit")}
	line := func(n int) string {
		return strings.Join(append(append(append([]string{}, parts...), extra[:n]...), tail...), "  ")
	}
	n := len(extra)
	for n > 0 && lipgloss.Width(line(n)) > m.width {
		n--
	}
	return line(n)
}

// tableView lays the rows out in width w and height h: header, then the page
// that holds the selection. Numeric columns are right-aligned; the state
// word in a cell is coloured, the rest of the row is not.
func (m model) tableView(d *sectionData, w, h int) string {
	if d == nil || len(d.columns) == 0 {
		return strings.Repeat("\n", max(h-1, 0))
	}
	rows := m.rows()
	numeric := numericColumns(rows, len(d.columns))
	widths := columnWidths(d.columns, rows, w-3) // two cells for the mark
	line := func(cells []string, sel, header bool) string {
		parts := make([]string, 0, len(d.columns))
		for i := range d.columns {
			if widths[i] == 0 {
				continue // dropped: no room at this width
			}
			v := truncate(col(cells, i), widths[i])
			var p string
			if numeric[i] {
				p = fmt.Sprintf("%*s", widths[i], v)
			} else {
				p = fmt.Sprintf("%-*s", widths[i], v)
			}
			if !sel && !header {
				c := colourCell(p, v)
				if c == p {
					c = stText.Render(p)
				}
				p = c
			}
			parts = append(parts, p)
		}
		mark := "  "
		if !header && m.marks[m.key()+"\x00"+col(cells, 0)] {
			mark = stWarn.Render("▸ ")
			if sel {
				mark = "▸ "
			}
		}
		if sel && noColor && mark == "  " {
			// NO_COLOR draws no attributes at all, so the highlight is a mark
			mark = "> "
		}
		s := mark + strings.Join(parts, "  ")
		if sel {
			return stSel.Render(fmt.Sprintf("%-*s", w-1, s))
		}
		return s
	}
	var b strings.Builder
	b.WriteString(stHead.Render(line(d.columns, false, true)) + "\n")
	limit := h - 1
	if limit < 1 {
		limit = 1
	}
	// the cursor sits in the middle of the window, so the rows before and
	// after it stay in view (vim's scrolloff; the operator's ask,
	// 2026-09-26): the window follows the cursor, clamped so the table
	// never shows blank rows at either end
	start := m.row - limit/2
	if start > len(rows)-limit {
		start = len(rows) - limit
	}
	if start < 0 {
		start = 0
	}
	n := 0
	for i := start; i < len(rows) && i < start+limit; i++ {
		b.WriteString(line(rows[i], i == m.row, false) + "\n")
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

// vitalsWidth is the left pane's width at terminal width w, 0 when it is
// hidden (i toggles it; below 100 columns the table needs the room).
func (m model) vitalsWidth(w int) int {
	if !m.detail || w < 100 {
		return 0
	}
	return min(max(w/4, 28), 44)
}

// vitalsView is the selected row as the left pane shows it: its name, every
// column as a property, then what the tab's detailer adds (disks, NICs, the
// zvol's properties). Exactly h lines, each exactly vw cells with the
// separator, so a value that grows on refresh is cut, never wrapped: a
// wrapped line is what made the old right-hand pane grow and push the menu
// down (2026-09-27). The verbs are in the menu below, not here.
func (m model) vitalsView(d *sectionData, vw, h int) []string {
	cw := vw - 3
	var lines []string
	r := m.selectedRow()
	switch {
	case d == nil || len(d.columns) == 0 || r == nil:
		lines = append(lines, stDim.Render("nothing selected"))
	default:
		lines = append(lines, stHead.Render(col(r, 0)), "")
		kw := 0
		for _, c := range d.columns[1:] {
			kw = max(kw, min(len(c), 12))
		}
		for i := 1; i < len(d.columns); i++ {
			v := col(r, i)
			if v == "" || v == "-" {
				continue
			}
			val := colourCell(v, v)
			if val == v {
				val = stPropV.Render(v)
			}
			lines = append(lines, prop(ansi.Truncate(d.columns[i], kw, ""), kw, val))
		}
		if extra, ok := m.details[m.key()+"\x00"+col(r, 0)]; ok {
			ekw := 0
			for _, e := range extra {
				if k, _, isKV := strings.Cut(e, "\t"); isKV {
					ekw = max(ekw, min(len(k), 14))
				}
			}
			for _, e := range extra {
				k, v, isKV := strings.Cut(e, "\t")
				if !isKV {
					lines = append(lines, "", stHead.Render(e))
					continue
				}
				lines = append(lines, prop(ansi.Truncate(k, ekw, ""), ekw, stPropV.Render(v)))
			}
		} else if _, ok := detailers[sections[m.active].name+"/"+m.subName()]; ok {
			lines = append(lines, "", stDim.Render("…"))
		}
	}
	out := make([]string, h)
	sep := " " + stRule.Render("│") + " "
	for i := range out {
		l := ""
		if i < len(lines) {
			l = ansi.Truncate(lines[i], cw, "…")
		}
		out[i] = padRight(l, cw) + sep
	}
	return out
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
		k("esc", "clear the marks, then the filter, then leave a drill-in (back to every VM / dataset)"),
		k("space", "mark the row (verbs then run on every marked row)   ·   ctrl+a all / none"),
		k("/", "filter rows; enter keeps it, esc clears it"),
		k("o", "sort: next column, then descending, then the tool's order"),
		k("i", "show or hide the vitals pane (the selected row, on the left)"),
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
		lines = append(lines, "  "+mnemonic(v.key, v.label, isDanger(v.label))+stDim.Render(strings.TrimPrefix(what, v.label)))
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
	// The first column is the row's name and keeps up to 24 cells: it used to
	// give way with the rest until every machine read "app-a…" (onyx, 120
	// columns, 2026-09-27). The others shrink to 5; if that is still too
	// wide, columns drop off the right (width 0, not drawn) rather than the
	// name shrinking further.
	nameMin := min(w[0], 24)
	fits := func() bool {
		t, n := 0, 0
		for _, x := range w {
			if x > 0 {
				t += x
				n++
			}
		}
		return t+2*(n-1) <= total
	}
	// shrink the widest other column still above floor(i); false when none is
	shrink := func(floor func(i int) int) bool {
		widest := -1
		for i := 1; i < len(w); i++ {
			if w[i] > floor(i) && (widest < 0 || w[i] > w[widest]) {
				widest = i
			}
		}
		if widest < 0 {
			return false
		}
		w[widest]--
		return true
	}
	// readable first: a size like "355.2G" is six cells, a header up to eight
	readable := func(i int) int { return min(max(len(cols[i]), 6), 8) }
	for !fits() {
		if shrink(readable) {
			continue
		}
		if w[0] > nameMin {
			w[0]--
			continue
		}
		if shrink(func(int) int { return 5 }) {
			continue
		}
		last := -1
		for i := len(w) - 1; i > 0; i-- {
			if w[i] > 0 {
				last = i
				break
			}
		}
		if last < 0 {
			w[0] = max(total, 1)
			break
		}
		w[last] = 0
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

// truncate cuts s to w cells with an ellipsis, escape sequences intact: the
// rune-slicing version cut a coloured hint line inside its SGR sequence and
// the status text after it rendered twice (2026-09-26).
func truncate(s string, w int) string {
	if w <= 0 {
		return ""
	}
	if lipgloss.Width(s) <= w {
		return s
	}
	if w == 1 {
		return "…"
	}
	return ansi.Truncate(s, w, "…")
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
	case "shut", "stopped", "off", "disabled", "no":
		return stOff.Render(rendered)
	}
	return rendered
}

// ─── in-TUI consoles ───────────────────────────────────────────────────────
// openConsole starts a console on the selected VM and hands it the keys and
// the mouse; updateConsole routes them until ctrl+] d detaches. The screen
// needs the mouse, so cell-motion reporting is on only while one is open:
// with it on, the terminal's own text selection is gone.

func (m model) openConsole(kind consoleKind, vm, addr string) (tea.Model, tea.Cmd) {
	// A text console drawn as dots is unreadable: in gnome-terminal (VTE with
	// sixels off, which is every GNOME terminal) w showed kldload-cp's login
	// screen as braille noise (fiend, 2026-09-27; the fallback of 90524367
	// promised "a boot log stays legible" and it does not at this scale). So a
	// terminal that cannot draw images gets the VM's serial console -- the
	// same console, as text -- whenever the VM has one, and says so. A VM with
	// no serial port (a Windows guest) still gets the cell picture.
	note := ""
	if kind == conScreen && !sixelTerminal && hasSerial(vm) {
		kind = conSerial
		note = "this terminal draws no images · ctrl+] 1 for the dot picture · pixels need a sixel terminal such as foot"
	}
	if kind == conScreen && sixelTerminal {
		// pixels where the terminal draws them: the full window, back to
		// the table on ctrl+] d
		cmd := exec.Command("kld", "screen", vm)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		return m, tea.ExecProcess(cmd, func(err error) tea.Msg {
			if err != nil {
				return doneMsg{"screen " + vm, err}
			}
			return doneMsg{what: "screen " + vm + ": back"}
		})
	}
	c, err := openConsole(kind, vm, addr, m.width, m.conBodyH())
	if err != nil {
		m.say(stWarn.Render(kind.String() + " " + vm + ": " + err.Error()))
		return m, nil
	}
	if m.con != nil && m.con.kind != conJob {
		m.con.close()
	}
	m.con = c
	c.note = note
	c.resize(m.width, m.conBodyH())
	if kind == conScreen {
		return m, tea.Batch(conTick(), tea.EnableMouseCellMotion)
	}
	return m, tea.Batch(conTick(), tea.DisableMouse)
}

// runningJobs counts the jobs whose child is still alive.
func (m model) runningJobs() int {
	n := 0
	for _, j := range m.jobs {
		if j.running() {
			n++
		}
	}
	return n
}

// leaveJob hides a job's pane; the job itself keeps running — except a
// follow (a journal), which has no work to finish and is ended, and
// removed from the jobs, when its pane is left.
func (m model) leaveJob() (tea.Model, tea.Cmd) {
	if c := m.con; c != nil && c.follow {
		c.close()
		for i, j := range m.jobs {
			if j == c {
				m.jobs = append(m.jobs[:i], m.jobs[i+1:]...)
				break
			}
		}
	}
	m.con = nil
	return m, conTick()
}

func (m model) closeConsole() (tea.Model, tea.Cmd) {
	if m.con != nil {
		m.con.close()
		m.say(stDim.Render(m.con.kind.String() + " " + m.con.vm + " detached"))
		m.con = nil
	}
	return m, tea.DisableMouse
}

func (m model) updateConsole(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	c := m.con
	if c.kind == conJob {
		return m.updateJob(msg)
	}
	if c.menu {
		c.menu = false
		c.seq.Add(1)
		switch msg.String() {
		case "d", "q":
			return m.closeConsole()
		case "1", "2", "3":
			kind := consoleKind(msg.String()[0] - '0')
			if kind == c.kind {
				return m, nil
			}
			return m.openConsole(kind, c.vm, c.addr)
		case "x":
			c.ctrlAltDel()
		case "f":
			// the pane is a thumbnail at a hundred columns; the full window
			// draws pixels where the terminal has sixels (kld screen)
			if c.kind == conScreen {
				vm := c.vm
				c.close()
				m.con = nil
				cmd := exec.Command("kld", "screen", vm)
				cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
				return m, tea.Sequence(tea.DisableMouse, tea.ExecProcess(cmd, func(err error) tea.Msg {
					if err != nil {
						return doneMsg{"screen " + vm, err}
					}
					return doneMsg{what: "screen " + vm + ": back"}
				}))
			}
		case "r":
			c.cache.s = ""
			c.resize(m.width, m.conBodyH())
			if c.rfb != nil {
				c.rfb.requestUpdate(false)
			}
		case "ctrl+]":
			if c.pty != nil {
				// error ignored: a dead child is reported by its reader
				_, _ = c.pty.Write([]byte{0x1d})
			} else {
				c.rfb.key(ksControlL, true)
				c.rfb.tap(']')
				c.rfb.key(ksControlL, false)
			}
		}
		return m, nil
	}
	if msg.String() == "ctrl+]" {
		c.menu = true
		c.seq.Add(1)
		return m, nil
	}
	if p := c.exit.Load(); p != nil && msg.String() == "enter" {
		// the session is over: Enter leaves, the way a closed ssh does
		return m.closeConsole()
	}
	c.key(msg)
	return m, nil
}

// colNamed reads the row's value under the named column of the current
// table, so a verb never depends on a column's position (the ssh verb read
// column 4 as the address and got the vCPU count after the group column
// was added, 2026-09-26).
func (m model) colNamed(row []string, name string) string {
	d := m.cur()
	if d == nil {
		return ""
	}
	for i, c := range d.columns {
		if c == name {
			return col(row, i)
		}
	}
	return ""
}

// updateJob is the key handling of a job pane: ctrl+] menu (d back, k
// kill, J next job), Enter on a finished job goes back, everything else
// goes to the job's pty in case it asks a question.
func (m model) updateJob(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	c := m.con
	if c.menu {
		c.menu = false
		c.seq.Add(1)
		switch msg.String() {
		case "d", "q":
			return m.leaveJob()
		case "k":
			c.close()
			m.say(stWarn.Render(c.vm + ": killed"))
			return m.leaveJob()
		case "J":
			for i, j := range m.jobs {
				if j == c {
					m.con = m.jobs[(i+1)%len(m.jobs)]
					m.con.resize(m.width, m.conBodyH())
					break
				}
			}
		}
		return m, nil
	}
	if msg.String() == "ctrl+]" {
		c.menu = true
		c.seq.Add(1)
		return m, nil
	}
	if !c.running() && msg.String() == "enter" {
		return m.leaveJob()
	}
	c.key(msg)
	return m, nil
}

// activityMsg asks for the Activity tab to reload.
type activityMsg struct{}

// openActivity is Enter on the Activity tab: a kld job's pane, or a live
// journal of a unit in a pane that ends when it is left.
func (m model) openActivity() (tea.Model, tea.Cmd) {
	r := m.selectedRow()
	if r == nil {
		return m, nil
	}
	if col(r, 1) == "job" {
		for _, j := range m.jobs {
			if j.vm == col(r, 0) {
				m.con = j
				j.resize(m.width, m.conBodyH())
				return m, conTick()
			}
		}
		return m, nil
	}
	unit := col(r, 0)
	if !unitOK(unit) {
		m.say(stWarn.Render("not a unit name: " + unit))
		return m, nil
	}
	c, err := openJob("journal "+unit, []string{"journalctl", "-o", "short", "--no-hostname", "-n", "200", "-fu", unit}, m.width, m.conBodyH())
	if err != nil {
		m.say(stBad.Render(err.Error()))
		return m, nil
	}
	c.follow = true
	m.jobs = append(m.jobs, c)
	m.con = c
	c.resize(m.width, m.conBodyH())
	return m, conTick()
}

// unitOK admits systemd unit names and nothing shell-shaped.
func unitOK(s string) bool {
	if s == "" || len(s) > 128 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.' || c == '@' || c == ':' || c == '\\') {
			return false
		}
	}
	return true
}

// jobSucceeded is true once a job has ended with exit status 0.
func jobSucceeded(c *console) bool {
	p := c.exit.Load()
	return p != nil && strings.HasSuffix((*p).Error(), " ended")
}
