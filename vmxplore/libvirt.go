// libvirt.go — the libvirt half of the join: domains, state, stats, disks.
//
// Talks the libvirt RPC wire protocol directly via digitalocean/go-libvirt
// (pure Go, CGO_ENABLED=0 static — the family's release story) instead of
// forking virsh per refresh, which matters at 25 domains on a 2s tick.
//
// Inputs:  the local libvirt socket (qemu:///system).
// Outputs: []Dom — everything the estate table needs from libvirt's side,
//
//	including each domain's disk sources parsed from its XML so
//	model.go can join them against ZFS datasets.
//
// Notes: ConnectGetAllDomainStats is one round trip for the whole estate;
// per-domain calls are only XML (cached by libvirt) and the guest-agent
// probe, which runs concurrently because a hung agent must not stall the
// whole refresh.
package main

import (
	"encoding/xml"
	"fmt"
	"net/url"
	"sort"
	"sync"
	"time"

	libvirt "github.com/digitalocean/go-libvirt"
)

// Disk is one <disk> of a domain: either a block device (zvols live here)
// or a file (qcow2 estates — tier 1, no join).
type Disk struct {
	Target string // guest-side name, e.g. vda
	Dev    string // host block device, e.g. /dev/zvol/rpool/vms/x
	File   string // host file path for file-backed disks
}

// Dom is a libvirt domain flattened to what the estate view renders.
type Dom struct {
	Name       string
	UUID       string
	Active     bool
	State      string // running / shut off / paused / …
	VCPUs      uint64
	CurMemKiB  uint64
	MaxMemKiB  uint64
	CPUTimeNs  uint64 // cumulative; CPU%% is a delta between two samples
	Disks      []Disk
	AgentUp    bool
	IPs        []string // guest-agent-reported, non-loopback
	Persistent bool     // transient domains vanish on destroy — verbs.go guards
	Autostart  bool
}

// LV wraps the libvirt connection for the estate reads.
type LV struct {
	l *libvirt.Libvirt
}

// ConnectSystem connects to the current target's libvirt URI (local
// qemu:///system by default; a remote qemu+ssh://host/system when
// ConnectTarget set one). Local needs root or the libvirt group — main.go
// handles elevation before retrying.
func ConnectSystem() (*LV, error) {
	uri, err := url.Parse(target.LibvirtURI)
	if err != nil {
		return nil, err
	}
	l, err := libvirt.ConnectToURI(uri)
	if err != nil {
		return nil, err
	}
	return &LV{l: l}, nil
}

// ConnectTarget points the process at a host (see ParseTarget) and connects.
// go-libvirt speaks qemu+ssh:// over a pure-Go dialer, so remote needs no
// cgo — the static story holds. Sets the global target on success so the
// verbs, ZFS reads and consoles all follow.
func ConnectTarget(dest string) (*LV, error) {
	prev := target
	target = ParseTarget(dest)
	lv, err := ConnectSystem()
	if err != nil {
		target = prev // don't leave the process pointed at a dead host
		return nil, err
	}
	return lv, nil
}

// Close disconnects. Errors are irrelevant on the way out.
func (lv *LV) Close() {
	// error ignored: nothing to do about a failed goodbye at exit
	_ = lv.l.Disconnect()
}

// domainStateNames maps libvirt VIR_DOMAIN_* state ints to virsh's words, so
// operators see the vocabulary they already grep logs for.
var domainStateNames = map[int64]string{
	int64(libvirt.DomainNostate):     "no state",
	int64(libvirt.DomainRunning):     "running",
	int64(libvirt.DomainBlocked):     "blocked",
	int64(libvirt.DomainPaused):      "paused",
	int64(libvirt.DomainShutdown):    "shutting down",
	int64(libvirt.DomainShutoff):     "shut off",
	int64(libvirt.DomainCrashed):     "crashed",
	int64(libvirt.DomainPmsuspended): "pmsuspended",
}

