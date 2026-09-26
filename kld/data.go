// data.go — what each section reads, and from which tool.
//
// A section has sub-tabs; each (section, sub) pair has one collector that
// shells out to the tool that owns the fact and parses its output; none of
// them re-derives anything. Collectors run in a tea.Cmd, so a slow one
// (kldload-estate ~3 s, kldload-doctor ~2 s) never freezes the keys. Each
// returns a sectionData: a headline, columns, rows, and the error the tool
// gave, and the model shows whichever it got.
//
// A "context" narrows a sub to one thing chosen on another: Enter on a VM
// opens Machines/Snapshots for that VM, Enter on a dataset opens
// Storage/Snapshots for that dataset.
package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type section struct {
	name string
	subs []string
}

// Section order is the sidebar order of the web console, and the number keys.
var sections = []section{
	{"Overview", []string{"Summary"}},
	{"Machines", []string{"VMs", "Snapshots", "microVMs", "Networks", "Pools"}},
	{"Storage", []string{"Pools", "Topology", "Datasets", "Snapshots", "Boot envs", "ARC"}},
	{"Network", []string{"Planes", "Peers", "Enrolled", "Fleet"}},
	{"Cluster", []string{"Nodes", "Pods", "Deployments", "Services"}},
	{"Ansible", []string{"Hosts", "Groups", "Plays"}},
	{"Helm", []string{"Releases", "Examples"}},
	{"Metrics", []string{"Targets"}},
	{"Estate", []string{"Drift", "Units", "Events"}},
	{"Provision", []string{"Armed", "Feed", "Goldens", "Answers"}},
}

func sectionNames() []string {
	out := make([]string, len(sections))
	for i, s := range sections {
		out[i] = strings.ToLower(s.name)
	}
	return out
}

func sectionIndex(name string) int {
	for i, s := range sections {
		if strings.EqualFold(s.name, name) {
			return i
		}
	}
	return -1
}

func subIndex(si int, name string) int {
	for j, s := range sections[si].subs {
		if strings.EqualFold(strings.ReplaceAll(s, " ", ""), strings.ReplaceAll(name, " ", "")) {
			return j
		}
	}
	return -1
}

// sectionData is one loaded (section, sub): a headline, table rows (the
// first column is what verbs act on), and the tool that answered — or the
// error it gave.
type sectionData struct {
	section  int
	sub      int
	ctx      string
	headline string
	columns  []string
	rows     [][]string
	err      string
	loadedAt time.Time
}

// run executes a tool with a bound and returns its stdout. Elevation is
// sudo -n: kld is not setuid and does not re-exec itself as root (rule 9,
// --help before any side effect, is why main.go handles help first).
func run(timeout time.Duration, name string, args ...string) (string, error) {
	cmd := exec.Command("sudo", append([]string{"-n", name}, args...)...)
	done := make(chan struct{})
	var out []byte
	var err error
	go func() { out, err = cmd.Output(); close(done) }()
	select {
	case <-done:
	case <-time.After(timeout):
		_ = cmd.Process.Kill()
		return "", fmt.Errorf("%s: no answer in %s", name, timeout)
	}
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			return string(out), fmt.Errorf("%s: %s", name, strings.TrimSpace(string(ee.Stderr)))
		}
		return string(out), fmt.Errorf("%s: %v", name, err)
	}
	return string(out), nil
}

func loadSection(si, sub int, ctx string) sectionData {
	d := sectionData{section: si, sub: sub, ctx: ctx, loadedAt: time.Now()}
	key := sections[si].name + "/" + sections[si].subs[sub]
	if f, ok := collectors[key]; ok {
		f(&d)
	} else {
		d.err = "no collector for " + key
	}
	return d
}

var collectors = map[string]func(*sectionData){
	"Overview/Summary":    loadOverview,
	"Machines/VMs":        loadVMs,
	"Machines/Snapshots":  loadVMSnapshots,
	"Machines/microVMs":   loadMicroVMs,
	"Machines/Networks":   loadVMNetworks,
	"Machines/Pools":      loadVMPools,
	"Storage/Pools":       loadPools,
	"Storage/Topology":    loadTopology,
	"Storage/Datasets":    loadDatasets,
	"Storage/Snapshots":   loadSnapshots,
	"Storage/Boot envs":   loadBootEnvs,
	"Storage/ARC":         loadARC,
	"Network/Planes":      loadPlanes,
	"Network/Peers":       loadPeers,
	"Network/Enrolled":    loadEnrolled,
	"Network/Fleet":       loadFleet,
	"Cluster/Nodes":       loadNodes,
	"Cluster/Pods":        loadPods,
	"Cluster/Deployments": loadDeployments,
	"Cluster/Services":    loadServices,
	"Ansible/Hosts":       loadAnsibleHosts,
	"Ansible/Groups":      loadAnsibleGroups,
	"Ansible/Plays":       loadPlays,
	"Helm/Releases":       loadReleases,
	"Helm/Examples":       loadHelmExamples,
	"Metrics/Targets":     loadMetrics,
	"Estate/Drift":        loadEstate,
	"Estate/Units":        loadUnits,
	"Estate/Events":       loadEvents,
	"Provision/Armed":     loadProvision,
	"Provision/Feed":      loadFeed,
	"Provision/Goldens":   loadGoldens,
	"Provision/Answers":   loadAnswers,
}

// ── kldload-estate ──────────────────────────────────────────────────────────

type estateMachine struct {
	Name       string `json:"name"`
	Class      string `json:"class"`
	Power      string `json:"power"`
	DBStatus   string `json:"db_status"`
	IP         string `json:"ip"`
	Network    string `json:"network"`
	InMesh     bool   `json:"in_mesh"`
	MeshIfaces string `json:"mesh_ifaces"`
	MeshID     string `json:"mesh_id"`
	K8s        string `json:"k8s"`
	GoldenSrc  string `json:"golden_src"`
}

type estateDrift struct {
	Machine string `json:"machine"`
	Kind    string `json:"kind"`
	Detail  string `json:"detail"`
	Repair  string `json:"repair"`
}

type estateReport struct {
	Machines []estateMachine `json:"machines"`
	Drift    []estateDrift   `json:"drift"`
	Sources  map[string]bool `json:"sources"`
}

func readEstate() (estateReport, error) {
	var r estateReport
	out, err := run(60*time.Second, "kldload-estate")
	if err != nil {
		return r, err
	}
	if err := json.Unmarshal([]byte(out), &r); err != nil {
		return r, fmt.Errorf("kldload-estate: %v", err)
	}
	return r, nil
}

// ── Machines ────────────────────────────────────────────────────────────────

