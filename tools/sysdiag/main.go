// sysdiag — the local-OS observability console, family chassis edition.
//
// Go/bubbletea replacement for the kldload-sysdiag tmux cockpit's watch
// loops: same primitive commands (iostat, df, zpool, ss, systemctl …),
// same read-only posture, but one keyboard-driven two-pane console in the
// zxplore/wgxplore idiom instead of tmux F-key windows. Sections on the
// left with health dots, the section's dossier on the right, every block
// headed by the literal command that produced it — primitives visible,
// zxplore-style.
//
// Interactive tools (htop, k9s, journalctl -f) are deliberately NOT
// embedded: they are their own consoles; this one shows snapshots and
// refreshes them. Health probes run cheap commands each tick to colour
// the section dots (failed units, pool state, fullest filesystem).
//
// Static build (CGO_ENABLED=0): scp it to any Linux box and it works.
package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const version = "0.1.0"

// ─── family palette — matches wgxplore tui.go / gui.go ───────────────────
var (
	stTitle  = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("87"))
	stSel    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("0")).Background(lipgloss.Color("87"))
	stDim    = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	stOK     = lipgloss.NewStyle().Foreground(lipgloss.Color("42"))
	stWarn   = lipgloss.NewStyle().Foreground(lipgloss.Color("214"))
	stBad    = lipgloss.NewStyle().Foreground(lipgloss.Color("203"))
	stCmd    = lipgloss.NewStyle().Foreground(lipgloss.Color("152"))
	stFooter = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
)

// section is one diagnostic view: a name and the commands whose output is
// its dossier. Commands run via bash -c with a per-command timeout so one
// hung tool cannot wedge the console.
type section struct {
	name string
	cmds []string
}

var sections = []section{
	{"overview", []string{
		"uptime",
		"free -h",
		"df -h --output=pcent,target -x tmpfs -x devtmpfs -x overlay | sort -rn | head -6",
		"systemctl --failed --no-legend --no-pager",
		"uname -r",
	}},
	{"cpu · mem", []string{
		"top -bn1 | head -18",
		"vmstat 1 1",
	}},
	{"disks", []string{
		"iostat -xm 1 1 | tail -n +2",
		"df -h | grep -vE 'tmpfs|devtmpfs|overlay|squashfs|cgroup' | head -15",
		"lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS | head -20",
	}},
	{"zfs", []string{
		"zpool status | head -30",
		"zpool list",
		"zfs list -t filesystem -o name,used,refer,mountpoint -s used | tail -15",
	}},
	{"network", []string{
		"ip -br addr",
		"ip -br route | head -8",
		"ss -tlnp | head -15",
		"ss -tnp state established | head -10",
	}},
	{"services", []string{
		"systemctl --failed --no-pager",
		"systemctl list-units --state=running --no-pager --no-legend | head -22",
	}},
	{"kernel", []string{
		"uname -a",
		"lsmod | sort -k2 -nr | head -20",
		"sysctl vm.swappiness vm.dirty_ratio fs.inotify.max_user_watches kernel.pid_max net.ipv4.ip_forward 2>/dev/null",
	}},
	{"packages", []string{
		"rpm -qa --last 2>/dev/null | head -20 || dpkg-query -W 2>/dev/null | tail -20",
		"dnf history list 2>/dev/null | head -12",
	}},
	{"hardware", []string{
		"lscpu | head -20",
		"sensors 2>/dev/null | head -18 || echo '(install lm_sensors)'",
		"lspci | head -25",
	}},
	// eBPF — is the machinery there, and is anything using it?
	//
	// This section answers "can this kernel do eBPF and is kldload's share of
	// it alive", NOT "trace something for me". A diagnostic console must
	// return promptly; every bcc tool worth running is a sampler that blocks
	// until you stop it, so those belong in ztxplore's trace tab, not here.
	//
	// The bcc lookup is spelled out because the tools are never installed
	// under the bare name: Debian ships <name>-bpfcc in /usr/sbin, RHEL puts
	// them in /usr/share/bcc/tools which is on nobody's PATH. Reporting "not
	// installed" for a package that is installed is worse than saying nothing.
	{"ebpf", []string{
		"echo '— kernel support —'; " +
			"test -f /sys/kernel/btf/vmlinux && echo 'BTF: present (CO-RE works)' || echo 'BTF: MISSING — CO-RE probes will not load'; " +
			"sysctl -n kernel.unprivileged_bpf_disabled 2>/dev/null | " +
			"sed 's/^0$/unprivileged bpf: allowed/;s/^1$/unprivileged bpf: disabled (root only)/;s/^2$/unprivileged bpf: disabled/'",
		"echo '— tooling —'; " +
			"command -v bpftrace >/dev/null && bpftrace --version 2>&1 | head -1 || echo 'bpftrace: not installed'; " +
			"n=$(ls /usr/sbin/*-bpfcc /usr/share/bcc/tools/* 2>/dev/null | wc -l); " +
			"echo \"bcc tools: $n found\"; " +
			"ls /usr/sbin/*-bpfcc 2>/dev/null | head -4 | sed 's|.*/|  |'",
		"echo '— exporter —'; " +
			"systemctl is-active ebpf_exporter 2>/dev/null | sed 's/^/ebpf_exporter: /'; " +
			"curl -s --max-time 3 http://127.0.0.1:9435/metrics 2>/dev/null | grep -c '^ebpf_exporter\\|^bio' | sed 's/^/metric series: /' || echo 'metrics: not answering'",
		"echo '— loaded programs —'; " +
			"bpftool prog show 2>/dev/null | grep -cE '^[0-9]+:' | sed 's/^/programs attached: /' || echo '(bpftool not installed or needs root)'; " +
			"bpftool prog show 2>/dev/null | grep -oE 'name [a-z_]+' | sort | uniq -c | sort -rn | head -6",
	}},
	{"journal", []string{
		"journalctl -n 40 --no-pager 2>/dev/null || echo '(journal needs privileges — run as root)'",
	}},
}

