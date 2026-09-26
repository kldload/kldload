// machines.go — vmxplore's estate, ported into the Machines section.
//
// What vmxplore's TUI showed that the plain VM list did not: the group a
// machine belongs to (from the same rules file vmxplore reads, so an
// operator's /etc/vmxplore/rules still applies), autostart, what it was
// cloned from, how many snapshots it carries, and pending-operation notes;
// plus the twelve-appliance catalogue and the Factory of image-set commands.
// Every verb still runs a shipped command (2026-09-26 port).
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// ── groups: vmxplore's rules file ───────────────────────────────────────────

type groupRule struct {
	re    *regexp.Regexp
	label string
}

// builtinRules are vmxplore's rules/kldload.rules group lines: the first
// match wins, $1 substitutes the capture.
var builtinRules = []string{
	`^k8s-golden$              goldens`,
	`^klab-golden-[a-z]+$      goldens`,
	`^klab-desktop-[a-z0-9]+$  goldens`,
	`^klab-ztest-[a-z0-9]+$    goldens`,
	`^kzfstest-golden-[a-z0-9]+$       zfs test lab`,
	`^kzfstest-[a-z0-9]+-[0-9]+$       zfs test lab`,
	`^kzfstest-.+$                     zfs test lab`,
	`^.+-golden$               goldens`,
	`^klab-(blue|green|test)-[a-z]+$   klab`,
	`^klab-ztest-[a-z0-9]+-[0-9]+$     klab`,
	`^app-[a-z0-9-]+$          apps`,
	`^st-[a-z0-9-]+$           apps (self-test)`,
	`^kspawn-(.+)-[0-9]+$      kspawn: $1`,
	`^(.+)-cp-?[0-9]*$         k8s: $1`,
	`^(.+)-w-?[0-9]+$          k8s: $1`,
}

func loadGroupRules() []groupRule {
	lines := builtinRules
	if b, err := os.ReadFile("/etc/vmxplore/rules"); err == nil {
		var own []string
		for _, l := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(strings.TrimSpace(l), "group ") {
				own = append(own, strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(l), "group ")))
			}
		}
		if len(own) > 0 {
			lines = own
		}
	}
	var out []groupRule
	for _, l := range lines {
		f := strings.Fields(l)
		if len(f) < 2 {
			continue
		}
		re, err := regexp.Compile(f[0])
		if err != nil {
			continue
		}
		out = append(out, groupRule{re, strings.Join(f[1:], " ")})
	}
	return out
}

func groupOf(rules []groupRule, name string, origin string) string {
	for _, r := range rules {
		if m := r.re.FindStringSubmatch(name); m != nil {
			label := r.label
			if len(m) > 1 {
				label = strings.ReplaceAll(label, "$1", m[1])
			}
			return label
		}
	}
	if origin != "" {
		return "clones"
	}
	return "ungrouped"
}

// ── the estate ──────────────────────────────────────────────────────────────

