// tui.go — the wgxplore console: estate on the left, dossier on the right.
//
// Deliberately the same shape as zxplore's TUI so the two consoles feel like
// one product: a navigable list of things, a full property dossier for the
// selected thing, keys that do not surprise (j/k, /, r, q, F-keys).
//
// Read-only. Every mutation lives behind the engine's explicit verbs, which
// echo the exact wg/ip command before running it.
package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

var (
	stTitle  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("87"))
	stHost   = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("111"))
	stSel    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("0")).Background(lipgloss.Color("87"))
	stDim    = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	stAlive  = lipgloss.NewStyle().Foreground(lipgloss.Color("42"))
	stQuiet  = lipgloss.NewStyle().Foreground(lipgloss.Color("214"))
	stStale  = lipgloss.NewStyle().Foreground(lipgloss.Color("203"))
	stAlarm  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("199"))
	stKey    = lipgloss.NewStyle().Foreground(lipgloss.Color("152"))
	stErr    = lipgloss.NewStyle().Foreground(lipgloss.Color("203"))
	stFooter = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
)

// row is one selectable line: a device header or a peer under it.
type row struct {
	dev   int
	peer  int // -1 = the device line itself
	label string
}

type model struct {
	devs     []Device
	rows     []row
	cursor   int
	filter   string
	filterOn bool
	vp       viewport.Model
	w, h     int
	loading  bool
	hosts    []string
}

type loadedMsg []Device

func (m model) Init() tea.Cmd { return m.reload() }

func (m model) reload() tea.Cmd {
	return func() tea.Msg {
		devs := CollectEstate(m.hosts)
		MarkDeclared(devs)
		return loadedMsg(devs)
	}
}

// buildRows flattens devices+peers into the navigable list, honouring filter.
func (m *model) buildRows() {
	m.rows = nil
	f := strings.ToLower(m.filter)
	for di, d := range m.devs {
		hostLabel := d.Host
		if hostLabel == "" {
			hostLabel = "local"
		}
		devLine := fmt.Sprintf("%s  %s", hostLabel, d.Name)
		match := f == "" || strings.Contains(strings.ToLower(devLine), f)
		var kids []row
		for pi, p := range d.Peers {
			pl := fmt.Sprintf("%s %s", p.PublicKey, p.AllowedIPs)
			if f == "" || strings.Contains(strings.ToLower(pl), f) || match {
				kids = append(kids, row{dev: di, peer: pi})
			}
		}
		if match || len(kids) > 0 {
			m.rows = append(m.rows, row{dev: di, peer: -1, label: devLine})
			m.rows = append(m.rows, kids...)
		}
	}
	if m.cursor >= len(m.rows) {
		m.cursor = max(0, len(m.rows)-1)
	}
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
		m.vp = viewport.New(msg.Width-42, msg.Height-4)
		return m, nil
	case loadedMsg:
		m.devs = []Device(msg)
		m.loading = false
		m.buildRows()
		return m, nil
	case tea.KeyMsg:
		if m.filterOn {
			switch msg.String() {
			case "enter", "esc":
				m.filterOn = false
			case "backspace":
				if m.filter != "" {
					m.filter = m.filter[:len(m.filter)-1]
					m.buildRows()
				}
			default:
				if len(msg.String()) == 1 {
					m.filter += msg.String()
					m.buildRows()
				}
			}
			return m, nil
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
		case "/":
			m.filterOn = true
		case "esc":
			m.filter = ""
			m.buildRows()
		case "r":
			m.loading = true
			return m, m.reload()
		}
	}
	return m, nil
}

