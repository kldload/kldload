// estate.go — the inventory layer: what WireGuard actually exists, everywhere.
//
// One estate is many hosts. Each host is reached exactly the way zxplore
// reaches its servers: plain ssh, no agent on the far side, ~/.ssh/config as
// the machine inventory. On every host we run `wg show all dump` and fold the
// result into one list of Devices (interfaces) and Peers.
//
// The reconciliation this enables is the point (docs/WG-NETWORKS-DESIGN.md):
//
//	declared + live   → healthy, coloured by handshake age
//	declared, absent  → never came up / host down
//	live, UNdeclared  → nobody added this peer: alarm
package main

import (
	"bufio"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Peer is one cryptokey-routed counterpart on some Device.
type Peer struct {
	PublicKey  string
	Endpoint   string
	AllowedIPs string
	Handshake  time.Time // zero = never
	RxBytes    int64
	TxBytes    int64
	Keepalive  string
	Declared   bool // matched a member in a declaration
}

// Device is one WireGuard interface on one host.
type Device struct {
	Host       string // "" = local
	Name       string // wg-mgmt, wg-k8s, wgx-lab …
	PublicKey  string
	ListenPort string
	Peers      []Peer
	Err        string // populated when the host could not be reached
}

// Health buckets a peer by handshake age — the "is this tunnel alive?"
// question that `wg show` answers only as a raw timestamp.
func (p Peer) Health() string {
	if p.Handshake.IsZero() {
		return "never"
	}
	switch d := time.Since(p.Handshake); {
	case d < 3*time.Minute:
		return "alive"
	case d < 30*time.Minute:
		return "quiet"
	default:
		return "stale"
	}
}

// Age renders the handshake age compactly ("42s", "6m12s", "never").
func (p Peer) Age() string {
	if p.Handshake.IsZero() {
		return "never"
	}
	return time.Since(p.Handshake).Round(time.Second).String()
}

// sshHosts returns Host aliases from ~/.ssh/config — the estate inventory.
// Wildcards and negations are skipped: they are patterns, not machines.
func sshHosts() []string {
	f, err := os.Open(filepath.Join(os.Getenv("HOME"), ".ssh", "config"))
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if !strings.HasPrefix(strings.ToLower(line), "host ") {
			continue
		}
		for _, h := range strings.Fields(line)[1:] {
			if strings.ContainsAny(h, "*?!") {
				continue
			}
			out = append(out, h)
		}
	}
	sort.Strings(out)
	return out
}

// parseDump folds `wg show all dump` into Devices. Format per line:
//
//	interface: name privkey pubkey port fwmark
//	peer:      name pubkey psk endpoint allowed-ips handshake rx tx keepalive
func parseDump(host, dump string) []Device {
	var devs []Device
	byName := map[string]*Device{}
	for _, line := range strings.Split(strings.TrimSpace(dump), "\n") {
		f := strings.Split(line, "\t")
		switch len(f) {
		case 5: // interface
			d := Device{Host: host, Name: f[0], PublicKey: f[2], ListenPort: f[3]}
			devs = append(devs, d)
			byName[f[0]] = &devs[len(devs)-1]
		case 9: // peer
			d, ok := byName[f[0]]
			if !ok {
				continue
			}
			p := Peer{
				PublicKey:  f[1],
				Endpoint:   f[3],
				AllowedIPs: f[4],
				Keepalive:  f[8],
			}
			if hs, _ := strconv.ParseInt(f[5], 10, 64); hs > 0 {
				p.Handshake = time.Unix(hs, 0)
			}
			p.RxBytes, _ = strconv.ParseInt(f[6], 10, 64)
			p.TxBytes, _ = strconv.ParseInt(f[7], 10, 64)
			d.Peers = append(d.Peers, p)
		}
	}
	return devs
}

// CollectEstate gathers devices from the local host and every ssh alias, in
// parallel. Unreachable hosts become a Device carrying Err rather than
// vanishing — "the box is down" is inventory information, not an error.
func CollectEstate(hosts []string) []Device {
	var (
		mu  sync.Mutex
		all []Device
		wg  sync.WaitGroup
	)

	collect := func(host string) {
		defer wg.Done()
		var out []byte
		var err error
		if host == "" {
			out, err = exec.Command("wg", "show", "all", "dump").Output()
		} else {
			out, err = exec.Command("ssh",
				"-o", "BatchMode=yes",
				"-o", "StrictHostKeyChecking=accept-new",
				"-o", "ConnectTimeout=6",
				host, "wg show all dump").Output()
		}
		mu.Lock()
		defer mu.Unlock()
		if err != nil {
			all = append(all, Device{Host: host, Name: "—", Err: shortErr(err)})
			return
		}
		all = append(all, parseDump(host, string(out))...)
	}

	wg.Add(1)
	go collect("")
	for _, h := range hosts {
		wg.Add(1)
		go collect(h)
	}
	wg.Wait()

	sort.Slice(all, func(i, j int) bool {
		if all[i].Host != all[j].Host {
			return all[i].Host < all[j].Host
		}
		return all[i].Name < all[j].Name
	})
	return all
}

func shortErr(err error) string {
	s := err.Error()
	if len(s) > 60 {
		s = s[:60]
	}
	return s
}

// MarkDeclared flags peers whose public key appears in any declaration under
// /etc/wgx. Everything left unflagged in a network we manage is a peer nobody
// declared — the row worth waking up for.
func MarkDeclared(devs []Device) map[string]string {
	known := map[string]string{} // pubkey → "network/member"
	entries, err := os.ReadDir(netDir)
	if err != nil {
		return known
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		n, err := loadNet(strings.TrimSuffix(e.Name(), ".json"))
		if err != nil {
			continue
		}
		for _, m := range n.Members {
			known[m.PublicKey] = n.Name + "/" + m.Name
		}
	}
	for i := range devs {
		for j := range devs[i].Peers {
			if _, ok := known[devs[i].Peers[j].PublicKey]; ok {
				devs[i].Peers[j].Declared = true
			}
		}
	}
	return known
}

// Totals summarises an estate for the header line.
func Totals(devs []Device) (hosts, ifaces, peers, alive, undeclared int) {
	seen := map[string]bool{}
	for _, d := range devs {
		seen[d.Host] = true
		if d.Err != "" {
			continue
		}
		ifaces++
		for _, p := range d.Peers {
			peers++
			if p.Health() == "alive" {
				alive++
			}
			if !p.Declared {
				undeclared++
			}
		}
	}
	return len(seen), ifaces, peers, alive, undeclared
}
