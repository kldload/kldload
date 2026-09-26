// install.go — `kld install`: the netboot menu's questions, on this machine.
//
// One installer exists, the unattended one driven by an answers file; the
// iPXE menu asks profile, distribution and security for a PXE client and
// writes that file. This is the same questions on the console of a machine
// booted from the USB, plus the ones the client gets from the network (disk,
// hostname, user, password), written to the same file and handed to the
// same `kldload-install-target --config`. Both doors write one format, so
// they cannot drift (operator, 2026-09-26: "the boot/net menu as the only
// installer, local and remote").
//
// The second branch, "provision another machine", is the Provision section
// of the console: arm a MAC or open mode through kldload-netboot-server.
//
// KLD_INSTALL_DRYRUN=1 writes the answers file and prints it (secrets
// redacted) instead of running the installer — the test hook.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const answersPath = "/run/kldload/answers.env"

type choice struct{ key, label, note string }

var profiles = []choice{
	{"core", "Core", "ZFS on root, the tools, nothing else"},
	{"server", "Server", "headless: ssh, mesh, monitoring"},
	{"desktop", "Desktop", "GNOME workstation with every console"},
	{"kvm", "KVM host", "a hypervisor: libvirt, goldens, klab"},
	{"k8s", "Kubernetes", "KVM host plus a 3-control-plane cluster in VMs"},
	{"storage", "Storage", "ZFS storage server: NFS, SMB, iSCSI over the mesh"},
	{"ai", "AI", "KVM host plus Ollama and Bob"},
}

var distros = []choice{
	{"fedora", "Fedora 44", ""}, {"debian", "Debian 13", ""}, {"ubuntu", "Ubuntu 24.04", ""},
	{"rocky", "Rocky Linux 10", ""}, {"centos", "CentOS Stream 10", ""}, {"rhel", "RHEL 10", "needs a subscription key"},
}

var securities = []choice{
	{"standard", "Standard", "not encrypted, Secure Boot off"},
	{"encrypted", "Encrypted", "ZFS native encryption, passphrase at boot"},
	{"secureboot", "Secure Boot", "shim + MOK, the CA enrolled at first boot"},
	{"both", "Encrypted + Secure Boot", "the whole posture"},
}

// darksiteDistros says which distributions this medium installs offline:
// the mirrors under /root/darksite. EL (rocky, centos, rhel) has no mirror
// and installs from the network.
func darksiteDistros() map[string]bool {
	have := map[string]bool{}
	for _, d := range []string{"fedora", "debian", "arch"} {
		if st, err := os.Stat("/root/darksite/" + d); err == nil && st.IsDir() {
			have[d] = true
		}
	}
	return have
}

func listDisks() []choice {
	out, err := run(10e9, "lsblk", "-d", "-e7,11", "-n", "-o", "PATH,SIZE,MODEL")
	if err != nil {
		return nil
	}
	var ds []choice
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		// zvols (zd*) are a hypervisor's guest disks and zram is memory;
		// neither is an install target. Nor is the disk the live medium
		// itself sits on.
		if strings.HasPrefix(f[0], "/dev/zd") || strings.HasPrefix(f[0], "/dev/zram") || f[0] == liveMediumDisk() {
			continue
		}
		ds = append(ds, choice{f[0], f[0] + "  " + f[1], strings.Join(f[2:], " ")})
	}
	return ds
}

// liveMediumDisk is the whole disk behind the live medium's mount, or "".
func liveMediumDisk() string {
	for _, m := range []string{"/run/initramfs/live", "/run/live/medium", "/lib/live/mount/medium"} {
		src, err := run(5e9, "findmnt", "-n", "-o", "SOURCE", m)
		if err != nil || strings.TrimSpace(src) == "" {
			continue
		}
		pk, err := run(5e9, "lsblk", "-no", "PKNAME", strings.TrimSpace(src))
		if err == nil && strings.TrimSpace(pk) != "" {
			return "/dev/" + strings.Fields(pk)[0]
		}
		return strings.TrimSpace(src)
	}
	return ""
}

type step int

