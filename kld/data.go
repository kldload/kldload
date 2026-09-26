// data.go — what each section reads, and from which tool.
//
// Every collector shells out to the tool that owns the fact and parses its
// output; none of them re-derives anything. Collectors run in a tea.Cmd, so
// a slow one (kldload-estate ~3 s, kldload-doctor ~2 s since the apiserver
// port probe) never freezes the keys. Each returns a sectionData with a
// pre-rendered table and an error string; the model shows whichever it got.
package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Section order is the sidebar order of the web console, and the 1-8 keys.
var sections = []string{"Overview", "Machines", "Storage", "Network", "Cluster", "Metrics", "Estate", "Provision"}

func sectionNames() []string {
	out := make([]string, len(sections))
	for i, s := range sections {
		out[i] = strings.ToLower(s)
	}
	return out
}

func sectionIndex(name string) int {
	for i, s := range sections {
		if strings.EqualFold(s, name) {
			return i
		}
	}
	return -1
}

// sectionData is one loaded section: a headline, table rows (first column is
// what verbs act on), and the tool that answered — or the error it gave.
type sectionData struct {
	section  int
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

func loadSection(i int) sectionData {
	d := sectionData{section: i, loadedAt: time.Now()}
	switch sections[i] {
	case "Overview":
		loadOverview(&d)
	case "Machines":
		loadMachines(&d)
	case "Storage":
		loadStorage(&d)
	case "Network":
		loadNetwork(&d)
	case "Cluster":
		loadCluster(&d)
	case "Metrics":
		loadMetrics(&d)
	case "Estate":
		loadEstate(&d)
	case "Provision":
		loadProvision(&d)
	}
	return d
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

func loadMachines(d *sectionData) {
	r, err := readEstate()
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"machine", "state", "class", "address", "network", "mesh", "k8s", "from"}
	running, mesh := 0, 0
	for _, m := range r.Machines {
		if m.Power == "running" {
			running++
		}
		if m.InMesh {
			mesh++
		}
		meshCol := "-"
		if m.InMesh {
			meshCol = m.MeshID + " " + m.MeshIfaces
		}
		d.rows = append(d.rows, []string{m.Name, m.Power, m.Class, orDash(m.IP), orDash(m.Network), meshCol, orDash(m.K8s), orDash(m.GoldenSrc)})
	}
	d.headline = fmt.Sprintf("%d machines, %d running, %d on the mesh, %d drift", len(r.Machines), running, mesh, len(r.Drift))
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

// ── kldload-doctor ──────────────────────────────────────────────────────────

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

// ── storage: zpool + kldload-rollback ───────────────────────────────────────

func loadStorage(d *sectionData) {
	out, err := run(15*time.Second, "zpool", "list", "-H", "-o", "name,size,alloc,free,frag,cap,health")
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"pool", "size", "alloc", "free", "frag", "cap", "health"}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if f := strings.Fields(line); len(f) >= 7 {
			d.rows = append(d.rows, f[:7])
		}
	}
	st, err := run(30*time.Second, "kldload-rollback", "status")
	if err != nil {
		d.headline = fmt.Sprintf("%d pool(s); rollback status: %v", len(d.rows), err)
		return
	}
	// "Key : value" lines from the tool, kept in its own words.
	var bits []string
	for _, line := range strings.Split(st, "\n") {
		k, v, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		switch k {
		case "Running from", "Next boot", "Boot path", "Newest pre-transaction snapshot":
			bits = append(bits, k+" "+v)
		}
	}
	d.headline = fmt.Sprintf("%d pool(s) · %s", len(d.rows), strings.Join(bits, " · "))
}

// ── network: wg show dump ───────────────────────────────────────────────────

