// planes.go — what each interface is FOR.
//
// What it does, in order:
//  1. Maps an interface name to the role this substrate gives it.
//  2. Groups an estate's devices by role rather than by host.
//  3. Summarises each plane: how many carriers, how many alive, what breaks
//     when it is down.
//
// WHY this file is the reason the console exists. `wg show` reports five
// interfaces with hex keys and byte counters. It cannot tell you that wg1
// going stale on one node is why that node stopped answering ssh, because
// nothing in WireGuard knows ssh is bound there. The substrate knows: it
// assigned the roles at first boot, and wrote them down. Reading the
// protocol without that mapping is the generic view anyone can get; reading
// it WITH the mapping is the only thing here that no other tool can do.
//
// The convention comes from the installer's firstboot, which builds four
// planes on every node, and from kube-network, which builds two more on
// cluster members:
//
//	wg0       enrollment only — deliberately carries no services
//	wg1       management — ssh and the config-management agent
//	wg2       kubernetes backend
//	wg3       storage replication
//	wg-mgmt   cluster management plane (10.250.0/24)
//	wg-k8s    cluster kubernetes plane (10.251.0/24)
//	ap-*      appliance meshes — kvm-mesh gives every appliance VM its own
//	          /24 to the host (10.254.x/24), named ap-<vm>; a dozen of them
//	          on a busy host, one per tile
//
// Notes: an unrecognised interface is NOT an error and must not be hidden.
// This console adopts estates it did not build — a hand-rolled wg0.conf on
// somebody's laptop is a legitimate thing to look at — so unknown names get
// a neutral role and are reported alongside the rest.
package main

import (
	"fmt"
	"sort"
	"strings"
)

// Plane is one role in the substrate's network design.
type Plane struct {
	Key      string // stable identifier for grouping
	Name     string // what an operator calls it
	Carries  string // what breaks when this plane is down
	Critical bool   // whether a stale peer here is worth waking up for
}

// planes are ordered by how much it hurts when they fail, because that is
// the order an operator wants to read them in during an incident.
var planeOrder = []Plane{
	{"management", "management", "ssh, config management", true},
	{"kubernetes", "kubernetes", "the cluster backend", true},
	{"storage", "storage", "replication", true},
	// One mesh per appliance VM, minted at enrollment. Not critical: losing
	// one takes the host's management path to ONE appliance, not a service.
	// Its own plane so ten of them read as one folder rather than ten rows
	// scattered among the substrate's planes ("all over the place",
	// operator, 2026-09-04).
	{"apps", "apps", "the host's management link to each appliance VM", false},
	{"enrollment", "enrollment", "joining only — no services by design", false},
	{"other", "unclassified", "unknown to this substrate", false},
}

// planeRank is a plane's position in planeOrder: the sort key every view
// uses so interfaces of one host read plane by plane.
func planeRank(p Plane) int {
	for i, q := range planeOrder {
		if q.Key == p.Key {
			return i
		}
	}
	return len(planeOrder)
}

// planeOf maps an interface name to its role.
//
// Matching is exact on the names the substrate creates, then prefix-based,
// so a site that appends a suffix (wg1-dc2) still classifies. Everything
// else lands in "other" rather than being guessed at.
func planeOf(iface string) Plane {
	byKey := func(k string) Plane {
		for _, p := range planeOrder {
			if p.Key == k {
				return p
			}
		}
		return planeOrder[len(planeOrder)-1]
	}
	n := strings.ToLower(strings.TrimSpace(iface))
	switch {
	case n == "wg0" || strings.HasPrefix(n, "wg0-"):
		return byKey("enrollment")
	case n == "wg1" || strings.HasPrefix(n, "wg1-"), strings.HasPrefix(n, "wg-mgmt"):
		return byKey("management")
	case n == "wg2" || strings.HasPrefix(n, "wg2-"), strings.HasPrefix(n, "wg-k8s"):
		return byKey("kubernetes")
	case n == "wg3" || strings.HasPrefix(n, "wg3-"), strings.HasPrefix(n, "wg-storage"):
		return byKey("storage")
	case strings.HasPrefix(n, "ap-"):
		return byKey("apps")
	}
	return byKey("other")
}