// loadVMs is libvirt's own list with the address resolver and the state DB
// on top: what vmxplore's estate shows, in the order it shows it. A per-VM
// dominfo costs 50 ms; forty VMs is two seconds, which is why the address
// and the DB row come from one call each.
func loadVMs(d *sectionData) {
	names, err := run(15*time.Second, "virsh", "list", "--all", "--name")
	if err != nil {
		d.err = err.Error()
		return
	}
	ips := map[string]string{}
	if out, err := run(20*time.Second, "kldload-vm-ip", "--all", "--json"); err == nil {
		_ = json.Unmarshal([]byte(out), &ips)
	}
	type dbrow struct {
		Name, Role, Cluster, Status, MeshID, Golden string
	}
	db := map[string]dbrow{}
	if out, err := run(15*time.Second, "kldload-db", "dump"); err == nil {
		var dump struct {
			VMs []struct {
				Name      string `json:"name"`
				Role      string `json:"role"`
				ClusterID string `json:"cluster_id"`
				Status    string `json:"status"`
				MeshID    string `json:"mesh_id"`
				GoldenSrc string `json:"golden_src"`
				DeletedAt string `json:"deleted_at"`
			} `json:"vms"`
		}
		if json.Unmarshal([]byte(out), &dump) == nil {
			for _, v := range dump.VMs {
				if v.DeletedAt == "" {
					db[v.Name] = dbrow{v.Name, v.Role, v.ClusterID, v.Status, v.MeshID, v.GoldenSrc}
				}
			}
		}
	}
	d.columns = []string{"vm", "state", "vcpus", "memory", "address", "mesh", "role", "from"}
	running := 0
	for _, name := range strings.Fields(names) {
		info, _ := run(10*time.Second, "virsh", "dominfo", name)
		state, cpus, mem := "?", "-", "-"
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
			}
		}
		if state == "running" {
			running++
		}
		r := db[name]
		d.rows = append(d.rows, []string{name, state, cpus, mem, orDash(ips[name]), orDash(r.MeshID), orDash(r.Role), orDash(r.Golden)})
	}
	d.headline = fmt.Sprintf("%d machines, %d running (libvirt · kldload-vm-ip · state.db)", len(d.rows), running)
}

// loadVMSnapshots lists the zvol snapshots under rpool/vms — what kvm-snap
// list shows per VM, for every VM at once (one zfs call, a second on onyx).
// With a context it is that VM's snapshots alone.
func loadVMSnapshots(d *sectionData) {
	out, err := run(30*time.Second, "zfs", "list", "-H", "-p", "-t", "snapshot", "-o", "name,used,creation", "-S", "creation", "-r", "rpool/vms")
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"vm", "snapshot", "used", "created"}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		f := strings.Split(line, "\t")
		if len(f) < 3 || !strings.Contains(f[0], "@") {
			continue
		}
		ds, snap, _ := strings.Cut(f[0], "@")
		vm := filepath.Base(ds)
		if d.ctx != "" && vm != d.ctx {
			continue
		}
		used, _ := strconv.ParseInt(f[1], 10, 64)
		ts, _ := strconv.ParseInt(f[2], 10, 64)
		d.rows = append(d.rows, []string{vm, snap, human(used), time.Unix(ts, 0).Format("2006-01-02 15:04")})
	}
	if d.ctx != "" {
		d.headline = fmt.Sprintf("%d snapshots of %s (kvm-snap %s list)", len(d.rows), d.ctx, d.ctx)
	} else {
		d.headline = fmt.Sprintf("%d VM snapshots under rpool/vms", len(d.rows))
	}
}

// loadMicroVMs is kfire's listing: Firecracker instances cloned from
// appliance goldens, each with its state, address and sizes. kfire prints
// one JSON object per line between brackets; each line is parsed on its own.
func loadMicroVMs(d *sectionData) {
	if _, err := exec.LookPath("kfire"); err != nil {
		d.err = "kfire is not installed on this host"
		return
	}
	out, err := run(30*time.Second, "kfire", "list", "--json")
	if err != nil && strings.TrimSpace(out) == "" {
		d.err = err.Error()
		return
	}
	d.columns = []string{"microvm", "state", "address", "golden", "vcpus", "ram", "tap"}
	running := 0
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSuffix(strings.TrimSpace(line), ",")
		if !strings.HasPrefix(line, "{") {
			continue
		}
		var m map[string]any
		if json.Unmarshal([]byte(line), &m) != nil {
			continue
		}
		if str(m["state"]) == "running" {
			running++
		}
		ram := str(m["ram_mb"])
		if n, err := strconv.ParseInt(ram, 10, 64); err == nil {
			ram = human(n * 1024 * 1024)
		}
		d.rows = append(d.rows, []string{str(m["name"]), orDash(str(m["state"])), orDash(str(m["ip"])), orDash(str(m["golden"])), orDash(str(m["vcpus"])), orDash(ram), orDash(str(m["tap"]))})
	}
	d.headline = fmt.Sprintf("%d Firecracker microVMs, %d running (kfire list)", len(d.rows), running)
	if len(d.rows) == 0 {
		d.headline = "no Firecracker microVMs — clone one from an appliance golden (c)"
	}
}

func loadVMNetworks(d *sectionData) {
	out, err := run(15*time.Second, "virsh", "net-list", "--all")
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"network", "state", "autostart", "persistent", "bridge", "range"}
	for _, line := range strings.Split(out, "\n")[2:] {
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		bridge, rng := "-", "-"
		if xml, err := run(10*time.Second, "virsh", "net-dumpxml", f[0]); err == nil {
			bridge = attr(xml, "<bridge", "name")
			if ip := attr(xml, "<ip", "address"); ip != "" {
				rng = ip + "/" + orDash(attr(xml, "<ip", "netmask"))
			}
		}
		d.rows = append(d.rows, []string{f[0], f[1], f[2], f[3], bridge, rng})
	}
	d.headline = fmt.Sprintf("%d libvirt networks", len(d.rows))
}

func loadVMPools(d *sectionData) {
	out, err := run(15*time.Second, "virsh", "pool-list", "--all", "--details")
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"pool", "state", "autostart", "persistent", "capacity", "allocated", "available"}
	for _, line := range strings.Split(out, "\n")[2:] {
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		row := []string{f[0], f[1], f[2], f[3], "-", "-", "-"}
		if len(f) >= 10 {
			row[4], row[5], row[6] = f[4]+f[5], f[6]+f[7], f[8]+f[9]
		}
		d.rows = append(d.rows, row)
	}
	d.headline = fmt.Sprintf("%d libvirt storage pools", len(d.rows))
}

// attr pulls one attribute off the first element that starts with tag; the
// libvirt XML here is small and regular enough that a parser would be more
// code than certainty.
func attr(xml, tag, name string) string {
	i := strings.Index(xml, tag)
	if i < 0 {
		return ""
	}
	rest := xml[i:]
	if j := strings.Index(rest, ">"); j >= 0 {
		rest = rest[:j]
	}
	k := strings.Index(rest, name+"='")
	if k < 0 {
		return ""
	}
	rest = rest[k+len(name)+2:]
	if e := strings.Index(rest, "'"); e >= 0 {
		return rest[:e]
	}
	return ""
}

