// kld — the kldload operator console, in a terminal.
//
// One binary, the same eight sections as the web console on :8443, read from
// the same tools: kldload-estate, kldload-doctor, zpool, kldload-rollback,
// wg, kubectl, Prometheus and kldload-netboot-server. It is a hub, not a
// fifth console: the deep views stay in vmxplore, zxplore and wgx, and this
// tool opens them on Enter and comes back when they exit.
//
//	kld                      the console
//	kld <section>            open on that section (overview, machines, storage,
//	                         network, cluster, metrics, estate, provision)
//	kld <section> --print    print that section once and exit (no TUI)
//	kld --version
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
	"fmt"
	"os"
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

  kld                       open the console
  kld <section>             open on a section: overview machines storage
                            network cluster metrics estate provision
  kld <section> --print     print that section once and exit
  kld --version

Keys inside:  1-8 or Tab  section   j/k  move   r  reload   Enter  open the
deep console for the section (vmxplore, zxplore, wgx, k9s)   c  clone the
selected machine   s  snapshot it   d  delete it   ?  help   q  quit
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
	start := 0
	print := false
	for _, a := range args {
		if a == "--print" {
			print = true
			continue
		}
		i := sectionIndex(a)
		if i < 0 {
			fmt.Fprintf(os.Stderr, "kld: no section named %q (try: %s)\n", a, strings.Join(sectionNames(), " "))
			os.Exit(2)
		}
		start = i
	}
	if print {
		// One section, rendered once, for scripts and for testing the
		// renderers without a terminal: View() is pure, so what --print
		// shows is what the TUI shows.
		m := newModel(start, 120)
		m.apply(loadSection(start))
		fmt.Print(m.body())
		return
	}
	if _, err := tea.NewProgram(newModel(start, 0), tea.WithAltScreen()).Run(); err != nil {
		fmt.Fprintln(os.Stderr, "kld:", err)
		os.Exit(1)
	}
}
