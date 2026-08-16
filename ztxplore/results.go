// =============================================================================
// results.go — reading what the lab found.
//
// WHAT IT DOES, IN ORDER:
//   1. Lists the runs kzfs-test has recorded, newest first.
//   2. Reads each run's per-distro .summary files into a matrix.
//   3. Reduces a run to one verdict, so a window can say "3 of 6 distros
//      failed" without the operator counting rows.
//
// WHY IT EXISTS:
//   A test run's output is tens of thousands of lines across six guests. The
//   summary files are the part that answers the actual question, and they are
//   already written; nothing was reading them except a shell function that
//   prints a table and exits.
//
// FILE FORMAT (kzfs-test's, not ours):
//   /root/kzfs-test/<run-id>/<distro>.summary, shell assignments:
//       distro=debian
//       pass=1382
//       fail=0
//       skip=44
//       total=1426
//   with /root/kzfs-test/latest a symlink to the newest run directory.
//
// Notes:
//   - The parser is deliberately not a shell. It reads KEY=VALUE lines and
//     ignores everything else, because `source`-ing a file to read five
//     integers means any run directory on the box can execute code as root.
//   - A malformed or half-written summary yields a row marked incomplete
//     rather than an error: a run that died mid-matrix must still show the
//     distros that finished, which is exactly when someone is looking.
// =============================================================================

package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// DefaultResultsDir mirrors kzfs-test's RESULTS_DIR.
const DefaultResultsDir = "/root/kzfs-test"

// runIDRE is the shape kzfs-test stamps a run directory with: YYYYMMDD-HHMMSS.
// Sorting these lexically is also what makes newest-first work without
// stat-ing anything.
var runIDRE = regexp.MustCompile(`^[0-9]{8}-[0-9]{6}$`)

// DistroResult is one distro's outcome within a run.
type DistroResult struct {
	Distro     string
	Pass       int
	Fail       int
	Skip       int
	Total      int
	Incomplete bool   // summary missing or unreadable — the run did not finish here
	Note       string // why it is incomplete, when we know
}

// OK reports whether this distro passed: finished, and nothing failed.
func (r DistroResult) OK() bool { return !r.Incomplete && r.Fail == 0 }

// Run is one invocation of the matrix.
type Run struct {
	ID      string // the directory name, which kzfs-test stamps with the time
	Dir     string
	Results []DistroResult
}

// Failed counts distros with at least one failing test.
func (r Run) Failed() int {
	n := 0
	for _, d := range r.Results {
		if !d.Incomplete && d.Fail > 0 {
			n++
		}
	}
	return n
}

// Incomplete counts distros that never produced a summary.
func (r Run) Incomplete() int {
	n := 0
	for _, d := range r.Results {
		if d.Incomplete {
			n++
		}
	}
	return n
}

// Totals sums the run.
func (r Run) Totals() (pass, fail, skip int) {
	for _, d := range r.Results {
		pass += d.Pass
		fail += d.Fail
		skip += d.Skip
	}
	return
}

// Verdict reduces a run to one sentence.
//
// Incomplete outranks failed, because "2 distros never reported" and "2
// distros failed" call for different actions and the first is easy to miss
// in a table of green rows.
func (r Run) Verdict() string {
	switch {
	case len(r.Results) == 0:
		return "no results recorded"
	case r.Incomplete() > 0:
		return fmt.Sprintf("%d of %d distros did not finish — the run was cut short",
			r.Incomplete(), len(r.Results))
	case r.Failed() > 0:
		p, f, _ := r.Totals()
		return fmt.Sprintf("%d of %d distros failed — %d failing tests over %d passing",
			r.Failed(), len(r.Results), f, p)
	default:
		p, _, s := r.Totals()
		return fmt.Sprintf("all %d distros passed — %d tests, %d skipped",
			len(r.Results), p, s)
	}
}

