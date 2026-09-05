// roster.go — membership without a registry.
//
// What it does, in order:
//  1. Builds the roster: every public key that some host in the estate owns.
//  2. Labels each peer that matches the roster with the host and interface
//     it actually belongs to, so views show names instead of key fragments.
//  3. Flags the peers that match nothing — orphans.
//  4. Finds one-way relationships — A carries B, B has never heard of A.
//
// WHY this file exists: the console used to answer "is this peer supposed to
// be here?" by reading declarations under /etc/wgx, which meant it could
// only speak about networks it had created itself. Point it at a kldload
// cluster, a hand-rolled wg0.conf, or anything a stranger built, and every
// peer came back untracked.
//
// There is no registry to read instead. kldload generates a keypair per host
// at install time and `kube-network add-peer` is run by hand on each node —
// deliberately, because a private key that never leaves the machine cannot
// leak from a central store and dies with the node that owned it. Nothing
// writes down the intended membership of the substrate's planes anywhere.
//
// The one exception is the appliance meshes: kvm-mesh mints a key for each
// VM it enrolls and records it in a members file on the host, and the VM
// is reachable only over that mesh — never a swept host. Those files are
// read with the sweep (estate.go, parseMembers) and join the roster below,
// so an appliance peer is declared by the host that made it.
//
// That turns out not to matter, because a full-estate sweep already contains
// the answer. Every legitimate peer entry in a mesh is some other host's own
// interface. So the union of the hosts' own public keys IS the roster, and
// set difference against it answers the questions that motivated wanting a
// registry in the first place — with the advantage that it describes what is
// actually running rather than what someone meant to deploy.
//
// Inputs:  a []Device from CollectEstate — the whole estate, not one host.
// Outputs: labels and flags written back into the devices, plus findings.
//
// Notes: this is only sound over a COMPLETE sweep. A partial estate makes
// every unswept host's key look orphaned, so callers must say how many hosts
// failed (see Findings.Partial) rather than reporting false orphans as fact.
package main

import (
	"fmt"
	"sort"
	"strings"
)

// Owner is the host and interface that a public key belongs to.
type Owner struct {
	Host  string // display name of the host
	Iface string // the interface on that host
}

// Orphan is a peer entry that matches no host in the estate.
type Orphan struct {
	OnHost     string // where the entry was found
	OnIface    string
	PublicKey  string
	Endpoint   string
	AllowedIPs string
	Health     string // alive / quiet / stale / never
}

// OneWay is a relationship carried in only one direction: `From` lists
// `To`'s key as a peer, but `To` has no peer entry for `From`.
type OneWay struct {
	FromHost, FromIface string
	ToHost, ToIface     string
}

// Findings is everything the roster analysis can say about an estate.
type Findings struct {
	Roster  map[string]Owner // pubkey → who owns it
	Orphans []Orphan
	OneWays []OneWay
	Partial int // hosts that failed to answer; >0 means treat orphans as suspect
}

// BuildRoster returns every public key owned by an interface in the estate,
// plus every key a swept host declares for a VM on one of its appliance
// meshes (Device.Members).
//
// Members go in first and a swept interface overwrites: when an appliance
// VM is itself in the inventory, its own row names the interface on the VM,
// which is the more precise owner than the host's record of it.
//
// A host that failed to answer contributes nothing, which is why the caller
// must track Partial — an unreachable host's key would otherwise look like
// an orphan everywhere it is legitimately peered.
func BuildRoster(devs []Device) (map[string]Owner, int) {
	roster := map[string]Owner{}
	partial := 0
	seenBad := map[string]bool{}
	for _, d := range devs {
		if d.Err != "" {
			continue
		}
		for _, m := range d.Members {
			if m.PublicKey != "" {
				roster[m.PublicKey] = Owner{Host: m.Name, Iface: m.Mesh}
			}
		}
	}
	for _, d := range devs {
		if d.Err != "" {
			// Count hosts, not interfaces: one unreachable host produces one
			// error row, but a reachable host produces one row per interface.
			if !seenBad[d.Host] {
				seenBad[d.Host] = true
				partial++
			}
			continue
		}
		if d.PublicKey == "" {
			continue
		}
		roster[d.PublicKey] = Owner{Host: HostDisplay(d), Iface: d.Name}
	}
	return roster, partial
}

