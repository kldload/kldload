// main.go — entry point for vmxplore, the ZFS-aware VM console.
//
// Console #3 in the xplore family (zxplore, wgxplore, vmxplore): the one
// keyboard-driven view that joins every libvirt domain to the zvol under it —
// clone ancestry, snapshot classes, live counters. Design + phasing:
// docs/VM-CONSOLE-DESIGN.md (kldload repo, the Phase A home).
//
//	vmx            → estate TUI (bubbletea)
//	vmx --once     → print the estate table once and exit (scripts, smoke)
//	vmx --rules F  → use rules file F for grouping/classification
//	vmx --version  → version and exit
//
// Tiers, capability-detected (never identity-gated): any libvirt host gets a
// full read console; zvol-backed disks light up the ZFS join; kldload hosts
// get the kldload ruleset + register reconciliation. Reads are side-effect
// free; the 0.2 verbs confirm-gate and audit-log every mutation (verbs.go).
//
// Privilege: qemu:///system needs root or the libvirt group. If the first
// connect is refused and we're on a tty, re-exec once under sudo (root
// inherits the tty — same pattern as zxplore's elevate()).
package main

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"

	"golang.org/x/term"
)

// version is the vmxplore release (shown by --version). Phase/versioning per
// the design doc: 0.1 = read-only estate view; 0.2 = the safe verbs.
const version = "0.2.0"

// build is stamped by the Makefile via -X main.build (UTC minute + git short
// hash) so every binary is distinguishable — the TUI title and --version both
// show it. A bare `go build` leaves it at "dev".
var build = "dev"

// versionString is the full "0.2.0+20260807.2153.abc1234" form shown in the
// TUI title bar and by --version.
func versionString() string {
	return version + "+" + build
}

const usage = `usage: vmx [--once] [--rules FILE] [--version]

  (no flags)   estate TUI — the joined libvirt + ZFS view
  --once       print the estate table once and exit
  --rules F    grouping/classification rules file
               (default: /etc/vmxplore/rules, else built-in profile)
  --version    print version and exit

Environment:
  VMX_SSH_USER   user for the TUI's ssh-to-guest verb
                 (default: current user; admin on a kldload host)

Reading is free of side effects. Mutations exist only behind the TUI's verb
keys (start/stop, force-off, snapshot, rollback, vcpu/mem, autostart): each
shows the exact virsh/zfs command and asks first, the dangerous ones require
retyping the domain name, and every run is appended to the audit log
(/var/log/kldload/vmx.log, else ~/.local/state/vmxplore/vmx.log).

Documentation: docs/VM-CONSOLE-DESIGN.md`

func main() {
	once := false
	rulesPath := ""
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--version", "-V":
			fmt.Println("vmxplore " + versionString())
			return
		case "--help", "-h":
			fmt.Println(usage)
			return
		case "--once":
			once = true
		case "--rules", "-r":
			i++
			if i >= len(args) {
				fmt.Fprintln(os.Stderr, "vmx: --rules needs a file argument")
				os.Exit(2)
			}
			rulesPath = args[i]
		default:
			fmt.Fprintf(os.Stderr, "vmx: unknown option %q\n%s\n", args[i], usage)
			os.Exit(2)
		}
	}

	rs, err := LoadRules(rulesPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "vmx: rules: %v\n", err)
		os.Exit(1)
	}

	if once {
		os.Exit(runOnce(rs))
	}

	lv, err := ConnectSystem()
	if err != nil {
		maybeElevate(err) // re-execs and never returns when it can help
		fmt.Fprintf(os.Stderr, "vmx: libvirt: %v\n"+
			"hint: qemu:///system needs root or the libvirt group\n", err)
		os.Exit(1)
	}
	defer lv.Close()

	if err := runTUI(lv, rs); err != nil {
		fmt.Fprintf(os.Stderr, "vmx: %v\n", err)
		os.Exit(1)
	}
}

// maybeElevate re-execs under sudo after a refused libvirt connect — once
// (VMX_ELEVATED guards the loop), only on a tty (sudo needs one to prompt),
// and never as root (a root refusal is a different problem worth seeing).
func maybeElevate(connectErr error) {
	if os.Geteuid() == 0 || os.Getenv("VMX_ELEVATED") != "" ||
		!term.IsTerminal(int(os.Stdin.Fd())) {
		return
	}
	sudo, err := exec.LookPath("sudo")
	if err != nil {
		return
	}
	fmt.Fprintf(os.Stderr,
		"vmx: libvirt refused the connection (%v) — retrying with sudo\n",
		connectErr)
	env := append(os.Environ(), "VMX_ELEVATED=1")
	argv := append([]string{sudo, "--preserve-env=VMX_ELEVATED,VMX_SSH_USER"},
		os.Args...)
	// error path falls through to main's normal failure message
	_ = syscall.Exec(sudo, argv, env)
}
