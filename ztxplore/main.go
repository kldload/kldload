// =============================================================================
// ztxplore — the OpenZFS test lab, in one place.
//
// WHAT IT DOES:
//   Builds the test matrix, runs zfs-tests.sh across it against whichever
//   OpenZFS you name, and shows the answer next to the evidence: results,
//   live output, kernel ring buffer, ARC and pool metrics, and eBPF tracing.
//
// WHY IT EXISTS:
//   All of this already existed and none of it was in one place. The goldens
//   were in klab, the runner in kzfs-test, the matrix in a web console, the
//   metrics in Grafana, the kernel log in a terminal and the eBPF tools in a
//   different tab of the web console. A ZFS developer chasing one assertion
//   had to hold five surfaces open and correlate them by wall-clock time.
//   This is those five surfaces as one application, and it is meant to be
//   the ONLY one you need open while you work.
//
// WHY IT IS A SEPARATE APPLICATION:
//   The lab is for people who develop OpenZFS, not for people who run a
//   server. Keeping it here means the rest of the system can drop it, and it
//   means this can grow the depth that audience needs without making
//   everybody else's console heavier.
//
// USAGE:
//   ztx                      open the window (falls back to the text view)
//   ztx --tui                force the text view
//   ztx --results [run-id]   print a run's matrix and exit
//   ztx --runs               list recorded runs
//   ztx --metrics            print ARC, pool I/O and latency once
//   ztx --kernel [n]         print the last n kernel lines, ZFS-classified
//   ztx --version
//
// EXIT STATUS:
//   0  ran; for --results, every distro passed
//   1  --results found a failing or unfinished distro
//   2  could not start, or the lab is not installed
//
// FILES:
//   /root/kzfs-test/<run-id>/<distro>.summary   per-distro counts
//   /root/kzfs-test/latest                      symlink to the newest run
//   /proc/spl/kstat/zfs/arcstats                ARC counters
//
// Notes:
//   - Read-only by default. Everything that mutates the lab (build, run,
//     destroy) is an explicit action; opening the app changes nothing.
// =============================================================================

package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"
	"time"
)

// buildNum is stamped at build time with -X main.buildNum.
var buildNum = "0"

const version = "0.1.0"

// windowTitle is the GUI window's title AND, because Fyne derives the X11
// class from the title, its WM_CLASS. It must stay byte-identical to
// StartupWMClass in the .desktop file or the shell draws a fallback icon.
const windowTitle = "OpenZFS Test Lab"

func main() {
	var (
		tui        = flag.Bool("tui", false, "force the text view")
		showVer    = flag.Bool("version", false, "print version and exit")
		results    = flag.Bool("results", false, "print a run's matrix and exit")
		runs       = flag.Bool("runs", false, "list recorded runs and exit")
		metrics    = flag.Bool("metrics", false, "print ARC, pool I/O and latency once")
		kernel     = flag.Bool("kernel", false, "print recent kernel messages, ZFS-classified")
		resultsDir = flag.String("results-dir", DefaultResultsDir, "where kzfs-test writes results")
	)
	flag.Usage = usage
	flag.Parse()

	switch {
	case *showVer:
		fmt.Printf("ztxplore %s b%s\n", version, buildNum)
		return
	case *runs:
		os.Exit(cmdRuns(*resultsDir))
	case *results:
		os.Exit(cmdResults(*resultsDir, flag.Arg(0)))
	case *metrics:
		os.Exit(cmdMetrics())
	case *kernel:
		n := 80
		if a := flag.Arg(0); a != "" {
			if v, err := strconv.Atoi(a); err == nil && v > 0 {
				n = v
			}
		}
		os.Exit(cmdKernel(n))
	case *tui:
		os.Exit(RunTUI(*resultsDir))
	}

	// A GUI build on a headless box, or a terminal-only build, must not
	// simply fail: this is the same binary a developer runs over ssh.
	if err := RunGUI(*resultsDir); err != nil {
		fmt.Fprintln(os.Stderr, "ztx: no GUI available:", err)
		fmt.Fprintln(os.Stderr, "ztx: falling back to the text view")
		os.Exit(RunTUI(*resultsDir))
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `ztxplore %s b%s — the OpenZFS test lab, in one place

USAGE
  ztx [flags] [argument]

FLAGS
  --tui              force the text view (headless hosts, ssh sessions)
  --results [ID]     print a run's matrix and exit; newest run if no ID
  --runs             list recorded runs, newest first
  --metrics          print ARC, pool I/O and block latency once
  --kernel [N]       print the last N kernel messages (default 80),
                     classified as ZFS / warning / critical
  --results-dir DIR  where kzfs-test writes results (default %s)
  --version          print version and exit

EXAMPLES
  ztx                          open the lab console
  ztx --results                did the last run pass?
  ztx --kernel 200 | grep -i verify    hunt an assertion
  ztx --metrics                what is the ARC doing right now?

EXIT STATUS
  0  ran; --results found every distro passing
  1  --results found a failing or unfinished distro
  2  could not start, or the lab is not installed

THE LAB ITSELF
  Machinery lives in kzfs-test(8); this console drives it. Which OpenZFS is
  under test is chosen in the console, or set directly:
      ZFS_SOURCE=repo | version:2.4.3 | git:openzfs/zfs@master | tarball:/path
`, version, buildNum, DefaultResultsDir)
}

