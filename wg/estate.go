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
	"bytes"
	"errors"
	"fmt"
	"net"
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
	Declared   bool   // matched a member in a declaration
	Label      string // "network/member" when declared — show names, not keys
}

// Device is one WireGuard interface on one host.
type Device struct {
	Host       string // "" = local
	HostFQDN   string // what the host calls itself (hostname -f)
	HostAddr   string // underlay IP the estate reaches it at (DNS of ssh HostName)
	Name       string // wg-mgmt, wg-k8s, wgx-lab …
	Addr       string // the interface's OWN overlay address(es), from `ip -br addr`
	PublicKey  string
	ListenPort string
	Peers      []Peer
	Err        string // populated when the host could not be reached
	Managed    bool   // this interface's own key appears in a declaration
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

// sshHosts returns the machines to scan.
//
// Source of truth, in order:
//  1. an explicit inventory — ~/.config/wgx/hosts or /etc/wgx/hosts, one
//     ssh target per line (# comments ok). If present, ONLY these are used.
//  2. otherwise ~/.ssh/config Host aliases, minus the ones that obviously
//     are not machines.
//
// That subtraction matters: an ssh config is full of git remotes. Scanning
// them produced a tree full of "github.com — unreachable", "gh-brain —
// unreachable" (onyx, 2026-08-03). A forge is identified by `User git`,
// by a known forge hostname, or by the gh-* alias convention.
// sshHostName maps an inventory alias to the HostName its ssh config dials,
// so the estate can show the underlay address the console actually reaches.
// Filled by sshHosts as a side effect; aliases without a HostName map to
// themselves.
var sshHostName = map[string]string{}

func sshHosts() []string {
	if h := inventoryFile(); len(h) > 0 {
		return h
	}
	f, err := os.Open(filepath.Join(os.Getenv("HOME"), ".ssh", "config"))
	if err != nil {
		return nil
	}
	defer f.Close()

	forge := map[string]bool{
		"github.com": true, "gitlab.com": true, "bitbucket.org": true,
		"codeberg.org": true, "git.sr.ht": true, "ssh.dev.azure.com": true,
		"git.launchpad.net": true, "gitea.com": true,
	}
	type entry struct {
		aliases  []string
		hostName string
		user     string
	}
	var entries []entry
	var cur *entry
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		switch strings.ToLower(fields[0]) {
		case "host":
			entries = append(entries, entry{aliases: fields[1:]})
			cur = &entries[len(entries)-1]
		case "hostname":
			if cur != nil && len(fields) > 1 {
				cur.hostName = fields[1]
			}
		case "user":
			if cur != nil && len(fields) > 1 {
				cur.user = fields[1]
			}
		}
	}

	var out []string
	for _, e := range entries {
		if e.user == "git" || forge[strings.ToLower(e.hostName)] {
			continue // a git remote, not a machine
		}
		for _, a := range e.aliases {
			if strings.ContainsAny(a, "*?!") { // pattern, not a host
				continue
			}
			if forge[strings.ToLower(a)] || strings.HasPrefix(a, "gh-") {
				continue
			}
			out = append(out, a)
			if e.hostName != "" {
				sshHostName[a] = e.hostName
			}
		}
	}
	sort.Strings(out)
	return out
}