const (
	stMenu step = iota
	stProfile
	stDistro
	stSecurity
	stDisk
	stHostname
	stUsername
	stPassword
	stPassword2
	stPassphrase
	stSummary
	stRunning
	stDone
)

type installModel struct {
	step     step
	cursor   int
	width    int
	height   int
	profile  string
	distro   string
	security string
	disk     string
	hostname string
	username string
	password string
	pass2    string
	passph   string
	input    textinput.Model
	err      string
	rc       int
	disks    []choice
	offline  map[string]bool
	dryrun   bool
	written  string
}

type installDoneMsg struct{ err error }

func newInstallModel() installModel {
	in := textinput.New()
	in.CharLimit = 64
	return installModel{input: in, disks: listDisks(), offline: darksiteDistros(),
		dryrun: os.Getenv("KLD_INSTALL_DRYRUN") == "1", hostname: "kldload", username: "admin"}
}

func (m installModel) Init() tea.Cmd { return nil }

func (m installModel) choices() []choice {
	switch m.step {
	case stMenu:
		return []choice{{"install", "Install this machine", "the questions the netboot menu asks, then the unattended installer"},
			{"provision", "Provision another machine", "arm a MAC or open mode: it netboots from this medium and installs"},
			{"console", "Operator console", "look around: machines, storage, mesh, estate"},
			{"shell", "Shell", "a root shell"}}
	case stProfile:
		return profiles
	case stDistro:
		out := make([]choice, len(distros))
		for i, d := range distros {
			out[i] = d
			if m.offline[d.key] {
				out[i].note = strings.TrimSpace("offline, from this medium · " + d.note)
			} else if d.note == "" {
				out[i].note = "from the network"
			} else {
				out[i].note = "from the network · " + d.note
			}
		}
		return out
	case stSecurity:
		return securities
	case stDisk:
		return m.disks
	}
	return nil
}

func (m installModel) textStep() bool {
	switch m.step {
	case stHostname, stUsername, stPassword, stPassword2, stPassphrase:
		return true
	}
	return false
}

func (m *installModel) startText(placeholder, value string, secret bool) tea.Cmd {
	m.input.SetValue(value)
	m.input.Placeholder = placeholder
	if secret {
		m.input.EchoMode = textinput.EchoPassword
	} else {
		m.input.EchoMode = textinput.EchoNormal
	}
	m.input.Focus()
	return textinput.Blink
}

func (m installModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil
	case installDoneMsg:
		m.step = stDone
		if msg.err != nil {
			m.err = msg.err.Error()
			m.rc = 1
		}
		return m, nil
	case tea.KeyMsg:
		if msg.String() == "ctrl+c" {
			return m, tea.Quit
		}
		if m.textStep() {
			return m.updateText(msg)
		}
		switch msg.String() {
		case "q":
			if m.step == stMenu || m.step == stDone {
				return m, tea.Quit
			}
		case "j", "down":
			if m.cursor < len(m.choices())-1 {
				m.cursor++
			}
		case "k", "up":
			if m.cursor > 0 {
				m.cursor--
			}
		case "esc", "left", "h":
			if m.step > stMenu && m.step < stRunning {
				m.step--
				m.cursor = 0
				m.err = ""
				if m.textStep() {
					return m, m.startText("", m.textValue(), m.step >= stPassword)
				}
			}
		case "enter", " ":
			return m.pick()
		case "r":
			if m.step == stDone && m.rc == 0 && !m.dryrun {
				c := exec.Command("sudo", "-n", "systemctl", "reboot")
				return m, tea.ExecProcess(c, func(error) tea.Msg { return tea.Quit() })
			}
		}
	}
	return m, nil
}

func (m installModel) textValue() string {
	switch m.step {
	case stHostname:
		return m.hostname
	case stUsername:
		return m.username
	}
	return ""
}