// loadVMsGrouped replaces loadVMs: one virsh dominfo per VM as before, plus
// one zfs listing for every zvol's origin and one for the snapshot counts,
// the DB's role and mesh id, pending-operation markers, and the group.
// Rows are sorted by group then name; synthetic rows for what libvirt does
// not know about — a DB row with no domain, a zvol with no domain — sit
// in the group "unreconciled" so they can be cleaned up (R).
func loadVMsGrouped(d *sectionData) {
	names, err := run(15*time.Second, "virsh", "list", "--all", "--name")
	if err != nil {
		d.err = err.Error()
		return
	}
	domains := map[string]bool{}
	for _, n := range strings.Fields(names) {
		domains[n] = true
	}
	ips := map[string]string{}
	if out, err := run(20*time.Second, "kldload-vm-ip", "--all", "--json"); err == nil {
		_ = jsonUnmarshal(out, &ips)
	}
	type dbrow struct{ Role, Cluster, MeshID, Golden string }
	db := map[string]dbrow{}
	if out, err := run(15*time.Second, "kldload-db", "dump"); err == nil {
		var dump struct {
			// explicit tags: encoding/json does not match deleted_at to
			// DeletedAt on its own, and without them every soft-deleted row
			// (273 on onyx) came back as "in state.db, not in libvirt"
			VMs []struct {
				Name      string `json:"name"`
				Role      string `json:"role"`
				ClusterID string `json:"cluster_id"`
				MeshID    string `json:"mesh_id"`
				GoldenSrc string `json:"golden_src"`
				DeletedAt string `json:"deleted_at"`
			} `json:"vms"`
		}
		if jsonUnmarshal(out, &dump) == nil {
			for _, v := range dump.VMs {
				if v.DeletedAt == "" {
					db[v.Name] = dbrow{v.Role, v.ClusterID, v.MeshID, v.GoldenSrc}
				}
			}
		}
	}
	origins := map[string]string{}
	zvols := map[string]bool{}
	if out, err := run(15*time.Second, "zfs", "list", "-H", "-o", "name,origin", "-t", "volume", "-r", "rpool/vms"); err == nil {
		for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
			f := strings.Split(line, "\t")
			if len(f) == 2 && strings.Count(f[0], "/") == 2 {
				zvols[filepath.Base(f[0])] = true
				if f[1] != "-" {
					origins[filepath.Base(f[0])] = f[1]
				}
			}
		}
	}
	snaps := map[string]int{}
	if out, err := run(30*time.Second, "zfs", "list", "-H", "-o", "name", "-t", "snapshot", "-r", "rpool/vms"); err == nil {
		for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
			if ds, _, ok := strings.Cut(line, "@"); ok {
				snaps[filepath.Base(ds)]++
			}
		}
	}
	notes := map[string]string{}
	for _, kind := range []string{"build", "export"} {
		if entries, err := os.ReadDir("/var/lib/kldload/vm-" + kind + "-pending"); err == nil {
			for _, e := range entries {
				notes[e.Name()] = kind + " pending"
			}
		}
	}
	rules := loadGroupRules()
	d.columns = []string{"vm", "group", "state", "boot", "vcpus", "memory", "address", "clone of", "snaps", "mesh", "role", "notes"}
	running := 0
	var rows [][]string
	for name := range domains {
		info, _ := run(10*time.Second, "virsh", "dominfo", name)
		state, cpus, mem, auto := "?", "-", "-", "-"
		for _, line := range strings.Split(info, "\n") {
			k, v, ok := strings.Cut(line, ":")
			if !ok {
				continue
			}
			v = strings.TrimSpace(v)
			switch strings.TrimSpace(k) {
			case "State":
				state = v
			case "CPU(s)":
				cpus = v
			case "Max memory":
				if kib, err := strconv.ParseInt(strings.Fields(v)[0], 10, 64); err == nil {
					mem = human(kib * 1024)
				}
			case "Autostart":
				if v == "enable" {
					auto = "on"
				} else {
					auto = "off"
				}
			}
		}
		if state == "running" {
			running++
		}
		origin := origins[name]
		short := "-"
		if origin != "" {
			short = strings.TrimPrefix(origin, "rpool/vms/")
		}
		r := db[name]
		rows = append(rows, []string{name, groupOf(rules, name, origin), state, auto, cpus, mem, orDash(ips[name]),
			short, strconv.Itoa(snaps[name]), orDash(r.MeshID), orDash(r.Role), orDash(notes[name])})
	}
	// unreconciled: the DB knows a VM libvirt does not; a zvol has no domain
	for name := range db {
		if !domains[name] {
			rows = append(rows, []string{name, "unreconciled", "absent", "-", "-", "-", "-", "-", "-", orDash(db[name].MeshID), db[name].Role, "in state.db, not in libvirt"})
		}
	}
	for z := range zvols {
		if !domains[z] && !strings.HasSuffix(z, "-data") && z != "isos" && z != "images" {
			rows = append(rows, []string{z, "unreconciled", "zvol", "-", "-", "-", "-", orDash(strings.TrimPrefix(origins[z], "rpool/vms/")), strconv.Itoa(snaps[z]), "-", "-", "zvol without a domain"})
		}
	}
	sort.SliceStable(rows, func(i, j int) bool {
		gi, gj := rows[i][1], rows[j][1]
		if gi != gj {
			// named groups first, then ungrouped, clones, unreconciled last
			rank := func(g string) int {
				switch g {
				case "ungrouped":
					return 1
				case "clones":
					return 2
				case "unreconciled":
					return 3
				}
				return 0
			}
			if rank(gi) != rank(gj) {
				return rank(gi) < rank(gj)
			}
			return gi < gj
		}
		return rows[i][0] < rows[j][0]
	})
	d.rows = rows
	d.headline = fmt.Sprintf("%d machines, %d running (libvirt · kldload-vm-ip · state.db · zfs · %d groups)", len(domains), running, countGroups(rows))
}

