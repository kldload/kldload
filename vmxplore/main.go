// main.go — entry point for vmxplore, the ZFS-aware VM console.
//
// Console #3 in the xplore family (zxplore, wgxplore, vmxplore): the one
// keyboard-driven view that joins every libvirt domain to the zvol under it —
// clone ancestry, snapshot classes, live counters. Design + phasing:
// docs/VM-CONSOLE-DESIGN.md (kldload repo, the Phase A home).
//
//	vmx            → native GUI (Fyne) in the full build; the static
//	                 TUI-only build (no `gui` tag) starts the TUI instead
//	vmx --tui      → estate TUI (bubbletea) — headless / SSH / power use
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

// version is the vmxplore release (shown by --version and, short-form, in
// the TUI title / GUI header). Phase/versioning per the design doc: 0.1 =
// read-only estate view; 0.2 = the safe verbs; .1 = folds/themes/key model;
// .2 = the Fyne GUI surface (GUI-first, operator call 2026-08-07).
const version = "0.2.2"

// buildNum is stamped by the Makefile (-X main.buildNum=<n>) from the
// self-incrementing, gitignored .buildnum counter — the family scheme
// (zxplore/wgxplore identical). Empty in a bare `go build`.
var buildNum = ""

// versionFull is version plus the build stamp: "0.2.2 b42".
func versionFull() string {
	if buildNum == "" || buildNum == "0" {
		return version
	}
	return version + " b" + buildNum
}

const usage = `usage: vmx [--tui] [--once] [--connect DEST] [--rules FILE] [--version]
       vmx --appliances
       vmx --appliance NAME --vm VMNAME [KEY=VALUE ...]
       vmx --appliance-script NAME [KEY=VALUE ...]

  (no flags)   native GUI — the estate frame (list · console · details);
               static/terminal-only builds start the TUI instead
  --tui        estate TUI (bubbletea) — headless / SSH / power use
  --once       print the estate table once and exit
  --connect D  drive a remote hypervisor: a host (fiend.unixbox.net),
               user@host, or a full libvirt URI (qemu+ssh://host/system).
               Uses ssh — same key/known_hosts as your shell.
  --rules F    grouping/classification rules file
               (default: /etc/vmxplore/rules, else built-in profile)
  --version    print version and exit

Appliances — push-button self-hosted apps (Build ▸ Appliance… in the GUI):

  --appliances            list the catalog with each entry's fields
  --appliance N           deploy appliance N as a VM and exit. Options
                          describe the guest, KEY=VALUE configures the app
                          (see --appliances for each entry's keys):
                            --vm NAME     the VM's name (required)
                            --user U      guest login    (default: admin)
                            --password P  guest password
                            --ssh-key F   public key file
                                          (default: ~/.ssh/id_ed25519.pub)
                            --no-wait     return once the VM is defined
                          By default it waits for the first boot to finish
                          and prints the appliance's real URL on stdout.
  --appliance-script N    print the post-install script instead of building.
                          The output is a standalone bash installer: it needs
                          no vmxplore, no libvirt and no kldload, so it also
                          works by hand on any fresh cloud VM.

    vmx --appliance WriteFreely --vm blog \
        WF_SITE_NAME='My Blog' WF_ADMIN_USER=matt

    vmx --appliance-script WriteFreely WF_DOMAIN=blog.example.com

Environment:
  VMX_SSH_USER   user for the TUI's ssh-to-guest verb
                 (default: current user; admin on a kldload host)
  VMX_THEME      dark | light — override the terminal-background
                 auto-detection for the TUI palette

Reading is free of side effects. Mutations exist only behind the TUI's verb
keys (start/stop, force-off, snapshot, rollback, vcpu/mem, autostart): each
shows the exact virsh/zfs command and asks first, the dangerous ones require
retyping the domain name, and every run is appended to the audit log
(/var/log/kldload/vmx.log, else ~/.local/state/vmxplore/vmx.log).

Documentation: docs/VM-CONSOLE-DESIGN.md`

func main() {
	once := false
	tui := false
	rulesPath := ""
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--version", "-V":
			fmt.Println("vmxplore " + versionFull())
			return
		case "--help", "-h":
			fmt.Println(usage)
			return
		case "--once":
			once = true
		case "--tui":
			tui = true
		case "--rules", "-r":
			i++
			if i >= len(args) {
				fmt.Fprintln(os.Stderr, "vmx: --rules needs a file argument")
				os.Exit(2)
			}
			rulesPath = args[i]
		case "--connect", "-c":
			i++
			if i >= len(args) {
				fmt.Fprintln(os.Stderr, "vmx: --connect needs a host or libvirt URI")
				os.Exit(2)
			}
			target = ParseTarget(args[i])
		case "--appliances":
			PrintAppliances(os.Stdout)
			return
		case "--appliance":
			i++
			if i >= len(args) {
				fmt.Fprintln(os.Stderr, "vmx: --appliance needs a name")
				os.Exit(2)
			}
			// Everything after the name belongs to the appliance, so the
			// rest of the loop must not try to parse it as flags.
			os.Exit(RunApplianceBuild(args[i], args[i+1:]))
		case "--appliance-script":
			i++
			if i >= len(args) {
				fmt.Fprintln(os.Stderr,
					"vmx: --appliance-script needs an appliance name")
				os.Exit(2)
			}
			// Everything after the name is KEY=VALUE for that appliance,
			// so the rest of the loop must not try to parse it as flags.
			os.Exit(RunApplianceScript(args[i], args[i+1:]))
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
	if tui {
		runTUIMain(rs)
		return
	}
	// GUI: no sudo-reexec — root can't reach the user's Wayland/X display
	// (the zxplore lesson). Privilege comes from the libvirt group; zfs
	// mutations elevate per-command inside runPlan.
	runGUI(rs)
}

// runTUIMain connects to libvirt (self-elevating via sudo when that helps —
// safe in a terminal, root inherits the tty) and runs the bubbletea TUI.
func runTUIMain(rs *Ruleset) {
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
	// a remote target authenticates over ssh — local sudo can't help, and
	// re-execing under sudo would drop the user's ssh agent/keys
	if target.SSHHost != "" {
		return
	}
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
