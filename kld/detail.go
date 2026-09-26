// detail.go — what the detail pane adds for a selected row, read lazily.
//
// A row is what a listing prints; the pane can afford one more call for
// the thing under the cursor: a VM's disks, NICs and zvol facts, a
// dataset's properties, a pool's tunables. Each detailer runs in a tea.Cmd
// when the selection lands on a row it has not seen, and its lines are
// cached for the life of the tab's data (a reload empties the cache).
package main

import (
	"sort"
	"strings"
	"time"
)

func sortStrings(xs []string) { sort.Strings(xs) }

// detailers return extra "key  value" lines for the row; a line without a
// tab is shown as a heading.
var detailers = map[string]func(row []string) []string{
	"Machines/VMs":      detailVM,
	"Storage/Pools":     detailPool,
	"Storage/Datasets":  detailDataset,
	"Storage/Snapshots": detailSnapshot,
	"Ansible/Hosts":     detailHost,
}

func detailVM(row []string) []string {
	name := col(row, 0)
	var out []string
	if blk, err := run(10*time.Second, "virsh", "domblklist", name); err == nil {
		out = append(out, "disks")
		for _, line := range strings.Split(blk, "\n")[2:] {
			if f := strings.Fields(line); len(f) >= 2 {
				out = append(out, f[0]+"\t"+f[1])
			}
		}
	}
	if ifs, err := run(10*time.Second, "virsh", "domiflist", name); err == nil {
		out = append(out, "nics")
		for _, line := range strings.Split(ifs, "\n")[2:] {
			if f := strings.Fields(line); len(f) >= 5 {
				out = append(out, f[4]+"\t"+f[2]+" ("+f[3]+")")
			}
		}
	}
	if props, err := run(10*time.Second, "zfs", "get", "-H", "-o", "property,value",
		"volsize,used,compression,compressratio,encryption,keystatus,origin,creation", "rpool/vms/"+name); err == nil {
		out = append(out, "zvol rpool/vms/"+name)
		out = append(out, propLines(props)...)
	}
	return out
}

func detailPool(row []string) []string {
	name := col(row, 0)
	props, err := run(10*time.Second, "zpool", "get", "-H", "-o", "property,value",
		"ashift,autotrim,autoreplace,fragmentation,capacity,dedupratio,freeing,leaked,readonly,bootfs,cachefile", name)
	if err != nil {
		return []string{"zpool get\t" + err.Error()}
	}
	return append([]string{"properties"}, propLines(props)...)
}

func detailDataset(row []string) []string {
	name := col(row, 0)
	props, err := run(10*time.Second, "zfs", "get", "-H", "-o", "property,value",
		"compression,compressratio,recordsize,volblocksize,quota,refquota,reservation,encryption,keystatus,atime,sync,mounted,origin,creation,snapshot_count", name)
	if err != nil {
		return []string{"zfs get\t" + err.Error()}
	}
	return append([]string{"properties"}, propLines(props)...)
}

func detailSnapshot(row []string) []string {
	name := col(row, 0)
	props, err := run(10*time.Second, "zfs", "get", "-H", "-o", "property,value",
		"used,referenced,creation,clones,defer_destroy,userrefs", name)
	if err != nil {
		return []string{"zfs get\t" + err.Error()}
	}
	return append([]string{"properties"}, propLines(props)...)
}

func detailHost(row []string) []string {
	inv, err := readInventory()
	if err != nil {
		return []string{"inventory\t" + err.Error()}
	}
	h := inv.hosts[col(row, 0)]
	var out []string
	if len(h) > 0 {
		out = append(out, "hostvars")
		keys := make([]string, 0, len(h))
		for k := range h {
			keys = append(keys, k)
		}
		sortStrings(keys)
		for _, k := range keys {
			out = append(out, k+"\t"+str(h[k]))
		}
	}
	var groups []string
	for g, members := range inv.groups {
		for _, m := range members {
			if m == col(row, 0) {
				groups = append(groups, g)
			}
		}
	}
	sortStrings(groups)
	if len(groups) > 0 {
		out = append(out, "groups\t"+strings.Join(groups, " "))
	}
	return out
}

func propLines(s string) []string {
	var out []string
	for _, line := range strings.Split(strings.TrimSpace(s), "\n") {
		if k, v, ok := strings.Cut(line, "\t"); ok && v != "-" && v != "" {
			out = append(out, k+"\t"+v)
		}
	}
	return out
}
