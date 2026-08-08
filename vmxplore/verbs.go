// verbs.go — the 0.2 mutation verbs: what they run, and the gates around them.
//
// Policy (docs/VM-CONSOLE-DESIGN.md "Privilege model"): every mutation shows
// the EXACT command it is about to run and asks first; the verbs that have
// already cost real homelab hours (force-off, zfs rollback) additionally
// require retyping the domain name; everything executed lands in an audit
// log. Verbs delegate to virsh/zfs rather than reimplementing them — the TUI
// teaches the CLI, never hides it.
//
// Inputs:  a Row (the selected estate line) + operator-typed parameters.
// Outputs: verbPlan — the command list plus its gates — consumed by tui.go's
//
//	confirm overlay, then executed by runPlan.
//
// Notes: command construction is pure (verbs_test.go); execution is the only
// I/O here. `virsh destroy` on a TRANSIENT domain loses the domain (webui
// lesson) — planForceOff refuses unless the domain is persistent. Rollback
// refuses while the domain runs, and uses `zfs rollback -r`, which destroys
// every newer snapshot — the confirm text says so with the count.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"time"
)

// verbPlan is a mutation ready to confirm: the argv list(s) to run in order,
// and the gates the confirm overlay must apply.
type verbPlan struct {
	title     string     // one-line description for the overlay
	cmds      [][]string // executed in order, stop on first failure
	retype    string     // non-empty: the string that must be typed to arm
	warn      string     // extra red text in the confirm overlay
	needsRoot bool       // true for zfs mutations (virsh works via group)
}

// virsh builds a virsh argv pinned to qemu:///system — the connection the
// whole tool reads from. Bare virsh as a non-root libvirt-group user
// defaults to qemu:///session, an empty estate, and every verb would fail
// with "failed to get domain" (bit us live 2026-08-07).
func virsh(args ...string) []string {
	return append([]string{"virsh", "-c", "qemu:///system"}, args...)
}

// cmdLines renders the exact commands, one per line — the contract that the
// operator sees precisely what will run.
func (p verbPlan) cmdLines() string {
	var b strings.Builder
	for _, c := range p.cmds {
		b.WriteString("  $ " + strings.Join(c, " ") + "\n")
	}
	return b.String()
}

// ─── plan builders (pure — tested) ──────────────────────────────────────────

func planStart(r Row) (verbPlan, error) {
	if r.Synthetic {
		return verbPlan{}, fmt.Errorf("no domain behind this row")
	}
	if r.D.State == "running" {
		return verbPlan{}, fmt.Errorf("%s is already running", r.D.Name)
	}
	return verbPlan{
		title: "start " + r.D.Name,
		cmds:  [][]string{virsh("start", r.D.Name)},
	}, nil
}

func planShutdown(r Row) (verbPlan, error) {
	if r.Synthetic || r.D.State != "running" {
		return verbPlan{}, fmt.Errorf("%s is not running", r.D.Name)
	}
	return verbPlan{
		title: "shut down " + r.D.Name + " (graceful, ACPI)",
		cmds:  [][]string{virsh("shutdown", r.D.Name)},
	}, nil
}

// planForceOff is `virsh destroy` — the plug-pull. Retype-gated, and refused
// for transient domains, where destroy doesn't stop the VM, it ERASES it.
func planForceOff(r Row) (verbPlan, error) {
	if r.Synthetic || r.D.State == "shut off" {
		return verbPlan{}, fmt.Errorf("%s is not up", r.D.Name)
	}
	if !r.D.Persistent {
		return verbPlan{}, fmt.Errorf(
			"%s is transient — destroy would erase the domain, not stop it", r.D.Name)
	}
	return verbPlan{
		title:  "force off " + r.D.Name,
		cmds:   [][]string{virsh("destroy", r.D.Name)},
		retype: r.D.Name,
		warn:   "pulls the plug — the guest gets no chance to flush",
	}, nil
}