func (m installModel) updateText(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.step--
		m.cursor = 0
		m.err = ""
		return m, nil
	case "enter":
		v := strings.TrimSpace(m.input.Value())
		switch m.step {
		case stHostname:
			if !nameOK(v) {
				m.err = "a hostname is letters, digits and dashes"
				return m, nil
			}
			m.hostname = v
			m.step = stUsername
			return m, m.startText("admin", m.username, false)
		case stUsername:
			if !nameOK(v) || v == "root" {
				m.err = "a user name is letters, digits and dashes, not root"
				return m, nil
			}
			m.username = v
			m.step = stPassword
			return m, m.startText("password for "+v, "", true)
		case stPassword:
			if len(v) < 4 {
				m.err = "four characters at least"
				return m, nil
			}
			m.password = v
			m.step = stPassword2
			return m, m.startText("the same password again", "", true)
		case stPassword2:
			if v != m.password {
				m.err = "the passwords differ"
				m.step = stPassword
				return m, m.startText("password for "+m.username, "", true)
			}
			m.err = ""
			if m.security == "encrypted" || m.security == "both" {
				m.step = stPassphrase
				return m, m.startText("ZFS passphrase, asked at every boot", "", true)
			}
			m.step = stSummary
			return m, nil
		case stPassphrase:
			if len(v) < 8 {
				m.err = "eight characters at least"
				return m, nil
			}
			m.passph = v
			m.err = ""
			m.step = stSummary
			return m, nil
		}
	}
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	return m, cmd
}

func (m installModel) pick() (tea.Model, tea.Cmd) {
	cs := m.choices()
	switch m.step {
	case stMenu:
		switch cs[m.cursor].key {
		case "install":
			m.step, m.cursor = stProfile, 0
		case "provision":
			c := exec.Command(os.Args[0], "--tui", "provision")
			c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
			return m, tea.ExecProcess(c, func(error) tea.Msg { return nil })
		case "console":
			c := exec.Command(os.Args[0], "--tui")
			c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
			return m, tea.ExecProcess(c, func(error) tea.Msg { return nil })
		case "shell":
			c := exec.Command("bash", "-l")
			c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
			return m, tea.ExecProcess(c, func(error) tea.Msg { return nil })
		}
	case stProfile:
		m.profile = cs[m.cursor].key
		m.step, m.cursor = stDistro, 0
	case stDistro:
		m.distro = cs[m.cursor].key
		m.step, m.cursor = stSecurity, 0
	case stSecurity:
		m.security = cs[m.cursor].key
		m.step, m.cursor = stDisk, 0
		if len(m.disks) == 0 {
			m.err = "no disks found (lsblk) — nothing to install to"
			m.step = stSecurity
		}
	case stDisk:
		m.disk = cs[m.cursor].key
		m.step = stHostname
		return m, m.startText("kldload", m.hostname, false)
	case stSummary:
		m.step = stRunning
		return m, m.runInstall()
	}
	return m, nil
}

// answers renders the file the unattended installer reads: the keys the
// iPXE menu writes for a PXE client, one per line, quoted.
func (m installModel) answers() string {
	enc, sb := "0", "0"
	switch m.security {
	case "encrypted":
		enc = "1"
	case "secureboot":
		sb = "1"
	case "both":
		enc, sb = "1", "1"
	}
	q := func(s string) string { return `"` + strings.ReplaceAll(s, `"`, "") + `"` }
	lines := []string{
		"# written by kld install " + versionFull() + " — the console's install menu",
		"KLDLOAD_PROFILE=" + q(m.profile),
		"KLDLOAD_DISTRO=" + q(m.distro),
		"KLDLOAD_DISK=" + q(m.disk),
		"KLDLOAD_HOSTNAME=" + q(m.hostname),
		"KLDLOAD_USERNAME=" + q(m.username),
		"KLDLOAD_PASSWORD=" + q(m.password),
		"KLDLOAD_STORAGE_MODE=zfs",
		"KLDLOAD_ENABLE_ZFS=1",
		"KLDLOAD_ZFS_TOPOLOGY=single",
		"KLDLOAD_ZFS_ENCRYPT=" + enc,
		"KLDLOAD_ENABLE_SECURE_BOOT=" + sb,
	}
	if enc == "1" {
		lines = append(lines, "KLDLOAD_ZFS_PASSPHRASE="+q(m.passph))
	}
	return strings.Join(lines, "\n") + "\n"
}