// ListRuns returns the recorded runs, newest first.
//
// Args:    dir, the results root ("" → DefaultResultsDir).
// Returns: the runs, and an error only if the root itself cannot be read.
// A run directory that cannot be parsed is included with whatever it had,
// never dropped — a broken run is the one worth looking at.
func ListRuns(dir string) ([]Run, error) {
	if dir == "" {
		dir = DefaultResultsDir
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("cannot read results in %s: %w", dir, err)
	}
	var runs []Run
	for _, e := range ents {
		// "latest" is a symlink to one of the others; following it would
		// list the same run twice under two names.
		if !e.IsDir() || e.Name() == "latest" {
			continue
		}
		// Only run directories. kzfs-test also keeps "goldens/" in here for
		// per-distro golden build logs, which was listed as a run with "no
		// results recorded" — a permanent phantom failure in the history
		// (fiend, 2026-08-15). Matching the run-id SHAPE rather than
		// blocklisting names means the next sibling directory somebody adds
		// does not reappear as a phantom run.
		if !runIDRE.MatchString(e.Name()) {
			continue
		}
		if e.Type()&os.ModeSymlink != 0 {
			continue
		}
		runs = append(runs, ReadRun(filepath.Join(dir, e.Name())))
	}
	// kzfs-test stamps run ids with the time, so lexical descending is
	// newest-first without stat-ing anything.
	sort.Slice(runs, func(i, j int) bool { return runs[i].ID > runs[j].ID })
	return runs, nil
}

// LatestRun follows the `latest` symlink, falling back to the newest
// directory when it is missing (a run killed before it linked).
func LatestRun(dir string) (Run, error) {
	if dir == "" {
		dir = DefaultResultsDir
	}
	if target, err := filepath.EvalSymlinks(filepath.Join(dir, "latest")); err == nil {
		return ReadRun(target), nil
	}
	runs, err := ListRuns(dir)
	if err != nil {
		return Run{}, err
	}
	if len(runs) == 0 {
		return Run{}, fmt.Errorf("no runs recorded in %s yet", dir)
	}
	return runs[0], nil
}

// ReadRun reads one run directory.
//
// Never errors: a run with nothing readable in it is a Run with no results,
// which the caller renders as "no results recorded". Refusing to return
// anything would blank the window over one bad directory.
func ReadRun(dir string) Run {
	r := Run{ID: filepath.Base(dir), Dir: dir}
	matches, _ := filepath.Glob(filepath.Join(dir, "*.summary"))
	sort.Strings(matches)
	for _, m := range matches {
		r.Results = append(r.Results, readSummary(m))
	}
	return r
}

// readSummary parses one <distro>.summary.
//
// The distro name is taken from the filename when the file does not carry
// one, so a truncated summary still reports which distro it belongs to —
// which is the single most useful field on a run that died.
func readSummary(path string) DistroResult {
	res := DistroResult{
		Distro: strings.TrimSuffix(filepath.Base(path), ".summary"),
	}
	f, err := os.Open(path)
	if err != nil {
		res.Incomplete = true
		res.Note = "summary unreadable"
		return res
	}
	defer f.Close()

	seen := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		key, val, ok := strings.Cut(strings.TrimSpace(sc.Text()), "=")
		if !ok {
			continue
		}
		// Values may be quoted by the shell that wrote them.
		val = strings.Trim(val, `"'`)
		switch key {
		case "distro":
			if val != "" {
				res.Distro = val
			}
		case "pass":
			res.Pass, _ = strconv.Atoi(val)
			seen++
		case "fail":
			res.Fail, _ = strconv.Atoi(val)
			seen++
		case "skip":
			res.Skip, _ = strconv.Atoi(val)
			seen++
		case "total":
			res.Total, _ = strconv.Atoi(val)
			seen++
		}
	}
	// A summary missing its counts is a run that died while writing it.
	if seen < 3 {
		res.Incomplete = true
		res.Note = "summary truncated — the run did not finish this distro"
		return res
	}
	// A COMPLETE summary of all zeroes is the same lie wearing a better
	// suit: zfs-tests.sh started, produced no results, and wrote 0/0/0.
	// Nothing ran, so "0 failures" is true and "passed" is not — and this
	// is the shape a broken test environment in the golden actually takes
	// (fiend, 2026-08-15: a run finished in 15s and reported a pass).
	//
	// Checked on the counts rather than on `total` alone, because a summary
	// with total=0 but a non-zero pass count is a different kind of broken
	// and must not be silently treated as empty.
	if res.Pass == 0 && res.Fail == 0 && res.Skip == 0 {
		res.Incomplete = true
		res.Note = "no tests ran — zfs-tests.sh produced no results, " +
			"so this distro's ZFS test environment is not working"
	}
	return res
}