// planSnapshot is a ZFS snapshot of the backing zvol — NOT virsh
// snapshot-create (the webui shipped that wrong concept once). The manual-
// prefix is what the kldload ruleset classes as operator-made.
func planSnapshot(r Row, suffix string) (verbPlan, error) {
	if r.DS == nil {
		return verbPlan{}, fmt.Errorf("no local dataset behind %s", r.D.Name)
	}
	if suffix == "" {
		suffix = time.Now().Format("20060102-150405")
	}
	name := "manual-" + suffix
	if strings.ContainsAny(suffix, " @/") {
		return verbPlan{}, fmt.Errorf("snapshot name must not contain spaces, @ or /")
	}
	warn := ""
	if r.D.State == "running" {
		warn = "guest is running — snapshot is crash-consistent"
		if r.D.AgentUp {
			warn = "guest is running — snapshot is crash-consistent (0.3 adds agent freeze)"
		}
	}
	return verbPlan{
		title:     "snapshot " + r.DS.Name + "@" + name,
		cmds:      [][]string{{"zfs", "snapshot", r.DS.Name + "@" + name}},
		warn:      warn,
		needsRoot: true,
	}, nil
}

// planClone builds "clone r into newName": snapshot the source zvol, clone
// the snapshot, then virt-clone the domain onto the new zvol with
// --preserve-data (new uuid + MACs, same disk bytes). Generic — works on
// any libvirt host whose guest sits on ZFS and has virt-clone installed;
// the kldload golden-image workflow is exactly this shape.
func planClone(r Row, newName string) (verbPlan, error) {
	if r.Synthetic {
		return verbPlan{}, fmt.Errorf("no domain behind this row")
	}
	if r.DS == nil {
		return verbPlan{}, fmt.Errorf("no local dataset behind %s — clone needs a zvol", r.D.Name)
	}
	if _, err := exec.LookPath("virt-clone"); err != nil {
		return verbPlan{}, fmt.Errorf("virt-clone not found — install virt-install")
	}
	newName = strings.TrimSpace(newName)
	if newName == "" || strings.ContainsAny(newName, " @/") {
		return verbPlan{}, fmt.Errorf("clone name must be non-empty, no spaces, @ or /")
	}
	if newName == r.D.Name {
		return verbPlan{}, fmt.Errorf("clone name must differ from the source")
	}
	parent := r.DS.Name
	if i := strings.LastIndexByte(parent, '/'); i >= 0 {
		parent = parent[:i]
	}
	newDS := parent + "/" + newName
	snap := r.DS.Name + "@clone-" + newName
	warn := "clone shares blocks with " + r.DS.Name + " until it diverges"
	if r.D.State == "running" {
		warn = "source is running — the clone is crash-consistent; " + warn
	}
	return verbPlan{
		title: "clone " + r.D.Name + " → " + newName,
		cmds: [][]string{
			{"zfs", "snapshot", snap},
			{"zfs", "clone", snap, newDS},
			{"virt-clone", "--connect", "qemu:///system", "--original", r.D.Name,
				"--name", newName, "--preserve-data",
				"--file", "/dev/zvol/" + newDS},
		},
		warn:      warn,
		needsRoot: true, // zfs snapshot/clone; virt-clone rides along as root
	}, nil
}

// planRollback rewinds the zvol to a snapshot. -r destroys every snapshot
// newer than the target — the single most dangerous verb here, so it counts
// the casualties into the confirm text and retype-gates.
func planRollback(r Row, snap string, newer int) (verbPlan, error) {
	if r.DS == nil {
		return verbPlan{}, fmt.Errorf("no local dataset behind this row")
	}
	if !r.Synthetic && r.D.State != "shut off" {
		return verbPlan{}, fmt.Errorf("%s must be shut off to roll back its disk", r.D.Name)
	}
	target := r.DS.Name + "@" + snap
	return verbPlan{
		title:     "rollback " + target,
		cmds:      [][]string{{"zfs", "rollback", "-r", target}},
		retype:    r.D.Name,
		warn:      fmt.Sprintf("destroys the %d snapshot(s) newer than @%s", newer, snap),
		needsRoot: true,
	}, nil
}