// inventoryFile reads an explicit host list, if the operator wrote one.
// One ssh target per line; blank lines and # comments ignored.
func inventoryFile() []string {
	for _, p := range []string{
		filepath.Join(os.Getenv("HOME"), ".config", "wgx", "hosts"),
		"/etc/wgx/hosts",
	} {
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		var out []string
		for _, l := range strings.Split(string(b), "\n") {
			l = strings.TrimSpace(l)
			if l == "" || strings.HasPrefix(l, "#") {
				continue
			}
			out = append(out, l)
		}
		if len(out) > 0 {
			return out
		}
	}
	return nil
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

// sepMark separates the three sections of the combined remote command —
// dump, addresses, fqdn — so one ssh round-trip gathers all identity data.
const sepMark = "==WGX-SEP=="

// parseAddrs folds `ip -br addr` into iface → its own address(es),
// link-local noise dropped. Empty on hosts without iproute2 (BSD) — the
// UIs fall back to inferring subnets from peers' allowed-ips.
func parseAddrs(out string) map[string]string {
	m := map[string]string{}
	for _, l := range strings.Split(out, "\n") {
		f := strings.Fields(l)
		if len(f) < 3 {
			continue
		}
		var addrs []string
		for _, a := range f[2:] {
			if strings.HasPrefix(a, "fe80") {
				continue
			}
			addrs = append(addrs, a)
		}
		if len(addrs) > 0 {
			m[strings.Split(f[0], "@")[0]] = strings.Join(addrs, " ")
		}
	}
	return m
}

// CollectEstate gathers devices from the local host and every ssh alias, in
// parallel. Unreachable hosts become a Device carrying Err rather than
// vanishing — "the box is down" is inventory information, not an error.
// Alongside each dump it collects the host's own identity (fqdn, interface
// addresses) and resolves the underlay address the ssh config dials.
func CollectEstate(hosts []string) []Device {
	var (
		mu  sync.Mutex
		all []Device
		wg  sync.WaitGroup
	)

	collect := func(host string) {
		defer wg.Done()
		var dump, addrOut, fqdn, haddr string
		var err error
		if host == "" {
			var out []byte
			out, err = localDump()
			dump = string(out)
			if a, e := exec.Command("ip", "-br", "addr").Output(); e == nil {
				addrOut = string(a)
			}
			if f, e := exec.Command("hostname", "-f").Output(); e == nil {
				fqdn = strings.TrimSpace(string(f))
			}
		} else {
			var out []byte
			out, err = exec.Command("ssh",
				"-o", "BatchMode=yes",
				"-o", "StrictHostKeyChecking=accept-new",
				"-o", "ConnectTimeout=6",
				host,
				"wg show all dump 2>/dev/null; echo "+sepMark+
					"; ip -br addr 2>/dev/null; echo "+sepMark+
					"; hostname -f 2>/dev/null || hostname").Output()
			if parts := strings.SplitN(string(out), sepMark+"\n", 3); len(parts) == 3 {
				dump, addrOut, fqdn = parts[0], parts[1], strings.TrimSpace(parts[2])
			}
			target := sshHostName[host]
			if target == "" {
				target = host
			}
			if ips, e := net.LookupHost(target); e == nil && len(ips) > 0 {
				haddr = ips[0]
			}
		}
		mu.Lock()
		defer mu.Unlock()
		if err != nil {
			all = append(all, Device{Host: host, HostAddr: haddr, Name: "—", Err: shortErr(err)})
			return
		}
		devs := parseDump(host, dump)
		addrs := parseAddrs(addrOut)
		for i := range devs {
			devs[i].Addr = addrs[devs[i].Name]
			devs[i].HostFQDN = fqdn
			devs[i].HostAddr = haddr
		}
		// A reachable host with ZERO WireGuard interfaces must still appear —
		// inventory truth. Without this marker the host silently vanished
		// from the tree, which read as "wgx is broken" the first time an
		// operator inventoried plain VMs (2026-08-03). Name=="" is the
		// marker the renderers translate to "no WireGuard interfaces".
		if len(devs) == 0 {
			devs = append(devs, Device{Host: host, HostFQDN: fqdn, HostAddr: haddr})
		}
		all = append(all, devs...)
	}

	wg.Add(1)
	go collect("")
	for _, h := range hosts {
		wg.Add(1)
		go collect(h)
	}
	wg.Wait()

	// Presentation order — one rule for the cards, the tree, and the text
	// estate: local first, then WireGuard-bearing hosts sorted by their
	// DISPLAY identity (fqdn — kldload-cp, -w-1, -w-2 … — not the ssh
	// target string, which scrambled workers into IP order), then
	// reachable no-WireGuard hosts, unreachable hosts last.
	class := map[string]int{}
	label := map[string]string{}
	for _, d := range all {
		c := 2 // unreachable
		if d.Err == "" {
			if d.Name != "" {
				c = 0 // has WireGuard
			} else {
				c = 1 // reachable, none
			}
		}
		if prev, ok := class[d.Host]; !ok || c < prev {
			class[d.Host] = c
		}
		if label[d.Host] == "" {
			label[d.Host] = HostDisplay(d)
		}
	}
	sort.Slice(all, func(i, j int) bool {
		a, b := all[i], all[j]
		if (a.Host == "") != (b.Host == "") {
			return a.Host == ""
		}
		if class[a.Host] != class[b.Host] {
			return class[a.Host] < class[b.Host]
		}
		if label[a.Host] != label[b.Host] {
			return label[a.Host] < label[b.Host]
		}
		if a.Host != b.Host {
			return a.Host < b.Host
		}
		return lessIface(a.Name, b.Name)
	})
	return all
}

// lessIface orders two interfaces of one host: by plane, in planeOrder, then
// by name. Every view — tree, cards, TUI, text — reads them in this order,
// so the management plane is first and the appliance meshes sit together.
func lessIface(a, b string) bool {
	ra, rb := planeRank(planeOf(a)), planeRank(planeOf(b))
	if ra != rb {
		return ra < rb
	}
	return a < b
}

// HostDisplay is the name a host is KNOWN by — its fqdn when it reported
// one, the ssh target otherwise. Sorting and labelling both use this, so
// the visible name is always the sort key.
func HostDisplay(d Device) string {
	if d.HostFQDN != "" {
		return d.HostFQDN
	}
	return hostLabel(d.Host)
}

// localDump reads this host's WireGuard state, elevating if it has to.
//
// `wg show` needs CAP_NET_ADMIN. Unprivileged it does something worse than
// failing: it prints "Operation not permitted" to stderr, writes NOTHING to
// stdout, and exits 0 — so a naive caller sees an empty estate and reports
// the local box as having no interfaces. That is exactly what the desktop
// launcher hit (fiend 2026-08-03): the tile runs as the operator, the GUI
// showed nothing, and "localhost unreachable" was the only clue.
//
// Order: direct (already root) → sudo -n (passwordless sudoers) → pkexec
// (polkit; kldload ships org.kldload.wgxplore.policy so wheel members can
// take this read-only dump without a password prompt on every refresh).
func localDump() ([]byte, error) {
	direct, err := exec.Command("wg", "show", "all", "dump").Output()
	if err == nil && len(bytes.TrimSpace(direct)) > 0 {
		return direct, nil
	}
	if os.Geteuid() == 0 {
		return direct, err // root and genuinely empty: no interfaces
	}
	// Nothing readable and we are not root. If the kernel has no WireGuard
	// interfaces at all, empty is the truth — say so without prompting.
	if links, lerr := exec.Command("ip", "-br", "link", "show", "type", "wireguard").Output(); lerr == nil &&
		len(bytes.TrimSpace(links)) == 0 {
		return nil, nil
	}
	self, _ := os.Executable()
	for _, try := range [][]string{
		{"sudo", "-n", "wg", "show", "all", "dump"},
		{"pkexec", self, "dump"},
	} {
		if _, lerr := exec.LookPath(try[0]); lerr != nil {
			continue
		}
		if out, eerr := exec.Command(try[0], try[1:]...).Output(); eerr == nil &&
			len(bytes.TrimSpace(out)) > 0 {
			return out, nil
		}
	}
	return nil, errors.New("needs privileges to read WireGuard state — run `sudo wgx`, or install the polkit rule (kldload ships it)")
}

func shortErr(err error) string {
	s := err.Error()
	if len(s) > 60 {
		s = s[:60]
	}
	return s
}

// Totals summarises an estate for the header line.
func Totals(devs []Device) (hosts, ifaces, peers, alive, undeclared int) {
	seen := map[string]bool{}
	for _, d := range devs {
		seen[d.Host] = true
		if d.Err != "" || d.Name == "" {
			continue
		}
		ifaces++
		for _, p := range d.Peers {
			peers++
			if p.Health() == "alive" {
				alive++
			}
			// The alarm only arms on managed interfaces (see roster.go).
			if d.Managed && !p.Declared {
				undeclared++
			}
		}
	}
	return len(seen), ifaces, peers, alive, undeclared
}

// PrintEstate renders the estate as a text tree — the same host → interface
// → peer shape the GUI shows, for terminals, scripts and remote checks.
func PrintEstate() error {
	devs := CollectEstate(sshHosts())
	Analyse(devs)
	h, i, p, alive, undeclared := Totals(devs)
	fmt.Printf("estate: %d hosts · %d interfaces · %d peers · %d alive", h, i, p, alive)
	if undeclared > 0 {
		fmt.Printf("  ⚠ %d UNDECLARED", undeclared)
	}
	fmt.Println()
	lastHost := "\x00"
	for _, d := range devs {
		host := d.Host
		if host == "" {
			host = "local"
		}
		if host != lastHost {
			id := ""
			if t := hostLabel(d.Host); t != HostDisplay(d) {
				id = "  ·  " + t
			}
			if d.HostAddr != "" {
				id += "  " + d.HostAddr
			}
			fmt.Printf("\n%s%s\n", HostDisplay(d), id)
			lastHost = host
		}
		if d.Err != "" {
			fmt.Printf("  └─ unreachable: %s\n", d.Err)
			continue
		}
		if d.Name == "" {
			fmt.Printf("  └─ (no WireGuard interfaces)\n")
			continue
		}
		fmt.Printf("  ├─ %s  %s  (%d peers)\n", d.Name, ifaceAddrText(d), len(d.Peers))
		for j, pr := range d.Peers {
			br := "│  ├─"
			if j == len(d.Peers)-1 {
				br = "│  └─"
			}
			mark := map[string]string{"alive": "●", "quiet": "●", "stale": "○", "never": "○"}[pr.Health()]
			flag := ""
			if d.Managed && !pr.Declared {
				flag = "  ⚠ undeclared"
			}
			who := strings.Split(pr.AllowedIPs, ",")[0]
			if pr.Label != "" {
				who = pr.Label
			}
			fmt.Printf("  %s %s %-18s %-24s %s%s\n", br, mark,
				who, orDash(pr.Endpoint), pr.Age(), flag)
		}
	}
	return nil
}

// ifaceAddrText prefers the interface's OWN address (what you point things
// at); only interfaces we could not read addresses for fall back to the
// subnet guess inferred from peers' allowed-ips.
func ifaceAddrText(d Device) string {
	if d.Addr != "" {
		return d.Addr
	}
	return ifaceSubnetText(d)
}

// ifaceSubnetText mirrors the GUI's subnet summary for the text tree.
func ifaceSubnetText(d Device) string {
	seen := map[string]bool{}
	var nets []string
	for _, p := range d.Peers {
		for _, cidr := range strings.Split(p.AllowedIPs, ",") {
			ip := strings.Split(strings.TrimSpace(cidr), "/")[0]
			parts := strings.Split(ip, ".")
			if len(parts) != 4 {
				continue
			}
			n := fmt.Sprintf("%s.%s.%s.0/24", parts[0], parts[1], parts[2])
			if !seen[n] {
				seen[n] = true
				nets = append(nets, n)
			}
		}
	}
	if len(nets) == 0 {
		return "—"
	}
	return strings.Join(nets, " ")
}

// DevicesOverview renders the top bar: one line per WireGuard interface,
// the way zxplore's pools bar renders one line per zpool. Same shape, same
// glance-value — this is the estate's "what have I got and is it healthy".
//
//	✓  wg-mgmt          10.250.0.0/24     4 peers ·  4 alive · port 51820 · rx 12.3M / tx 8.1M
//	⚠  wg-k8s           10.251.0.0/24     4 peers ·  0 alive · port 51821 · 4 undeclared
func DevicesOverview(devs []Device) string {
	if len(devs) == 0 {
		return "  (no WireGuard interfaces found)"
	}
	var b strings.Builder
	for _, d := range devs {
		if d.Err != "" {
			fmt.Fprintf(&b, "✗  %-16s %s\n", hostLabel(d.Host), "unreachable: "+d.Err)
			continue
		}
		if d.Name == "" {
			fmt.Fprintf(&b, "—  %-16s no WireGuard interfaces\n", hostLabel(d.Host))
			continue
		}
		var alive, undecl int
		var rx, tx int64
		for _, p := range d.Peers {
			if p.Health() == "alive" {
				alive++
			}
			if d.Managed && !p.Declared {
				undecl++
			}
			rx += p.RxBytes
			tx += p.TxBytes
		}
		mark := "✓"
		if len(d.Peers) > 0 && alive == 0 {
			mark = "⚠"
		}
		name := d.Name
		if d.Host != "" {
			name = d.Host + ":" + d.Name
		}
		fmt.Fprintf(&b, "%s  %-18s %-17s %2d peers · %2d alive · port %-6s rx %s / tx %s",
			mark, name, ifaceAddrText(d), len(d.Peers), alive, orDash(d.ListenPort),
			human(rx), human(tx))
		if undecl > 0 {
			fmt.Fprintf(&b, " · ⚠ %d undeclared", undecl)
		}
		b.WriteString("\n")
	}
	return strings.TrimRight(b.String(), "\n")
}

func hostLabel(h string) string {
	if h == "" {
		return "local"
	}
	return h
}
