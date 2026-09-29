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
	"os"
	"slices"
	"strconv"
	"strings"
	"time"
)

type verb struct {
	key     string
	label   string // the menu shows it short ((S)tart), the help and palette in full
	prompt  string // when set, the verb asks for this before running
	confirm bool   // the row's name must be typed back (destructive verbs)
	noRow   bool   // the verb needs no selection
	// asUser runs a job verb as the operator instead of under sudo -n: for
	// a command that hands something to the operator's desktop. Root has no
	// Wayland or D-Bus session, so the VDI wall opened under sudo reached
	// no browser at all (onyx, 2026-09-28).
	asUser bool
	inter  bool // takes the terminal (virsh console, ssh, logs, plays)
	// argv builds the command; row is the selected row (nil when noRow),
	// input is what the prompt collected. A returned error is shown as is.
	argv func(row []string, input string) ([]string, error)
	// ctxArgv builds it from the tab's context instead (a pod's logs on
	// the Logs tab, where the context is "namespace/pod").
	ctxArgv func(ctx string) ([]string, error)
	secret  bool // the prompt's input is a passphrase: masked on screen
	stdin   bool // the input is fed to the command's stdin, not argv
	// rowCtxArgv builds the command from the row AND the tab's context (a
	// snapshot row under a file's Versions).
	rowCtxArgv func(row []string, ctx string) ([]string, error)
	// console opens an in-TUI console of this kind on the row's VM instead
	// of running a command (console.go)
	console consoleKind
	// job runs the command in a pane inside the TUI (a pty behind the
	// emulator) instead of silently or by taking the terminal over: for
	// anything that runs long or whose output the operator must read
	job bool
	// argvs is argv for a verb that runs several commands in order in one
	// job pane (the Build menu's "everything")
	argvs func(row []string, in string) ([][]string, error)
	// names lists what the verb would create, so the TUI can refuse a name
	// the table already shows before anything runs (a count-clone named
	// vdi-1 over the operator's own vdi-1, 2026-09-26: kvm-clone refused
	// it, but only after the job had started)
	names func(row []string, in string) []string
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
		{key: "K", label: "force off", argv: onRow("virsh", "destroy", "{}")},
		{key: "c", label: "clone", job: true, prompt: "clone {} as <name> [count] [--snap @name]  (count > 1 makes name-1, name-2, …): ", names: func(_ []string, in string) []string {
			names, _, _ := cloneNames(in)
			return names
		}, argv: func(row []string, in string) ([]string, error) {
			names, snap, err := cloneNames(in)
			if err != nil {
				return nil, err
			}
			if len(names) == 1 && snap == "" {
				return []string{"kvm-clone", col(row, 0), names[0]}, nil
			}
			// sequential, one shell with a fixed argv: clones of one source
			// each snapshot the same zvol, and the first failure names its
			// clone instead of leaving the operator to count what appeared
			script := `src="$1"; snap="$2"; shift 2; for n in "$@"; do echo "== kvm-clone $src $n"; if [ -n "$snap" ]; then kvm-clone "$src" "$n" --snap "$snap" || exit 1; else kvm-clone "$src" "$n" || exit 1; fi; done`
			return append([]string{"sh", "-c", script, "_", col(row, 0), snap}, names...), nil
		}},
		{key: "s", label: "snapshot", argv: onRow("kvm-snap", "{}")},
		{key: "b", label: "rollback to the newest snapshot", argv: onRow("kvm-snap", "{}", "rollback")},
		{key: "d", label: "delete VM + zvol", argv: onRow("kvm-delete", "{}", "--force")},
		{key: "e", label: "enrol on the mesh", job: true, argv: onRow("kldload-enroll", "{}")},
		{key: "z", label: "suspend", argv: onRow("virsh", "suspend", "{}")},
		{key: "Z", label: "resume", argv: onRow("virsh", "resume", "{}")},
		{key: "A", label: "autostart on/off", argv: func(row []string, _ string) ([]string, error) {
			if col(row, 3) == "on" {
				return []string{"virsh", "autostart", "--disable", col(row, 0)}, nil
			}
			return []string{"virsh", "autostart", col(row, 0)}, nil
		}},
		{key: "M", label: "make golden (shut down, seal, @golden)", job: true, argv: func(row []string, _ string) ([]string, error) {
			// vmxplore's MakeGolden: shut it down and wait, seal the zvol with
			// kldload-seal (virt-sysprep is what it falls back to), then a
			// fresh @golden on the zvol. One shell with a fixed argv: the VM
			// name is $1 and never meets the shell as text.
			script := `vm="$1"; ds="rpool/vms/$vm"; if virsh domstate "$vm" | grep -q running; then echo "== shutting $vm down"; virsh shutdown "$vm"; for i in $(seq 180); do virsh domstate "$vm" | grep -q "shut off" && break; sleep 1; done; fi; virsh domstate "$vm" | grep -q "shut off" || { echo "$vm is still running after 3 minutes; K forces it off"; exit 1; }; echo "== sealing /dev/zvol/$ds"; kldload-seal "/dev/zvol/$ds" || virt-sysprep -a "/dev/zvol/$ds" || { echo "seal failed"; exit 1; }; if zfs list -H "$ds@golden" >/dev/null 2>&1; then echo "== replacing $ds@golden"; zfs destroy "$ds@golden" || { echo "clones still depend on the old @golden: zfs promote them first"; exit 1; }; fi; zfs snapshot "$ds@golden" && echo "== $vm@golden is the golden; c clones it"`
			return []string{"sh", "-c", script, "_", col(row, 0)}, nil
		}},
		{key: "F", label: "seal as a Firecracker golden", job: true, argv: onRow("kfire", "golden", "{}")},
		{key: "v", label: "vcpus and memory", prompt: "{}: <vcpus> <memory GiB> (applies to the next boot): ", argv: func(row []string, in string) ([]string, error) {
			f := strings.Fields(in)
			if len(f) != 2 || strings.Trim(f[0], "0123456789") != "" || strings.Trim(f[1], "0123456789") != "" {
				return nil, errors.New("two numbers: vcpus and memory in GiB")
			}
			// four virsh calls, fixed argv with the values as positionals
			return []string{"sh", "-c", `virsh setvcpus "$1" "$2" --config --maximum && virsh setvcpus "$1" "$2" --config && virsh setmaxmem "$1" "$3"G --config && virsh setmem "$1" "$3"G --config`, "_", col(row, 0), f[0], f[1]}, nil
		}},
		{key: "+", label: "grow the root disk", job: true, prompt: "grow {} to <GiB> (block device, partition and filesystem): ", argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if in == "" || strings.Trim(in, "0123456789") != "" {
				return nil, errors.New("a size in GiB")
			}
			return []string{"kvm-grow", col(row, 0), in}, nil
		}},
		{key: "X", label: "reconcile an unreconciled row", argv: func(row []string, _ string) ([]string, error) {
			if col(row, 1) != "unreconciled" {
				return nil, errors.New("only rows in the unreconciled group")
			}
			if col(row, 2) == "zvol" {
				return []string{"zfs", "destroy", "-r", "rpool/vms/" + col(row, 0)}, nil
			}
			return []string{"kldload-db", "vm-delete", "--name", col(row, 0)}, nil
		}},
		// the three consoles open inside the TUI (console.go); ctrl+] is
		// the menu that detaches or switches between them
		{key: "w", label: "screen (video console)", console: conScreen},
		{key: "C", label: "serial console", console: conSerial},
		{key: "H", label: "ssh terminal", console: conSSH},
		{key: "V", label: "vmxplore", noRow: true, inter: true, argv: fixed("vmxplore", "--tui")},
		// The wall is a browser page -- fifty live video tiles cannot be drawn
		// in a terminal -- so kld hands it to vmx, which finds every VDI
		// that is streaming (the appliance and its Firecracker clones),
		// writes the page and opens it; the job pane shows what it found
		// and the page's path (operator, 2026-09-28: the video shoot is
		// driven from kld alone).
		{key: "W", label: "VDI wall: every streaming desktop in the browser", noRow: true, job: true, asUser: true, argv: fixed("vmxplore", "--vdi-wall", "--open")},
		{key: "n", label: "new VM", job: true, noRow: true, prompt: "kvm-create <name> [--ram MB] [--cpus N] [--disk GB] [--iso path]: ", argv: func(_ []string, in string) ([]string, error) {
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
		}, names: func(_ []string, in string) []string {
			if f := strings.Fields(in); len(f) > 0 {
				return f[:1]
			}
			return nil
		}},
	},
	"Machines/Snapshots": {
		{key: "b", label: "roll the VM back to this snapshot", argv: func(row []string, _ string) ([]string, error) {
			return []string{"kvm-snap", col(row, 0), "rollback", "@" + col(row, 1)}, nil
		}},
		{key: "d", label: "delete snapshot", argv: func(row []string, _ string) ([]string, error) {
			return []string{"kvm-snap", col(row, 0), "delete", "@" + col(row, 1)}, nil
		}},
		{key: "s", label: "snapshot this VM now", argv: onRow("kvm-snap", "{}")},
	},
	"Machines/Appliances": {
		{key: "b", label: "build one as a VM", prompt: "vm name, then KEY=VALUE settings for {}: ", job: true, argv: func(row []string, in string) ([]string, error) {
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
		{key: "s", label: "show its install script", job: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"sh", "-c", `vmxplore --appliance-script "$1" | less`, "_", col(row, 0)}, nil
		}},
		{key: "B", label: "build every appliance (vmx --build-all)", noRow: true, job: true, argv: fixed("vmxplore", "--build-all")},
	},
	"Machines/Build": {
		{key: "x", label: "build it", job: true, argvs: func(row []string, _ string) ([][]string, error) {
			if col(row, 6) == "typed" {
				return nil, errors.New("this row destroys: D, with its name typed")
			}
			return buildArgvs(col(row, 4), "")
		}},
		{key: "D", label: "destroy what the row names (type its name)", job: true, confirm: true, argvs: func(row []string, _ string) ([][]string, error) {
			if col(row, 6) != "typed" {
				return nil, errors.New("only the DESTROY rows; x builds this one")
			}
			return buildArgvs(col(row, 4), "")
		}},
		{key: "X", label: "build it with an argument (a distro, a format, an image and a count)", job: true, prompt: "argument for {}: ", argvs: func(row []string, in string) ([][]string, error) {
			in = strings.TrimSpace(in)
			switch col(row, 5) {
			case "distro":
				if !slices.Contains(append(slices.Clone(klabDistros), "all"), in) {
					return nil, errors.New("one of " + strings.Join(klabDistros, " ") + " all")
				}
				return buildArgvs(col(row, 4), in)
			case "format":
				if !slices.Contains([]string{"qcow2", "raw", "vhd", "vmdk", "all"}, in) {
					return nil, errors.New("one of qcow2 raw vhd vmdk all")
				}
				return [][]string{{"kimage", "export", in}}, nil
			case "deploy":
				f := strings.Fields(in)
				if len(f) != 2 || !nameOK(f[0]) {
					return nil, errors.New("<image name> <count>")
				}
				if n, err := strconv.Atoi(f[1]); err != nil || n < 1 || n > 64 {
					return nil, errors.New("a count from 1 to 64")
				}
				return [][]string{{"kimage", "deploy", f[0], f[1]}}, nil
			case "workers":
				n, err := strconv.Atoi(in)
				if in == "" {
					n, err = 3, nil
				}
				if err != nil || n < 0 || n > 64 {
					return nil, errors.New("how many workers, 0 to 64 (blank = 3)")
				}
				return [][]string{{"kube-cluster", "bootstrap", "--control-planes", "3", "--workers", strconv.Itoa(n)}}, nil
			case "moreworkers":
				n, err := strconv.Atoi(in)
				if err != nil || n < 1 || n > 64 {
					return nil, errors.New("how many more workers, 1 to 64")
				}
				return [][]string{{"kube-cluster", "scale", strconv.Itoa(n)}}, nil
			case "cps":
				if in != "1" && in != "3" && in != "5" {
					return nil, errors.New("1, 3 or 5 control planes")
				}
				return [][]string{{"kube-cluster", "scale", "--control-planes", in}}, nil
			case "golden", "vm":
				// <name> <distro|vm> [post-install: a readable file, else a command line]
				f := strings.Fields(in)
				if len(f) < 2 || !nameOK(f[0]) || !nameOK(f[1]) {
					return nil, errors.New("<name> <distro or base VM> [post-install file, or a command to run as root]")
				}
				argv := []string{"kvm-golden", f[0], "--from", f[1]}
				if col(row, 5) == "vm" {
					argv = append(argv, "--keep")
				}
				if len(f) > 2 {
					rest := strings.TrimSpace(strings.TrimPrefix(in, f[0]))
					rest = strings.TrimSpace(strings.TrimPrefix(rest, f[1]))
					if st, err := os.Stat(rest); err == nil && !st.IsDir() {
						argv = append(argv, "--post", rest)
					} else {
						argv = append(argv, "--run", rest)
					}
				}
				return [][]string{argv}, nil
			}
			return nil, errors.New(col(row, 0) + " takes no argument; x builds it")
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
		{key: "d", label: "destroy", argv: onRow("kfire", "destroy", "{}")},
		{key: "H", label: "ssh", inter: true, argv: onRow("kfire", "ssh", "{}")},
		{key: "C", label: "serial console log", inter: true, argv: onRow("kfire", "console", "{}")},
		{key: "!", label: "kfire status", noRow: true, job: true, argv: fixed("sh", "-c", `kfire status; echo; read -r -p "enter to return" _`)},
		// Same verb as Machines/VMs W: the wall is a browser page -- fifty live video tiles cannot be drawn
		// in a terminal -- so kld hands it to vmx, which finds every VDI
		// that is streaming (the appliance and its Firecracker clones),
		// writes the page and opens it; the job pane shows what it found
		// and the page's path (operator, 2026-09-28: the video shoot is
		// driven from kld alone).
		{key: "W", label: "VDI wall: every streaming desktop in the browser", noRow: true, job: true, asUser: true, argv: fixed("vmxplore", "--vdi-wall", "--open")},
	},
	"Machines/Networks": {
		{key: "S", label: "start", argv: onRow("virsh", "net-start", "{}")},
		{key: "T", label: "stop", argv: onRow("virsh", "net-destroy", "{}")},
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
		{key: "E", label: "create an encrypted child (zfs asks the passphrase)", prompt: "encrypted child of {}: ", job: true, argv: func(row []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if in == "" || strings.Contains(in, "/") || !datasetOK(col(row, 0)+"/"+in) {
				return nil, errors.New("a child name (no slashes)")
			}
			return []string{"zfs", "create", "-o", "encryption=on", "-o", "keyformat=passphrase", "-o", "keylocation=prompt", col(row, 0) + "/" + in}, nil
		}},
		{key: "d", label: "destroy the dataset and everything under it", confirm: true, argv: onRow("zfs", "destroy", "-r", "{}")},
		{key: "z", label: "zxplore", noRow: true, inter: true, argv: fixed("zxplore", "--tui")},
	},
	"Storage/Versions": {
		// the restores name their source and destination from the context
		// (the file) and the row (the snapshot), never from a cursor that
		// moved since — zxplore's explorer restored the wrong file that way
		{key: "c", label: "restore this version as a copy beside the live file", rowCtxArgv: func(row []string, ctx string) ([]string, error) {
			src, dst, err := versionPaths(row, ctx)
			if err != nil {
				return nil, err
			}
			return []string{"cp", "-a", "--", src, dst + ".from-" + col(row, 0)}, nil
		}},
		{key: "R", label: "restore this version over the live file", confirm: true, rowCtxArgv: func(row []string, ctx string) ([]string, error) {
			src, dst, err := versionPaths(row, ctx)
			if err != nil {
				return nil, err
			}
			return []string{"cp", "-a", "--", src, dst}, nil
		}},
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
		{key: "D", label: "diff against live", job: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"sh", "-c", `zfs diff -H "$1" | less -S`, "_", col(row, 0)}, nil
		}},
		{key: "f", label: "diff against another snapshot", prompt: "diff {} against snapshot (name after @): ", job: true, argv: func(row []string, in string) ([]string, error) {
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
		{key: "T", label: "replicate to a dataset, local or user@host:pool/ds", confirm: true, prompt: "send {} to <dataset> or <user@host:dataset>: ", job: true, argv: func(row []string, in string) ([]string, error) {
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
		{key: "B", label: "bootstrap an HA cluster (3 control planes)", noRow: true, job: true, prompt: "kube-cluster bootstrap --control-planes 3 --workers <N> (blank = 3): ", argv: func(_ []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if in == "" {
				in = "3"
			}
			if strings.Trim(in, "0123456789") != "" {
				return nil, errors.New("workers must be a number")
			}
			return []string{"kube-cluster", "bootstrap", "--control-planes", "3", "--workers", in}, nil
		}},
		{key: "A", label: "add workers", noRow: true, job: true, prompt: "kube-cluster scale <N more workers>: ", argv: func(_ []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if in == "" || strings.Trim(in, "0123456789") != "" {
				return nil, errors.New("a number of workers is needed")
			}
			return []string{"kube-cluster", "scale", in}, nil
		}},
		{key: "P", label: "set the control-plane count (odd)", noRow: true, job: true, prompt: "kube-cluster scale --control-planes <1|3|5>: ", argv: func(_ []string, in string) ([]string, error) {
			in = strings.TrimSpace(in)
			if in != "1" && in != "3" && in != "5" {
				return nil, errors.New("control planes are 1, 3 or 5 (etcd quorum)")
			}
			return []string{"kube-cluster", "scale", "--control-planes", in}, nil
		}},
		{key: "W", label: "power the cluster off", noRow: true, confirm: false, job: true, argv: fixed("kube-cluster", "stop")},
		{key: "O", label: "power the cluster on", noRow: true, job: true, argv: fixed("kube-cluster", "start")},
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
		{key: "p", label: "ping", job: true, argv: onRow("ansible", "{}", "-i", "/usr/local/bin/kldload-inventory", "-m", "ping")},
		{key: "H", label: "ssh", inter: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", col(row, 2) + "@" + col(row, 1)}, nil
		}},
		{key: "m", label: "run a module", prompt: "ansible {} -m <module> -a <args>: ", job: true, argv: func(row []string, in string) ([]string, error) {
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
		{key: "p", label: "ping the group", job: true, argv: onRow("ansible", "{}", "-i", "/usr/local/bin/kldload-inventory", "-m", "ping")},
	},
	"Ansible/Plays": {
		{key: "p", label: "run the play", prompt: "--limit for {} (blank = the play's hosts): ", job: true, argv: func(row []string, in string) ([]string, error) {
			argv := []string{"ansible-playbook", "-i", "/usr/local/bin/kldload-inventory", playbookDir + "/" + col(row, 0)}
			if in = strings.TrimSpace(in); in != "" {
				argv = append(argv, "--limit", in)
			}
			return argv, nil
		}},
		{key: "n", label: "check mode (no changes)", job: true, argv: onRow("ansible-playbook", "-i", "/usr/local/bin/kldload-inventory", "--check", "--diff", playbookDir+"/{}")},
	},
	"Helm/Releases": {
		{key: "U", label: "uninstall", confirm: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"helm", "uninstall", "-n", col(row, 1), col(row, 0)}, nil
		}},
		{key: "Y", label: "history", job: true, argv: func(row []string, _ string) ([]string, error) {
			return []string{"sh", "-c", `helm history -n "$1" "$2"; echo; read -r -p "enter to return" _`, "_", col(row, 1), col(row, 0)}, nil
		}},
	},
	"Helm/Examples": {
		{key: "I", label: "install", prompt: "helm install <release> [namespace] from {}: ", job: true, argv: func(row []string, in string) ([]string, error) {
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
		{key: "J", label: "journal", job: true, argv: onRow("journalctl", "-u", "{}", "-e", "--no-hostname")},
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

// versionPaths resolves a Versions row (a snapshot) and its context (the
// file) to the snapshot's copy of the file and the live path.
func versionPaths(row []string, ctx string) (src, dst string, err error) {
	snap := col(row, 0)
	if snap == "" || snap == "(live)" || !snapNameOK(snap) {
		return "", "", errors.New("pick a snapshot row")
	}
	ds, rel := splitExplorerCtx(ctx)
	mp, mounted := datasetMountpoint(ds)
	if !mounted || rel == "/" {
		return "", "", errors.New("no file is open, or its dataset is not mounted")
	}
	return mp + "/.zfs/snapshot/" + snap + rel, mp + rel, nil
}

// cloneNames parses the clone prompt: a name, an optional count (the name
// becomes a base: name-1 … name-N) and an optional --snap @name.
func cloneNames(in string) (names []string, snap string, err error) {
	f := strings.Fields(in)
	if len(f) == 0 || !nameOK(f[0]) {
		return nil, "", errors.New("a name for the clone comes first")
	}
	count := 1
	for i := 1; i < len(f); i++ {
		switch {
		case f[i] == "--snap" && i+1 < len(f) && snapNameOK(strings.TrimPrefix(f[i+1], "@")):
			snap = "@" + strings.TrimPrefix(f[i+1], "@")
			i++
		default:
			n, err := strconv.Atoi(f[i])
			if err != nil || n < 1 || n > 99 {
				return nil, "", errors.New("after the name: a count from 1 to 99, or --snap @name")
			}
			count = n
		}
	}
	names = []string{f[0]}
	if count > 1 {
		// the typed name is a base: fifteen clones used to be fifteen trips
		// through the prompt (vmxplore's cloneqty round)
		names = names[:0]
		for i := 1; i <= count; i++ {
			names = append(names, fmt.Sprintf("%s-%d", f[0], i))
		}
	}
	for _, n := range names {
		if !nameOK(n) {
			return nil, "", fmt.Errorf("%q is not a VM name", n)
		}
	}
	return names, snap, nil
}

// buildArgvs splits a Build row's command column (commands joined by " ; ")
// into argvs; with a distro, the trailing "all" of each klab command
// becomes that distro.
func buildArgvs(cmd, distro string) ([][]string, error) {
	if strings.TrimSpace(cmd) == "" {
		return nil, errors.New("this row is a pointer, not a build: read its description")
	}
	var out [][]string
	for _, c := range strings.Split(cmd, " ; ") {
		argv := strings.Fields(c)
		if len(argv) == 0 {
			continue
		}
		if distro != "" && argv[len(argv)-1] == "all" {
			argv[len(argv)-1] = distro
		}
		out = append(out, argv)
	}
	return out, nil
}
