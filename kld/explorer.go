// explorer.go — zxplore's Explorer: a dataset's files, and every snapshot's
// version of one file, through the .zfs/snapshot directory.
//
// The context carries what is shown — "dataset:/relative/path" for the
// Explorer tab, "dataset:/relative/path/file" for Versions — so a restore
// acts on the file the row names. zxplore kept the versions of a file after
// the cursor had moved and could restore the wrong one (2026-09-26 port).
package main

import (
	"fmt"
	"path"
	"strconv"
	"strings"
	"time"
)

func splitExplorerCtx(ctx string) (ds, rel string) {
	ds, rel, _ = strings.Cut(ctx, ":")
	if rel == "" {
		rel = "/"
	}
	return ds, path.Clean("/" + rel)
}

func loadExplorer(d *sectionData) {
	if d.ctx == "" {
		d.headline = "press x on a dataset in Datasets to explore its files here"
		return
	}
	ds, rel := splitExplorerCtx(d.ctx)
	mp, mounted := datasetMountpoint(ds)
	if !mounted {
		d.err = ds + " is not mounted (or has no mountpoint)"
		return
	}
	dir := path.Join(mp, rel)
	out, err := run(20*time.Second, "sh", "-c", `cd -- "$1" && LC_ALL=C ls -lAn --time-style=+%Y-%m-%d_%H:%M -- .`, "_", dir)
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"name", "kind", "size", "modified", "mode", "owner"}
	if rel != "/" {
		d.rows = append(d.rows, []string{"..", "up", "", "", "", ""})
	}
	dirs, files := 0, 0
	for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		f := strings.Fields(line)
		if len(f) < 7 || strings.HasPrefix(line, "total") {
			continue
		}
		kind := "file"
		switch line[0] {
		case 'd':
			kind = "dir"
			dirs++
		case 'l':
			kind = "link"
		default:
			files++
		}
		name := strings.Join(f[6:], " ")
		if kind == "link" {
			name, _, _ = strings.Cut(name, " -> ")
		}
		size := f[4]
		if n, err := strconv.ParseInt(size, 10, 64); err == nil {
			size = human(n)
		}
		d.rows = append(d.rows, []string{name, kind, size, strings.ReplaceAll(f[5], "_", " "), f[0], f[2] + ":" + f[3]})
	}
	d.headline = fmt.Sprintf("%s %s — %d dirs, %d files (enter: open · backspace: up · v: versions)", ds, rel, dirs, files)
}

// loadVersions lists the file as every snapshot has it, plus live, marking
// which snapshots hold a different size or mtime from the live file.
func loadVersions(d *sectionData) {
	if d.ctx == "" {
		d.headline = "press enter or v on a file in Explorer to see its versions here"
		return
	}
	ds, rel := splitExplorerCtx(d.ctx)
	mp, mounted := datasetMountpoint(ds)
	if !mounted {
		d.err = ds + " is not mounted"
		return
	}
	// nanosecond mtimes: three writes in one second all read "same" on
	// seconds alone (probe run, 2026-09-26)
	live, _ := run(10*time.Second, "stat", "-c", "%s %.9Y", path.Join(mp, rel))
	lf := strings.Fields(live)
	// one shell loop over .zfs/snapshot: the directory is virtual and
	// listing it is the only way to see which snapshots hold the file
	out, err := run(60*time.Second, "sh", "-c", `cd -- "$1/.zfs/snapshot" 2>/dev/null || exit 0; for s in */; do s="${s%/}"; if [ -e "$s$2" ]; then stat -c "$s %s %.9Y" -- "$s$2"; fi; done`, "_", mp, rel)
	if err != nil {
		d.err = err.Error()
		return
	}
	d.columns = []string{"snapshot", "size", "modified", "vs live"}
	if len(lf) == 2 {
		n, _ := strconv.ParseInt(lf[0], 10, 64)
		d.rows = append(d.rows, []string{"(live)", human(n), mtimeText(lf[1]), "-"})
	}
	differ := 0
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		f := strings.Fields(line)
		if len(f) != 3 {
			continue
		}
		n, _ := strconv.ParseInt(f[1], 10, 64)
		vs := "same"
		if len(lf) != 2 || f[1] != lf[0] || f[2] != lf[1] {
			vs = "differs"
			differ++
		}
		d.rows = append(d.rows, []string{f[0], human(n), mtimeText(f[2]), vs})
	}
	d.headline = fmt.Sprintf("%s%s — %d snapshot version(s), %d differ from live (c: restore as a copy · R: restore over live)", ds, rel, len(d.rows)-1, differ)
}

// mtimeText renders a stat "%.9Y" (seconds.nanoseconds) for the table.
func mtimeText(s string) string {
	sec, _, _ := strings.Cut(s, ".")
	ts, err := strconv.ParseInt(sec, 10, 64)
	if err != nil {
		return s
	}
	return time.Unix(ts, 0).Format("2006-01-02 15:04:05")
}
