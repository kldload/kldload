package main

import (
	"strings"
	"testing"
	"time"
)

// The role mapping is the whole value of this console, so the names the
// substrate actually creates are pinned here. If firstboot or kube-network
// ever renames an interface, this is what should fail.
func TestPlaneOfKnowsTheSubstrateConvention(t *testing.T) {
	cases := map[string]string{
		"wg0":         "enrollment",
		"wg1":         "management",
		"wg2":         "kubernetes",
		"wg3":         "storage",
		"wg-mgmt":     "management",
		"wg-k8s":      "kubernetes",
		"wg1-dc2":     "management", // suffixed sites still classify
		"WG2":         "kubernetes", // case is not meaningful
		"tailscale0":  "other",
		"wg-personal": "other",
	}
	for iface, want := range cases {
		if got := planeOf(iface).Key; got != want {
			t.Errorf("planeOf(%q) = %s, want %s", iface, got, want)
		}
	}
}

// An adopted estate is a first-class case: this console is pointed at hosts
// it did not build. An unknown interface must be reported, not hidden.
func TestUnknownInterfacesAreReportedNotHidden(t *testing.T) {
	devs := []Device{{Host: "laptop", Name: "wg-personal", PublicKey: "K",
		Peers: []Peer{{PublicKey: "P", Handshake: time.Now()}}}}
	r := PlaneReport(devs)
	if len(r) != 1 || r[0].Plane.Key != "other" {
		t.Fatalf("unknown interface not reported: %+v", r)
	}
	if r[0].Peers != 1 || r[0].Alive != 1 {
		t.Errorf("its peers must still be counted: %+v", r[0])
	}
}

// Severity order, because this is read during an incident: management before
// kubernetes before storage, and enrollment last since it carries nothing.
func TestPlanesAreOrderedByBlastRadius(t *testing.T) {
	mk := func(name string) Device {
		return Device{Host: "n1", Name: name, PublicKey: "k" + name,
			Peers: []Peer{{PublicKey: "p", Handshake: time.Now()}}}
	}
	r := PlaneReport([]Device{mk("wg3"), mk("wg0"), mk("wg2"), mk("wg1")})
	var got []string
	for _, h := range r {
		got = append(got, h.Plane.Key)
	}
	want := "management,kubernetes,storage,enrollment"
	if strings.Join(got, ",") != want {
		t.Errorf("order = %s, want %s", strings.Join(got, ","), want)
	}
}

// A plane nobody runs must not be mentioned. An operator with no cluster
// should not read a line about kubernetes.
func TestAbsentPlanesAreOmitted(t *testing.T) {
	devs := []Device{{Host: "n1", Name: "wg1", PublicKey: "K",
		Peers: []Peer{{PublicKey: "P", Handshake: time.Now()}}}}
	out := PlaneSummary(devs)
	if strings.Contains(out, "kubernetes") || strings.Contains(out, "storage") {
		t.Errorf("planes that do not exist must not be listed:\n%s", out)
	}
	if !strings.Contains(out, "management") {
		t.Errorf("the plane that DOES exist must be listed:\n%s", out)
	}
}

// The summary must name what breaks, not just that something is wrong —
// "management is degraded" is only actionable with "carries ssh".
func TestDegradedPlaneNamesWhatItCarries(t *testing.T) {
	devs := []Device{{Host: "n1", HostFQDN: "n1", Name: "wg1", PublicKey: "K",
		Peers: []Peer{{PublicKey: "P"}}}} // zero handshake = never
	out := PlaneSummary(devs)
	if !strings.Contains(out, "ssh, config management") {
		t.Errorf("a degraded plane must say what it carries:\n%s", out)
	}
	if !strings.Contains(out, "never handshaken") {
		t.Errorf("it must name the fault:\n%s", out)
	}
}

// Forty dead peers on one interface is one problem, not forty clauses.
func TestRepeatedReasonsCollapse(t *testing.T) {
	var peers []Peer
	for i := 0; i < 40; i++ {
		peers = append(peers, Peer{PublicKey: "p"})
	}
	devs := []Device{{Host: "n1", HostFQDN: "n1", Name: "wg1", PublicKey: "K", Peers: peers}}
	out := PlaneSummary(devs)
	if strings.Count(out, "never handshaken") != 1 {
		t.Errorf("reasons should collapse to one clause:\n%s", out)
	}
	if !strings.Contains(out, "40 peer(s)") {
		t.Errorf("the count must survive the collapse:\n%s", out)
	}
}
