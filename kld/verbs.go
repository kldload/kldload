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
	// ctxArgv builds it from the tab's context instead (a pod's logs on
	// the Logs tab, where the context is "namespace/pod").
	ctxArgv func(ctx string) ([]string, error)
	secret  bool // the prompt's input is a passphrase: masked on screen
	stdin   bool // the input is fed to the command's stdin, not argv
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
		{key: "z", label: "suspend", argv: onRow("virsh", "suspend", "{}")},
		{key: "Z", label: "resume", argv: onRow("virsh", "resume", "{}")},
		{key: "A", label: "autostart on/off", argv: func(row []string, _ string) ([]string, error) {
			if col(row, 3) == "on" {
				return []string{"virsh", "autostart", "--disable", col(row, 0)}, nil
			}
			return []string{"virsh", "autostart", col(row, 0)}, nil
		}},
		{key: "F", label: "seal as a Firecracker golden", argv: onRow("kfire", "golden", "{}")},
		{key: "v", label: "vcpus and memory", prompt: "{}: <vcpus> <memory GiB> (applies to the next boot): ", argv: func(row []string, in string) ([]string, error) {
			f := strings.Fields(in)
			if len(f) != 2 || strings.Trim(f[0], "0123456789") != "" || strings.Trim(f[1], "0123456789") != "" {
				return nil, errors.New("two numbers: vcpus and memory in GiB")
			}
			// four virsh calls, fixed argv with the values as positionals
			return []string{"sh", "-c", `virsh setvcpus "$1" "$2" --config --maximum && virsh setvcpus "$1" "$2" --config && virsh setmaxmem "$1" "$3"G --config && virsh setmem "$1" "$3"G --config`, "_", col(row, 0), f[0], f[1]}, nil
		}},
		{key: "+", label: "grow the root disk", prompt: "grow {} to <GiB> (block device, partition and filesystem): ", argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if in == "" || strings.Trim(in, "0123456789") != "" {
				return nil, errors.New("a size in GiB")
			}
			return []string{"kvm-grow", col(row, 0), in}, nil
		}},
		{key: "X", label: "reconcile an unreconciled row", confirm: true, argv: func(row []string, _ string) ([]string, error) {
			if col(row, 1) != "unreconciled" {
				return nil, errors.New("only rows in the unreconciled group")
			}
			if col(row, 2) == "zvol" {
				return []string{"zfs", "destroy", "-r", "rpool/vms/" + col(row, 0)}, nil
			}
			return []string{"kldload-db", "vm-delete", "--name", col(row, 0)}, nil
		}},
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
		{key: "V", label: "vmxplore", noRow: true, inter: true, argv: fixed("vmxplore", "--tui")},
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
	"Machines/Appliances": {
		{key: "b", label: "build one as a VM", prompt: "vm name, then KEY=VALUE settings for {}: ", inter: true, argv: func(row []string, in string) ([]string, error) {
			f := strings.Fields(in)
			if len(f) == 0 || !nameOK(f[0]) {
				return nil, errors.New("a VM name comes first, then KEY=VALUE settings")
			}
			for _, kv := range f[1:] {
				if !strings.Contains(kv, "=") || strings.HasPrefix(kv, "-") {
					return nil, errors.New("settings are KEY=VALUE")
				}
			}
			return append([]string{"vmxplore", "--appliance", col(row, 0), "--vm", f[0]}, f[1:]...), nil
		}},
		{key: "s", label: "show its install script", inter: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"sh", "-c", `vmxplore --appliance-script "$1" | less`, "_", col(row, 0)}, nil
		}},
		{key: "B", label: "build every appliance (vmx --build-all)", noRow: true, inter: true, argv: fixed("vmxplore", "--build-all")},
	},
	"Machines/Factory": {
		{key: "x", label: "run it", inter: true, argv: func(row []string, _ string) ([]string, error) {
			return strings.Fields(col(row, 3)), nil
		}},
		{key: "X", label: "run it for one distro", prompt: "distro for {} (centos rocky fedora debian ubuntu): ", inter: true, argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			switch in {
			case "centos", "rocky", "fedora", "debian", "ubuntu", "all":
			default:
				return nil, errors.New("one of centos rocky fedora debian ubuntu all")
			}
			argv := strings.Fields(col(row, 3))
			if len(argv) > 0 && argv[len(argv)-1] == "all" {
				argv[len(argv)-1] = in
			}
			return argv, nil
		}},
	},
	"Machines/microVMs": {
		{key: "c", label: "clone microVMs from a golden", noRow: true, prompt: "kfire clone <golden> [options]: ", argv: func(_ []string, in string) ([]string, error) {
			f := strings.Fields(in)
			if len(f) == 0 || !nameOK(f[0]) {
				return nil, errors.New("a golden name comes first")
			}
			for _, a := range f[1:] {
				if strings.HasPrefix(a, "--") && (a == "--all") {
					return nil, errors.New("--all is not a clone option")
				}
			}
			return append([]string{"kfire", "clone"}, f...), nil
		}},
		{key: "S", label: "start", argv: onRow("kfire", "start", "{}")},
		{key: "T", label: "stop", argv: onRow("kfire", "stop", "{}")},
		{key: "d", label: "destroy", confirm: true, argv: onRow("kfire", "destroy", "{}")},
		{key: "H", label: "ssh", inter: true, argv: onRow("kfire", "ssh", "{}")},
		{key: "C", label: "serial console log", inter: true, argv: onRow("kfire", "console", "{}")},
		{key: "!", label: "kfire status", noRow: true, inter: true, argv: fixed("sh", "-c", `kfire status; echo; read -r -p "enter to return" _`)},
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
		{key: "n", label: "create a child dataset", prompt: "child of {}: ", argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if in == "" || !datasetOK(col(row, 0)+"/"+in) || strings.Contains(in, "/") {
				return nil, errors.New("a child name (no slashes)")
			}
			return []string{"zfs", "create", "-p", col(row, 0) + "/" + in}, nil
		}},
		{key: "V", label: "create a zvol", prompt: "zvol under {}: <name> <size, e.g. 10G>: ", argv: func(row []string, in string) ([]string, error) {
			f := strings.Fields(in)
			if len(f) != 2 || strings.Contains(f[0], "/") || !datasetOK(col(row, 0)+"/"+f[0]) || strings.Trim(f[1], "0123456789KMGTkmgt") != "" {
				return nil, errors.New("a name and a size like 10G")
			}
			return []string{"zfs", "create", "-V", f[1], col(row, 0) + "/" + f[0]}, nil
		}},
		{key: "m", label: "rename", prompt: "rename {} to: ", argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if !datasetOK(in) {
				return nil, errors.New("a full dataset name, pool/…")
			}
			return []string{"zfs", "rename", col(row, 0), in}, nil
		}},
		{key: "L", label: "load the encryption key", prompt: "passphrase for {}: ", secret: true, stdin: true, argv: onRow("zfs", "load-key", "{}")},
		{key: "U", label: "unload the encryption key", confirm: true, argv: onRow("zfs", "unload-key", "{}")},
		{key: "E", label: "create an encrypted child (zfs asks the passphrase)", prompt: "encrypted child of {}: ", inter: true, argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if in == "" || strings.Contains(in, "/") || !datasetOK(col(row, 0)+"/"+in) {
				return nil, errors.New("a child name (no slashes)")
			}
			return []string{"zfs", "create", "-o", "encryption=on", "-o", "keyformat=passphrase", "-o", "keylocation=prompt", col(row, 0) + "/" + in}, nil
		}},
		{key: "d", label: "destroy the dataset and everything under it", confirm: true, argv: onRow("zfs", "destroy", "-r", "{}")},
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
		{key: "D", label: "diff against live", inter: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"sh", "-c", `zfs diff -H "$1" | less -S`, "_", col(row, 0)}, nil
		}},
		{key: "f", label: "diff against another snapshot", prompt: "diff {} against snapshot (name after @): ", inter: true, argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if !snapNameOK(in) {
				return nil, errors.New("a snapshot name, the part after @")
			}
			return []string{"sh", "-c", `zfs diff -H "$1" "$2" | less -S`, "_", col(row, 0), col(row, 1) + "@" + in}, nil
		}},
		{key: "K", label: "bookmark", prompt: "bookmark {} as (name after #): ", argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if !snapNameOK(in) {
				return nil, errors.New("a bookmark name")
			}
			return []string{"zfs", "bookmark", col(row, 0), col(row, 1) + "#" + in}, nil
		}},
		{key: "H", label: "hold (tag kld)", argv: onRow("zfs", "hold", "kld", "{}")},
		{key: "U", label: "release the hold", argv: onRow("zfs", "release", "kld", "{}")},
		{key: "T", label: "replicate to a dataset, local or user@host:pool/ds", confirm: true, prompt: "send {} to <dataset> or <user@host:dataset>: ", inter: true, argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			host, ds, remote := strings.Cut(in, ":")
			if !remote {
				ds = in
			}
			if !datasetOK(ds) || (remote && (host == "" || strings.ContainsAny(host, " ;|&"))) {
				return nil, errors.New("a dataset, or user@host:dataset")
			}
			// zfs recv -F rolls the destination back to match: that is why
			// this verb asks for the snapshot's name to be typed
			if remote {
				return []string{"sh", "-c", `zfs send -vP "$1" | ssh -o BatchMode=yes "$2" zfs recv -s -F -o readonly=on -o canmount=noauto "$3"`, "_", col(row, 0), host, ds}, nil
			}
			return []string{"sh", "-c", `zfs send -vP "$1" | zfs recv -s -F -o readonly=on -o canmount=noauto "$2"`, "_", col(row, 0), ds}, nil
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
	"Network/Fleet": {
		{key: "w", label: "wgx", noRow: true, inter: true, argv: fixed("wgx", "tui")},
		{key: "H", label: "ssh to the host", inter: true, argv: func(row []string, _ string) ([]string, error) {
			t := col(row, 7)
			if t == "" || t == "local" || strings.HasPrefix(t, "unreachable") {
				return nil, errors.New("this row is the local host or unreachable")
			}
			return []string{"ssh", t}, nil
		}},
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
		{key: "K", label: "k9s", noRow: true, inter: true, argv: fixed("k9s")},
		// The shape is kube-cluster's own: bootstrap asks for three control
		// planes (HA; the tool clamps to what fits and says so), scale adds
		// workers or grows the control plane through the integrated path.
		{key: "B", label: "bootstrap an HA cluster (3 control planes)", noRow: true, inter: true, prompt: "kube-cluster bootstrap --control-planes 3 --workers <N> (blank = 3): ", argv: func(_ []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if in == "" {
				in = "3"
			}
			if strings.Trim(in, "0123456789") != "" {
				return nil, errors.New("workers must be a number")
			}
			return []string{"kube-cluster", "bootstrap", "--control-planes", "3", "--workers", in}, nil
		}},
		{key: "A", label: "add workers", noRow: true, inter: true, prompt: "kube-cluster scale <N more workers>: ", argv: func(_ []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if in == "" || strings.Trim(in, "0123456789") != "" {
				return nil, errors.New("a number of workers is needed")
			}
			return []string{"kube-cluster", "scale", in}, nil
		}},
		{key: "P", label: "set the control-plane count (odd)", noRow: true, inter: true, prompt: "kube-cluster scale --control-planes <1|3|5>: ", argv: func(_ []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if in != "1" && in != "3" && in != "5" {
				return nil, errors.New("control planes are 1, 3 or 5 (etcd quorum)")
			}
			return []string{"kube-cluster", "scale", "--control-planes", in}, nil
		}},
		{key: "W", label: "power the cluster off", noRow: true, confirm: false, inter: true, argv: fixed("kube-cluster", "stop")},
		{key: "O", label: "power the cluster on", noRow: true, inter: true, argv: fixed("kube-cluster", "start")},
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
		{key: "K", label: "k9s", noRow: true, inter: true, argv: fixed("k9s")},
	},
	"Cluster/Logs": {
		{key: "L", label: "follow in the terminal", noRow: true, inter: true, ctxArgv: func(ctx string) ([]string, error) {
			ns, pod, ok := strings.Cut(ctx, "/")
			if !ok || pod == "" {
				return nil, errors.New("no pod is open — press enter on one in Pods")
			}
			return []string{"kubectl", "logs", "-f", "-n", ns, pod, "--all-containers=true", "--prefix=true", "--tail=100"}, nil
		}},
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
		{key: "I", label: "install", prompt: "helm install <release> [namespace] from {}: ", inter: true, argv: func(row []string, in string) ([]string, error) {
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
