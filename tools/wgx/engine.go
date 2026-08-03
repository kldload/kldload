// engine.go — wgxplore: declarations, rendering, and the kernel verbs.
//
// Design: docs/WG-NETWORKS-DESIGN.md in the kldload repo. Two nouns, one
// verb: declared Networks rendered to plain wg configs; Members attached by
// moving kernel WireGuard interfaces — including INTO container network
// namespaces, where the tunnel keeps working because the UDP socket stays
// anchored in the namespace where the interface was created.
//
// Prototype scope (deliberately thin — prove the primitives, not the UI):
//
//	wgx show                        peer dossiers, handshake-age coloring
//	wgx net create <name> --subnet 10.44.0.0/24 [--topology mesh|hub-spoke]
//	wgx net add <name> <member> [--endpoint host:port] [--hub]
//	wgx net render <name>           write per-member wg .conf files
//	wgx net up <name> <member>      bring this machine up as <member>
//	wgx attach <net> <container>    move this net's iface into a podman
//	                                container's netns (the kernel trick)
//
// Declarations live in /etc/wgx/<name>.json — the file IS the API. Every
// privileged action shells out to plain `wg`/`ip` with the exact command
// echoed first (primitives, not abstractions). Unprivileged operations
// (declare/add/render) never need root.
package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const netDir = "/etc/wgx"

const (
	cG = "\x1b[1;32m"
	cY = "\x1b[1;33m"
	cR = "\x1b[1;31m"
	cC = "\x1b[1;36m"
	cD = "\x1b[2m"
	cN = "\x1b[0m"
)

// ─── declaration model ───────────────────────────────────────────────────

type Member struct {
	Name       string `json:"name"`
	IP         string `json:"ip"`       // address inside the network subnet
	PublicKey  string `json:"pubkey"`   //
	PrivateKey string `json:"privkey"`  // prototype: kept in the declaration; real tool: per-member key custody
	Endpoint   string `json:"endpoint"` // host:port, empty for roaming spokes
	Hub        bool   `json:"hub"`      // hub-spoke: the reachable rendezvous
}

type Network struct {
	Name     string   `json:"name"`
	Subnet   string   `json:"subnet"`
	Topology string   `json:"topology"` // mesh | hub-spoke
	Port     int      `json:"port"`
	Members  []Member `json:"members"`
}

func netPath(name string) string { return filepath.Join(netDir, name+".json") }

func loadNet(name string) (*Network, error) {
	b, err := os.ReadFile(netPath(name))
	if err != nil {
		return nil, err
	}
	var n Network
	if err := json.Unmarshal(b, &n); err != nil {
		return nil, err
	}
	return &n, nil
}

func saveNet(n *Network) error {
	if err := os.MkdirAll(netDir, 0o755); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(n, "", "  ")
	return os.WriteFile(netPath(n.Name), append(b, '\n'), 0o600)
}

// run echoes then executes — every mutation shows its exact command,
// zxplore-style. Output is returned for parsing, stderr passes through.
func run(args ...string) (string, error) {
	fmt.Printf("%s$ %s%s\n", cD, strings.Join(args, " "), cN)
	out, err := exec.Command(args[0], args[1:]...).Output()
	return string(out), err
}

func genKeypair() (priv, pub string, err error) {
	out, err := exec.Command("wg", "genkey").Output()
	if err != nil {
		return "", "", err
	}
	priv = strings.TrimSpace(string(out))
	c := exec.Command("wg", "pubkey")
	c.Stdin = strings.NewReader(priv)
	out, err = c.Output()
	return priv, strings.TrimSpace(string(out)), err
}

// ─── wgx show ── dossiers from `wg show all dump` ────────────────────────

