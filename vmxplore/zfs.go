// zfs.go — the ZFS half of the join: datasets, origins, snapshots.
//
// Shells out to the zfs CLI exactly as zxplore does, because the CLI is the
// stable interface across every OpenZFS platform and the family's mock-CLI
// test rig already speaks it. No libzfs binding: that would cost the static
// build for an interface that changes more often than the CLI does.
//
// Inputs:  the local zfs command (absent → tier 1, the join stays dark).
// Outputs: dataset map (name → used/refer/origin/type) and snapshot lists
//
//	per dataset, consumed by model.go.
//
// Notes: a real host carries ~16k snapshots (sanoid every 15 min), so
// ListSnapshots returns names only — properties per snapshot would turn one
// cheap listing into 16k stat calls. Classification happens on the name.
package main

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// Dataset is one zfs filesystem or volume; Origin is the lineage edge.
type Dataset struct {
	Name   string
	Used   uint64 // bytes
	Refer  uint64 // bytes
	Origin string // "" when not a clone
	Type   string // filesystem | volume
}

// HasZFS reports whether the join can light up at all (tier 2 gate). Local:
// is `zfs` on PATH. Remote: assume the hypervisor has it (the estate read
// already succeeded over ssh); a probe would be a second round trip and
// zfsRun degrades gracefully if it's absent.
func HasZFS() bool {
	if target.SSHHost != "" {
		return true
	}
	_, err := exec.LookPath("zfs")
	return err == nil
}

// zfsRun executes zfs on the hypervisor (locally or over ssh — zfsArgv
// routes it) with stdout captured; stderr rides the error so a failure
// names its cause in the status line instead of a bare exit code.
func zfsRun(args ...string) (string, error) {
	argv := zfsArgv(args...)
	cmd := exec.Command(argv[0], argv[1:]...)
	var errb strings.Builder
	cmd.Stderr = &errb
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("zfs %s: %s", strings.Join(args, " "),
			strings.TrimSpace(errb.String()))
	}
	return string(out), nil
}

// ListDatasets returns every filesystem and volume with the join columns.
// -p for exact byte counts (the UI does its own humanizing).
func ListDatasets() (map[string]*Dataset, error) {
	out, err := zfsRun("list", "-H", "-p", "-t", "filesystem,volume",
		"-o", "name,used,refer,origin,type")
	if err != nil {
		return nil, err
	}
	m := make(map[string]*Dataset)
	for _, line := range strings.Split(out, "\n") {
		f := strings.Split(line, "\t")
		if len(f) != 5 {
			continue
		}
		used, _ := strconv.ParseUint(f[1], 10, 64)
		refer, _ := strconv.ParseUint(f[2], 10, 64)
		origin := f[3]
		if origin == "-" {
			origin = ""
		}
		m[f[0]] = &Dataset{Name: f[0], Used: used, Refer: refer,
			Origin: origin, Type: f[4]}
	}
	return m, nil
}

// ListSnapshots returns snapshot names (the part after '@') per dataset.
// One listing for the whole host — see the 16k-snapshot note in the banner.
func ListSnapshots() (map[string][]string, error) {
	out, err := zfsRun("list", "-H", "-t", "snapshot", "-o", "name")
	if err != nil {
		return nil, err
	}
	m := make(map[string][]string)
	for _, line := range strings.Split(out, "\n") {
		ds, snap, ok := strings.Cut(strings.TrimSpace(line), "@")
		if !ok {
			continue
		}
		m[ds] = append(m[ds], snap)
	}
	return m, nil
}

// zvolDataset maps a domain disk's block path to its dataset name:
// /dev/zvol/rpool/vms/x → rpool/vms/x. "" when the path is not a zvol.
func zvolDataset(dev string) string {
	const p = "/dev/zvol/"
	if strings.HasPrefix(dev, p) {
		return strings.TrimPrefix(dev, p)
	}
	return ""
}

// humanBytes renders exact bytes the way zfs list does (1.75G, 412M), so the
// table agrees with what the operator sees in zfs list.
func humanBytes(b uint64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%dB", b)
	}
	div, exp := uint64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	v := float64(b) / float64(div)
	suffix := "KMGTPE"[exp : exp+1]
	if v >= 100 {
		return fmt.Sprintf("%.0f%s", v, suffix)
	}
	return fmt.Sprintf("%.1f%s", v, suffix)
}
