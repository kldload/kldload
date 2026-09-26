// network.go — the WireGuard estate, ported from wgxplore into the console.
//
// wgxplore's one screen (an estate list and a peer dossier), its health
// model (alive under three minutes, quiet under thirty, stale after) and
// its `check` (peers matching no host, links that only exist from one side)
// live here as tabs of the Network section. Two things it never did are
// done here: peers are named from kldload's own records — the enrolment
// files kldload-enroll writes and the state DB's mesh ids — so an enrolled
// VM is not "undeclared"; and no interface's private key is ever read out
// of `wg show … dump` (the first line of a dump carries it; wgxplore's
// pkexec path printed it, 2026-09-26 read-through).
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ── who is who: the roster ──────────────────────────────────────────────────

// roster maps a peer's public key to the name it belongs to: an enrolled
// VM (enrolment records, the DB), a mesh member file, or a swept host's
// own interface.
type roster map[string]string

func localRoster() roster {
	r := roster{}
	// kldload-enroll's records: node_id= and guest_pub= per VM
	if entries, err := os.ReadDir("/var/lib/kldload/mesh/enrolled"); err == nil {
		for _, e := range entries {
			if e.IsDir() || strings.HasPrefix(e.Name(), ".") {
				continue
			}
			rec, err := run(5*time.Second, "cat", "/var/lib/kldload/mesh/enrolled/"+e.Name())
			if err != nil {
				continue
			}
			for _, line := range strings.Split(rec, "\n") {
				if v, ok := strings.CutPrefix(line, "guest_pub="); ok && v != "" {
					r[strings.TrimSpace(v)] = e.Name()
				}
			}
		}
	}
	// kvm-mesh's member files: <vm> <id> <pubkey> <ip>
	if files, _ := filepath.Glob("/var/lib/kldload/mesh/*.members"); len(files) > 0 {
		for _, f := range files {
			out, err := run(5*time.Second, "cat", f)
			if err != nil {
				continue
			}
			for _, line := range strings.Split(out, "\n") {
				if fl := strings.Fields(line); len(fl) >= 3 {
					if _, seen := r[fl[2]]; !seen {
						r[fl[2]] = fl[0] + "/" + strings.TrimSuffix(filepath.Base(f), ".members")
					}
				}
			}
		}
	}
	// the state DB's mesh rows (kldload-db vm-mesh writes wg_pubkey)
	if out, err := run(15*time.Second, "kldload-db", "dump"); err == nil {
		var dump struct {
			VMs []struct {
				Name      string `json:"name"`
				WgPubkey  string `json:"wg_pubkey"`
				DeletedAt string `json:"deleted_at"`
			} `json:"vms"`
		}
		if jsonUnmarshal(out, &dump) == nil {
			for _, v := range dump.VMs {
				if v.WgPubkey != "" && v.DeletedAt == "" {
					if _, seen := r[v.WgPubkey]; !seen {
						r[v.WgPubkey] = v.Name
					}
				}
			}
		}
	}
	return r
}

// ── the estate: this host and every host we can ssh to ─────────────────────

type wgIface struct {
	host, name, plane, addr, pubkey string
	port                            string
	peers                           []peer
}

type wgHost struct {
	name, target, err string
	ifaces            []wgIface
}