func (m installModel) runInstall() tea.Cmd {
	path := answersPath
	if m.dryrun {
		path = filepath.Join(os.TempDir(), "kld-install-dryrun.env")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return func() tea.Msg { return installDoneMsg{err} }
	}
	// 0600 from creation: the file carries the password and the passphrase
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return func() tea.Msg { return installDoneMsg{err} }
	}
	if _, err := f.WriteString(m.answers()); err != nil {
		_ = f.Close()
		return func() tea.Msg { return installDoneMsg{err} }
	}
	_ = f.Close()
	if m.dryrun {
		return func() tea.Msg { return installDoneMsg{nil} }
	}
	c := exec.Command("sudo", "-n", "kldload-install-target", "--config", path)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	return tea.ExecProcess(c, func(err error) tea.Msg { return installDoneMsg{err} })
}

func (m installModel) View() string {
	var b strings.Builder
	b.WriteString(stBrand.Render("kldload") + stDim.Render("  install · "+versionFull()) + "\n\n")
	title := map[step]string{
		stMenu: "What is this machine for?", stProfile: "Profile", stDistro: "Distribution",
		stSecurity: "Security", stDisk: "Install to which disk? (everything on it is erased)",
		stHostname: "Hostname", stUsername: "Admin user", stPassword: "Password", stPassword2: "Password, again",
		stPassphrase: "ZFS encryption passphrase", stSummary: "Ready to install", stRunning: "Installing", stDone: "Done",
	}[m.step]
	b.WriteString(stTitle.Render(title) + "\n\n")
	switch {
	case m.step == stSummary:
		rows := [][2]string{{"profile", m.profile}, {"distribution", m.distro}, {"security", m.security}, {"disk", m.disk},
			{"hostname", m.hostname}, {"user", m.username}, {"password", strings.Repeat("•", len(m.password))}}
		if m.passph != "" {
			rows = append(rows, [2]string{"passphrase", strings.Repeat("•", len(m.passph))})
		}
		for _, r := range rows {
			b.WriteString("  " + stDim.Render(fmt.Sprintf("%-13s", r[0])) + r[1] + "\n")
		}
		b.WriteString("\n" + stWarn.Render("  enter installs — "+m.disk+" is erased") + stDim.Render("   esc goes back") + "\n")
	case m.step == stRunning:
		b.WriteString(stDim.Render("  the installer has the terminal…") + "\n")
	case m.step == stDone:
		if m.dryrun {
			b.WriteString(stGood.Render("  dry run: answers written to "+filepath.Join(os.TempDir(), "kld-install-dryrun.env")) + "\n")
		} else if m.rc == 0 && m.err == "" {
			b.WriteString(stGood.Render("  installed. ") + stKey.Render("r") + stDim.Render(" reboots into it · ") + stKey.Render("q") + stDim.Render(" stays here") + "\n")
		} else {
			b.WriteString(stBad.Render("  the installer failed: "+m.err) + "\n" + stDim.Render("  the log is /var/log/installer/ · q for the menu") + "\n")
		}
	case m.textStep():
		b.WriteString("  " + m.input.View() + "\n")
	default:
		for i, c := range m.choices() {
			// pad the plain text, then colour it: a styled string counts its
			// escape codes toward %-26s and the note lands on the label
			mark, label := "  ", fmt.Sprintf("%-26s", c.label)
			if i == m.cursor {
				mark, label = stKey.Render("▸ "), stKey.Render(label)
			}
			line := mark + label
			if c.note != "" {
				line += stDim.Render(c.note)
			}
			b.WriteString(line + "\n")
		}
	}
	if m.err != "" {
		b.WriteString("\n" + stBad.Render("  "+m.err) + "\n")
	}
	b.WriteString("\n" + stDim.Render("  j/k choose · enter next · esc back · ctrl+c quit") + "\n")
	return lipgloss.NewStyle().Padding(1, 2).Render(b.String())
}

func runInstallMenu() error {
	_, err := tea.NewProgram(newInstallModel(), tea.WithAltScreen()).Run()
	return err
}