// Analyse labels peers against the roster and returns what it found.
//
// It writes back into devs: Peer.Declared and Peer.Label for peers that
// belong to a known host, and Device.Managed for every interface the estate
// owns — which, with the roster built from the estate itself, is all of
// them. Managed stays in place because the views key their alarm off it.
//
// The alarm semantics are deliberately unchanged from the declaration era:
// an orphan is worth showing, but a sweep that could not reach half the
// estate must not paint the survivors pink. Callers check Partial first.
func Analyse(devs []Device) Findings {
	roster, partial := BuildRoster(devs)
	f := Findings{Roster: roster, Partial: partial}

	// peersOf[ownerKey] = the set of keys that owner's host carries, so the
	// reciprocity check below is a lookup rather than a second sweep.
	carries := map[string]map[string]bool{}

	for i := range devs {
		d := &devs[i]
		if d.Err != "" {
			continue
		}
		d.Managed = d.PublicKey != ""
		if d.PublicKey != "" {
			carries[d.PublicKey] = map[string]bool{}
		}
		for j := range d.Peers {
			p := &d.Peers[j]
			if d.PublicKey != "" {
				carries[d.PublicKey][p.PublicKey] = true
			}
			if o, ok := roster[p.PublicKey]; ok {
				p.Declared = true
				p.Label = o.Host + "/" + o.Iface
				continue
			}
			p.Declared = false
			p.Label = ""
			f.Orphans = append(f.Orphans, Orphan{
				OnHost:     HostDisplay(*d),
				OnIface:    d.Name,
				PublicKey:  p.PublicKey,
				Endpoint:   p.Endpoint,
				AllowedIPs: p.AllowedIPs,
				Health:     p.Health(),
			})
		}
	}

	// Reciprocity. In a mesh every relationship should be carried by both
	// ends; a one-way entry is a half-built tunnel that looks configured
	// from one side and does not exist from the other. This is the failure
	// `wg show` structurally cannot report, because it only ever sees one
	// end.
	for _, d := range devs {
		if d.Err != "" || d.PublicKey == "" {
			continue
		}
		for _, p := range d.Peers {
			owner, known := roster[p.PublicKey]
			if !known {
				continue // orphans are already reported; not a mesh gap
			}
			if back, ok := carries[p.PublicKey]; ok && !back[d.PublicKey] {
				f.OneWays = append(f.OneWays, OneWay{
					FromHost: HostDisplay(d), FromIface: d.Name,
					ToHost: owner.Host, ToIface: owner.Iface,
				})
			}
		}
	}

	sort.Slice(f.Orphans, func(i, j int) bool {
		if f.Orphans[i].OnHost != f.Orphans[j].OnHost {
			return f.Orphans[i].OnHost < f.Orphans[j].OnHost
		}
		return f.Orphans[i].PublicKey < f.Orphans[j].PublicKey
	})
	sort.Slice(f.OneWays, func(i, j int) bool {
		if f.OneWays[i].FromHost != f.OneWays[j].FromHost {
			return f.OneWays[i].FromHost < f.OneWays[j].FromHost
		}
		return f.OneWays[i].ToHost < f.OneWays[j].ToHost
	})
	return f
}

// Report renders the findings as text for `wgx check`.
//
// It is deliberately quiet on a healthy estate: one line saying so. An
// operator who runs this in a loop should be able to tell "nothing wrong"
// from "something wrong" without reading.
func (f Findings) Report() string {
	var b strings.Builder
	if f.Partial > 0 {
		fmt.Fprintf(&b, "%s⚠ %d host(s) did not answer — membership is incomplete,\n"+
			"  so orphans below may simply be hosts this sweep could not reach.%s\n\n",
			cY, f.Partial, cN)
	}
	if len(f.Orphans) == 0 && len(f.OneWays) == 0 {
		fmt.Fprintf(&b, "%s✓ %d keys in the estate; every peer accounted for, every link mutual.%s\n",
			cG, len(f.Roster), cN)
		return b.String()
	}
	if len(f.Orphans) > 0 {
		fmt.Fprintf(&b, "%sPeers matching no host in the estate (%d)%s\n", cC, len(f.Orphans), cN)
		fmt.Fprintf(&b, "%s  A dead node's leftover entry, or an off-estate client —\n"+
			"  a laptop or phone. Handshake age tells you which.%s\n", cD, cN)
		for _, o := range f.Orphans {
			col := cR
			if o.Health == "alive" {
				col = cG // handshaking right now: a real client, not debris
			}
			fmt.Fprintf(&b, "  %s/%s  %s  %s%s%s  %s\n",
				o.OnHost, o.OnIface, short(o.PublicKey), col, o.Health, cN, orDash(o.Endpoint))
		}
		b.WriteString("\n")
	}
	if len(f.OneWays) > 0 {
		fmt.Fprintf(&b, "%sOne-way links (%d)%s\n", cC, len(f.OneWays), cN)
		fmt.Fprintf(&b, "%s  The left side carries the right side as a peer; the right side\n"+
			"  has no entry back. Traffic goes one way at best.%s\n", cD, cN)
		for _, w := range f.OneWays {
			fmt.Fprintf(&b, "  %s%s/%s → %s/%s%s   (no return peer)\n",
				cY, w.FromHost, w.FromIface, w.ToHost, w.ToIface, cN)
		}
	}
	return b.String()
}

// cmdCheck is `wgx check` — sweep the estate and report what does not add up.
func cmdCheck() error {
	devs := CollectEstate(sshHosts())
	f := Analyse(devs)
	// Planes first: an operator reading this during an incident wants "which
	// plane is broken" before "which peer key is unaccounted for".
	if ps := PlaneSummary(devs); ps != "" {
		fmt.Print(ps)
		fmt.Println()
	}
	fmt.Print(f.Report())
	return nil
}
