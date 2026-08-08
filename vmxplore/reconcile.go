// reconcile.go — annotations from the registers that may be stale.
//
// The estate's state lives in four stores that already disagree (see
// docs/VM-CONSOLE-DESIGN.md "four sources of truth"). vmx treats live
// libvirt + live ZFS as the ONLY truth; everything here is an annotation
// layered on top, never a filter. Missing tools/files simply yield empty
// annotations — every probe is capability-gated.
//
// What is annotated, and deliberately what is not: state.db is a partial
// register BY CONSTRUCTION (klab, kvm-win, kimage, kspawn never write it),
// so "in libvirt but not in state.db" would tag half a healthy estate.
// The reverse IS drift worth showing: a register claiming a VM that libvirt
// does not have.
//
// Inputs:  kldload-db (exec, `dump` JSON), /var/lib/kspawn/clusters/*/
//
//	manifest.json, /var/lib/kldload/vm-{build,export}-pending/.
//
// Outputs: Annotations, consumed by model.go.
package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
)

// Annotations is everything the stale registers claim about the estate.
type Annotations struct {
	HasStateDB bool
	StateDB    map[string]bool   // VM name → registered (not soft-deleted)
	Kspawn     map[string]string // VM name → kspawn cluster
	Markers    map[string]string // VM name → webui pending-operation note
}

// LoadAnnotations gathers all register views. Never fails: a register that
// cannot be read is a register with nothing to say.
func LoadAnnotations() *Annotations {
	a := &Annotations{
		StateDB: map[string]bool{},
		Kspawn:  map[string]string{},
		Markers: map[string]string{},
	}
	a.loadStateDB()
	a.loadKspawn()
	a.loadMarkers()
	return a
}

// loadStateDB parses `kldload-db dump` — the tool's own JSON debug surface,
// so vmx carries no sqlite driver and no schema knowledge. Rows are decoded
// generically: a schema change degrades to "no annotation", not a crash.
func (a *Annotations) loadStateDB() {
	if _, err := exec.LookPath("kldload-db"); err != nil {
		return
	}
	out, err := exec.Command("kldload-db", "dump").Output()
	if err != nil {
		return // no DB yet / no permission — nothing to annotate
	}
	var dump map[string][]map[string]any
	if json.Unmarshal(out, &dump) != nil {
		return
	}
	for _, vm := range dump["vms"] {
		name, _ := vm["name"].(string)
		if name == "" {
			continue
		}
		// soft-delete column: a non-empty deleted_at means deregistered
		if del, ok := vm["deleted_at"].(string); ok && del != "" {
			continue
		}
		a.StateDB[name] = true
	}
	a.HasStateDB = true
}

// loadKspawn reads each cluster manifest and collects its node names.
func (a *Annotations) loadKspawn() {
	manifests, _ := filepath.Glob("/var/lib/kspawn/clusters/*/manifest.json")
	for _, m := range manifests {
		b, err := os.ReadFile(m)
		if err != nil {
			continue
		}
		var doc struct {
			Cluster string `json:"cluster"`
			Nodes   []struct {
				Name string `json:"name"`
			} `json:"nodes"`
		}
		if json.Unmarshal(b, &doc) != nil {
			continue // hand-rolled printf JSON; a bad manifest annotates nothing
		}
		cluster := doc.Cluster
		if cluster == "" {
			cluster = filepath.Base(filepath.Dir(m))
		}
		for _, n := range doc.Nodes {
			if n.Name != "" {
				a.Kspawn[n.Name] = cluster
			}
		}
	}
}

// loadMarkers picks up the webui's pending-operation breadcrumbs: a file per
// VM whose presence means "an async provisioning step has not finished".
func (a *Annotations) loadMarkers() {
	for dir, note := range map[string]string{
		"/var/lib/kldload/vm-build-pending":  "build pending",
		"/var/lib/kldload/vm-export-pending": "export pending",
	} {
		ents, err := os.ReadDir(dir)
		if err != nil {
			continue // dir absent on most hosts; that is the normal case
		}
		for _, e := range ents {
			a.Markers[e.Name()] = note
		}
	}
}
