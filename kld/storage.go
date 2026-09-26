// storage.go — zxplore's terminal, ported into the Storage section.
//
// The pool drill-down (vitals, space, vdevs, I/O, events), the shares view
// (NFS, SMB, iSCSI matched to the dataset that serves them), and the
// verbs of zxplore's snapshot and dataset menus (storage verbs live in
// verbs.go). Every mutation is the zfs/zpool command zxplore ran, with the
// consent zxplore asked for where it asked (a typed name), and one it did
// not: replicate asks, because `zfs recv -F` rolls the destination back
// (2026-09-26 port).
package main

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

// loadPoolDetail is zxplore's PoolDossier: one tab of text sections for the
// pool Enter was pressed on (the context).
func loadPoolDetail(d *sectionData) {
	pool := d.ctx
	if pool == "" {
		d.headline = "press enter on a pool in Pools to open it here"
		return
	}
	d.columns = []string{"zpool " + pool}
	add := func(title string, cmd ...string) {
		out, err := run(30*time.Second, cmd[0], cmd[1:]...)
		d.rows = append(d.rows, []string{"── " + title + " ── " + strings.Join(cmd, " ")})
		if err != nil {
			d.rows = append(d.rows, []string{"  " + err.Error()})
			return
		}
		for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
			d.rows = append(d.rows, []string{"  " + line})
		}
		d.rows = append(d.rows, []string{""})
	}
	add("vitals", "zpool", "get", "-H", "-o", "property,value", "health,size,allocated,free,capacity,fragmentation,dedupratio,ashift,autotrim,autoexpand,autoreplace,failmode,readonly,bootfs,guid", pool)
	add("space", "zfs", "list", "-o", "name,used,available,referenced,usedbysnapshots,usedbydataset,usedbychildren", "-r", "-d", "1", "-t", "filesystem", pool)
	add("vdevs", "zpool", "status", "-v", "-P", pool)
	add("i/o since import", "zpool", "iostat", "-v", pool)
	add("last events", "sh", "-c", `zpool events -H | tail -n 12`)
	d.headline = fmt.Sprintf("%s — %d lines", pool, len(d.rows))
}

// ── shares: what this host serves, matched to the dataset behind it ─────────

type share struct{ kind, name, path, clients, opts string }

func loadShares(d *sectionData) {
	var shares []share
	notRead := []string{}
	// NFS: exportfs -v prints "path  client(options)" (long paths wrap)
	if out, err := run(10*time.Second, "exportfs", "-v"); err == nil {
		var last *share
		for _, line := range strings.Split(out, "\n") {
			if line == "" {
				continue
			}
			if strings.HasPrefix(line, "/") {
				f := strings.Fields(line)
				shares = append(shares, share{kind: "nfs", name: f[0], path: f[0]})
				last = &shares[len(shares)-1]
				if len(f) > 1 {
					last.clients, last.opts = splitClientOpts(f[1])
				}
			} else if last != nil {
				last.clients, last.opts = splitClientOpts(strings.TrimSpace(line))
			}
		}
	} else {
		notRead = append(notRead, "nfs (exportfs)")
	}
	// SMB: testparm -s prints [share] sections with path = …
	if out, err := run(15*time.Second, "testparm", "-s"); err == nil {
		var cur *share
		for _, line := range strings.Split(out, "\n") {
			t := strings.TrimSpace(line)
			if strings.HasPrefix(t, "[") && strings.HasSuffix(t, "]") {
				name := strings.Trim(t, "[]")
				if name == "global" {
					cur = nil
					continue
				}
				shares = append(shares, share{kind: "smb", name: name})
				cur = &shares[len(shares)-1]
				continue
			}
			if cur == nil {
				continue
			}
			if k, v, ok := strings.Cut(t, "="); ok {
				k, v = strings.TrimSpace(k), strings.TrimSpace(v)
				switch k {
				case "path":
					cur.path = v
				case "valid users", "hosts allow":
					cur.clients = v
				case "read only", "guest ok", "browseable":
					cur.opts = strings.TrimSpace(cur.opts + " " + k + "=" + v)
				}
			}
		}
	} else {
		notRead = append(notRead, "smb (testparm)")
	}
	// iSCSI: targetcli's block backstores name the zvol they export
	if out, err := run(15*time.Second, "targetcli", "ls", "/backstores/block"); err == nil {
		for _, line := range strings.Split(out, "\n") {
			if i := strings.Index(line, "/dev/zvol/"); i >= 0 {
				f := strings.Fields(line[i:])
				name := "-"
				if j := strings.Index(line, "o- "); j >= 0 {
					name = strings.Fields(line[j+3:])[0]
				}
				shares = append(shares, share{kind: "iscsi", name: name, path: f[0]})
			}
		}
	} else {
		notRead = append(notRead, "iscsi (targetcli)")
	}
	// the dataset behind each share: the longest mountpoint that prefixes
	// the path, or the zvol itself
	mounts := map[string]string{}
	if out, err := run(15*time.Second, "zfs", "list", "-H", "-o", "name,mountpoint", "-t", "filesystem"); err == nil {
		for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
			if f := strings.Split(line, "\t"); len(f) == 2 && strings.HasPrefix(f[1], "/") {
				mounts[f[1]] = f[0]
			}
		}
	}
	daemons := []string{}
	for _, u := range []string{"nfs-server", "nfs-kernel-server", "smb", "smbd", "target", "tgt"} {
		if out, err := run(5*time.Second, "systemctl", "is-active", u); err == nil && strings.TrimSpace(out) == "active" {
			daemons = append(daemons, u)
		}
	}
	d.columns = []string{"share", "kind", "dataset", "path", "clients", "options"}
	for _, s := range shares {
		ds := "-"
		if strings.HasPrefix(s.path, "/dev/zvol/") {
			ds = strings.TrimPrefix(s.path, "/dev/zvol/")
		} else {
			best := ""
			for mp, name := range mounts {
				if (s.path == mp || strings.HasPrefix(s.path, strings.TrimSuffix(mp, "/")+"/")) && len(mp) > len(best) {
					best, ds = mp, name
				}
			}
		}
		d.rows = append(d.rows, []string{s.name, s.kind, ds, orDash(s.path), orDash(s.clients), orDash(s.opts)})
	}
	sort.SliceStable(d.rows, func(i, j int) bool { return d.rows[i][1]+d.rows[i][0] < d.rows[j][1]+d.rows[j][0] })
	switch {
	case len(daemons) == 0:
		d.headline = "no share daemon is running (nfs-server, smb, target) — SHARES NOT SERVED"
	default:
		d.headline = fmt.Sprintf("%d share(s) · serving: %s", len(d.rows), strings.Join(daemons, " "))
	}
	if len(notRead) > 0 {
		d.headline += " · not read: " + strings.Join(notRead, ", ")
	}
}

func splitClientOpts(s string) (string, string) {
	if i := strings.Index(s, "("); i >= 0 {
		return s[:i], strings.Trim(s[i:], "()")
	}
	return s, ""
}

// datasetMounted says whether a filesystem is mounted, for verbs that need a path.
func datasetMountpoint(ds string) (string, bool) {
	out, err := run(5*time.Second, "zfs", "get", "-H", "-o", "value", "mountpoint,mounted", ds)
	if err != nil {
		return "", false
	}
	f := strings.Split(strings.TrimSpace(out), "\n")
	if len(f) != 2 || !strings.HasPrefix(f[0], "/") {
		return "", false
	}
	return f[0], f[1] == "yes"
}