// ── Storage ─────────────────────────────────────────────────────────────────

func loadPools(d *sectionData) {
	out, err := run(15*time.Second, "zpool", "list", "-H", "-o", "name,size,alloc,free,frag,cap,dedup,health")
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"pool", "size", "alloc", "free", "frag", "cap", "dedup", "health"}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if f := strings.Fields(line); len(f) >= 8 {
			d.rows = append(d.rows, f[:8])
		}
	}
	st, err := run(30*time.Second, "kldload-rollback", "status")
	if err != nil {
		d.headline = fmt.Sprintf("%d pool(s); rollback status: %v", len(d.rows), err)
		return
	}
	var bits []string
	for _, line := range strings.Split(st, "\n") {
		k, v, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		switch k {
		case "Running from", "Next boot", "Boot path":
			bits = append(bits, k+" "+v)
		}
	}
	d.headline = fmt.Sprintf("%d pool(s) · %s", len(d.rows), strings.Join(bits, " · "))
}

// loadTopology is `zpool status` as rows: every vdev with its state and
// error counters, indented by depth the way zpool prints it, and the scrub
// line as the headline — what zxplore's pool view shows first.
func loadTopology(d *sectionData) {
	out, err := run(30*time.Second, "zpool", "status", "-P")
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"vdev", "pool", "state", "read", "write", "cksum", "note"}
	var pool string
	var scrubs []string
	inConfig := false
	for _, raw := range strings.Split(out, "\n") {
		line := strings.TrimRight(raw, " ")
		t := strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(t, "pool:"):
			pool = strings.TrimSpace(strings.TrimPrefix(t, "pool:"))
			inConfig = false
		case strings.HasPrefix(t, "scan:"):
			scrubs = append(scrubs, pool+": "+strings.TrimSpace(strings.TrimPrefix(t, "scan:")))
		case strings.HasPrefix(t, "config:"):
			inConfig = true
		case strings.HasPrefix(t, "errors:"):
			inConfig = false
			if !strings.Contains(t, "No known data errors") {
				d.rows = append(d.rows, []string{"errors", pool, "ERROR", "", "", "", strings.TrimSpace(strings.TrimPrefix(t, "errors:"))})
			}
		case inConfig && t != "":
			f := strings.Fields(t)
			if f[0] == "NAME" || len(f) < 2 {
				continue
			}
			// depth from the indentation zpool prints (a tab, then two spaces per level)
			depth := (len(line) - len(strings.TrimLeft(line, " \t")) - 1) / 2
			if depth < 0 {
				depth = 0
			}
			row := []string{strings.Repeat("  ", depth) + f[0], pool, f[1], "", "", "", ""}
			if len(f) >= 5 {
				row[3], row[4], row[5] = f[2], f[3], f[4]
			}
			if len(f) > 5 {
				row[6] = strings.Join(f[5:], " ")
			}
			d.rows = append(d.rows, row)
		}
	}
	d.headline = strings.Join(scrubs, " · ")
	if d.headline == "" {
		d.headline = fmt.Sprintf("%d vdev rows", len(d.rows))
	}
}

func loadDatasets(d *sectionData) {
	out, err := run(30*time.Second, "zfs", "list", "-H", "-p", "-o", "name,type,used,avail,refer,mountpoint,compressratio", "-t", "filesystem,volume")
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"dataset", "type", "used", "avail", "refer", "mountpoint", "ratio"}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		f := strings.Split(line, "\t")
		if len(f) < 7 {
			continue
		}
		used, _ := strconv.ParseInt(f[2], 10, 64)
		avail, _ := strconv.ParseInt(f[3], 10, 64)
		refer, _ := strconv.ParseInt(f[4], 10, 64)
		d.rows = append(d.rows, []string{f[0], f[1], human(used), human(avail), human(refer), f[5], f[6]})
	}
	d.headline = fmt.Sprintf("%d datasets and volumes (enter: a dataset's snapshots)", len(d.rows))
}

// loadSnapshots without a context reads every snapshot (eight to eleven
// seconds on onyx's 4,800; the spinner covers it); with one, that dataset's
// own in 75 ms.
func loadSnapshots(d *sectionData) {
	args := []string{"list", "-H", "-p", "-t", "snapshot", "-o", "name,used,refer,creation", "-S", "creation"}
	if d.ctx != "" {
		args = append(args, "-d1", d.ctx)
	}
	out, err := run(120*time.Second, "zfs", args...)
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"snapshot", "dataset", "used", "refer", "created"}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		f := strings.Split(line, "\t")
		if len(f) < 4 || !strings.Contains(f[0], "@") {
			continue
		}
		ds, snap, _ := strings.Cut(f[0], "@")
		used, _ := strconv.ParseInt(f[1], 10, 64)
		refer, _ := strconv.ParseInt(f[2], 10, 64)
		ts, _ := strconv.ParseInt(f[3], 10, 64)
		d.rows = append(d.rows, []string{f[0], ds, human(used), human(refer), time.Unix(ts, 0).Format("2006-01-02 15:04")})
		_ = snap
	}
	if d.ctx != "" {
		d.headline = fmt.Sprintf("%d snapshots of %s", len(d.rows), d.ctx)
	} else {
		d.headline = fmt.Sprintf("%d snapshots on the host", len(d.rows))
	}
}

func loadBootEnvs(d *sectionData) {
	st, err := run(30*time.Second, "kldload-rollback", "status")
	if err != nil {
		d.err = err.Error()
		return
	}
	status := map[string]string{}
	for _, line := range strings.Split(st, "\n") {
		if k, v, ok := strings.Cut(line, ":"); ok {
			status[strings.TrimSpace(k)] = strings.TrimSpace(v)
		}
	}
	running := status["Running from"]
	d.headline = fmt.Sprintf("running %s · next boot %s · %s", orDash(running), orDash(status["Next boot"]), orDash(status["Boot path"]))
	if v := status["Staged rollback"]; v != "" {
		d.headline += " · STAGED: " + v
	}
	// the environments, then the running one's snapshots (what `rollback
	// to` takes)
	d.columns = []string{"name", "kind", "created", "used", "source"}
	if out, err := run(15*time.Second, "zfs", "list", "-H", "-p", "-o", "name,used,creation", "-r", "-d1", "-t", "filesystem", "rpool/ROOT"); err == nil {
		for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
			f := strings.Split(line, "\t")
			if len(f) < 3 || f[0] == "rpool/ROOT" {
				continue
			}
			used, _ := strconv.ParseInt(f[1], 10, 64)
			ts, _ := strconv.ParseInt(f[2], 10, 64)
			kind := "environment"
			if f[0] == running {
				kind = "environment (running)"
			}
			if f[0] == status["Next boot"] {
				kind += " (boots next)"
			}
			d.rows = append(d.rows, []string{f[0], kind, time.Unix(ts, 0).Format("2006-01-02 15:04"), human(used), "-"})
		}
	}
	if running != "" {
		if out, err := run(15*time.Second, "zfs", "list", "-H", "-p", "-t", "snapshot", "-o", "name,used,creation", "-S", "creation", "-d1", running); err == nil {
			for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
				f := strings.Split(line, "\t")
				if len(f) < 3 {
					continue
				}
				used, _ := strconv.ParseInt(f[1], 10, 64)
				ts, _ := strconv.ParseInt(f[2], 10, 64)
				_, snap, _ := strings.Cut(f[0], "@")
				d.rows = append(d.rows, []string{f[0], "snapshot", time.Unix(ts, 0).Format("2006-01-02 15:04"), human(used), snapFamily(snap)})
			}
		}
	}
}