// cmdRuns lists recorded runs.
func cmdRuns(dir string) int {
	rs, err := ListRuns(dir)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ztx:", err)
		return 2
	}
	if len(rs) == 0 {
		fmt.Println("No runs recorded yet. Start one from the console, or: kzfs-test run")
		return 0
	}
	for _, r := range rs {
		fmt.Printf("%-24s  %s\n", r.ID, r.Verdict())
	}
	return 0
}

// cmdResults prints one run's matrix. Exit status IS the answer, so a CI job
// can call this directly.
func cmdResults(dir, id string) int {
	var (
		run Run
		err error
	)
	if id == "" {
		run, err = LatestRun(dir)
	} else {
		run = ReadRun(dir + "/" + id)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "ztx:", err)
		return 2
	}
	fmt.Printf("OpenZFS Test Lab — run %s\n\n", run.ID)
	fmt.Printf("  %-14s %8s %8s %8s %8s  %s\n", "DISTRO", "PASS", "FAIL", "SKIP", "TOTAL", "STATUS")
	for _, d := range run.Results {
		status := "pass"
		switch {
		case d.Incomplete:
			status = "DID NOT FINISH — " + d.Note
		case d.Fail > 0:
			status = "FAIL"
		}
		fmt.Printf("  %-14s %8d %8d %8d %8d  %s\n",
			d.Distro, d.Pass, d.Fail, d.Skip, d.Total, status)
	}
	fmt.Printf("\n%s\n", run.Verdict())
	if run.Failed() > 0 || run.Incomplete() > 0 {
		return 1
	}
	return 0
}

// cmdMetrics prints one sample of everything the Metrics pane shows.
func cmdMetrics() int {
	arc := ReadARC("")
	fmt.Println("ARC")
	if !arc.Available {
		fmt.Println("  " + arc.Why)
	} else {
		fmt.Printf("  size %s of %s target (max %s)\n",
			humanBytes(arc.Size), humanBytes(arc.Target), humanBytes(arc.Max))
		fmt.Printf("  hit rate %.1f%%  (%d hits, %d misses)\n",
			arc.HitRate(), arc.Hits, arc.Misses)
		fmt.Printf("  mfu %s   mru %s\n", humanBytes(arc.MFUSize), humanBytes(arc.MRUSize))
	}

	fmt.Println("\nPool I/O")
	pools, err := ReadPoolIO(5 * time.Second)
	if err != nil {
		fmt.Println("  " + err.Error())
	}
	for _, p := range pools {
		fmt.Printf("  %-12s alloc %-10s free %-10s  read %d ops %s/s  write %d ops %s/s\n",
			p.Pool, humanBytes(p.Alloc), humanBytes(p.Free),
			p.ReadOps, humanBytes(p.ReadBW), p.WriteOps, humanBytes(p.WriteBW))
	}

	fmt.Println("\nBlock latency (eBPF)")
	lat := ReadLatency(3 * time.Second)
	if !lat.Available {
		fmt.Println("  " + lat.Why)
		return 0
	}
	for _, b := range lat.Buckets {
		fmt.Printf("  ≤ %-8s %d\n", b.Bound(), b.Count)
	}
	return 0
}

// cmdKernel prints recent kernel messages with their classification.
func cmdKernel(n int) int {
	lines, err := ReadKernelLog(n, 5*time.Second)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ztx:", err)
		return 2
	}
	for _, l := range lines {
		tag := "    "
		switch l.Severity {
		case KernCritical:
			tag = "CRIT"
		case KernWarn:
			tag = "WARN"
		case KernZFS:
			tag = "zfs "
		}
		fmt.Printf("%s  %s\n", tag, l.Text)
	}
	return 0
}

// humanBytes renders a byte count the way a storage person reads one.
func humanBytes(b uint64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := uint64(unit), 0
	for n := b / unit; n >= unit && exp < 5; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(b)/float64(div), "KMGTPE"[exp])
}