func cmdShow() error {
	out, err := exec.Command("wg", "show", "all", "dump").Output()
	if err != nil {
		return fmt.Errorf("wg show needs root (try sudo): %w", err)
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) == 0 || lines[0] == "" {
		fmt.Println("no WireGuard interfaces up")
		return nil
	}
	cur := ""
	for _, l := range lines {
		f := strings.Split(l, "\t")
		if len(f) == 5 { // interface line: iface priv pub port fwmark
			cur = f[0]
			fmt.Printf("\n%s━━ %s%s  %sport %s%s\n", cC, cur, cN, cD, f[3], cN)
			continue
		}
		if len(f) < 9 || f[0] != cur && cur == "" {
			continue
		}
		// peer line: iface pub psk endpoint allowed-ips handshake rx tx keepalive
		hs, _ := strconv.ParseInt(f[5], 10, 64)
		age, col, state := "never", cR, "no handshake"
		if hs > 0 {
			d := time.Since(time.Unix(hs, 0)).Round(time.Second)
			age = d.String()
			switch {
			case d < 3*time.Minute:
				col, state = cG, "alive"
			case d < 30*time.Minute:
				col, state = cY, "quiet"
			default:
				col, state = cR, "stale"
			}
		}
		rx, _ := strconv.ParseInt(f[6], 10, 64)
		tx, _ := strconv.ParseInt(f[7], 10, 64)
		fmt.Printf("  peer %s…%s\n", f[1][:16], f[1][len(f[1])-6:])
		fmt.Printf("    endpoint    %s\n", orDash(f[3]))
		fmt.Printf("    allowed-ips %s\n", f[4])
		fmt.Printf("    handshake   %s%s (%s)%s   rx %s  tx %s\n",
			col, age, state, cN, human(rx), human(tx))
	}
	return nil
}

func orDash(s string) string {
	if s == "" || s == "(none)" {
		return "—"
	}
	return s
}

func human(b int64) string {
	switch {
	case b > 1<<30:
		return fmt.Sprintf("%.1fGiB", float64(b)/(1<<30))
	case b > 1<<20:
		return fmt.Sprintf("%.1fMiB", float64(b)/(1<<20))
	case b > 1<<10:
		return fmt.Sprintf("%.1fKiB", float64(b)/(1<<10))
	}
	return fmt.Sprintf("%dB", b)
}

// ─── wgx net ── declare / add / render ───────────────────────────────────

func cmdNetCreate(name string, args []string) error {
	n := &Network{Name: name, Subnet: "10.44.0.0/24", Topology: "mesh", Port: 51820}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--subnet":
			i++
			n.Subnet = args[i]
		case "--topology":
			i++
			n.Topology = args[i]
		case "--port":
			i++
			n.Port, _ = strconv.Atoi(args[i])
		}
	}
	if _, _, err := net.ParseCIDR(n.Subnet); err != nil {
		return fmt.Errorf("bad --subnet: %w", err)
	}
	if err := saveNet(n); err != nil {
		return err
	}
	fmt.Printf("%s✓%s network %q declared: %s %s → %s\n", cG, cN, name, n.Topology, n.Subnet, netPath(name))
	return nil
}

func cmdNetAdd(name, member string, args []string) error {
	n, err := loadNet(name)
	if err != nil {
		return err
	}
	m := Member{Name: member}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--endpoint":
			i++
			m.Endpoint = args[i]
		case "--hub":
			m.Hub = true
		}
	}
	_, ipnet, _ := net.ParseCIDR(n.Subnet)
	ip := ipnet.IP.To4()
	m.IP = fmt.Sprintf("%d.%d.%d.%d", ip[0], ip[1], ip[2], len(n.Members)+1)
	if m.PrivateKey, m.PublicKey, err = genKeypair(); err != nil {
		return err
	}
	n.Members = append(n.Members, m)
	if err := saveNet(n); err != nil {
		return err
	}
	fmt.Printf("%s✓%s member %q → %s  pub %s…\n", cG, cN, member, m.IP, m.PublicKey[:16])
	return nil
}

// renderConf builds one member's wg-quick config. Policy IS the peer list:
// mesh = everyone peers with everyone; hub-spoke = spokes peer only with
// the hub, the hub carries the whole subnet (cryptokey routing enforces it).
func renderConf(n *Network, self *Member) string {
	var b strings.Builder
	// `wg setconf` format (NOT wg-quick): no Address= here — wgx applies
	// addresses itself via `ip addr`, which is what lets the same config
	// work before AND after an interface moves into a container netns.
	fmt.Fprintf(&b, "# rendered by wgx from %s — edit the declaration, not this file\n", netPath(n.Name))
	fmt.Fprintf(&b, "[Interface]\nPrivateKey = %s\n", self.PrivateKey)
	if self.Hub || n.Topology == "mesh" {
		fmt.Fprintf(&b, "ListenPort = %d\n", n.Port)
	}
	for i := range n.Members {
		p := &n.Members[i]
		if p.Name == self.Name {
			continue
		}
		if n.Topology == "hub-spoke" && !self.Hub && !p.Hub {
			continue // spokes only know the hub
		}
		fmt.Fprintf(&b, "\n[Peer] # %s\nPublicKey = %s\n", p.Name, p.PublicKey)
		if n.Topology == "hub-spoke" && p.Hub {
			fmt.Fprintf(&b, "AllowedIPs = %s\n", n.Subnet) // hub routes the net
		} else {
			fmt.Fprintf(&b, "AllowedIPs = %s/32\n", p.IP)
		}
		if p.Endpoint != "" {
			fmt.Fprintf(&b, "Endpoint = %s\nPersistentKeepalive = 25\n", p.Endpoint)
		}
	}
	return b.String()
}

