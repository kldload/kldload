// verbs.go — what a key does to the selected row, per section and sub-tab.
//
// One registry instead of one function per verb: a verb names its key, what
// it needs (a row, typed input, the row's name typed back as consent), the
// argv it builds from the row, and whether it takes the terminal. The keys a
// verb may use exclude the navigation set (numbers, tab, j k g G, / o i r ?
// q, enter, ctrl-*). Every verb runs a shipped command — kvm-*, virsh, zfs,
// kldload-rollback, kube-network, kldload-enroll, kubectl, ansible, helm,
// kldload-netboot-server — so the console cannot drift from what the estate
// tests prove; nothing here re-implements a tool.
package main

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

type verb struct {
	key     string
	label   string // shown in the status bar and the detail pane
	prompt  string // when set, the verb asks for this before running
	confirm bool   // the row's name must be typed back (destructive verbs)
	noRow   bool   // the verb needs no selection
	inter   bool   // takes the terminal (virsh console, ssh, logs, plays)
	// argv builds the command; row is the selected row (nil when noRow),
	// input is what the prompt collected. A returned error is shown as is.
	argv func(row []string, input string) ([]string, error)
}

// col returns column i of a row, or "".
func col(row []string, i int) string {
	if i < len(row) {
		return row[i]
	}
	return ""
}

func fixed(args ...string) func([]string, string) ([]string, error) {
	return func([]string, string) ([]string, error) { return args, nil }
}

// onRow builds argv from the first column: name(row) placed where "{}" is.
func onRow(args ...string) func([]string, string) ([]string, error) {
	return func(row []string, _ string) ([]string, error) {
		out := make([]string, len(args))
		for i, a := range args {
			out[i] = strings.ReplaceAll(a, "{}", col(row, 0))
		}
		return out, nil
	}
}