// health is the tri-state a section dot can show.
type health int

const (
	hOK health = iota
	hWarn
	hBad
	hNone
)

func (h health) dot() string {
	switch h {
	case hOK:
		return stOK.Render("●")
	case hWarn:
		return stWarn.Render("●")
	case hBad:
		return stBad.Render("●")
	}
	return stDim.Render("○")
}

// runCmd executes one command with a hard timeout and returns its combined
// output plus the exec error — a diagnostic console must show stderr
// ("permission denied" IS the diagnosis), which is why this is not Output().
// The error is returned rather than dropped because a probe that cannot
// tell "zpool said nothing" from "zpool is not installed" from "zpool
// failed" colours its dot from noise.
func runCmd(cmd string, timeout time.Duration) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "bash", "-c", cmd).CombinedOutput()
	if ctx.Err() != nil {
		err = fmt.Errorf("timed out after %s", timeout)
	}
	return strings.TrimRight(string(out), "\n"), err
}

// runOut is runCmd for display: the output, or the error when the command
// produced none, so a failing command never renders as "(no output)".
func runOut(cmd string, timeout time.Duration) string {
	s, err := runCmd(cmd, timeout)
	if err != nil {
		if s == "" {
			return stDim.Render("(" + err.Error() + ")")
		}
		return s + stDim.Render("\n("+err.Error()+")")
	}
	if s == "" {
		s = stDim.Render("(no output)")
	}
	return s
}

// zfsHealth turns the output of `zpool list -H -o health` into a dot.
//
// One line per pool, and EVERY line must read ONLINE for green. The first
// cut tested Contains("ONLINE") && !ContainsAny("D") — meant as "no
// DEGRADED" — so one ONLINE pool beside an UNAVAIL or OFFLINE pool (neither
// spells a D) showed green. A failed command is red, not grey: grey means
// "nothing to report" and a probe that fails must never wear it.
func zfsHealth(out string, err error) health {
	if err != nil {
		return hBad
	}
	lines := strings.Fields(out)
	if len(lines) == 0 {
		return hNone // no pools imported
	}
	for _, l := range lines {
		if l != "ONLINE" {
			return hBad
		}
	}
	return hOK
}

// probe colours the section dots from cheap read-only checks.
func probe() map[string]health {
	m := map[string]health{}
	// services / overview: any failed unit is a red dot
	failed := strings.TrimSpace(runOut("systemctl --failed --no-legend --no-pager | wc -l", 2*time.Second))
	if failed == "0" {
		m["services"] = hOK
	} else {
		m["services"] = hBad
	}
	// zfs: one health word per pool. A box with no zpool binary has nothing
	// to report (grey), which is a different thing from zpool failing (red).
	if _, err := exec.LookPath("zpool"); err != nil {
		m["zfs"] = hNone
	} else {
		m["zfs"] = zfsHealth(runCmd("zpool list -H -o health", 2*time.Second))
	}
	// disks: fullest real filesystem
	pc := strings.TrimSpace(runOut(
		"df --output=pcent -x tmpfs -x devtmpfs -x overlay 2>/dev/null | tail -n +2 | tr -d ' %' | sort -n | tail -1", 2*time.Second))
	if n, err := strconv.Atoi(pc); err == nil {
		switch {
		case n >= 90:
			m["disks"] = hBad
		case n >= 80:
			m["disks"] = hWarn
		default:
			m["disks"] = hOK
		}
	}
	// network: a default route exists
	if strings.Contains(runOut("ip route show default", 2*time.Second), "default") {
		m["network"] = hOK
	} else {
		m["network"] = hBad
	}
	// overview aggregates the worst of the above
	worst := hOK
	for _, k := range []string{"services", "zfs", "disks", "network"} {
		if h, ok := m[k]; ok && h != hNone && h > worst {
			worst = h
		}
	}
	m["overview"] = worst
	return m
}