func snapFamily(s string) string {
	switch {
	case strings.HasPrefix(s, "autosnap"):
		return "sanoid"
	case strings.HasPrefix(s, "dnf-pre"), strings.HasPrefix(s, "apt-pre"):
		return "pre-transaction"
	case strings.HasPrefix(s, "kpkg"):
		return "kpkg"
	case strings.HasPrefix(s, "install"):
		return "install"
	case strings.HasPrefix(s, "auto-"):
		return "kldload-snapshot"
	}
	return "manual"
}

// loadARC reads the ARC's own counters from /proc/spl/kstat/zfs/arcstats:
// size against its ceiling, the hit ratio, and what the cache holds — the
// numbers zxplore's Observe tab watches, as one table.
func loadARC(d *sectionData) {
	out, err := run(5*time.Second, "cat", "/proc/spl/kstat/zfs/arcstats")
	if err != nil {
		d.err = "arcstats: " + err.Error()
		return
	}
	st := map[string]int64{}
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) == 3 {
			if v, err := strconv.ParseInt(f[2], 10, 64); err == nil {
				st[f[0]] = v
			}
		}
	}
	ratio := func(a, b int64) string {
		if a+b == 0 {
			return "-"
		}
		return fmt.Sprintf("%.1f%%", 100*float64(a)/float64(a+b))
	}
	d.columns = []string{"counter", "value", "about"}
	rows := [][]string{
		{"size", human(st["size"]), "ARC in use"},
		{"c", human(st["c"]), "target size"},
		{"c_max", human(st["c_max"]), "ceiling (zfs_arc_max)"},
		{"c_min", human(st["c_min"]), "floor"},
		{"hit ratio", ratio(st["hits"], st["misses"]), "hits / (hits + misses) since boot"},
		{"hits", strconv.FormatInt(st["hits"], 10), ""},
		{"misses", strconv.FormatInt(st["misses"], 10), ""},
		{"demand data", ratio(st["demand_data_hits"], st["demand_data_misses"]), "file data hit ratio"},
		{"demand metadata", ratio(st["demand_metadata_hits"], st["demand_metadata_misses"]), "metadata hit ratio"},
		{"prefetch data", ratio(st["prefetch_data_hits"], st["prefetch_data_misses"]), "prefetch hit ratio"},
		{"mru", human(st["mru_size"]), "recently used"},
		{"mfu", human(st["mfu_size"]), "frequently used"},
		{"data", human(st["data_size"]), "file data held"},
		{"metadata", human(st["metadata_size"]), "metadata held"},
		{"dnode", human(st["dnode_size"]), "dnodes held"},
		{"l2 size", human(st["l2_size"]), "L2ARC (0 without a cache device)"},
		{"l2 hit ratio", ratio(st["l2_hits"], st["l2_misses"]), ""},
		{"memory throttle", strconv.FormatInt(st["memory_throttle_count"], 10), "times the ARC was throttled for memory"},
	}
	d.rows = rows
	d.headline = fmt.Sprintf("ARC %s of %s (target %s) · hit ratio %s", human(st["size"]), human(st["c_max"]), human(st["c"]), ratio(st["hits"], st["misses"]))
}

// loadFleet is wgx's estate tree: every host it can ssh to, every plane,
// every peer, as lines — the one view that looks past this host.
func loadFleet(d *sectionData) {
	if _, err := exec.LookPath("wgx"); err != nil {
		d.err = "wgx is not installed on this host"
		return
	}
	out, err := run(90*time.Second, "wgx", "estate")
	if err != nil && strings.TrimSpace(out) == "" {
		d.err = err.Error()
		return
	}
	d.columns = []string{"wgx estate"}
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) > 0 {
		d.headline = strings.TrimSpace(lines[0])
		lines = lines[1:]
	}
	for _, l := range lines {
		if strings.TrimSpace(l) == "" {
			continue
		}
		d.rows = append(d.rows, []string{l})
	}
}

// ── Network: wg show dump ───────────────────────────────────────────────────

type peer struct {
	plane, key, endpoint, allowed string
	handshake                     int64
	rx, tx                        int64
}

func readPeers() ([]string, []peer, error) {
	ifs, err := run(10*time.Second, "wg", "show", "interfaces")
	if err != nil {
		return nil, nil, err
	}
	planes := strings.Fields(ifs)
	var peers []peer
	for _, iface := range planes {
		dump, err := run(10*time.Second, "wg", "show", iface, "dump")
		if err != nil {
			continue
		}
		for i, line := range strings.Split(strings.TrimSpace(dump), "\n") {
			f := strings.Split(line, "\t")
			if i == 0 || len(f) < 7 {
				continue // the first line is this interface's own keys
			}
			p := peer{plane: iface, key: f[0], endpoint: strings.TrimPrefix(f[2], "(none)"), allowed: f[3]}
			p.handshake, _ = strconv.ParseInt(f[4], 10, 64)
			p.rx, _ = strconv.ParseInt(f[5], 10, 64)
			p.tx, _ = strconv.ParseInt(f[6], 10, 64)
			peers = append(peers, p)
		}
	}
	return planes, peers, nil
}

func handshakeAge(ts int64) (string, bool) {
	if ts == 0 {
		return "never", false
	}
	age := time.Since(time.Unix(ts, 0))
	return age.Truncate(time.Second).String() + " ago", age < 3*time.Minute
}

func loadPlanes(d *sectionData) {
	planes, peers, err := readPeers()
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"plane", "purpose", "peers", "alive", "rx/tx"}
	for _, p := range planes {
		n, alive := 0, 0
		var rx, tx int64
		for _, q := range peers {
			if q.plane != p {
				continue
			}
			n++
			if _, ok := handshakeAge(q.handshake); ok {
				alive++
			}
			rx += q.rx
			tx += q.tx
		}
		purpose := "-"
		switch p {
		case "wg-mgmt":
			purpose = "management 10.250.0.0/24"
		case "wg-k8s":
			purpose = "cluster 10.251.0.0/24"
		}
		d.rows = append(d.rows, []string{p, purpose, strconv.Itoa(n), strconv.Itoa(alive), human(rx) + "/" + human(tx)})
	}
	d.headline = fmt.Sprintf("%d plane(s), %d peers", len(planes), len(peers))
}