// planSpecs sets vCPU count and memory via --config: the change lands in the
// persistent definition and takes effect on the next start — safe for both
// running and stopped domains, and the only variant that survives a reboot.
func planSpecs(r Row, vcpus int, memGiB int) (verbPlan, error) {
	if r.Synthetic {
		return verbPlan{}, fmt.Errorf("no domain behind this row")
	}
	if vcpus < 1 || vcpus > 512 || memGiB < 1 || memGiB > 4096 {
		return verbPlan{}, fmt.Errorf("out of range: %d vcpus / %d GiB", vcpus, memGiB)
	}
	mem := fmt.Sprintf("%dG", memGiB)
	p := verbPlan{
		title: fmt.Sprintf("set %s to %d vcpu / %s (applies on next start)",
			r.D.Name, vcpus, mem),
		cmds: [][]string{
			virsh("setvcpus", r.D.Name, fmt.Sprint(vcpus), "--config", "--maximum"),
			virsh("setvcpus", r.D.Name, fmt.Sprint(vcpus), "--config"),
			virsh("setmaxmem", r.D.Name, mem, "--config"),
			virsh("setmem", r.D.Name, mem, "--config"),
		},
	}
	if r.D.State == "running" {
		p.warn = "domain is running — new specs apply after it stops and starts"
	}
	return p, nil
}

func planAutostart(r Row) (verbPlan, error) {
	if r.Synthetic {
		return verbPlan{}, fmt.Errorf("no domain behind this row")
	}
	if r.D.Autostart {
		return verbPlan{
			title: "disable autostart for " + r.D.Name,
			cmds:  [][]string{virsh("autostart", "--disable", r.D.Name)},
		}, nil
	}
	return verbPlan{
		title: "enable autostart for " + r.D.Name + " (boots with the host)",
		cmds:  [][]string{virsh("autostart", r.D.Name)},
	}, nil
}

// ─── execution & audit ──────────────────────────────────────────────────────

// runPlan executes the plan's commands in order, stopping at the first
// failure. zfs mutations need root; when we aren't root, sudo -n is tried so
// a NOPASSWD host works and a password host fails loudly instead of hanging
// a TUI on a hidden prompt. Every command lands in the audit log either way.
func runPlan(p verbPlan) error {
	for _, argv := range p.cmds {
		if p.needsRoot && os.Geteuid() != 0 {
			argv = append([]string{"sudo", "-n"}, argv...)
		}
		out, err := exec.Command(argv[0], argv[1:]...).CombinedOutput()
		rc := 0
		if err != nil {
			rc = 1
		}
		auditLog(strings.Join(argv, " "), rc)
		if err != nil {
			msg := strings.TrimSpace(string(out))
			if msg == "" {
				msg = err.Error()
			}
			return fmt.Errorf("%s: %s", argv[0], msg)
		}
	}
	return nil
}

// auditLog appends "when | who | command | rc" to /var/log/kldload/vmx.log,
// falling back to the user's state dir when that path isn't writable (non-
// root on a non-kldload host). Best-effort by design: an unwritable audit
// trail must not block an already-confirmed verb, and the command itself
// still shows in the status line.
func auditLog(cmdline string, rc int) {
	who := "?"
	if u, err := user.Current(); err == nil {
		who = u.Username
	}
	line := fmt.Sprintf("%s | %s | %s | rc=%d\n",
		time.Now().Format(time.RFC3339), who, cmdline, rc)
	for _, path := range []string{
		"/var/log/kldload/vmx.log",
		filepath.Join(os.Getenv("HOME"), ".local/state/vmxplore/vmx.log"),
	} {
		// MkdirAll only for the fallback; /var/log/kldload exists on kldload
		if strings.HasPrefix(path, os.Getenv("HOME")) && os.Getenv("HOME") != "" {
			// error ignored: fallback dir creation failing means the write
			// below fails too, and we are out of places to log
			_ = os.MkdirAll(filepath.Dir(path), 0o700)
		}
		f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err != nil {
			continue
		}
		_, werr := f.WriteString(line)
		// error ignored on close: the write above already succeeded or not
		_ = f.Close()
		if werr == nil {
			return
		}
	}
}