func (m model) View() string {
	if m.w == 0 {
		return "starting…"
	}
	hosts, ifaces, peers, alive, undeclared := Totals(m.devs)
	head := stTitle.Render("wgxplore") + stDim.Render(fmt.Sprintf(
		"  %d hosts · %d interfaces · %d peers · %d alive", hosts, ifaces, peers, alive))
	if undeclared > 0 {
		head += "  " + stAlarm.Render(fmt.Sprintf("⚠ %d undeclared", undeclared))
	}
	if m.loading {
		head += stDim.Render("  · scanning…")
	}

	// ── left: estate list ────────────────────────────────────────────────
	var left []string
	for i, r := range m.rows {
		d := m.devs[r.dev]
		var line string
		if r.peer < 0 {
			line = stHost.Render(r.label)
			if d.Err != "" {
				line = stErr.Render(r.label + " (unreachable)")
			}
		} else {
			p := d.Peers[r.peer]
			mark := map[string]string{
				"alive": stAlive.Render("●"),
				"quiet": stQuiet.Render("●"),
				"stale": stStale.Render("○"),
				"never": stStale.Render("○"),
			}[p.Health()]
			key := p.PublicKey
			if len(key) > 12 {
				key = key[:12] + "…"
			}
			flag := " "
			if !p.Declared {
				flag = stAlarm.Render("!")
			}
			line = fmt.Sprintf("  %s%s %s %s", mark, flag, stKey.Render(key), stDim.Render(p.Age()))
		}
		if i == m.cursor {
			line = stSel.Render(lipgloss.NewStyle().MaxWidth(38).Render(stripANSI(line)))
		}
		left = append(left, line)
	}
	leftBox := lipgloss.NewStyle().Width(40).MaxHeight(m.h - 3).Render(strings.Join(left, "\n"))

	// ── right: dossier for the selection ─────────────────────────────────
	right := "no selection"
	if m.cursor < len(m.rows) {
		r := m.rows[m.cursor]
		d := m.devs[r.dev]
		if r.peer < 0 {
			right = m.deviceDossier(d)
		} else {
			right = m.peerDossier(d, d.Peers[r.peer])
		}
	}
	rightBox := lipgloss.NewStyle().Width(max(20, m.w-44)).MaxHeight(m.h - 3).Render(right)

	foot := stFooter.Render("j/k move · / filter · esc clear · r refresh · q quit")
	if m.filterOn {
		foot = stTitle.Render("filter: ") + m.filter + stDim.Render("  (enter to apply)")
	}
	return head + "\n" + lipgloss.JoinHorizontal(lipgloss.Top, leftBox, rightBox) + "\n" + foot
}

func (m model) deviceDossier(d Device) string {
	host := d.Host
	if host == "" {
		host = "local"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n\n", stTitle.Render("interface "+d.Name))
	if d.Err != "" {
		fmt.Fprintf(&b, "%s\n  %s\n", stErr.Render("UNREACHABLE"), d.Err)
		return b.String()
	}
	fmt.Fprintf(&b, "  %-12s %s\n", "host", host)
	fmt.Fprintf(&b, "  %-12s %s\n", "public key", d.PublicKey)
	fmt.Fprintf(&b, "  %-12s %s\n", "listen port", orDash(d.ListenPort))
	fmt.Fprintf(&b, "  %-12s %d\n\n", "peers", len(d.Peers))
	var alive, undeclared int
	for _, p := range d.Peers {
		if p.Health() == "alive" {
			alive++
		}
		if !p.Declared {
			undeclared++
		}
	}
	fmt.Fprintf(&b, "  %s %d/%d peers handshaking\n", stAlive.Render("●"), alive, len(d.Peers))
	if undeclared > 0 {
		fmt.Fprintf(&b, "  %s %d peer(s) not in any declaration\n",
			stAlarm.Render("⚠"), undeclared)
	}
	return b.String()
}

func (m model) peerDossier(d Device, p Peer) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n\n", stTitle.Render("peer"))
	fmt.Fprintf(&b, "  %-12s %s\n", "public key", p.PublicKey)
	fmt.Fprintf(&b, "  %-12s %s\n", "on", d.Name)
	fmt.Fprintf(&b, "  %-12s %s\n", "endpoint", orDash(p.Endpoint))
	fmt.Fprintf(&b, "  %-12s %s\n", "allowed-ips", p.AllowedIPs)
	style := map[string]lipgloss.Style{
		"alive": stAlive, "quiet": stQuiet, "stale": stStale, "never": stStale,
	}[p.Health()]
	fmt.Fprintf(&b, "  %-12s %s\n", "handshake", style.Render(p.Age()+"  ("+p.Health()+")"))
	fmt.Fprintf(&b, "  %-12s rx %s / tx %s\n", "traffic", human(p.RxBytes), human(p.TxBytes))
	fmt.Fprintf(&b, "  %-12s %s\n\n", "keepalive", orDash(p.Keepalive))
	if p.Declared {
		fmt.Fprintf(&b, "  %s declared — this peer is in a wgxplore network\n", stAlive.Render("✓"))
	} else {
		fmt.Fprintf(&b, "  %s UNDECLARED — no declaration lists this key.\n", stAlarm.Render("⚠"))
		fmt.Fprintf(&b, "    A peer cannot appear by accident: someone with root\n")
		fmt.Fprintf(&b, "    on %s added it. Investigate.\n", d.Name)
	}
	return b.String()
}

// stripANSI removes styling so the selection highlight paints a clean bar.
func stripANSI(s string) string {
	var out strings.Builder
	skip := false
	for _, r := range s {
		switch {
		case r == '\x1b':
			skip = true
		case skip && r == 'm':
			skip = false
		case !skip:
			out.WriteRune(r)
		}
	}
	return out.String()
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// RunTUI starts the console.
func RunTUI() error {
	m := model{loading: true, hosts: sshHosts()}
	_, err := tea.NewProgram(m, tea.WithAltScreen()).Run()
	return err
}
