// kld — the kldload operator console, in a terminal.
//
// One binary, the same eight sections as the web console on :8443, read from
// the same tools: kldload-estate, kldload-doctor, zpool, kldload-rollback,
// wg, kubectl, Prometheus and kldload-netboot-server. It is a hub, not a
// fifth console: the deep views stay in vmxplore, zxplore and wgx, and this
// tool opens them on Enter and comes back when they exit.
//
//	kld                      the terminal console
//	kld <section> [sub]      open on that section and sub-tab
//	kld --gui [section]      this console in a terminal window (the GUI is the TUI)
//	kld <section> --print    print that sub-tab once and exit (no TUI)
//	kld --version
//
// One app for both a window manager and a headless box (operator,
// 2026-09-26): the terminal console is the console, everywhere, and is the
// default even under a display — the operator typed `kld` on a desktop and
// got a Chrome window when they wanted the TUI (10:20 that day). --gui opens
// this console in a terminal window through kldload-term: the GUI is the
// TUI, so nothing drifts between them.
//
// WHY: on 2026-09-26 the estate had four terminal consoles with four key
// maps, and the answers an operator wants first — what is running, what
// drifted, what boots next, who is on the mesh, is the rack armed — lived in
// eight different commands. The web console got one sidebar by task; this
// is the same sidebar for ssh.
//
// Verbs here go through the shipped bash verbs (kvm-clone, kvm-delete,
// kvm-snap, kldload-netboot-server) so the TUI cannot drift from what the
// tests prove; nothing is re-implemented.
//
// Exit: 0; 2 on a usage error.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

const version = "0.1.0"

// buildNum is stamped by the Makefile / build-iso.sh (-X main.buildNum=…),
// the same way wgx and zxplore carry theirs.
var buildNum = ""

func versionFull() string {
	if buildNum == "" || buildNum == "0" {
		return version
	}
	return version + " b" + buildNum
}

func usage() {
	fmt.Print(`kld ` + versionFull() + ` — the kldload operator console (terminal)

  kld                       open the terminal console
  kld <section> [<sub-tab>] open on a section: overview machines storage
                            network cluster ansible helm metrics estate
                            provision — and one of its sub-tabs
  kld --gui [section]       this console in a terminal window (kldload-term;
                            needs a display) — the GUI is the TUI
  kld <section> [<sub-tab>] --print
                            print that sub-tab once and exit
  kld screen <vm> [--blocks|--sixel]
                            the VM's display full-screen in this terminal:
                            sixels where the terminal draws them (never under
                            tmux unless --sixel), half-block cells otherwise
                            (--blocks forces them); ctrl+] is the menu, d
                            detaches
  kld install               the install menu: profile, distribution, security,
                            disk, hostname, user — then the unattended
                            installer; or provision another machine
  kld --version

Keys inside:  1-9, 0  section   tab  sub-tab   j/k  row   enter  drill in
(a VM's or a dataset's snapshots)   /  filter   o  sort   i  detail pane
r  reload   ?  the verbs of the current tab   q  quit
Verbs run the shipped commands (virsh, kvm-*, zfs, kldload-rollback,
kldload-enroll, kubectl, ansible, helm, kldload-netboot-server); the
destructive ones ask for the name to be typed back.
`)
}

func main() {
	args := os.Args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "-h", "--help", "help":
			usage()
			return
		case "--version", "-V":
			fmt.Println("kld " + versionFull())
			return
		case "install":
			// the install menu: the live medium's boot target
			if err := runInstallMenu(); err != nil {
				fmt.Fprintln(os.Stderr, "kld install:", err)
				os.Exit(1)
			}
			return
		case "screen":
			// a VM's display, full-screen in this terminal (screen.go)
			if err := runScreen(args[1:]); err != nil {
				fmt.Fprintln(os.Stderr, "kld screen:", err)
				os.Exit(1)
			}
			return
		}
	}
	start, sub := 0, 0
	print, gui, sawSection := false, false, false
	for _, a := range args {
		switch a {
		case "--print":
			print = true
			continue
		case "--gui":
			gui = true
			continue
		case "--tui": // the old default's opt-out, kept as a no-op alias
			continue
		}
		// a sub-tab of the section already named wins over a section of the
		// same name: `kld metrics machines` is Metrics/Machines, not Machines
		if sawSection {
			if j := subIndex(start, a); j >= 0 {
				sub = j
				continue
			}
		}
		if i := sectionIndex(a); i >= 0 {
			start, sub, sawSection = i, 0, true
			continue
		}
		if j := subIndex(start, a); j >= 0 {
			sub = j
			continue
		}
		fmt.Fprintf(os.Stderr, "kld: no section or sub-tab named %q (sections: %s; sub-tabs of %s: %s)\n",
			a, strings.Join(sectionNames(), " "), sections[start].name, strings.ToLower(strings.Join(sections[start].subs, " ")))
		os.Exit(2)
	}
	if print {
		// One sub-tab, rendered once, for scripts and for testing the
		// renderers without a terminal: body() is pure, so what --print
		// shows is what the TUI shows.
		m := newModel(start, sub, 120)
		m.apply(loadSection(start, sub, ""))
		fmt.Print(m.body())
		return
	}
	if gui && !print {
		if err := openWindow(start); err != nil {
			fmt.Fprintln(os.Stderr, "kld:", err, "— starting the terminal console")
		} else {
			return
		}
	}
	if _, err := tea.NewProgram(newModel(start, sub, 0), tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintln(os.Stderr, "kld:", err)
		os.Exit(1)
	}
}

// ── the window ──────────────────────────────────────────────────────────────

var errNoDisplay = errors.New("no display")

// openWindow is the GUI: this same console in a terminal window, opened by
// kldload-term --app (the wrapper every terminal launcher on a kldload host
// uses: whichever emulator the distro ships, full screen, closes on quit).
// One program for a window manager and a headless box, and nothing to
// drift between them (operator, 2026-09-26: "no web gui at all"). It
// returns errNoDisplay when there is nothing to draw on, and any other
// error when the wrapper is missing, so the caller falls back to the
// terminal it is already in.
func openWindow(section int) error {
	if os.Getenv("DISPLAY") == "" && os.Getenv("WAYLAND_DISPLAY") == "" {
		return errNoDisplay
	}
	wrapper, err := exec.LookPath("kldload-term")
	if err != nil {
		return errors.New("kldload-term is not installed")
	}
	self, err := os.Executable()
	if err != nil {
		self = "kld"
	}
	c := exec.Command(wrapper, "--app", self, "--tui", strings.ToLower(sections[section].name))
	c.Stdin = os.Stdin
	return c.Run()
}