func countGroups(rows [][]string) int {
	seen := map[string]bool{}
	for _, r := range rows {
		seen[r[1]] = true
	}
	return len(seen)
}

// ── the appliance catalogue ─────────────────────────────────────────────────

// loadAppliances parses `vmx --appliances`: a name line, a summary line, a
// "license · distro · size" line, "serves:", "fit:", then the settings.
func loadAppliances(d *sectionData) {
	out, err := run(60*time.Second, "vmxplore", "--appliances")
	if err != nil && strings.TrimSpace(out) == "" {
		d.err = "vmxplore --appliances: " + err.Error()
		return
	}
	d.columns = []string{"appliance", "distro", "size", "serves", "fit", "settings", "about"}
	var cur []string
	settings := 0
	flush := func() {
		if cur != nil {
			cur[5] = strconv.Itoa(settings)
			d.rows = append(d.rows, cur)
		}
		cur, settings = nil, 0
	}
	for _, line := range strings.Split(out, "\n") {
		switch {
		case line == "":
			continue
		case !strings.HasPrefix(line, " "):
			flush()
			cur = []string{strings.TrimSpace(line), "-", "-", "-", "-", "0", ""}
		case cur == nil:
			continue
		case strings.HasPrefix(line, "    "):
			settings++
		case strings.HasPrefix(strings.TrimSpace(line), "serves:"):
			cur[3] = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "serves:"))
		case strings.HasPrefix(strings.TrimSpace(line), "fit:"):
			cur[4] = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "fit:"))
		case strings.Contains(line, " · "):
			parts := strings.Split(strings.TrimSpace(line), " · ")
			if len(parts) >= 3 {
				cur[1] = parts[len(parts)-2]
				cur[2] = parts[len(parts)-1]
			}
		default:
			if cur[6] == "" {
				cur[6] = strings.TrimSpace(line)
			}
		}
	}
	flush()
	d.headline = fmt.Sprintf("%d appliances (vmxplore --appliances) — b builds one, B builds them all", len(d.rows))
}

// ── the Factory: image sets, each a shipped command ─────────────────────────

var factoryRows = [][]string{
	{"klab golden", "goldens", "lean cloud goldens for every distro", "klab golden all"},
	{"klab golden-desktop", "goldens", "GNOME desktop goldens", "klab golden-desktop all"},
	{"klab golden-xfce", "goldens", "Xfce desktop goldens", "klab golden-xfce all"},
	{"klab golden-kde", "goldens", "KDE Plasma desktop goldens", "klab golden-kde all"},
	{"klab golden-db", "goldens", "PostgreSQL goldens", "klab golden-db all"},
	{"klab golden-ztest", "goldens", "OpenZFS test-lab goldens", "klab golden-ztest all"},
	{"kube-cluster golden", "goldens", "the Kubernetes node golden", "kube-cluster golden"},
	{"vmx --build-all", "appliances", "every appliance as a VM, sealed as Firecracker goldens where kfire is", "vmxplore --build-all"},
	{"kube-smoke-test", "tests", "the cluster's smoke test", "kube-smoke-test"},
	{"kldload-test", "tests", "the kldload suite", "kldload-test"},
}

func loadFactory(d *sectionData) {
	d.columns = []string{"image set", "kind", "what it builds", "command"}
	for _, r := range factoryRows {
		d.rows = append(d.rows, append([]string(nil), r...))
	}
	d.headline = "image sets — x runs the selected command in the terminal, X with a distro"
}
