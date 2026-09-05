package main

import (
	"strings"
	"testing"
	"time"
)

// estate builds a small three-host mesh: a, b, c, each with one interface,
// fully peered unless a test says otherwise. Keys are readable on purpose —
// a failing assertion should name the host, not a base64 fragment.
func estate() []Device {
	mk := func(host, key string, peers ...string) Device {
		d := Device{Host: host, HostFQDN: host, Name: "wg0", PublicKey: key}
		for _, p := range peers {
			d.Peers = append(d.Peers, Peer{PublicKey: p, Handshake: time.Now()})
		}
		return d
	}
	return []Device{
		mk("a", "KEYA", "KEYB", "KEYC"),
		mk("b", "KEYB", "KEYA", "KEYC"),
		mk("c", "KEYC", "KEYA", "KEYB"),
	}
}

// The roster is the estate's own keys — this is what replaces the registry,
// so it is the assertion the whole design rests on.
func TestBuildRosterIsEveryHostsOwnKey(t *testing.T) {
	roster, partial := BuildRoster(estate())
	if partial != 0 {
		t.Errorf("partial=%d on a fully reachable estate, want 0", partial)
	}
	if len(roster) != 3 {
		t.Fatalf("roster has %d keys, want 3", len(roster))
	}
	if o := roster["KEYB"]; o.Host != "b" || o.Iface != "wg0" {
		t.Errorf("KEYB owned by %q/%q, want b/wg0", o.Host, o.Iface)
	}
}

// A healthy mesh must produce no findings at all. If this ever fails the
// tool cries wolf, and an alarm that fires on a working estate is worse
// than no alarm.
func TestHealthyMeshIsSilent(t *testing.T) {
	f := Analyse(estate())
	if len(f.Orphans) != 0 {
		t.Errorf("orphans on a healthy mesh: %+v", f.Orphans)
	}
	if len(f.OneWays) != 0 {
		t.Errorf("one-ways on a healthy mesh: %+v", f.OneWays)
	}
	if !strings.Contains(f.Report(), "every peer accounted for") {
		t.Errorf("healthy report should say so, got:\n%s", f.Report())
	}
}

// Peers get labelled with the host they belong to. This is the whole reason
// the joined view is more useful than three separate `wg show` runs.
func TestPeersAreLabelledWithTheirOwner(t *testing.T) {
	devs := estate()
	Analyse(devs)
	for _, p := range devs[0].Peers {
		if !p.Declared {
			t.Errorf("peer %s on host a not accounted for", p.PublicKey)
		}
		if p.Label != "b/wg0" && p.Label != "c/wg0" {
			t.Errorf("peer %s labelled %q, want b/wg0 or c/wg0", p.PublicKey, p.Label)
		}
	}
}

// A key nobody in the estate owns is an orphan: a dead node's leftover entry
// or an off-estate client. Both are worth showing and neither is visible
// from any single host.
func TestOrphanPeerIsFound(t *testing.T) {
	devs := estate()
	devs[0].Peers = append(devs[0].Peers, Peer{PublicKey: "KEYGHOST"})
	f := Analyse(devs)
	if len(f.Orphans) != 1 {
		t.Fatalf("orphans=%d, want 1: %+v", len(f.Orphans), f.Orphans)
	}
	if f.Orphans[0].PublicKey != "KEYGHOST" || f.Orphans[0].OnHost != "a" {
		t.Errorf("orphan = %+v, want KEYGHOST on host a", f.Orphans[0])
	}
	if !strings.Contains(f.Report(), "matching no host") {
		t.Errorf("report should name the orphan section:\n%s", f.Report())
	}
}

// The failure `wg show` structurally cannot report: a carries b, b has no
// entry back. Looks configured from one side, does not exist from the other.
func TestOneWayLinkIsFound(t *testing.T) {
	devs := estate()
	// b forgets a.
	devs[1].Peers = []Peer{{PublicKey: "KEYC", Handshake: time.Now()}}
	f := Analyse(devs)
	if len(f.OneWays) != 1 {
		t.Fatalf("one-ways=%d, want 1: %+v", len(f.OneWays), f.OneWays)
	}
	w := f.OneWays[0]
	if w.FromHost != "a" || w.ToHost != "b" {
		t.Errorf("one-way %s→%s, want a→b", w.FromHost, w.ToHost)
	}
	if len(f.Orphans) != 0 {
		t.Errorf("a one-way link is not an orphan: %+v", f.Orphans)
	}
}

