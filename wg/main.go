// wgxplore — the WireGuard estate console.
//
// A read-first lens over one protocol: sweep every host you can ssh to, join
// their interfaces and peers into one view, and say which tunnels are alive,
// which peers belong to nobody, and which links only exist from one side.
//
//	wgx                       the console (GUI, or TUI where there is no GL)
//	wgx estate                the whole estate as a text tree
//	wgx check                 orphaned peers and one-way links
//	wgx show                  peer dossiers for this host
//	wgx attach <iface> <ctr>  move a live wg interface into a container netns
//
// WHY there is no `net create`: this console does not mint keys and cannot
// declare a network. kldload generates a keypair per host at install time,
// so the private key never crosses a filesystem or network boundary and
// dies with the machine — the right design for cattle, and one a central
// declaration store can only weaken. Dropping the minting half is what lets
// this tool adopt networks it did not build: a kldload cluster, a
// hand-rolled wg0.conf, a stranger's box. See roster.go for how membership
// is derived from the estate itself, with no registry to keep in sync.
//
// Remote hosts come from ~/.ssh/config (or /etc/wgx/hosts); the far side
// needs only sshd and wg. Reads elevate through sudo -n then pkexec, never
// by re-executing themselves as root.
package main

import (
	"fmt"
	"os"
)

const version = "0.2.0"

// buildNum is stamped by the Makefile (-X main.buildNum=<n>) from the
// self-incrementing .buildnum counter — same mechanism zxplore uses, so
// "which build am I looking at" is answerable on a box you did not build.
var buildNum = ""

// versionFull is version plus the build stamp: "0.2.0 b7".
func versionFull() string {
	if buildNum == "" || buildNum == "0" {
		return version
	}
	return version + " b" + buildNum
}

func usage() {
	fmt.Print(`wgxplore ` + versionFull() + ` — the WireGuard estate console

  wgx                                    open the console (GUI, or TUI)
  wgx tui                                force the terminal console
  wgx estate                             the whole estate as a text tree
  wgx check                              orphaned peers and one-way links
  wgx show                               peer dossiers for this host
  wgx attach <iface> <container>         move a live wg interface into a
                                         container's network namespace (root)

This console reads; it does not mint keys or declare networks. Hosts
generate their own keypairs, so it adopts whatever is already running —
kldload clusters, hand-rolled configs, hosts it has never seen.

Inventory comes from /etc/wgx/hosts if present, else ~/.ssh/config.
The far side needs only sshd and wg.
`)
}

func main() {
	a := os.Args[1:]
	var err error
	switch {
	case len(a) == 0:
		// Default: native window in the GUI build, TUI in the static one.
		if err = RunGUI(); err != nil {
			err = RunTUI()
		}
	case a[0] == "-h", a[0] == "--help":
		usage()
	case a[0] == "--version", a[0] == "-V":
		fmt.Println("wgxplore " + versionFull())
	case a[0] == "tui":
		err = RunTUI()
	case a[0] == "gui":
		err = RunGUI()
	case a[0] == "dump":
		// Privileged helper: pkexec target for the GUI/TUI running as a
		// normal user. Prints the raw `wg show all dump` and nothing else.
		err = cmdDump()
	case a[0] == "estate":
		err = PrintEstate()
	case a[0] == "check":
		err = cmdCheck()
	case a[0] == "show":
		err = cmdShow()
	case a[0] == "attach" && len(a) >= 3:
		err = cmdAttach(a[1], a[2])
	default:
		usage()
		os.Exit(64)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "\x1b[1;31m✗ %v\x1b[0m\n", err)
		os.Exit(1)
	}
}