func loadPeers(d *sectionData) {
	_, peers, err := readPeers()
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"peer", "plane", "endpoint", "allowed", "handshake", "rx/tx"}
	alive := 0
	for _, p := range peers {
		hs, ok := handshakeAge(p.handshake)
		if ok {
			alive++
		}
		id := p.allowed
		if strings.HasPrefix(p.allowed, "10.25") {
			id = "node " + strings.TrimSuffix(p.allowed[strings.LastIndex(p.allowed, ".")+1:], "/32")
		}
		d.rows = append(d.rows, []string{id, p.plane, orDash(p.endpoint), p.allowed, hs, human(p.rx) + "/" + human(p.tx)})
	}
	d.headline = fmt.Sprintf("%d peers, %d with a handshake in the last 3 min", len(peers), alive)
}

func loadEnrolled(d *sectionData) {
	entries, err := os.ReadDir("/var/lib/kldload/mesh/enrolled")
	if err != nil {
		d.err = "no enrolment records: " + err.Error()
		return
	}
	d.columns = []string{"vm", "mesh id", "public key"}
	for _, e := range entries {
		if e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		rec, _ := run(5*time.Second, "cat", "/var/lib/kldload/mesh/enrolled/"+e.Name())
		id, pub := "-", "-"
		for _, line := range strings.Split(rec, "\n") {
			if v, ok := strings.CutPrefix(line, "node_id="); ok {
				id = v
			}
			if v, ok := strings.CutPrefix(line, "guest_pub="); ok {
				pub = v
			}
		}
		d.rows = append(d.rows, []string{e.Name(), id, pub})
	}
	d.headline = fmt.Sprintf("%d enrolled machines (kldload-enroll records)", len(d.rows))
}

// ── Cluster: kubectl, after a port probe ────────────────────────────────────

// apiserverReachable is the same trick kldload-doctor and kldload-estate use:
// kubectl's --request-timeout does not cover TCP connect, so a stale
// kubeconfig pointing at a dead cluster hung every call for a minute (onyx,
// 2026-09-26). Ask the port first.
func apiserverReachable() (string, bool) {
	out, err := run(10*time.Second, "kubectl", "config", "view", "--minify", "-o", "jsonpath={.clusters[0].cluster.server}")
	server := strings.TrimSpace(out)
	if err != nil || server == "" {
		return "", false
	}
	host := strings.TrimPrefix(strings.TrimPrefix(server, "https://"), "http://")
	if !strings.Contains(host, ":") {
		host += ":443"
	}
	c, err := net.DialTimeout("tcp", host, 1500*time.Millisecond)
	if err != nil {
		return server, false
	}
	_ = c.Close()
	return server, true
}

// kube runs one kubectl listing if the apiserver answers, and sets the
// section's headline to why not otherwise.
func kube(d *sectionData, args ...string) (string, bool) {
	server, ok := apiserverReachable()
	if server == "" {
		d.headline = "no kubeconfig on this host — this is not a cluster node"
		return "", false
	}
	if !ok {
		d.headline = "apiserver " + server + " does not answer (port probe)"
		return "", false
	}
	out, err := run(30*time.Second, "kubectl", append(args, "--request-timeout=15s")...)
	if err != nil {
		d.err = err.Error()
		return "", false
	}
	return out, true
}

func tableRows(d *sectionData, out string, n int) {
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if f := strings.Fields(line); len(f) >= n {
			d.rows = append(d.rows, f[:n])
		}
	}
}

func loadNodes(d *sectionData) {
	out, ok := kube(d, "get", "nodes", "--no-headers", "-o",
		"custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,ROLE:.metadata.labels.node-role\\.kubernetes\\.io/control-plane,VERSION:.status.nodeInfo.kubeletVersion,IP:.status.addresses[0].address,OS:.status.nodeInfo.osImage")
	if !ok {
		return
	}
	d.columns = []string{"node", "status", "control-plane", "kubelet", "address", "os"}
	tableRows(d, out, 6)
	d.headline = fmt.Sprintf("%d node(s)", len(d.rows))
}

func loadPods(d *sectionData) {
	out, ok := kube(d, "get", "pods", "-A", "--no-headers", "-o",
		"custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount,IP:.status.podIP")
	if !ok {
		return
	}
	d.columns = []string{"pod", "namespace", "phase", "node", "restarts", "address"}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if f := strings.Fields(line); len(f) >= 6 {
			d.rows = append(d.rows, []string{f[1], f[0], f[2], f[3], f[4], f[5]})
		}
	}
	d.headline = fmt.Sprintf("%d pod(s) in every namespace", len(d.rows))
}

func loadDeployments(d *sectionData) {
	out, ok := kube(d, "get", "deployments", "-A", "--no-headers", "-o",
		"custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:.status.readyReplicas,WANT:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image")
	if !ok {
		return
	}
	d.columns = []string{"deployment", "namespace", "ready", "wanted", "image"}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if f := strings.Fields(line); len(f) >= 5 {
			d.rows = append(d.rows, []string{f[1], f[0], f[2], f[3], f[4]})
		}
	}
	d.headline = fmt.Sprintf("%d deployment(s)", len(d.rows))
}

func loadServices(d *sectionData) {
	out, ok := kube(d, "get", "services", "-A", "--no-headers", "-o",
		"custom-columns=NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type,CLUSTER-IP:.spec.clusterIP,EXTERNAL:.status.loadBalancer.ingress[0].ip,PORTS:.spec.ports[*].port")
	if !ok {
		return
	}
	d.columns = []string{"service", "namespace", "type", "cluster ip", "external ip", "ports"}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if f := strings.Fields(line); len(f) >= 6 {
			d.rows = append(d.rows, []string{f[1], f[0], f[2], f[3], f[4], f[5]})
		}
	}
	d.headline = fmt.Sprintf("%d service(s)", len(d.rows))
}

// ── Ansible: kldload-inventory and the playbook library ────────────────────

const playbookDir = "/usr/local/share/kldload-ansible/playbooks"

type inventory struct {
	groups map[string][]string
	hosts  map[string]map[string]any
}