// The soundness limit, and the reason Partial exists: an unreachable host
// contributes no key, so every legitimate peer entry pointing AT it looks
// orphaned. The report must say the sweep was incomplete rather than
// present those orphans as fact.
func TestUnreachableHostIsNotReportedAsOrphansWithoutWarning(t *testing.T) {
	devs := estate()
	devs[2] = Device{Host: "c", Err: "unreachable"}
	f := Analyse(devs)
	if f.Partial != 1 {
		t.Errorf("partial=%d, want 1", f.Partial)
	}
	// a and b both still list KEYC, so c's absence manufactures two orphans.
	if len(f.Orphans) != 2 {
		t.Errorf("orphans=%d, want 2 (the artefact this warning is for)", len(f.Orphans))
	}
	r := f.Report()
	if !strings.Contains(r, "did not answer") || !strings.Contains(r, "may simply be hosts") {
		t.Errorf("incomplete sweep must be disclosed before the orphan list:\n%s", r)
	}
	if strings.Index(r, "did not answer") > strings.Index(r, "matching no host") {
		t.Error("the warning must come BEFORE the orphan list, not after it")
	}
}

// One unreachable host with several interfaces is still one host. Counting
// error rows instead would overstate how broken the sweep was.
func TestPartialCountsHostsNotRows(t *testing.T) {
	devs := append(estate(),
		Device{Host: "d", Err: "unreachable"},
		Device{Host: "d", Err: "unreachable"},
	)
	if _, partial := BuildRoster(devs); partial != 1 {
		t.Errorf("partial=%d, want 1 — two error rows are one unreachable host", partial)
	}
}

// An appliance VM is never a swept host — it is reachable only over the
// mesh its host minted — so its key comes from the host's kvm-mesh members
// file. Before this, every appliance peer read as undeclared: 17 of 17 on
// onyx, six of them handshaking (2026-09-04).
func TestMembersFilesDeclareAppliancePeers(t *testing.T) {
	devs := estate()
	host := Device{Host: "onyx", HostFQDN: "onyx", Name: "ap-app-adguard", PublicKey: "KEYONYX",
		Peers:   []Peer{{PublicKey: "KEYVM", Handshake: time.Now()}, {PublicKey: "KEYSTRAY"}},
		Members: []MeshMember{{Mesh: "ap-app-adguard", Name: "app-adguard-ho", PublicKey: "KEYVM"}}}
	devs = append(devs, host)
	f := Analyse(devs)
	d := devs[3]
	if !d.Peers[0].Declared || d.Peers[0].Label != "app-adguard-ho/ap-app-adguard" {
		t.Errorf("member peer: declared=%v label=%q, want declared as app-adguard-ho/ap-app-adguard",
			d.Peers[0].Declared, d.Peers[0].Label)
	}
	if d.Peers[1].Declared {
		t.Error("a key in no members file must still be an orphan")
	}
	if len(f.Orphans) != 1 || f.Orphans[0].PublicKey != "KEYSTRAY" {
		t.Errorf("orphans = %+v, want only KEYSTRAY", f.Orphans)
	}
}

// A swept VM's own interface is the more precise owner than its host's
// record of it, so the sweep wins over the members file.
func TestSweptInterfaceOutranksMembersFile(t *testing.T) {
	devs := []Device{
		{Host: "onyx", HostFQDN: "onyx", Name: "ap-app-x", PublicKey: "KEYH",
			Members: []MeshMember{{Mesh: "ap-app-x", Name: "app-x", PublicKey: "KEYVM"}}},
		{Host: "app-x", HostFQDN: "app-x.lan", Name: "wg-app", PublicKey: "KEYVM"},
	}
	roster, _ := BuildRoster(devs)
	if o := roster["KEYVM"]; o.Host != "app-x.lan" || o.Iface != "wg-app" {
		t.Errorf("KEYVM owned by %q/%q, want the swept app-x.lan/wg-app", o.Host, o.Iface)
	}
}

// The parser takes grep -H output: file:line. An empty members file — what a
// failed `kvm-mesh up` leaves behind — is a mesh with no members, not junk.
func TestParseMembers(t *testing.T) {
	out := "/var/lib/kldload/mesh/ap-app-adguard.members:app-adguard-ho 1 wRuf/70VFJj4mYp0fRR5ncVfm4= 192.168.122.214\n" +
		"/var/lib/kldload/mesh/ap-app-writefre.members:\n" +
		"/var/lib/kldload/mesh/testnet.members:mesh-2 2 IAFGWEHCUjm3mfF9RjdY5rKG= 192.168.122.179\n" +
		"garbage without a colon\n"
	ms := parseMembers(out)
	if len(ms) != 2 {
		t.Fatalf("parsed %d members, want 2: %+v", len(ms), ms)
	}
	if m := ms[0]; m.Mesh != "ap-app-adguard" || m.Name != "app-adguard-ho" ||
		m.PublicKey != "wRuf/70VFJj4mYp0fRR5ncVfm4=" || m.Addr != "192.168.122.214" {
		t.Errorf("first member = %+v", m)
	}
	if ms[1].Mesh != "testnet" || ms[1].Name != "mesh-2" {
		t.Errorf("second member = %+v", ms[1])
	}
}
