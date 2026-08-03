// wgxplore — the WireGuard networks console.
//
// Sister project to zxplore: same console shape, same primitives ethos, one
// domain over. Declare networks, attach anything to them (hosts, containers
// via the kernel's netns move, VMs), and see the whole estate — every device,
// every peer, handshake-fresh or stale — in one keyboard-driven view.
//
// Nothing here is a control plane: declarations are plain files, every
// mutation shells out to wg/ip and echoes the exact command first, and remote
// hosts are reached over plain ssh with ~/.ssh/config as the inventory.
//
//	wgx                       the console (TUI)
//	wgx show                  peer dossiers, one-shot
//	wgx net create|add|render|up
//	wgx attach <net> <container> <member>
//
// Design: docs/WG-NETWORKS-DESIGN.md in the kldload repo.
package main

import (
	"fmt"
	"os"
)

const version = "0.1.0"

func usage() {
	fmt.Print(`wgxplore ` + version + ` — the WireGuard networks console

  wgx                                          open the console (GUI, or TUI)
  wgx tui                                      force the terminal console
  wgx show                                     peer dossiers, one-shot (root)
  wgx net create <name> [--subnet CIDR] [--topology mesh|hub-spoke] [--port N]
  wgx net add <name> <member> [--endpoint host:port] [--hub]
  wgx net render <name>                        write per-member configs
  wgx net up <name> <member>                   bring this host up (root)
  wgx attach <net> <container> <member>        move iface into container netns

Declarations live in /etc/wgx/<name>.json — the file is the API.
Remote hosts come from ~/.ssh/config; the far side needs only sshd + wg.
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
		fmt.Println("wgxplore " + version)
	case a[0] == "tui":
		err = RunTUI()
	case a[0] == "gui":
		err = RunGUI()
	case a[0] == "show":
		err = cmdShow()
	case a[0] == "net" && len(a) >= 3 && a[1] == "create":
		err = cmdNetCreate(a[2], a[3:])
	case a[0] == "net" && len(a) >= 4 && a[1] == "add":
		err = cmdNetAdd(a[2], a[3], a[4:])
	case a[0] == "net" && len(a) >= 3 && a[1] == "render":
		err = cmdNetRender(a[2])
	case a[0] == "net" && len(a) >= 4 && a[1] == "up":
		err = cmdNetUp(a[2], a[3])
	case a[0] == "attach" && len(a) >= 4:
		err = cmdAttach(a[1], a[2], a[3])
	default:
		usage()
		os.Exit(64)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "\x1b[1;31m✗ %v\x1b[0m\n", err)
		os.Exit(1)
	}
}