var verbs = map[string][]verb{
	"Machines/VMs": {
		{key: "S", label: "start", argv: onRow("virsh", "start", "{}")},
		{key: "T", label: "shutdown", argv: onRow("virsh", "shutdown", "{}")},
		{key: "R", label: "reboot", argv: onRow("virsh", "reboot", "{}")},
		{key: "K", label: "force off", confirm: true, argv: onRow("virsh", "destroy", "{}")},
		{key: "c", label: "clone", prompt: "clone {} as: ", argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if !nameOK(in) {
				return nil, fmt.Errorf("%q is not a VM name", in)
			}
			return []string{"kvm-clone", col(row, 0), in}, nil
		}},
		{key: "s", label: "snapshot", argv: onRow("kvm-snap", "{}")},
		{key: "b", label: "rollback to the newest snapshot", confirm: true, argv: onRow("kvm-snap", "{}", "rollback")},
		{key: "d", label: "delete VM + zvol", confirm: true, argv: onRow("kvm-delete", "{}", "--force")},
		{key: "e", label: "enrol on the mesh", argv: onRow("kldload-enroll", "{}")},
		{key: "C", label: "serial console (ctrl+] leaves)", inter: true, argv: onRow("virsh", "console", "{}")},
		{key: "H", label: "ssh", inter: true, argv: func(row []string, _ string) ([]string, error) {
			ip := col(row, 4)
			if ip == "" || ip == "-" {
				return nil, errors.New("no address for " + col(row, 0) + " yet")
			}
			// the host's root key is what kldload-enroll used; the guest
			// changes every rebuild, so its host key is not pinned
			return []string{"ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "root@" + ip}, nil
		}},
		{key: "v", label: "vmxplore", noRow: true, inter: true, argv: fixed("vmxplore", "--tui")},
		{key: "n", label: "new VM", noRow: true, prompt: "kvm-create <name> [--ram MB] [--cpus N] [--disk GB] [--iso path]: ", argv: func(_ []string, in string) ([]string, error) {
			f := strings.Fields(in)
			if len(f) == 0 || !nameOK(f[0]) {
				return nil, errors.New("a VM name comes first")
			}
			for i := 1; i < len(f); i++ {
				switch f[i] {
				case "--ram", "--cpus", "--disk", "--iso", "--bridge", "--os", "--volblocksize":
					if i+1 >= len(f) || strings.HasPrefix(f[i+1], "-") {
						return nil, errors.New(f[i] + " needs a value")
					}
					i++
				default:
					return nil, errors.New("unknown option " + f[i])
				}
			}
			return append([]string{"kvm-create"}, f...), nil
		}},
	},
	"Machines/Snapshots": {
		{key: "b", label: "roll the VM back to this snapshot", confirm: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"kvm-snap", col(row, 0), "rollback", "@" + col(row, 1)}, nil
		}},
		{key: "d", label: "delete snapshot", confirm: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"kvm-snap", col(row, 0), "delete", "@" + col(row, 1)}, nil
		}},
		{key: "s", label: "snapshot this VM now", argv: onRow("kvm-snap", "{}")},
	},
	"Machines/Networks": {
		{key: "S", label: "start", argv: onRow("virsh", "net-start", "{}")},
		{key: "T", label: "stop", confirm: true, argv: onRow("virsh", "net-destroy", "{}")},
	},
	"Machines/Pools": {
		{key: "R", label: "refresh", argv: onRow("virsh", "pool-refresh", "{}")},
	},
	"Storage/Pools": {
		{key: "S", label: "scrub", argv: onRow("zpool", "scrub", "{}")},
		{key: "P", label: "stop scrub", argv: onRow("zpool", "scrub", "-s", "{}")},
		{key: "z", label: "zxplore", noRow: true, inter: true, argv: fixed("zxplore", "--tui")},
	},
	"Storage/Topology": {
		{key: "F", label: "offline the vdev", confirm: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"zpool", "offline", col(row, 1), strings.TrimSpace(col(row, 0))}, nil
		}},
		{key: "O", label: "online the vdev", argv: func(row []string, _ string) ([]string, error) {
			return []string{"zpool", "online", col(row, 1), strings.TrimSpace(col(row, 0))}, nil
		}},
		{key: "E", label: "clear the pool's error counters", argv: func(row []string, _ string) ([]string, error) {
			return []string{"zpool", "clear", col(row, 1)}, nil
		}},
		{key: "S", label: "scrub the pool", argv: func(row []string, _ string) ([]string, error) {
			return []string{"zpool", "scrub", col(row, 1)}, nil
		}},
	},
	"Storage/Datasets": {
		{key: "s", label: "snapshot", prompt: "snapshot {} as (blank = manual-<time>): ", argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if in == "" {
				in = "manual-" + time.Now().Format("2006-01-02_15:04:05")
			}
			if !snapNameOK(in) {
				return nil, fmt.Errorf("%q is not a snapshot name", in)
			}
			return []string{"zfs", "snapshot", col(row, 0) + "@" + in}, nil
		}},
		{key: "P", label: "set a property", prompt: "zfs set <property>=<value> on {}: ", argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			k, val, ok := strings.Cut(in, "=")
			if !ok || k == "" || val == "" || strings.ContainsAny(k, " \t") || strings.HasPrefix(k, "-") {
				return nil, errors.New("need property=value")
			}
			return []string{"zfs", "set", in, col(row, 0)}, nil
		}},
		{key: "M", label: "mount", argv: onRow("zfs", "mount", "{}")},
		{key: "N", label: "unmount", confirm: true, argv: onRow("zfs", "unmount", "{}")},
		{key: "z", label: "zxplore", noRow: true, inter: true, argv: fixed("zxplore", "--tui")},
	},
	"Storage/Snapshots": {
		{key: "b", label: "roll back (the root goes through a boot environment)", confirm: true, argv: func(row []string, _ string) ([]string, error) {
			name := col(row, 0)
			if strings.HasPrefix(name, "rpool/ROOT/") {
				return []string{"kldload-rollback", "to", name, "--no-reboot"}, nil
			}
			return []string{"zfs", "rollback", "-r", name}, nil
		}},
		{key: "d", label: "destroy snapshot", confirm: true, argv: onRow("zfs", "destroy", "{}")},
		{key: "c", label: "clone into a dataset", prompt: "clone {} into dataset: ", argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if !datasetOK(in) {
				return nil, fmt.Errorf("%q is not a dataset name", in)
			}
			return []string{"zfs", "clone", col(row, 0), in}, nil
		}},
	},
	"Storage/Boot envs": {
		{key: "B", label: "boot into this on the next reboot", confirm: true, argv: func(row []string, _ string) ([]string, error) {
			name := col(row, 0)
			if strings.Contains(name, "@") {
				return []string{"kldload-rollback", "to", name, "--no-reboot"}, nil
			}
			return []string{"kldload-rollback", "activate", name}, nil
		}},
		{key: "X", label: "cancel a staged rollback", noRow: true, argv: fixed("kldload-rollback", "cancel")},
	},
	"Network/Planes": {
		{key: "w", label: "wgx", noRow: true, inter: true, argv: fixed("wgx", "tui")},
	},
	"Network/Peers": {
		{key: "w", label: "wgx", noRow: true, inter: true, argv: fixed("wgx", "tui")},
	},
	"Network/Enrolled": {
		{key: "e", label: "enrol a VM", noRow: true, prompt: "kldload-enroll <vm>: ", argv: func(_ []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if !nameOK(in) {
				return nil, fmt.Errorf("%q is not a VM name", in)
			}
			return []string{"kldload-enroll", in}, nil
		}},
		{key: "E", label: "re-enrol", argv: onRow("kldload-enroll", "{}")},
	},
	"Cluster/Nodes": {
		{key: "D", label: "drain", confirm: true, argv: onRow("kubectl", "drain", "{}", "--ignore-daemonsets", "--delete-emptydir-data", "--request-timeout=60s")},
		{key: "U", label: "uncordon", argv: onRow("kubectl", "uncordon", "{}", "--request-timeout=30s")},
		{key: "k", label: "k9s", noRow: true, inter: true, argv: fixed("k9s")},
	},
	"Cluster/Pods": {
		{key: "L", label: "logs (follow)", inter: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"kubectl", "logs", "-f", "-n", col(row, 1), col(row, 0), "--tail=200"}, nil
		}},
		{key: "E", label: "shell in the pod", inter: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"kubectl", "exec", "-it", "-n", col(row, 1), col(row, 0), "--", "sh"}, nil
		}},
		{key: "X", label: "delete pod", confirm: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"kubectl", "delete", "pod", "-n", col(row, 1), col(row, 0), "--request-timeout=60s"}, nil
		}},
		{key: "k", label: "k9s", noRow: true, inter: true, argv: fixed("k9s")},
	},
	"Cluster/Deployments": {
		{key: "R", label: "rollout restart", argv: func(row []string, _ string) ([]string, error) {
			return []string{"kubectl", "rollout", "restart", "deployment", "-n", col(row, 1), col(row, 0), "--request-timeout=30s"}, nil
		}},
		{key: "N", label: "scale", prompt: "replicas for {}: ", argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if in == "" || strings.Trim(in, "0123456789") != "" {
				return nil, errors.New("replicas must be a number")
			}
			return []string{"kubectl", "scale", "deployment", "-n", col(row, 1), col(row, 0), "--replicas=" + in, "--request-timeout=30s"}, nil
		}},
	},
	"Ansible/Hosts": {
		{key: "p", label: "ping", inter: true, argv: onRow("ansible", "{}", "-i", "/usr/local/bin/kldload-inventory", "-m", "ping")},
		{key: "H", label: "ssh", inter: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", col(row, 2) + "@" + col(row, 1)}, nil
		}},
		{key: "m", label: "run a module", prompt: "ansible {} -m <module> -a <args>: ", inter: true, argv: func(row []string, in string) ([]string, error) {
			f := strings.Fields(in)
			if len(f) == 0 {
				return nil, errors.New("a module name is needed")
			}
			argv := []string{"ansible", col(row, 0), "-i", "/usr/local/bin/kldload-inventory", "-m", f[0]}
			if len(f) > 1 {
				argv = append(argv, "-a", strings.Join(f[1:], " "))
			}
			return argv, nil
		}},
	},
	"Ansible/Groups": {
		{key: "p", label: "ping the group", inter: true, argv: onRow("ansible", "{}", "-i", "/usr/local/bin/kldload-inventory", "-m", "ping")},
	},
	"Ansible/Plays": {
		{key: "p", label: "run the play", prompt: "--limit for {} (blank = the play's hosts): ", inter: true, argv: func(row []string, in string) ([]string, error) {
			argv := []string{"ansible-playbook", "-i", "/usr/local/bin/kldload-inventory", playbookDir + "/" + col(row, 0)}
			if in = strings.TrimSpace(in); in != "" {
				argv = append(argv, "--limit", in)
			}
			return argv, nil
		}},
		{key: "n", label: "check mode (no changes)", inter: true, argv: onRow("ansible-playbook", "-i", "/usr/local/bin/kldload-inventory", "--check", "--diff", playbookDir+"/{}")},
	},
	"Helm/Releases": {
		{key: "U", label: "uninstall", confirm: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"helm", "uninstall", "-n", col(row, 1), col(row, 0)}, nil
		}},
		{key: "Y", label: "history", inter: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"sh", "-c", `helm history -n "$1" "$2"; echo; read -r -p "enter to return" _`, "_", col(row, 1), col(row, 0)}, nil
		}},
	},
	"Helm/Examples": {
		{key: "i", label: "install", prompt: "helm install <release> [namespace] from {}: ", inter: true, argv: func(row []string, in string) ([]string, error) {
			f := strings.Fields(in)
			if len(f) == 0 || !nameOK(f[0]) {
				return nil, errors.New("a release name is needed")
			}
			ns := "default"
			if len(f) > 1 {
				ns = f[1]
			}
			return []string{"helm", "install", f[0], helmExamples + "/" + col(row, 0), "-n", ns, "--create-namespace"}, nil
		}},
	},
	"Estate/Units": {
		{key: "J", label: "journal", inter: true, argv: onRow("journalctl", "-u", "{}", "-e", "--no-hostname")},
		{key: "S", label: "start", argv: onRow("systemctl", "start", "{}")},
		{key: "T", label: "stop", confirm: true, argv: onRow("systemctl", "stop", "{}")},
		{key: "R", label: "restart", argv: onRow("systemctl", "restart", "{}")},
		{key: "F", label: "reset failed state", argv: onRow("systemctl", "reset-failed", "{}")},
	},
	"Provision/Goldens": {
		{key: "a", label: "arm-deploy a machine with this golden", prompt: "arm-deploy <mac> --disk <disk> [--hostname <h>] for {}: ", argv: func(row []string, in string) ([]string, error) {
			f := strings.Fields(in)
			if len(f) < 3 || !macOrAny(f[0]) || f[0] == "any" || f[1] != "--disk" || strings.HasPrefix(f[2], "-") {
				return nil, errors.New("need: <mac> --disk <disk> [--hostname <h>]")
			}
			argv := []string{"kldload-netboot-server", "arm-deploy", f[0], "--golden", strings.TrimSuffix(col(row, 0), ".zfs"), "--disk", f[2]}
			if len(f) >= 5 && f[3] == "--hostname" && nameOK(f[4]) {
				argv = append(argv, "--hostname", f[4])
			}
			return argv, nil
		}},
	},
	"Provision/Armed": {
		{key: "a", label: "arm a machine", noRow: true, prompt: "arm-install <mac|any> <answers.env>: ", argv: func(_ []string, in string) ([]string, error) {
			f := strings.Fields(in)
			if len(f) != 2 || !macOrAny(f[0]) || strings.HasPrefix(f[1], "-") {
				return nil, errors.New("need a MAC (or any) and an answers file")
			}
			return []string{"kldload-netboot-server", "arm-install", f[0], f[1]}, nil
		}},
		{key: "x", label: "disarm", argv: func(row []string, _ string) ([]string, error) {
			if !macOrAny(col(row, 0)) {
				return nil, errors.New("nothing armed is selected")
			}
			return []string{"kldload-netboot-server", "disarm", col(row, 0)}, nil
		}},
		{key: "X", label: "disarm every machine", noRow: true, confirm: true, argv: fixed("kldload-netboot-server", "disarm-all")},
	},
	"Provision/Answers": {
		{key: "a", label: "arm a machine with this file", prompt: "arm <mac|any> with {}: ", argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if !macOrAny(in) {
				return nil, errors.New("need a MAC or any")
			}
			return []string{"kldload-netboot-server", "arm-install", in, col(row, 0)}, nil
		}},
	},
}

// ── name guards: nothing reaches argv that a tool would read as an option ──

func nameOK(s string) bool {
	if s == "" || len(s) > 63 || s[0] == '-' {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
			return false
		}
	}
	return true
}

func snapNameOK(s string) bool {
	if s == "" || s[0] == '-' || strings.ContainsAny(s, "@/ ") {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("-_.:", c)) {
			return false
		}
	}
	return true
}

func datasetOK(s string) bool {
	if s == "" || s[0] == '-' || s[0] == '/' || strings.Contains(s, "..") || strings.ContainsAny(s, "@ ") {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("-_./:", c)) {
			return false
		}
	}
	return strings.Contains(s, "/")
}

// macOrAny accepts aa:bb:cc:dd:ee:ff, the aa-bb-… form the token files use,
// or the word any; nothing else reaches the tool's argv.
func macOrAny(s string) bool {
	if s == "any" {
		return true
	}
	if len(s) != 17 {
		return false
	}
	for i, c := range s {
		if i%3 == 2 {
			if c != ':' && c != '-' {
				return false
			}
		} else if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}