func readInventory() (inventory, error) {
	inv := inventory{groups: map[string][]string{}, hosts: map[string]map[string]any{}}
	out, err := run(30*time.Second, "kldload-inventory", "--list")
	if err != nil {
		return inv, err
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(out), &raw); err != nil {
		return inv, fmt.Errorf("kldload-inventory: %v", err)
	}
	for k, v := range raw {
		if k == "_meta" {
			var meta struct {
				Hostvars map[string]map[string]any `json:"hostvars"`
			}
			_ = json.Unmarshal(v, &meta)
			inv.hosts = meta.Hostvars
			continue
		}
		var g struct {
			Hosts []string `json:"hosts"`
		}
		if json.Unmarshal(v, &g) == nil {
			inv.groups[k] = g.Hosts
		}
	}
	return inv, nil
}

func loadAnsibleHosts(d *sectionData) {
	inv, err := readInventory()
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"host", "address", "user", "role", "cluster", "status", "mesh id"}
	names := make([]string, 0, len(inv.hosts))
	for n := range inv.hosts {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		h := inv.hosts[n]
		d.rows = append(d.rows, []string{n, str(h["ansible_host"]), str(h["ansible_user"]), str(h["kldload_role"]), orDash(str(h["kldload_cluster"])), str(h["kldload_status"]), orDash(str(h["kldload_mesh_id"]))})
	}
	d.headline = fmt.Sprintf("%d hosts in the dynamic inventory (kldload-inventory --list)", len(d.rows))
}

func loadAnsibleGroups(d *sectionData) {
	inv, err := readInventory()
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"group", "hosts", "members"}
	names := make([]string, 0, len(inv.groups))
	for n := range inv.groups {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		hs := inv.groups[n]
		d.rows = append(d.rows, []string{n, strconv.Itoa(len(hs)), truncateList(hs, 6)})
	}
	d.headline = fmt.Sprintf("%d groups", len(d.rows))
}

func truncateList(xs []string, n int) string {
	if len(xs) <= n {
		return strings.Join(xs, " ")
	}
	return strings.Join(xs[:n], " ") + fmt.Sprintf(" … +%d", len(xs)-n)
}

func loadPlays(d *sectionData) {
	entries, err := os.ReadDir(playbookDir)
	if err != nil {
		d.err = "no playbook library: " + err.Error()
		return
	}
	d.columns = []string{"playbook", "hosts", "about"}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".yml") {
			continue
		}
		hosts, about := "-", ""
		if b, err := os.ReadFile(filepath.Join(playbookDir, e.Name())); err == nil {
			for _, line := range strings.Split(string(b), "\n") {
				t := strings.TrimSpace(line)
				if v, ok := strings.CutPrefix(t, "hosts:"); ok && hosts == "-" {
					hosts = strings.TrimSpace(v)
				}
				if v, ok := strings.CutPrefix(t, "- name:"); ok && about == "" {
					about = strings.Trim(strings.TrimSpace(v), `"'`)
				}
			}
		}
		d.rows = append(d.rows, []string{e.Name(), hosts, about})
	}
	d.headline = fmt.Sprintf("%d playbooks in %s", len(d.rows), playbookDir)
}

// ── Helm ────────────────────────────────────────────────────────────────────

const helmExamples = "/usr/local/share/kldload-examples/helm"

func loadReleases(d *sectionData) {
	server, ok := apiserverReachable()
	if server == "" {
		d.headline = "no kubeconfig on this host — helm has no cluster to ask"
		return
	}
	if !ok {
		d.headline = "apiserver " + server + " does not answer (port probe)"
		return
	}
	out, err := run(30*time.Second, "helm", "list", "-A", "-o", "json")
	if err != nil {
		d.err = err.Error()
		return
	}
	var raw []map[string]any
	_ = json.Unmarshal([]byte(out), &raw)
	d.columns = []string{"release", "namespace", "revision", "status", "chart", "app version", "updated"}
	for _, r := range raw {
		d.rows = append(d.rows, []string{str(r["name"]), str(r["namespace"]), str(r["revision"]), str(r["status"]), str(r["chart"]), str(r["app_version"]), str(r["updated"])})
	}
	d.headline = fmt.Sprintf("%d release(s) in every namespace", len(d.rows))
}

func loadHelmExamples(d *sectionData) {
	entries, err := os.ReadDir(helmExamples)
	if err != nil {
		d.err = "no helm examples: " + err.Error()
		return
	}
	d.columns = []string{"example", "kind", "about"}
	for _, e := range entries {
		kind, about := "file", ""
		if e.IsDir() {
			kind = "chart"
			if b, err := os.ReadFile(filepath.Join(helmExamples, e.Name(), "Chart.yaml")); err == nil {
				for _, line := range strings.Split(string(b), "\n") {
					if v, ok := strings.CutPrefix(strings.TrimSpace(line), "description:"); ok {
						about = strings.TrimSpace(v)
					}
				}
			}
		} else if strings.HasPrefix(e.Name(), "values-") {
			kind = "values"
		}
		d.rows = append(d.rows, []string{e.Name(), kind, about})
	}
	d.headline = fmt.Sprintf("%d entries in %s", len(d.rows), helmExamples)
}

// ── Metrics: Prometheus targets ─────────────────────────────────────────────

