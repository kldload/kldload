// machines.go — vmxplore's estate, ported into the Machines section.
//
// What vmxplore's TUI showed that the plain VM list did not: the group a
// machine belongs to (from the same rules file vmxplore reads, so an
// operator's /etc/vmxplore/rules still applies), autostart, what it was
// cloned from, how many snapshots it carries, and pending-operation notes;
// plus the twelve-appliance catalogue and the Build menu of every image.
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
	"sync"
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
	// the five host reads are independent: run them at once. In series they
	// were 2.3 s; kldload-vm-ip alone is 1.5 s and is cached for 15 s.
	type dbrow struct{ Role, Cluster, MeshID, Golden string }
	var (
		ips     map[string]string
		db      = map[string]dbrow{}
		dbOut   string
		zvolOut string
		stats   map[string]domStat
		auto    = map[string]bool{}
		snaps   map[string]int
		wg      sync.WaitGroup
	)
	wg.Add(5)
	go func() { defer wg.Done(); ips = vmAddresses() }()
	go func() { defer wg.Done(); dbOut, _ = run(15*time.Second, "kldload-db", "dump") }()
	go func() {
		defer wg.Done()
		zvolOut, _ = run(15*time.Second, "zfs", "list", "-H", "-o", "name,origin", "-t", "volume", "-r", "rpool/vms")
	}()
	go func() {
		defer wg.Done()
		stats = domStats()
		if out, err := run(10*time.Second, "virsh", "list", "--autostart", "--name"); err == nil {
			for _, n := range strings.Fields(out) {
				auto[n] = true
			}
		}
	}()
	go func() { defer wg.Done(); snaps = vmSnapCounts() }()
	wg.Wait()
	if out := dbOut; out != "" {
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
	if out := zvolOut; out != "" {
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
	notes := map[string]string{}
	for _, kind := range []string{"build", "export"} {
		if entries, err := os.ReadDir("/var/lib/kldload/vm-" + kind + "-pending"); err == nil {
			for _, e := range entries {
				notes[e.Name()] = kind + " pending"
			}
		}
	}
	rules := loadGroupRules()
	d.columns = []string{"vm", "group", "state", "cpu", "boot", "vcpus", "memory", "address", "clone of", "snaps", "mesh", "role", "notes"}
	running := 0
	var rows [][]string
	// one virsh domstats for every domain (64 ms) where a dominfo per VM
	// cost 56 ms each — 4.2 s for fifty machines, felt on every keypress
	// that reloaded the table (2026-09-26). Autostart is one more call.
	// a shut-off domain without balloon/vcpu lines still needs a dominfo;
	// those run eight at a time rather than one after another
	var need []string
	for name := range domains {
		if st := stats[name]; st.vcpus == 0 || st.memKiB == 0 {
			need = append(need, name)
		}
	}
	infos := dominfoAll(need)
	for name := range domains {
		st := stats[name]
		state, cpus, mem, boot := st.state, "-", "-", "off"
		if state == "" {
			state = "?"
		}
		if st.vcpus > 0 {
			cpus = strconv.Itoa(st.vcpus)
		}
		if st.memKiB > 0 {
			mem = human(st.memKiB * 1024)
		}
		if info, ok := infos[name]; ok {
			if info.cpus != "" && cpus == "-" {
				cpus = info.cpus
			}
			if info.mem != "" && mem == "-" {
				mem = info.mem
			}
		}
		if auto[name] {
			boot = "on"
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
		rows = append(rows, []string{name, groupOf(rules, name, origin), state, st.cpuPct, boot, cpus, mem, orDash(ips[name]),
			short, strconv.Itoa(snaps[name]), orDash(r.MeshID), orDash(r.Role), orDash(notes[name])})
	}
	// unreconciled: the DB knows a VM libvirt does not; a zvol has no domain
	for name := range db {
		if !domains[name] {
			rows = append(rows, []string{name, "unreconciled", "absent", "-", "-", "-", "-", "-", "-", "-", orDash(db[name].MeshID), db[name].Role, "in state.db, not in libvirt"})
		}
	}
	for z := range zvols {
		if !domains[z] && !strings.HasSuffix(z, "-data") && z != "isos" && z != "images" {
			rows = append(rows, []string{z, "unreconciled", "zvol", "-", "-", "-", "-", "-", orDash(strings.TrimPrefix(origins[z], "rpool/vms/")), strconv.Itoa(snaps[z]), "-", "-", "zvol without a domain"})
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

// ── (the Build menu follows) ─────────────────────────────────────────────────

// ── the Build menu ──────────────────────────────────────────────────────
// Every image the platform can make, as rows: one button for everything,
// one per family (all klab goldens, all appliances), one per kind (lean,
// GNOME, Xfce, KDE, PostgreSQL, ztest) with X asking for a single distro,
// plus Kubernetes, Windows, this host as a cloud image, exports, tests.
// "have" counts what already exists (@golden snapshots under rpool/vms,
// app-* domains) so the operator sees what a button would add. A row with
// several commands (joined by " ; ") runs them in order in one job pane.
// The operator's ask, 2026-09-26: "some way to build all 30+ images,
// ideally via smaller buttons — build all the goldens, build klab, etc."

type buildRow struct {
	name, kind, what, cmd, arg string // arg: distro | format | deploy | workers | … | ""
	have                       func(g map[string]bool, apps int) string
	danger                     bool // destroys images: D with the row's name typed, never x
}

var klabDistros = []string{"centos", "rocky", "fedora", "debian", "ubuntu"}

// klabHave counts klab-<prefix>-<distro>@golden over the five distros.
func klabHave(prefix string) func(map[string]bool, int) string {
	return func(g map[string]bool, _ int) string {
		n := 0
		for _, d := range klabDistros {
			if g["klab-"+prefix+"-"+d] {
				n++
			}
		}
		return fmt.Sprintf("%d/%d", n, len(klabDistros))
	}
}

var klabKinds = []struct{ verb, prefix, what string }{
	{"golden", "golden", "lean cloud goldens"},
	{"golden-desktop", "desktop", "GNOME desktop goldens"},
	{"golden-xfce", "xfce", "Xfce desktop goldens"},
	{"golden-kde", "kde", "KDE Plasma desktop goldens"},
	{"golden-db", "db", "PostgreSQL goldens"},
	{"golden-ztest", "ztest", "OpenZFS test-lab goldens"},
}

func buildRows() []buildRow {
	var klabAll []string
	for _, k := range klabKinds {
		klabAll = append(klabAll, "klab "+k.verb+" all")
	}
	allKlab := strings.Join(klabAll, " ; ")
	sumKlab := func(g map[string]bool, _ int) string {
		n := 0
		for _, k := range klabKinds {
			for _, d := range klabDistros {
				if g["klab-"+k.prefix+"-"+d] {
					n++
				}
			}
		}
		return fmt.Sprintf("%d/%d", n, len(klabKinds)*len(klabDistros))
	}
	appsHave := func(_ map[string]bool, apps int) string { return strconv.Itoa(apps) + " built" }
	rows := []buildRow{
		{name: "EVERYTHING", kind: "everything", what: "every klab golden, the Kubernetes golden, every appliance", cmd: allKlab + " ; kube-cluster golden ; vmxplore --build-all", have: func(g map[string]bool, apps int) string {
			n, _, _ := strings.Cut(sumKlab(g, 0), "/")
			kn, _ := strconv.Atoi(n)
			if g["k8s-golden"] {
				kn++
			}
			return fmt.Sprintf("%d/%d + %d apps", kn, len(klabKinds)*len(klabDistros)+1, apps)
		}},
		{name: "all klab goldens", kind: "goldens", what: "the six kinds for the five distros (30 images)", cmd: allKlab, have: sumKlab},
	}
	for _, k := range klabKinds {
		rows = append(rows, buildRow{name: "klab " + k.verb, kind: "goldens", what: k.what + " for every distro (X: one distro)", cmd: "klab " + k.verb + " all", arg: "distro", have: klabHave(k.prefix)})
	}
	rows = append(rows,
		buildRow{name: "kubernetes golden", kind: "kubernetes", what: "the node image kube-cluster clones control planes and workers from", cmd: "kube-cluster golden", have: func(g map[string]bool, _ int) string { return yesNo(g["k8s-golden"]) }},
		buildRow{name: "kubernetes: build the HA cluster", kind: "kubernetes", what: "kube-cluster bootstrap --control-planes 3 --workers N (X: N, default 3) — the golden first if it is missing", cmd: "kube-cluster bootstrap --control-planes 3 --workers 3", arg: "workers", have: nodesHave},
		buildRow{name: "kubernetes: add workers", kind: "kubernetes", what: "kube-cluster scale N (X: how many more)", arg: "moreworkers", have: nodesHave},
		buildRow{name: "kubernetes: set the control planes", kind: "kubernetes", what: "kube-cluster scale --control-planes N (X: 1, 3 or 5; grows or shrinks the HA set)", arg: "cps", have: nodesHave},
		buildRow{name: "windows 11 golden", kind: "windows", what: "unattended Win11 eval golden (fetched on demand, q35 + TPM)", cmd: "kvm-win golden win11"},
		buildRow{name: "windows server golden", kind: "windows", what: "unattended Windows Server golden", cmd: "kvm-win golden server"},
		buildRow{name: "all appliances", kind: "appliances", what: "every catalogue appliance as a VM (app-*), sealed as Firecracker goldens where kfire is", cmd: "vmxplore --build-all", have: appsHave},
		buildRow{name: "appliance self-test", kind: "appliances", what: "build every tile as a VM and audit it (st-*), tear down the passing ones", cmd: "vmxplore --selftest"},
		buildRow{name: "one appliance", kind: "appliances", what: "b on the Appliances tab: pick the tile, name the VM, set its KEY=VALUE fields"},
		buildRow{name: "this host as a cloud image", kind: "images", what: "kimage build: prep this system as a cloud-init golden", cmd: "kimage build"},
		buildRow{name: "export this host's image", kind: "images", what: "kimage export (X: qcow2 raw vhd vmdk all) to /srv/images", cmd: "kimage export qcow2", arg: "format"},
		buildRow{name: "deploy VMs from an image", kind: "images", what: "kimage deploy (X: <image> <count>)", arg: "deploy"},
		buildRow{name: "build your own golden", kind: "custom", what: "kvm-golden: clone a base (X: <name> <distro|vm> [post-install file or a command]), boot, run your post-install as root, shut down, seal, @golden", arg: "golden"},
		buildRow{name: "build your own VM", kind: "custom", what: "the same, left running and not sealed (X: <name> <distro|vm> [post-install file or a command])", arg: "vm"},
		buildRow{name: "custom golden from a VM", kind: "custom", what: "n makes a VM, its screen/serial/ssh customise it, M on its row seals it as @golden; c then clones it"},
		buildRow{name: "verify the goldens", kind: "tests", what: "klab verify all: boot a clone of each golden and check it", cmd: "klab verify all", arg: "distro"},
		buildRow{name: "kubernetes smoke test", kind: "tests", what: "the cluster's smoke test", cmd: "kube-smoke-test"},
		buildRow{name: "kldload suite", kind: "tests", what: "the kldload test suite", cmd: "kldload-test"},
		// the way back: a minimal install builds all of this after the fact,
		// and takes it down again (the operator's ask, 2026-09-26)
		buildRow{name: "DESTROY-klab-goldens", kind: "remove", what: "klab destroy goldens: every klab golden (clones of them refuse it; delete those first)", cmd: "klab destroy goldens", have: sumKlab, danger: true},
		buildRow{name: "DESTROY-appliances", kind: "remove", what: "vmxplore --destroy-all --yes: every app-* and st-* VM, their zvols, seeds, Firecracker goldens and mesh peers", cmd: "vmxplore --destroy-all --yes", have: appsHave, danger: true},
		buildRow{name: "DESTROY-the-cluster", kind: "remove", what: "kube-cluster destroy: every control plane and worker VM and zvol", cmd: "kube-cluster destroy", have: nodesHave, danger: true},
		buildRow{name: "remove one golden or node", kind: "remove", what: "d on its row in VMs (kvm-delete): a golden with clones refuses; a cluster node's peers are dropped on the next scale"},
	)
	return rows
}

// nodesHave counts the cluster's domains on this host: control planes and
// workers, by the names kube-cluster gives them.
func nodesHave(_ map[string]bool, _ int) string {
	out, err := run(10*time.Second, "virsh", "list", "--all", "--name")
	if err != nil {
		return "-"
	}
	cps, ws := 0, 0
	for _, n := range strings.Fields(out) {
		switch {
		case n == "kldload-cp" || strings.HasPrefix(n, "kldload-cp-"):
			cps++
		case strings.HasPrefix(n, "kldload-w-"):
			ws++
		}
	}
	if cps+ws == 0 {
		return "no cluster"
	}
	return fmt.Sprintf("%d cp, %d workers", cps, ws)
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

func loadBuild(d *sectionData) {
	d.columns = []string{"build", "kind", "have", "what it builds", "command"}
	goldens := map[string]bool{}
	if out, err := run(30*time.Second, "zfs", "list", "-H", "-o", "name", "-t", "snapshot", "-r", "rpool/vms"); err == nil {
		for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
			if ds, snap, ok := strings.Cut(line, "@"); ok && snap == "golden" {
				goldens[filepath.Base(ds)] = true
			}
		}
	}
	apps := 0
	if out, err := run(10*time.Second, "virsh", "list", "--all", "--name"); err == nil {
		for _, n := range strings.Fields(out) {
			if strings.HasPrefix(n, "app-") {
				apps++
			}
		}
	}
	for _, r := range buildRows() {
		have := "-"
		if r.have != nil {
			have = r.have(goldens, apps)
		}
		danger := ""
		if r.danger {
			danger = "typed"
		}
		d.rows = append(d.rows, []string{r.name, r.kind, have, r.what, r.cmd, r.arg, danger})
	}
	d.headline = fmt.Sprintf("%d goldens on this host — x builds the row (a job pane), X asks for its argument (a distro, a format); rows with several commands run them in order", len(goldens))
}

// ── the light VM stats path ─────────────────────────────────────────────
// domStats reads every domain's state, cpu time, memory and vcpus in one
// virsh call and turns two consecutive cpu times into a CPU percentage,
// the way vmxplore's 2 s estate refresh does.

type domStat struct {
	state  string
	vcpus  int
	memKiB int64
	cpuPct string
	cpuNs  int64 // cpu.time as read; the percentage is computed once the row is complete
}

var (
	cpuMu   sync.Mutex
	cpuPrev = map[string]struct {
		ns int64
		at time.Time
	}{}
)

var domStates = map[string]string{"1": "running", "2": "blocked", "3": "paused", "4": "in shutdown", "5": "shut off", "6": "crashed", "7": "pmsuspended"}

func domStats() map[string]domStat {
	out, err := run(15*time.Second, "virsh", "domstats", "--state", "--cpu-total", "--balloon", "--vcpu")
	if err != nil {
		return map[string]domStat{}
	}
	now := time.Now()
	res := map[string]domStat{}
	cpuMu.Lock()
	defer cpuMu.Unlock()
	cur, st := "", domStat{}
	flush := func() {
		if cur == "" {
			return
		}
		// cpu.time arrives before the vcpu lines, so the percentage waits
		// for the whole block (the first cut computed it on the cpu.time
		// line, when vcpus was still 0, and every row read "-")
		if st.cpuNs > 0 {
			if p, ok := cpuPrev[cur]; ok && st.vcpus > 0 && now.After(p.at) && st.cpuNs >= p.ns {
				pct := float64(st.cpuNs-p.ns) / float64(now.Sub(p.at).Nanoseconds()) / float64(st.vcpus) * 100
				st.cpuPct = fmt.Sprintf("%.0f%%", min(pct, 100))
			}
			cpuPrev[cur] = struct {
				ns int64
				at time.Time
			}{st.cpuNs, now}
		}
		res[cur] = st
		cur, st = "", domStat{}
	}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "Domain: '") {
			flush()
			cur = strings.TrimSuffix(strings.TrimPrefix(line, "Domain: '"), "'")
			st.cpuPct = "-"
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok || cur == "" {
			continue
		}
		switch k {
		case "state.state":
			st.state = domStates[v]
		case "vcpu.current":
			st.vcpus, _ = strconv.Atoi(v)
		case "vcpu.maximum":
			if st.vcpus == 0 {
				st.vcpus, _ = strconv.Atoi(v)
			}
		case "balloon.maximum":
			st.memKiB, _ = strconv.ParseInt(v, 10, 64)
		case "cpu.time":
			st.cpuNs, _ = strconv.ParseInt(v, 10, 64)
		}
	}
	flush()
	// a domain that is not running has no cpu.time line and no percentage
	for n, s := range res {
		if s.state != "running" {
			s.cpuPct = "-"
			res[n] = s
		}
	}
	return res
}

// vmSnapCounts counts the snapshots under rpool/vms per zvol, cached for
// 30 s: the listing is 700 ms and the count does not change under a
// keypress (vmxplore refreshes ZFS every 30 s for the same reason).
var (
	snapMu    sync.Mutex
	snapCache map[string]int
	snapAt    time.Time
)

func vmSnapCounts() map[string]int {
	snapMu.Lock()
	defer snapMu.Unlock()
	if snapCache != nil && time.Since(snapAt) < 30*time.Second {
		return snapCache
	}
	snaps := map[string]int{}
	if out, err := run(30*time.Second, "zfs", "list", "-H", "-o", "name", "-t", "snapshot", "-r", "rpool/vms"); err == nil {
		for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
			if ds, _, ok := strings.Cut(line, "@"); ok {
				snaps[filepath.Base(ds)]++
			}
		}
	}
	snapCache, snapAt = snaps, time.Now()
	return snaps
}

// invalidateSnapCounts is for the verbs that change them (snapshot,
// rollback, delete): the next table load counts again.
func invalidateSnapCounts() {
	snapMu.Lock()
	snapAt = time.Time{}
	snapMu.Unlock()
}

// dominfoAll runs virsh dominfo for the named domains, eight at a time,
// and returns their vcpu count and maximum memory.
type domInfo struct{ cpus, mem string }

func dominfoAll(names []string) map[string]domInfo {
	res := map[string]domInfo{}
	if len(names) == 0 {
		return res
	}
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 8)
	for _, name := range names {
		wg.Add(1)
		go func(name string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			info, _ := run(10*time.Second, "virsh", "dominfo", name)
			var di domInfo
			for _, line := range strings.Split(info, "\n") {
				k, v, ok := strings.Cut(line, ":")
				if !ok {
					continue
				}
				v = strings.TrimSpace(v)
				switch strings.TrimSpace(k) {
				case "CPU(s)":
					di.cpus = v
				case "Max memory":
					if f := strings.Fields(v); len(f) > 0 {
						if kib, err := strconv.ParseInt(f[0], 10, 64); err == nil {
							di.mem = human(kib * 1024)
						}
					}
				}
			}
			mu.Lock()
			res[name] = di
			mu.Unlock()
		}(name)
	}
	wg.Wait()
	return res
}

// vmAddresses is kldload-vm-ip --all --json, cached for 15 s: it probes
// lease, agent and ARP for every VM and costs 1.5 s, and an address does
// not change under a keypress.
var (
	ipMu    sync.Mutex
	ipCache map[string]string
	ipAt    time.Time
)

func vmAddresses() map[string]string {
	ipMu.Lock()
	defer ipMu.Unlock()
	if ipCache != nil && time.Since(ipAt) < 15*time.Second {
		return ipCache
	}
	ips := map[string]string{}
	if out, err := run(20*time.Second, "kldload-vm-ip", "--all", "--json"); err == nil {
		_ = jsonUnmarshal(out, &ips)
	}
	ipCache, ipAt = ips, time.Now()
	return ips
}