func cmdNetRender(name string) error {
	n, err := loadNet(name)
	if err != nil {
		return err
	}
	outdir := filepath.Join(netDir, name)
	if err := os.MkdirAll(outdir, 0o700); err != nil {
		return err
	}
	for i := range n.Members {
		p := filepath.Join(outdir, n.Members[i].Name+".conf")
		if err := os.WriteFile(p, []byte(renderConf(n, &n.Members[i])), 0o600); err != nil {
			return err
		}
		fmt.Printf("%s✓%s %s\n", cG, cN, p)
	}
	return nil
}

func cmdNetUp(name, member string) error {
	conf := filepath.Join(netDir, name, member+".conf")
	if _, err := os.Stat(conf); err != nil {
		return fmt.Errorf("%s not rendered — run: wgx net render %s", conf, name)
	}
	iface := "wgx-" + name
	if _, err := run("ip", "link", "add", iface, "type", "wireguard"); err != nil {
		return err
	}
	n, _ := loadNet(name)
	var self *Member
	for i := range n.Members {
		if n.Members[i].Name == member {
			self = &n.Members[i]
		}
	}
	if _, err := run("wg", "setconf", iface, conf); err != nil {
		return err
	}
	if _, err := run("ip", "addr", "add", self.IP+"/"+strings.Split(n.Subnet, "/")[1], "dev", iface); err != nil {
		return err
	}
	if _, err := run("ip", "link", "set", iface, "up"); err != nil {
		return err
	}
	fmt.Printf("%s✓%s %s up as %q (%s)\n", cG, cN, iface, member, self.IP)
	return nil
}

// ─── wgx attach ── the kernel trick ──────────────────────────────────────
// Create the interface HERE (its UDP socket anchors to this namespace),
// configure it, then move it into the container's netns. The tunnel keeps
// working; the container gains a mesh interface no workload can escape.

func cmdAttach(name, container, member string) error {
	out, err := exec.Command("podman", "inspect", "-f", "{{.State.Pid}}", container).Output()
	if err != nil {
		return fmt.Errorf("podman inspect %s: %w", container, err)
	}
	pid := strings.TrimSpace(string(out))
	n, err := loadNet(name)
	if err != nil {
		return err
	}
	var self *Member
	for i := range n.Members {
		if n.Members[i].Name == member {
			self = &n.Members[i]
		}
	}
	if self == nil {
		return fmt.Errorf("member %q not in network %q — run: wgx net add %s %s", member, name, name, member)
	}
	conf := filepath.Join(netDir, name, member+".conf")
	if _, err := os.Stat(conf); err != nil {
		return fmt.Errorf("%s not rendered — run: wgx net render %s", conf, name)
	}
	iface := "wgx-" + short(name+container)
	if _, err := run("ip", "link", "add", iface, "type", "wireguard"); err != nil {
		return err
	}
	if _, err := run("wg", "setconf", iface, conf); err != nil {
		return err
	}
	// The move: after this the socket stays HERE, the interface lives THERE.
	if _, err := run("ip", "link", "set", iface, "netns", pid); err != nil {
		return err
	}
	if _, err := run("nsenter", "-t", pid, "-n", "ip", "addr", "add",
		self.IP+"/"+strings.Split(n.Subnet, "/")[1], "dev", iface); err != nil {
		return err
	}
	if _, err := run("nsenter", "-t", pid, "-n", "ip", "link", "set", iface, "up"); err != nil {
		return err
	}
	fmt.Printf("%s✓%s container %q is on %q as %q (%s) — interface lives in its netns, socket anchored here\n",
		cG, cN, container, name, member, self.IP)
	return nil
}

func short(s string) string {
	h := base64.RawURLEncoding.EncodeToString([]byte(s))
	if len(h) > 8 {
		h = h[:8]
	}
	return strings.ToLower(h)
}