// fleetHosts is wgxplore's host list, same sources, same order: the
// inventory kldload-networks writes for root, /etc/wgx/hosts, else the
// Host aliases of ~/.ssh/config minus forges and wildcards.
func fleetHosts() []string {
	for _, f := range []string{"/root/.config/wgx/hosts", "/etc/wgx/hosts"} {
		out, err := run(5*time.Second, "cat", f)
		if err != nil {
			continue
		}
		var hs []string
		for _, line := range strings.Split(out, "\n") {
			line = strings.TrimSpace(line)
			if line != "" && !strings.HasPrefix(line, "#") {
				hs = append(hs, line)
			}
		}
		if len(hs) > 0 {
			return hs
		}
	}
	home, _ := os.UserHomeDir()
	f, err := os.Open(filepath.Join(home, ".ssh", "config"))
	if err != nil {
		return nil
	}
	defer f.Close()
	var hs []string
	forges := map[string]bool{"github.com": true, "gitlab.com": true, "bitbucket.org": true, "codeberg.org": true,
		"git.sr.ht": true, "ssh.dev.azure.com": true, "git.launchpad.net": true, "gitea.com": true}
	sc := bufio.NewScanner(f)
	var cur []string
	flush := func() {
		for _, h := range cur {
			hs = append(hs, h)
		}
		cur = nil
	}
	for sc.Scan() {
		fl := strings.Fields(sc.Text())
		if len(fl) < 2 {
			continue
		}
		switch strings.ToLower(fl[0]) {
		case "host":
			flush()
			for _, h := range fl[1:] {
				if strings.ContainsAny(h, "*?!") || forges[h] || strings.HasPrefix(h, "gh-") {
					continue
				}
				cur = append(cur, h)
			}
		case "user":
			if strings.EqualFold(fl[1], "git") {
				cur = nil
			}
		}
	}
	flush()
	return hs
}

// parseDump turns `wg show all dump` into interfaces and peers. The first
// line of each interface carries its PRIVATE key in field 2: it is read
// past and never stored.
func parseDump(host, dump string, addrs map[string]string) []wgIface {
	var out []wgIface
	byName := map[string]int{}
	for _, line := range strings.Split(strings.TrimRight(dump, "\n"), "\n") {
		f := strings.Split(line, "\t")
		if len(f) == 5 {
			// iface private public port fwmark
			byName[f[0]] = len(out)
			out = append(out, wgIface{host: host, name: f[0], plane: planeOf(f[0]), pubkey: f[2], port: f[3], addr: addrs[f[0]]})
			continue
		}
		if len(f) >= 9 {
			// iface peer psk endpoint allowed handshake rx tx keepalive
			i, ok := byName[f[0]]
			if !ok {
				continue
			}
			p := peer{plane: f[0], key: f[1], endpoint: strings.TrimPrefix(f[3], "(none)"), allowed: f[4]}
			p.handshake, _ = strconv.ParseInt(f[5], 10, 64)
			p.rx, _ = strconv.ParseInt(f[6], 10, 64)
			p.tx, _ = strconv.ParseInt(f[7], 10, 64)
			out[i].peers = append(out[i].peers, p)
		}
	}
	return out
}

func parseAddrs(brief string) map[string]string {
	m := map[string]string{}
	for _, line := range strings.Split(brief, "\n") {
		if f := strings.Fields(line); len(f) >= 3 {
			m[f[0]] = f[2]
		}
	}
	return m
}

// planeOf is wgxplore's classification by interface name.
func planeOf(name string) string {
	switch {
	case name == "wg0" || strings.HasPrefix(name, "wg0-"):
		return "enrollment"
	case name == "wg1" || strings.HasPrefix(name, "wg1-") || strings.HasPrefix(name, "wg-mgmt"):
		return "management"
	case name == "wg2" || strings.HasPrefix(name, "wg2-") || strings.HasPrefix(name, "wg-k8s"):
		return "kubernetes"
	case name == "wg3" || strings.HasPrefix(name, "wg3-") || strings.HasPrefix(name, "wg-storage"):
		return "storage"
	case strings.HasPrefix(name, "ap-"):
		return "apps"
	}
	return "unclassified"
}

func healthOf(ts int64) string {
	switch {
	case ts == 0:
		return "never"
	case time.Since(time.Unix(ts, 0)) < 3*time.Minute:
		return "alive"
	case time.Since(time.Unix(ts, 0)) < 30*time.Minute:
		return "quiet"
	}
	return "stale"
}

