// engine_test.go — table tests for the pure engine functions.
//
// These are the parts that decide what the operator SEES and what the kernel
// GETS: dump parsing, config rendering (topology = the peer list), inventory
// filtering, and the reconciliation that arms the undeclared-peer alarm. They
// take no privileges and touch no interfaces, so they run anywhere — the
// mutating verbs are covered separately by their echoed commands.
package main

import (
	"strconv"
	"strings"
	"testing"
	"time"
)

// tab builds a `wg show all dump` line the way the kernel does: TAB separated.
func tab(fields ...string) string { return strings.Join(fields, "\t") }

func TestParseDump(t *testing.T) {
	now := time.Now().Unix()
	dump := strings.Join([]string{
		tab("wg-mgmt", "privkey", "IFACEPUB", "51820", "off"),
		tab("wg-mgmt", "PEER1", "(none)", "10.0.0.2:51820", "10.250.0.2/32", "0", "100", "200", "25"),
		tab("wg-mgmt", "PEER2", "(none)", "(none)", "10.250.0.3/32", itoa(now), "1", "2", "off"),
		tab("wg-k8s", "privkey", "IFACE2PUB", "51821", "off"),
		tab("wg-k8s", "PEER3", "(none)", "10.0.0.4:51821", "10.251.0.4/32", "0", "0", "0", "off"),
	}, "\n")

	devs := parseDump("host1", dump)
	if len(devs) != 2 {
		t.Fatalf("want 2 devices, got %d", len(devs))
	}
	if devs[0].Name != "wg-mgmt" || devs[0].PublicKey != "IFACEPUB" || devs[0].ListenPort != "51820" {
		t.Errorf("interface line parsed wrong: %+v", devs[0])
	}
	if devs[0].Host != "host1" {
		t.Errorf("host not stamped: %q", devs[0].Host)
	}
	// Peers must land on the interface that owns them, not on the last one seen.
	if len(devs[0].Peers) != 2 || len(devs[1].Peers) != 1 {
		t.Fatalf("peers mis-assigned: %d and %d", len(devs[0].Peers), len(devs[1].Peers))
	}
	if devs[1].Peers[0].PublicKey != "PEER3" {
		t.Errorf("second interface got the wrong peer: %+v", devs[1].Peers[0])
	}
	// handshake 0 means never; a real timestamp must survive.
	if !devs[0].Peers[0].Handshake.IsZero() {
		t.Error("handshake 0 should parse as never")
	}
	if devs[0].Peers[1].Handshake.Unix() != now {
		t.Errorf("handshake timestamp lost: %v", devs[0].Peers[1].Handshake)
	}
	if devs[0].Peers[0].RxBytes != 100 || devs[0].Peers[0].TxBytes != 200 {
		t.Errorf("byte counters wrong: %+v", devs[0].Peers[0])
	}
}

func TestParseDumpJunk(t *testing.T) {
	// Empty output (no interfaces) and malformed lines must not panic or invent.
	for _, in := range []string{"", "\n", "garbage", tab("a", "b"), tab("i", "p", "k", "port")} {
		if got := parseDump("", in); len(got) != 0 {
			t.Errorf("input %q produced %d devices, want 0", in, len(got))
		}
	}
}

func TestPeerHealth(t *testing.T) {
	cases := []struct {
		age  time.Duration
		want string
	}{
		{10 * time.Second, "alive"},
		{2*time.Minute + 59*time.Second, "alive"},
		{4 * time.Minute, "quiet"},
		{29 * time.Minute, "quiet"},
		{31 * time.Minute, "stale"},
		{72 * time.Hour, "stale"},
	}
	for _, c := range cases {
		p := Peer{Handshake: time.Now().Add(-c.age)}
		if got := p.Health(); got != c.want {
			t.Errorf("age %v: got %q want %q", c.age, got, c.want)
		}
	}
	if got := (Peer{}).Health(); got != "never" {
		t.Errorf("zero handshake: got %q want never", got)
	}
	if got := (Peer{}).Age(); got != "never" {
		t.Errorf("zero handshake Age(): got %q", got)
	}
}

func TestParseAddrs(t *testing.T) {
	out := strings.Join([]string{
		"lo               UNKNOWN        127.0.0.1/8 ::1/128",
		"enp1s0@if2       UP             192.168.1.5/24 fe80::1/64",
		"wg-mgmt          UNKNOWN        10.250.0.100/24",
		"down0            DOWN",
	}, "\n")
	m := parseAddrs(out)
	if m["wg-mgmt"] != "10.250.0.100/24" {
		t.Errorf("wg address wrong: %q", m["wg-mgmt"])
	}
	if got := m["enp1s0"]; got != "192.168.1.5/24" {
		t.Errorf("link-local not dropped, or alias not trimmed: %q", got)
	}
	if _, ok := m["down0"]; ok {
		t.Error("an interface with no address must not appear")
	}
}

// The managed-interface gate is the fix that stopped an adopted estate
// from rendering as a wall of false alarms. Roster analysis replaced the
// declaration lookup that used to set these flags (see roster.go), but the
// alarm arithmetic Totals does on top of them is unchanged, so this test
// still guards the same regression.
func TestTotalsAlarmOnlyOnManagedInterfaces(t *testing.T) {
	devs := []Device{
		{Name: "wg-managed", Managed: true, Peers: []Peer{
			{Declared: true, Handshake: time.Now()},
			{Declared: false},
		}},
		{Name: "wg-foreign", Managed: false, Peers: []Peer{
			{Declared: false}, {Declared: false},
		}},
		{Host: "down", Err: "unreachable"},
	}
	hosts, ifaces, peers, alive, undeclared := Totals(devs)
	if ifaces != 2 {
		t.Errorf("unreachable device must not count as an interface: %d", ifaces)
	}
	if peers != 4 || alive != 1 {
		t.Errorf("peers=%d alive=%d, want 4 and 1", peers, alive)
	}
	if undeclared != 1 {
		t.Errorf("undeclared=%d: only the MANAGED interface's unaccounted peer counts", undeclared)
	}
	if hosts != 2 { // "" (local) and "down"
		t.Errorf("hosts=%d, want 2", hosts)
	}
}

func TestIfaceSubnetSummary(t *testing.T) {
	d := Device{Peers: []Peer{
		{AllowedIPs: "10.250.0.2/32"},
		{AllowedIPs: "10.250.0.3/32"},
		{AllowedIPs: "10.251.0.4/32, 10.252.0.0/24"},
	}}
	got := ifaceSubnetText(d)
	if !strings.Contains(got, "10.250.0.0/24") || !strings.Contains(got, "10.251.0.0/24") {
		t.Errorf("subnets not summarised: %q", got)
	}
	if got := ifaceSubnetText(Device{}); got != "—" {
		t.Errorf("no peers should render as a dash, got %q", got)
	}
}

func TestHostDisplayPrefersFQDN(t *testing.T) {
	if got := HostDisplay(Device{Host: "root@10.0.0.1", HostFQDN: "node1"}); got != "node1" {
		t.Errorf("fqdn should win: %q", got)
	}
	if got := HostDisplay(Device{Host: "root@10.0.0.1"}); got != "root@10.0.0.1" {
		t.Errorf("ssh target is the fallback: %q", got)
	}
	if got := HostDisplay(Device{}); got != "local" {
		t.Errorf("empty host is local: %q", got)
	}
}

func itoa(v int64) string { return strconv.FormatInt(v, 10) }