// render runs a section's commands and assembles the dossier, each block
// headed by the literal command — the primitives stay visible.
func render(s section) string {
	var b strings.Builder
	for _, c := range s.cmds {
		b.WriteString(stCmd.Render("$ "+c) + "\n")
		b.WriteString(runOut(c, 4*time.Second) + "\n\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

// ─── the model ───────────────────────────────────────────────────────────

type contentMsg struct {
	idx  int
	body string
}
type probeMsg map[string]health
type tickMsg struct{}

type model struct {
	cursor  int
	content map[int]string
	healths map[string]health
	scroll  int
	w, h    int
	loading bool
}

func load(idx int) tea.Cmd {
	return func() tea.Msg { return contentMsg{idx, render(sections[idx])} }
}
func doProbe() tea.Cmd {
	return func() tea.Msg { return probeMsg(probe()) }
}
func tick() tea.Cmd {
	return tea.Tick(5*time.Second, func(time.Time) tea.Msg { return tickMsg{} })
}

func (m model) Init() tea.Cmd {
	return tea.Batch(load(0), doProbe(), tick())
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
	case contentMsg:
		m.content[msg.idx] = msg.body
		if msg.idx == m.cursor {
			m.loading = false
		}
	case probeMsg:
		m.healths = msg
	case tickMsg:
		return m, tea.Batch(load(m.cursor), doProbe(), tick())
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "j", "down":
			if m.cursor < len(sections)-1 {
				m.cursor++
				m.scroll = 0
				m.loading = m.content[m.cursor] == ""
				return m, load(m.cursor)
			}
		case "k", "up":
			if m.cursor > 0 {
				m.cursor--
				m.scroll = 0
				m.loading = m.content[m.cursor] == ""
				return m, load(m.cursor)
			}
		case "r":
			m.loading = true
			return m, tea.Batch(load(m.cursor), doProbe())
		case "pgdown", "f":
			m.scroll += 10
		case "pgup", "b":
			m.scroll = max(0, m.scroll-10)
		case "g":
			m.scroll = 0
		}
	}
	return m, nil
}

func (m model) View() string {
	if m.w == 0 {
		return "starting…"
	}
	head := stTitle.Render("sysdiag") +
		stDim.Render("  "+version+" · local-OS observability · refresh 5s")
	if m.loading {
		head += stDim.Render(" · running…")
	}

	// left: section list with health dots
	var left []string
	for i, s := range sections {
		dot := hNone.dot()
		if h, ok := m.healths[s.name]; ok {
			dot = h.dot()
		}
		line := fmt.Sprintf(" %s %s", dot, s.name)
		if i == m.cursor {
			line = stSel.Render(fmt.Sprintf("  %-13s", s.name))
		}
		left = append(left, line)
	}
	leftBox := lipgloss.NewStyle().Width(17).Render(strings.Join(left, "\n"))

	// right: the dossier, scrolled
	body := m.content[m.cursor]
	lines := strings.Split(body, "\n")
	if m.scroll >= len(lines) {
		m.scroll = max(0, len(lines)-1)
	}
	visible := lines[m.scroll:]
	maxLines := m.h - 4
	if len(visible) > maxLines {
		visible = visible[:maxLines]
	}
	rightBox := lipgloss.NewStyle().Width(max(20, m.w-20)).
		Render(strings.Join(visible, "\n"))

	foot := stFooter.Render("j/k section · f/b scroll · g top · r refresh · q quit")
	return head + "\n\n" +
		lipgloss.JoinHorizontal(lipgloss.Top, leftBox, rightBox) + "\n" + foot
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "--version" || os.Args[1] == "-V") {
		fmt.Println("sysdiag " + version)
		return
	}
	m := model{content: map[int]string{}, healths: map[string]health{}, loading: true}
	if _, err := tea.NewProgram(m, tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