// collectFleet sweeps this host and every fleet host in parallel, twenty
// seconds each; an unreachable host is a row that says so, not a gap.
func collectFleet() ([]wgHost, roster) {
	r := localRoster()
	var hosts []wgHost
	local := wgHost{name: hostname(), target: "local"}
	if dump, err := run(10*time.Second, "wg", "show", "all", "dump"); err == nil {
		brief, _ := run(5*time.Second, "ip", "-br", "addr")
		local.ifaces = parseDump(local.name, dump, parseAddrs(brief))
	} else {
		local.err = err.Error()
	}
	hosts = append(hosts, local)
	targets := fleetHosts()
	results := make([]wgHost, len(targets))
	var wg sync.WaitGroup
	for i, t := range targets {
		wg.Add(1)
		go func(i int, t string) {
			defer wg.Done()
			h := wgHost{name: t, target: t}
			// as root: the inventory kldload-networks writes lists root@<ip>
			// and the key that opens those is root's ops key (wgxplore ran
			// this as the desktop user and every host read "unreachable")
			// Host keys are not pinned: the hosts in this inventory are VMs
			// and benches that are rebuilt, and every rebuild mints a new
			// key. root's known_hosts on onyx held the previous cluster's
			// keys and every node read "unreachable" (2026-09-26). The same
			// policy as the estate tests' ssh; a durable host is reached by
			// its ssh config alias, where its key is pinned as usual.
			cmd := exec.Command("sudo", "-n", "ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
				"-o", "LogLevel=ERROR", "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2", t,
				"sudo -n wg show all dump 2>/dev/null || wg show all dump 2>/dev/null; echo ==SEP==; ip -br addr 2>/dev/null; echo ==SEP==; hostname -f 2>/dev/null || hostname")
			done := make(chan struct{})
			var out []byte
			var err error
			go func() { out, err = cmd.Output(); close(done) }()
			select {
			case <-done:
			case <-time.After(20 * time.Second):
				_ = cmd.Process.Kill()
				err = fmt.Errorf("no answer in 20s")
			}
			if err != nil {
				h.err = "unreachable: " + strings.TrimSpace(err.Error())
				results[i] = h
				return
			}
			parts := strings.SplitN(string(out), "==SEP==\n", 3)
			if len(parts) == 3 {
				if n := strings.TrimSpace(parts[2]); n != "" {
					h.name = n
				}
				h.ifaces = parseDump(h.name, parts[0], parseAddrs(parts[1]))
			}
			results[i] = h
		}(i, t)
	}
	wg.Wait()
	hosts = append(hosts, results...)
	// every swept interface's own key names its peer rows elsewhere
	for _, h := range hosts {
		for _, i := range h.ifaces {
			if i.pubkey != "" {
				r[i.pubkey] = h.name + "/" + i.name
			}
		}
	}
	return hosts, r
}

func labelOf(r roster, key string) string {
	if n, ok := r[key]; ok {
		return n
	}
	return key[:12] + "…"
}

// ── the tabs ────────────────────────────────────────────────────────────────

func loadFleet(d *sectionData) {
	hosts, r := collectFleet()
	d.columns = []string{"host", "interface", "plane", "address", "peers", "alive", "undeclared", "reached"}
	nh, ni, np, na, nu, unreachable := 0, 0, 0, 0, 0, 0
	for _, h := range hosts {
		nh++
		if h.err != "" {
			unreachable++
			d.rows = append(d.rows, []string{h.name, "-", "-", "-", "-", "-", "-", h.err})
			continue
		}
		if len(h.ifaces) == 0 {
			d.rows = append(d.rows, []string{h.name, "(no WireGuard)", "-", "-", "0", "0", "0", h.target})
			continue
		}
		for _, i := range h.ifaces {
			ni++
			alive, undecl := 0, 0
			for _, p := range i.peers {
				np++
				if healthOf(p.handshake) == "alive" {
					alive++
					na++
				}
				if _, ok := r[p.key]; !ok {
					undecl++
					nu++
				}
			}
			d.rows = append(d.rows, []string{h.name, i.name, i.plane, orDash(i.addr), strconv.Itoa(len(i.peers)), strconv.Itoa(alive), strconv.Itoa(undecl), h.target})
		}
	}
	d.headline = fmt.Sprintf("%d hosts · %d interfaces · %d peers · %d alive", nh, ni, np, na)
	if nu > 0 {
		d.headline += fmt.Sprintf(" · %d UNDECLARED", nu)
	}
	if unreachable > 0 {
		d.headline += fmt.Sprintf(" · %d host(s) did not answer — membership is incomplete", unreachable)
	}
}