// PlaneHealth is one plane's state across the whole estate.
type PlaneHealth struct {
	Plane    Plane
	Hosts    int      // hosts carrying an interface on this plane
	Ifaces   int      // interfaces on it
	Peers    int      // peer entries across those interfaces
	Alive    int      // peers that handshook recently
	Never    int      // peers that have NEVER handshaken
	Stale    int      // peers last seen too long ago
	Degraded []string // "host/iface — why", worst first
}

// Down reports whether this plane has a problem worth naming.
func (h PlaneHealth) Down() bool { return h.Never > 0 || h.Stale > 0 }

// PlaneReport groups an estate by role and scores each plane.
//
// Args:    devs  the whole estate from CollectEstate, after Analyse has
//
//	labelled its peers.
//
// Returns: one entry per plane that actually exists in this estate, in
// severity order. Planes nobody runs are omitted — an operator with no
// cluster should not read two lines about kubernetes being absent.
func PlaneReport(devs []Device) []PlaneHealth {
	acc := map[string]*PlaneHealth{}
	hostsSeen := map[string]map[string]bool{}

	for _, d := range devs {
		if d.Err != "" || d.Name == "" {
			continue
		}
		p := planeOf(d.Name)
		h, ok := acc[p.Key]
		if !ok {
			h = &PlaneHealth{Plane: p}
			acc[p.Key] = h
			hostsSeen[p.Key] = map[string]bool{}
		}
		if !hostsSeen[p.Key][d.Host] {
			hostsSeen[p.Key][d.Host] = true
			h.Hosts++
		}
		h.Ifaces++
		for _, peer := range d.Peers {
			h.Peers++
			switch peer.Health() {
			case "alive":
				h.Alive++
			case "never":
				h.Never++
			case "stale":
				h.Stale++
			}
		}
		// Name the interface only when something is actually wrong with it,
		// so a healthy plane prints one line and an unhealthy one prints
		// the hosts to go and look at.
		var bad []string
		for _, peer := range d.Peers {
			switch peer.Health() {
			case "never":
				bad = append(bad, "never handshaken")
			case "stale":
				bad = append(bad, "stale "+peer.Age())
			}
		}
		if len(bad) > 0 {
			h.Degraded = append(h.Degraded,
				fmt.Sprintf("%s/%s — %d peer(s): %s",
					HostDisplay(d), d.Name, len(bad), strings.Join(uniq(bad), ", ")))
		}
	}

	var out []PlaneHealth
	for _, p := range planeOrder {
		if h, ok := acc[p.Key]; ok {
			sort.Strings(h.Degraded)
			out = append(out, *h)
		}
	}
	return out
}

// uniq collapses repeated reasons so one interface with forty dead peers
// reads as "40 peer(s): never handshaken" rather than forty identical
// clauses.
func uniq(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// PlaneSummary renders the planes for `wgx check` and the estate header.
//
// Healthy planes get one line each. That is deliberate: the value of this
// view is that an operator can tell "the backplane is fine" from "management
// is broken on node4" in one glance, without reading peer rows.
func PlaneSummary(devs []Device) string {
	report := PlaneReport(devs)
	if len(report) == 0 {
		return ""
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%sPlanes%s\n", cC, cN)
	for _, h := range report {
		col := cG
		state := "ok"
		if h.Down() {
			col, state = cR, "degraded"
			if !h.Plane.Critical {
				col = cY
			}
		}
		fmt.Fprintf(&b, "  %s%-13s%s %d host(s), %d iface(s), %d/%d peers alive   %s%s%s\n",
			cC, h.Plane.Name, cN, h.Hosts, h.Ifaces, h.Alive, h.Peers, col, state, cN)
		if h.Down() {
			fmt.Fprintf(&b, "%s      carries %s%s\n", cD, h.Plane.Carries, cN)
			for _, d := range h.Degraded {
				fmt.Fprintf(&b, "      %s\n", d)
			}
		}
	}
	return b.String()
}