func loadNetwork(d *sectionData) {
	ifs, err := run(10*time.Second, "wg", "show", "interfaces")
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"plane", "peer", "endpoint", "allowed", "handshake", "rx/tx"}
	alive, total := 0, 0
	for _, iface := range strings.Fields(ifs) {
		dump, err := run(10*time.Second, "wg", "show", iface, "dump")
		if err != nil {
			d.rows = append(d.rows, []string{iface, "?", err.Error(), "", "", ""})
			continue
		}
		lines := strings.Split(strings.TrimSpace(dump), "\n")
		for i, line := range lines {
			f := strings.Split(line, "\t")
			if i == 0 || len(f) < 7 {
				continue // the first line is this interface's own keys
			}
			total++
			hs := "never"
			if ts, _ := strconv.ParseInt(f[4], 10, 64); ts > 0 {
				age := time.Since(time.Unix(ts, 0))
				hs = age.Truncate(time.Second).String() + " ago"
				if age < 3*time.Minute {
					alive++
				}
			}
			rx, _ := strconv.ParseInt(f[5], 10, 64)
			tx, _ := strconv.ParseInt(f[6], 10, 64)
			d.rows = append(d.rows, []string{iface, f[0][:12] + "…", orDash(strings.TrimPrefix(f[2], "(none)")), f[3], hs, human(rx) + "/" + human(tx)})
		}
	}
	d.headline = fmt.Sprintf("%d plane(s), %d peers, %d with a handshake in the last 3 min", len(strings.Fields(ifs)), total, alive)
}

// ── cluster: kubectl, after a port probe ────────────────────────────────────

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

func loadCluster(d *sectionData) {
	server, ok := apiserverReachable()
	if server == "" {
		d.headline = "no kubeconfig on this host — this is not a cluster node"
		return
	}
	if !ok {
		d.headline = "apiserver " + server + " does not answer (port probe)"
		return
	}
	out, err := run(20*time.Second, "kubectl", "get", "nodes", "--no-headers", "--request-timeout=10s",
		"-o", "custom-columns=NAME:.metadata.name,READY:.status.conditions[-1].type,ROLE:.metadata.labels.node-role\\.kubernetes\\.io/control-plane,VER:.status.nodeInfo.kubeletVersion,IP:.status.addresses[0].address")
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"node", "ready", "control-plane", "kubelet", "address"}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if f := strings.Fields(line); len(f) >= 5 {
			d.rows = append(d.rows, f[:5])
		}
	}
	d.headline = fmt.Sprintf("%s · %d node(s)", server, len(d.rows))
}

// ── metrics: Prometheus targets ─────────────────────────────────────────────

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
	sort.Slice(d.rows, func(i, j int) bool { return d.rows[i][2] != "up" && d.rows[j][2] == "up" })
	d.headline = fmt.Sprintf("%d/%d targets up · dashboards: https://%s:8443/grafana/", up, len(rep.Data.Active), hostname())
}

// ── provision: kldload-netboot-server status --json ─────────────────────────

func loadProvision(d *sectionData) {
	out, err := run(20*time.Second, "kldload-netboot-server", "status", "--json")
	if err != nil {
		d.err = err.Error()
		return
	}
	// The shape kldload-netboot-server status --json prints (2026-09-26):
	// payload {present, source, version, commit}, net {configured, used,
	// commit, distros, why}, service, open, goldens [{name, size}],
	// armed [{mac, mode, golden, netdev}].
	var st struct {
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
	if err := json.Unmarshal([]byte(out), &st); err != nil {
		d.err = "kldload-netboot-server: " + err.Error()
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
	d.headline = fmt.Sprintf("service %s · %s · %s · %s · %d golden(s)", st.Service, mode, payload, netiso, len(st.Goldens))
	d.columns = []string{"armed", "mode", "golden", "download nic"}
	for _, a := range st.Armed {
		d.rows = append(d.rows, []string{str(a["mac"]), str(a["mode"]), orDash(str(a["golden"])), orDash(str(a["netdev"]))})
	}
	if len(d.rows) == 0 {
		d.rows = append(d.rows, []string{"(nothing armed)", "", "", ""})
	}
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