// loadCheck is wgxplore's `check`: peers matching no host in the estate,
// and links that exist from one side only.
func loadCheck(d *sectionData) {
	hosts, r := collectFleet()
	d.columns = []string{"finding", "where", "peer", "health", "endpoint", "detail"}
	// carries: for every swept interface key, the set of peer keys it holds
	carries := map[string]map[string]bool{}
	owner := map[string]string{}
	for _, h := range hosts {
		for _, i := range h.ifaces {
			if i.pubkey == "" {
				continue
			}
			owner[i.pubkey] = h.name + "/" + i.name
			set := map[string]bool{}
			for _, p := range i.peers {
				set[p.key] = true
			}
			carries[i.pubkey] = set
		}
	}
	orphans, oneWay := 0, 0
	for _, h := range hosts {
		for _, i := range h.ifaces {
			for _, p := range i.peers {
				hs := healthOf(p.handshake)
				if _, known := r[p.key]; !known {
					orphans++
					detail := "no host, enrolment record or DB row owns this key"
					if hs == "alive" {
						detail = "handshaking — a real client nobody recorded"
					}
					d.rows = append(d.rows, []string{"orphan", h.name + "/" + i.name, p.key[:12] + "…", hs, orDash(p.endpoint), detail})
					continue
				}
				// one-way: the peer's owner was swept and does not carry us back
				if set, swept := carries[p.key]; swept && i.pubkey != "" && !set[i.pubkey] {
					oneWay++
					d.rows = append(d.rows, []string{"one-way", h.name + "/" + i.name, labelOf(r, p.key), hs, orDash(p.endpoint), owner[p.key] + " has no return peer"})
				}
			}
		}
	}
	unreachable := 0
	for _, h := range hosts {
		if h.err != "" {
			unreachable++
			d.rows = append(d.rows, []string{"unreachable", h.name, "-", "-", "-", h.err})
		}
	}
	switch {
	case orphans == 0 && oneWay == 0 && unreachable == 0:
		d.headline = fmt.Sprintf("%d keys in the estate; every peer accounted for, every link mutual", len(r))
	default:
		d.headline = fmt.Sprintf("%d orphan peer(s), %d one-way link(s), %d host(s) unreachable", orphans, oneWay, unreachable)
	}
}

// loadPeersNamed is the Peers tab with wgxplore's dossier columns: the
// peer's name from the roster, its plane, health, endpoint, allowed IPs,
// handshake, transfer and keepalive.
func loadPeersNamed(d *sectionData) {
	dump, err := run(10*time.Second, "wg", "show", "all", "dump")
	if err != nil {
		d.err = err.Error()
		return
	}
	r := localRoster()
	brief, _ := run(5*time.Second, "ip", "-br", "addr")
	ifaces := parseDump(hostname(), dump, parseAddrs(brief))
	for _, i := range ifaces {
		if i.pubkey != "" {
			r[i.pubkey] = hostname() + "/" + i.name
		}
	}
	d.columns = []string{"peer", "plane", "health", "handshake", "endpoint", "allowed", "rx/tx", "key"}
	alive, total := 0, 0
	for _, i := range ifaces {
		for _, p := range i.peers {
			total++
			hs := healthOf(p.handshake)
			if hs == "alive" {
				alive++
			}
			age, _ := handshakeAge(p.handshake)
			name := labelOf(r, p.key)
			if _, known := r[p.key]; !known {
				name = "undeclared " + name
			}
			d.rows = append(d.rows, []string{name, i.name, hs, age, orDash(p.endpoint), p.allowed, human(p.rx) + "/" + human(p.tx), p.key[:12] + "…"})
		}
	}
	d.headline = fmt.Sprintf("%d peers on this host, %d alive (a handshake in the last 3 min)", total, alive)
}
