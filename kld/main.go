// kld — the kldload operator console, in a terminal.
//
// One binary, the same eight sections as the web console on :8443, read from
// the same tools: kldload-estate, kldload-doctor, zpool, kldload-rollback,
// wg, kubectl, Prometheus and kldload-netboot-server. It is a hub, not a
// fifth console: the deep views stay in vmxplore, zxplore and wgx, and this
// tool opens them on Enter and comes back when they exit.
//
//	kld                      the console: a window under a display, the
//	                         terminal console otherwise
//	kld <section>            open on that section (overview, machines, storage,
//	                         network, cluster, metrics, estate, provision)
//	kld --tui [section]      the terminal console even under a display
//	kld <section> --print    print that section once and exit (no TUI)
//	kld --version
//
// One app for both a window manager and a headless box (operator,
// 2026-09-26): under a display the window IS the web console, hosted by
// kldload-chrome-app as a standalone app window, so a desktop and a browser
// see the same console from one codebase; the terminal gets this TUI. A
// second native copy of every view would drift from the web console within
// a week, so there is none.
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

  kld                       open the console: a window under a display,
                            the terminal console otherwise
  kld <section> [<sub-tab>] open on a section: overview machines storage
                            network cluster ansible helm metrics estate
                            provision — and one of its sub-tabs
  kld --tui [section]       the terminal console even under a display
  kld <section> [<sub-tab>] --print
                            print that sub-tab once and exit
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
		}
	}
	start, sub := 0, 0
	print, tui := false, false
	for _, a := range args {
		if a == "--print" {
			print = true
			continue
		}
		if a == "--tui" {
			tui = true
			continue
		}
		if i := sectionIndex(a); i >= 0 {
			start, sub = i, 0
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
	if !tui && !print {
		if err := openWindow(start); err == nil {
			return
		} else if err != errNoDisplay {
			fmt.Fprintln(os.Stderr, "kld:", err, "— starting the terminal console")
		}
	}
	if _, err := tea.NewProgram(newModel(start, sub, 0), tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintln(os.Stderr, "kld:", err)
		os.Exit(1)
	}
}

// ── the window ──────────────────────────────────────────────────────────────

var errNoDisplay = errors.New("no display")

// spaView maps a section to the web console's view id in the URL hash.
var spaView = map[string]string{
	"Overview": "overview", "Machines": "vms", "Storage": "zfs", "Network": "network",
	"Cluster": "k8s", "Metrics": "metrics", "Estate": "estate", "Provision": "provision",
}

// openWindow hands off to kldload-chrome-app, the wrapper every desktop
// launcher on a kldload host already uses (a dedicated Chrome profile, the
// window class the .desktop file names, the localhost cert trusted). It
// returns errNoDisplay when there is nothing to draw on, and any other error
// when the wrapper is missing, so the caller falls back to the terminal.
func openWindow(section int) error {
	if os.Getenv("DISPLAY") == "" && os.Getenv("WAYLAND_DISPLAY") == "" {
		return errNoDisplay
	}
	wrapper, err := exec.LookPath("kldload-chrome-app")
	if err != nil {
		return errors.New("kldload-chrome-app is not installed (desktop profile only)")
	}
	url := "https://localhost:8443/?app=1#" + spaView[sections[section].name]
	c := exec.Command(wrapper, "com.kldload.console", url)
	c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
	return c.Run()
}