func loadMetrics(d *sectionData) {
	client := http.Client{Timeout: 4 * time.Second}
	resp, err := client.Get("http://localhost:9090/api/v1/targets")
	if err != nil {
		d.err = "prometheus: " + err.Error()
		return
	}
	defer resp.Body.Close()
	var rep struct {
		Data struct {
			Active []struct {
				Labels    map[string]string `json:"labels"`
				Health    string            `json:"health"`
				LastError string            `json:"lastError"`
				ScrapeURL string            `json:"scrapeUrl"`
			} `json:"activeTargets"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&rep); err != nil {
		d.err = "prometheus: " + err.Error()
		return
	}
	d.columns = []string{"target", "job", "health", "url", "last error"}
	up := 0
	for _, t := range rep.Data.Active {
		if t.Health == "up" {
			up++
		}
		name := t.Labels["vm"]
		if name == "" {
			name = t.Labels["instance"]
		}
		d.rows = append(d.rows, []string{name, t.Labels["job"], t.Health, t.ScrapeURL, t.LastError})
	}
	sort.SliceStable(d.rows, func(i, j int) bool { return d.rows[i][2] != "up" && d.rows[j][2] == "up" })
	d.headline = fmt.Sprintf("%d/%d targets up · dashboards: https://%s:8443/grafana/", up, len(rep.Data.Active), hostname())
}

// ── Estate ──────────────────────────────────────────────────────────────────

type doctorCheck struct {
	Name        string `json:"name"`
	Subsystem   string `json:"subsystem"`
	Status      string `json:"status"`
	Actual      string `json:"actual"`
	Remediation string `json:"remediation"`
}

func readDoctor() ([]doctorCheck, map[string]int, error) {
	out, err := run(120*time.Second, "kldload-doctor", "--json")
	if err != nil && strings.TrimSpace(out) == "" {
		return nil, nil, err
	}
	var rep struct {
		Results []doctorCheck  `json:"results"`
		Summary map[string]int `json:"summary"`
	}
	if err := json.Unmarshal([]byte(out), &rep); err != nil {
		return nil, nil, fmt.Errorf("kldload-doctor: %v", err)
	}
	return rep.Results, rep.Summary, nil
}

func loadEstate(d *sectionData) {
	r, err := readEstate()
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"machine", "finding", "detail", "repair"}
	for _, x := range r.Drift {
		d.rows = append(d.rows, []string{x.Machine, x.Kind, x.Detail, x.Repair})
	}
	src := []string{}
	for k, v := range r.Sources {
		if v {
			src = append(src, k)
		}
	}
	sort.Strings(src)
	d.headline = fmt.Sprintf("%d machines across %s; %d drift", len(r.Machines), strings.Join(src, ", "), len(r.Drift))
	// The doctor's failures and warnings belong on the same page: drift is
	// where sources disagree, the doctor is where the host disagrees with
	// its baseline.
	if res, sum, err := readDoctor(); err != nil {
		d.rows = append(d.rows, []string{"doctor", "did not run", err.Error(), ""})
	} else {
		d.headline += fmt.Sprintf("; doctor %d ok %d warn %d fail %d skip", sum["ok"], sum["warn"], sum["fail"], sum["skip"])
		for _, c := range res {
			if c.Status == "fail" || c.Status == "warn" {
				d.rows = append(d.rows, []string{"doctor:" + c.Subsystem, c.Status + " " + c.Name, c.Actual, c.Remediation})
			}
		}
	}
}

// loadUnits is every kldload-* and klab-* unit with its state — "is the
// first boot done", "is the netboot server up", "did the enrol sweep run"
// — the questions that used to take a systemctl pattern to answer.
func loadUnits(d *sectionData) {
	out, err := run(15*time.Second, "systemctl", "list-units", "--all", "--no-legend", "--plain",
		"kldload-*", "klab-*", "kfire-*", "grafana-server.service", "prometheus.service", "libvirtd.service", "nginx.service")
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"unit", "load", "active", "sub", "description"}
	running, failed := 0, 0
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		f := strings.Fields(line)
		if len(f) < 4 {
			continue
		}
		switch f[3] {
		case "running":
			running++
		case "failed":
			failed++
		}
		d.rows = append(d.rows, []string{f[0], f[1], f[2], f[3], strings.Join(f[4:], " ")})
	}
	// timers too: the sweeps and snapshots that run on their own
	if out, err := run(15*time.Second, "systemctl", "list-timers", "--all", "--no-legend", "--plain", "kldload-*", "klab-*"); err == nil {
		for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
			f := strings.Fields(line)
			if len(f) < 6 {
				continue
			}
			// NEXT LEFT LAST PASSED UNIT ACTIVATES: the unit is the second-to-last field
			unit := f[len(f)-2]
			d.rows = append(d.rows, []string{unit, "timer", "next " + f[0] + " " + f[1], "left " + strings.Join(f[2:len(f)-6+2], " "), "activates " + f[len(f)-1]})
		}
	}
	d.headline = fmt.Sprintf("%d units, %d running, %d failed", len(d.rows), running, failed)
	if failed > 0 {
		d.headline = fmt.Sprintf("%d units, %d running, %d FAILED", len(d.rows), running, failed)
	}
}

func loadEvents(d *sectionData) {
	out, err := run(15*time.Second, "kldload-db", "dump")
	if err != nil {
		d.err = err.Error()
		return
	}
	var dump struct {
		Events []struct {
			TS, Type, Subject, Message string
		} `json:"events"`
	}
	if err := json.Unmarshal([]byte(out), &dump); err != nil {
		d.err = "kldload-db dump: " + err.Error()
		return
	}
	d.columns = []string{"when", "type", "subject", "message"}
	ev := dump.Events
	for i := len(ev) - 1; i >= 0 && len(d.rows) < 200; i-- {
		d.rows = append(d.rows, []string{ev[i].TS, ev[i].Type, ev[i].Subject, ev[i].Message})
	}
	d.headline = fmt.Sprintf("last %d of %d events in state.db", len(d.rows), len(ev))
}

// ── Provision: kldload-netboot-server status --json ─────────────────────────

type netbootStatus struct {
	Service string `json:"service"`
	Open    bool   `json:"open"`
	Payload struct {
		Present bool   `json:"present"`
		Source  string `json:"source"`
		Version string `json:"version"`
		Commit  string `json:"commit"`
	} `json:"payload"`
	Net struct {
		Configured bool   `json:"configured"`
		Used       bool   `json:"used"`
		Distros    string `json:"distros"`
		Why        string `json:"why"`
	} `json:"net"`
	Armed   []map[string]any `json:"armed"`
	Goldens []map[string]any `json:"goldens"`
}

func readNetboot() (netbootStatus, error) {
	var st netbootStatus
	out, err := run(20*time.Second, "kldload-netboot-server", "status", "--json")
	if err != nil {
		return st, err
	}
	if err := json.Unmarshal([]byte(out), &st); err != nil {
		return st, fmt.Errorf("kldload-netboot-server: %v", err)
	}
	return st, nil
}

func loadProvision(d *sectionData) {
	st, err := readNetboot()
	if err != nil {
		d.err = err.Error()
		return
	}
	mode := "armed machines only"
	if st.Open {
		mode = "OPEN: any machine that PXE-boots gets the install menu"
	}
	payload := "no payload"
	if st.Payload.Present {
		payload = "payload " + st.Payload.Version + " " + st.Payload.Commit + " (" + st.Payload.Source + ")"
	}
	netiso := "no net edition"
	if st.Net.Configured {
		netiso = "net edition for " + orDash(st.Net.Distros)
		if !st.Net.Used {
			netiso += " (unused: " + st.Net.Why + ")"
		}
	}
	d.headline = fmt.Sprintf("service %s · %s · %s · %s", st.Service, mode, payload, netiso)
	d.columns = []string{"armed", "mode", "golden", "download nic"}
	for _, a := range st.Armed {
		d.rows = append(d.rows, []string{str(a["mac"]), str(a["mode"]), orDash(str(a["golden"])), orDash(str(a["netdev"]))})
	}
}

// loadFeed is the netboot server's nginx access log, newest first: which
// machine fetched the kernel, the root image, its answers file — the same
// feed the web console's Provision page shows while a rack installs.
func loadFeed(d *sectionData) {
	root := os.Getenv("NETBOOT_ROOT")
	if root == "" {
		root = "/var/lib/kldload/netboot-serve"
	}
	out, err := run(10*time.Second, "tail", "-n", "300", root+"/nginx-access.log")
	if err != nil {
		d.err = "no netboot feed: " + err.Error()
		return
	}
	d.columns = []string{"when", "client", "request", "status", "bytes", "what"}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		// 10.100.10.142 - - [26/Sep/2026:09:01:17 -0700] "GET /kldload/squashfs.img HTTP/1.1" 200 16787533824 "-" "curl/8.18.0"
		l := lines[i]
		client, rest, ok := strings.Cut(l, " - - [")
		if !ok {
			continue
		}
		when, rest, ok := strings.Cut(rest, "] \"")
		if !ok {
			continue
		}
		req, rest, ok := strings.Cut(rest, "\" ")
		if !ok {
			continue
		}
		f := strings.Fields(rest)
		status, size := "", ""
		if len(f) >= 2 {
			status, size = f[0], f[1]
		}
		if n, err := strconv.ParseInt(size, 10, 64); err == nil {
			size = human(n)
		}
		path := req
		if p := strings.Fields(req); len(p) >= 2 {
			path = p[0] + " " + p[1]
		}
		what := ""
		switch {
		case strings.Contains(path, "squashfs"):
			what = "root image"
		case strings.Contains(path, "vmlinuz"), strings.Contains(path, "initrd"):
			what = "kernel/initrd"
		case strings.Contains(path, "/answers/"):
			what = "answers file"
		case strings.Contains(path, "/armed/"):
			what = "consent token"
		case strings.Contains(path, ".ipxe"):
			what = "boot menu"
		case strings.Contains(path, "/golden/"):
			what = "golden stream"
		}
		if t := strings.Fields(when); len(t) > 0 {
			when = strings.TrimPrefix(t[0][strings.Index(t[0], ":")+1:], "")
		}
		d.rows = append(d.rows, []string{when, client, path, status, size, what})
	}
	d.headline = fmt.Sprintf("last %d requests to the netboot server, newest first", len(d.rows))
}

func loadGoldens(d *sectionData) {
	st, err := readNetboot()
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"golden", "size"}
	for _, g := range st.Goldens {
		size := str(g["size"])
		if n, err := strconv.ParseInt(size, 10, 64); err == nil {
			size = human(n)
		}
		d.rows = append(d.rows, []string{str(g["name"]), size})
	}
	d.headline = fmt.Sprintf("%d golden image(s) the netboot server can deploy (arm-deploy)", len(d.rows))
}

// answersDirs are where answers files live on a host: the netboot tree, and
// the matrix a workstation keeps for its benches.
var answersDirs = []string{"/var/lib/kldload/netboot-serve/answers", "/var/lib/kldload/netboot/answers", "/etc/kldload/answers"}

func loadAnswers(d *sectionData) {
	d.columns = []string{"answers file", "profile", "distro", "hostname"}
	for _, dir := range answersDirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".env") {
				continue
			}
			p := filepath.Join(dir, e.Name())
			profile, distro, host := "-", "-", "-"
			if b, err := os.ReadFile(p); err == nil {
				for _, line := range strings.Split(string(b), "\n") {
					k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
					if !ok {
						continue
					}
					v = strings.Trim(v, `"'`)
					switch k {
					case "PROFILE", "KLDLOAD_PROFILE":
						profile = v
					case "DISTRO", "KLDLOAD_DISTRO":
						distro = v
					case "HOSTNAME", "KLDLOAD_HOSTNAME":
						host = v
					}
				}
			}
			d.rows = append(d.rows, []string{p, profile, distro, host})
		}
	}
	d.headline = fmt.Sprintf("%d answers file(s) (a: arm a machine with the selected one)", len(d.rows))
}