// asUint coerces a TypedParamValue payload (int32/uint32/int64/uint64 …
// depending on the wire discriminant) to uint64.
func asUint(v interface{}) (uint64, bool) {
	switch n := v.(type) {
	case int32:
		return uint64(n), true
	case uint32:
		return uint64(n), true
	case int64:
		return uint64(n), true
	case uint64:
		return n, true
	case int:
		return uint64(n), true
	}
	return 0, false
}

// Estate lists every domain (active + inactive) with state, stats, disks and
// guest-agent info — the complete libvirt side of one refresh.
func (lv *LV) Estate() ([]Dom, error) {
	doms, _, err := lv.l.ConnectListAllDomains(1,
		libvirt.ConnectListDomainsActive|libvirt.ConnectListDomainsInactive)
	if err != nil {
		return nil, fmt.Errorf("list domains: %w", err)
	}

	stats, err := lv.l.ConnectGetAllDomainStats(doms,
		uint32(libvirt.DomainStatsState|libvirt.DomainStatsCPUTotal|
			libvirt.DomainStatsBalloon|libvirt.DomainStatsVCPU), 0)
	if err != nil {
		return nil, fmt.Errorf("domain stats: %w", err)
	}
	byName := make(map[string]*Dom, len(doms))
	out := make([]Dom, 0, len(doms))
	for _, rec := range stats {
		d := Dom{Name: rec.Dom.Name, UUID: uuidString(rec.Dom.UUID), State: "unknown"}
		for _, p := range rec.Params {
			n, ok := asUint(p.Value.I)
			if !ok {
				continue
			}
			switch p.Field {
			case libvirt.DomainStatsStateState:
				if s, ok := domainStateNames[int64(n)]; ok {
					d.State = s
				}
				d.Active = n == uint64(libvirt.DomainRunning) ||
					n == uint64(libvirt.DomainPaused) ||
					n == uint64(libvirt.DomainBlocked)
			case "cpu.time":
				d.CPUTimeNs = n
			case "balloon.current":
				d.CurMemKiB = n
			case "balloon.maximum":
				d.MaxMemKiB = n
			case "vcpu.current":
				d.VCPUs = n
			}
		}
		out = append(out, d)
		byName[d.Name] = &out[len(out)-1]
	}

	// Disks come from the XML; one call per domain, cheap and cached by
	// libvirtd. Shut-off domains have no balloon stats — backfill mem/vcpu
	// from the config so the table isn't blank for them.
	for _, ld := range doms {
		d, ok := byName[ld.Name]
		if !ok {
			continue
		}
		if pers, err := lv.l.DomainIsPersistent(ld); err == nil {
			d.Persistent = pers == 1
		}
		if as, err := lv.l.DomainGetAutostart(ld); err == nil {
			d.Autostart = as == 1
		}
		x, err := lv.l.DomainGetXMLDesc(ld, 0)
		if err != nil {
			continue // domain vanished mid-refresh; next tick catches up
		}
		info, err := parseDomainXML(x)
		if err == nil {
			d.Disks = info.disks
			if d.MaxMemKiB == 0 {
				d.MaxMemKiB = info.memKiB
			}
			if d.VCPUs == 0 {
				d.VCPUs = info.vcpus
			}
		}
	}

	// Guest-agent probe, running domains only, concurrent: a hung agent
	// blocks its goroutine, not the refresh.
	var wg sync.WaitGroup
	for _, ld := range doms {
		d, ok := byName[ld.Name]
		if !ok || !d.Active {
			continue
		}
		wg.Add(1)
		go func(ld libvirt.Domain, d *Dom) {
			defer wg.Done()
			ifs, err := lv.l.DomainInterfaceAddresses(ld,
				uint32(libvirt.DomainInterfaceAddressesSrcAgent), 0)
			if err != nil {
				return // no channel or agent down — AgentUp stays false
			}
			d.AgentUp = true
			for _, i := range ifs {
				for _, a := range i.Addrs {
					if a.Addr != "127.0.0.1" && a.Addr != "::1" {
						d.IPs = append(d.IPs, a.Addr)
					}
				}
			}
		}(ld, d)
	}
	wg.Wait()

	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// CPUSample grabs just cpu.time for every domain — the cheap half of a CPU%%
// measurement. Callers diff two samples over a wall-clock interval.
func (lv *LV) CPUSample() (map[string]uint64, time.Time, error) {
	doms, _, err := lv.l.ConnectListAllDomains(1, libvirt.ConnectListDomainsActive)
	if err != nil {
		return nil, time.Time{}, err
	}
	stats, err := lv.l.ConnectGetAllDomainStats(doms,
		uint32(libvirt.DomainStatsCPUTotal), 0)
	if err != nil {
		return nil, time.Time{}, err
	}
	m := make(map[string]uint64, len(stats))
	for _, rec := range stats {
		for _, p := range rec.Params {
			if p.Field == "cpu.time" {
				if n, ok := asUint(p.Value.I); ok {
					m[rec.Dom.Name] = n
				}
			}
		}
	}
	return m, time.Now(), nil
}

// XML returns the full domain XML (the detail view's raw tab).
func (lv *LV) XML(name string) (string, error) {
	d, err := lv.l.DomainLookupByName(name)
	if err != nil {
		return "", err
	}
	return lv.l.DomainGetXMLDesc(d, 0)
}

func uuidString(u libvirt.UUID) string {
	return fmt.Sprintf("%x-%x-%x-%x-%x", u[0:4], u[4:6], u[6:8], u[8:10], u[10:16])
}

// ─── domain XML parsing ─────────────────────────────────────────────────────
// Only what the join needs: disk sources, and memory/vcpu fallbacks for
// shut-off domains. encoding/xml with minimal structs; tested in
// libvirt_xml_test.go against real dumpxml output.

type domInfo struct {
	disks  []Disk
	memKiB uint64
	vcpus  uint64
}

type xmlDomain struct {
	Memory struct {
		Unit  string `xml:"unit,attr"`
		Value uint64 `xml:",chardata"`
	} `xml:"memory"`
	VCPU struct {
		Value uint64 `xml:",chardata"`
	} `xml:"vcpu"`
	Devices struct {
		Disks []struct {
			Device string `xml:"device,attr"`
			Source struct {
				Dev  string `xml:"dev,attr"`
				File string `xml:"file,attr"`
			} `xml:"source"`
			Target struct {
				Dev string `xml:"dev,attr"`
			} `xml:"target"`
		} `xml:"disk"`
	} `xml:"devices"`
}

// memUnitKiB converts libvirt <memory unit=…> to KiB. Unknown units return 0
// rather than a wrong number — a blank beats a lie in an ops table.
func memUnitKiB(unit string, v uint64) uint64 {
	switch unit {
	case "", "KiB", "k", "KB":
		return v
	case "MiB", "M", "MB":
		return v * 1024
	case "GiB", "G", "GB":
		return v * 1024 * 1024
	case "b", "bytes":
		return v / 1024
	}
	return 0
}

// parseDomainDisks parses <disk device="disk"> sources; cdroms are skipped —
// an attached ISO is not the VM's storage.
func parseDomainXML(x string) (domInfo, error) {
	var d xmlDomain
	if err := xml.Unmarshal([]byte(x), &d); err != nil {
		return domInfo{}, err
	}
	info := domInfo{
		memKiB: memUnitKiB(d.Memory.Unit, d.Memory.Value),
		vcpus:  d.VCPU.Value,
	}
	for _, disk := range d.Devices.Disks {
		if disk.Device != "" && disk.Device != "disk" {
			continue
		}
		info.disks = append(info.disks, Disk{
			Target: disk.Target.Dev,
			Dev:    disk.Source.Dev,
			File:   disk.Source.File,
		})
	}
	return info, nil
}