// ── overview: one line per section, from the same collectors ───────────────

func loadOverview(d *sectionData) {
	d.columns = []string{"area", "state"}
	if r, err := readEstate(); err != nil {
		d.rows = append(d.rows, []string{"machines", err.Error()})
	} else {
		running, mesh := 0, 0
		for _, m := range r.Machines {
			if m.Power == "running" {
				running++
			}
			if m.InMesh {
				mesh++
			}
		}
		d.rows = append(d.rows, []string{"machines", fmt.Sprintf("%d known, %d running, %d on the mesh", len(r.Machines), running, mesh)})
		d.rows = append(d.rows, []string{"drift", fmt.Sprintf("%d finding(s)", len(r.Drift))})
	}
	if out, err := run(15*time.Second, "zpool", "list", "-H", "-o", "name,cap,health"); err == nil {
		d.rows = append(d.rows, []string{"pools", strings.Join(strings.Fields(strings.ReplaceAll(out, "\t", " ")), " ")})
	} else {
		d.rows = append(d.rows, []string{"pools", err.Error()})
	}
	if out, err := run(10*time.Second, "wg", "show", "interfaces"); err == nil {
		d.rows = append(d.rows, []string{"mesh", orDash(strings.TrimSpace(out))})
	}
	if server, ok := apiserverReachable(); server == "" {
		d.rows = append(d.rows, []string{"cluster", "not a cluster node"})
	} else if ok {
		d.rows = append(d.rows, []string{"cluster", server + " answers"})
	} else {
		d.rows = append(d.rows, []string{"cluster", server + " does not answer"})
	}
	if _, sum, err := readDoctor(); err == nil {
		d.rows = append(d.rows, []string{"doctor", fmt.Sprintf("%d ok, %d warn, %d fail, %d skipped", sum["ok"], sum["warn"], sum["fail"], sum["skip"])})
	} else {
		d.rows = append(d.rows, []string{"doctor", err.Error()})
	}
	if out, err := run(15*time.Second, "systemctl", "list-units", "--state=failed", "--no-legend", "--plain"); err == nil {
		var failed []string
		for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
			if f := strings.Fields(line); len(f) > 0 {
				failed = append(failed, f[0])
			}
		}
		if len(failed) == 0 {
			d.rows = append(d.rows, []string{"units", "no failed units"})
		} else {
			d.rows = append(d.rows, []string{"units", fmt.Sprintf("%d FAILED: %s", len(failed), truncateList(failed, 4))})
		}
	}
	d.headline = hostname() + " · " + time.Now().Format("2006-01-02 15:04")
}

// ── small helpers ───────────────────────────────────────────────────────────

func orDash(s string) string {
	if strings.TrimSpace(s) == "" {
		return "-"
	}
	return s
}

func str(v any) string {
	if v == nil {
		return ""
	}
	switch x := v.(type) {
	case float64:
		if x == float64(int64(x)) {
			return strconv.FormatInt(int64(x), 10)
		}
	}
	return fmt.Sprint(v)
}

func human(n int64) string {
	const u = "BKMGT"
	f, i := float64(n), 0
	for f >= 1024 && i < len(u)-1 {
		f /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%d%c", n, u[i])
	}
	return fmt.Sprintf("%.1f%c", f, u[i])
}

func hostname() string {
	out, err := exec.Command("hostname").Output()
	if err != nil {
		return "localhost"
	}
	return strings.TrimSpace(string(out))
}
