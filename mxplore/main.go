// =============================================================================
// mxplore — the metrics explorer. A machine as a tree you walk into.
//
// WHAT IT DOES, IN ORDER:
//   1. Resolves where Prometheus is and checks it is actually there, once, so
//      a dead backend is reported as one line rather than under every branch.
//   2. Builds the four views — network, storage, compute, host — by running
//      the queries in specs.go.
//   3. Renders the tree, or opens the window when this is the GUI build.
//
// WHY IT EXISTS: kldload ships 28 Grafana dashboards and they are good at time
// series and bad at hierarchy. "Which disk in which vdev in which pool" is a
// question you answer by walking in, and on a dashboard you answer it by
// already knowing the answer so you can pick the right variable. The console
// family has a shape for this — zxplore does it for datasets — and metrics did
// not have one.
//
// TWO BINARIES FROM ONE TREE, exactly as ztxplore and zxplore do it:
//   mx-tui  static, CGO_ENABLED=0, no graphics stack, runs on a hypervisor
//   mx      the same thing with a window, built with -tags gui
//
// INPUTS:   --prometheus / KLDLOAD_MX_PROMETHEUS (default http://localhost:9090)
// OUTPUTS:  the tree on stdout; diagnostics on stderr
// EXIT:     0 tree rendered · 1 Prometheus unreachable or every branch failed
//           · 2 usage
//
// Notes:
//   - A branch whose exporter is down renders as a line SAYING it is down.
//     Vanishing quietly is how a view starts lying by omission.
//   - SEE ALSO: kldload-command-center, which puts one Grafana dashboard per
//     workspace; this is the other half, the one you drill with.
// =============================================================================

package main

import (
	"flag"
	"fmt"
	"os"
	"time"
)

// buildNum is stamped in by the Makefile: -X main.buildNum=$(cat .buildnum).
var buildNum = "0"

const version = "0.1.0"

func main() {
	var (
		promURL  = flag.String("prometheus", envOr("KLDLOAD_MX_PROMETHEUS", "http://localhost:9090"), "Prometheus base URL")
		depth    = flag.Int("depth", 0, "stop drawing below this depth (0 = no limit)")
		watch    = flag.Duration("watch", 0, "redraw every interval, e.g. 10s (0 = draw once)")
		showVer  = flag.Bool("version", false, "print the version and exit")
		wantGUI  = flag.Bool("gui", false, "open the window (GUI build only)")
		hostName = flag.String("host", hostname(), "name for the root of the tree")
	)
	flag.Usage = usage
	flag.Parse()

	if *showVer {
		fmt.Printf("mxplore %s b%s\n", version, buildNum)
		return
	}

	p := NewProm(*promURL)
	// Ask once. Without this every branch reports the same connection error
	// and the real message — "Prometheus is not running" — is buried under
	// twenty copies of itself.
	if err := p.Reachable(); err != nil {
		fmt.Fprintf(os.Stderr, "mxplore: %v\n", err)
		fmt.Fprintf(os.Stderr, "  start it with: systemctl start prometheus\n")
		fmt.Fprintf(os.Stderr, "  or point elsewhere: mxplore --prometheus http://host:9090\n")
		os.Exit(1)
	}

	if *wantGUI {
		if err := RunGUI(p, *hostName); err != nil {
			fmt.Fprintf(os.Stderr, "mxplore: %v\n", err)
			os.Exit(1)
		}
		return
	}

	r := NewRenderer(os.Stdout)
	r.MaxDepth = *depth

	draw := func() int {
		tree, errs := Build(p, *hostName, Views())
		r.Render(tree)
		return len(errs)
	}

	if *watch <= 0 {
		draw()
		return
	}
	for {
		// Clear and home, so a watch loop looks like a watch loop rather than
		// an ever-growing scrollback.
		fmt.Print("\033[H\033[2J")
		draw()
		fmt.Printf("\n%s  refreshing every %s — ctrl-c to stop\n", time.Now().Format("15:04:05"), *watch)
		time.Sleep(*watch)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `mxplore — the metrics explorer: a machine as a tree you walk into

usage: mxplore [options]

  --prometheus URL   Prometheus base URL (default http://localhost:9090,
                     or $KLDLOAD_MX_PROMETHEUS)
  --host NAME        name for the root of the tree (default: this hostname)
  --depth N          stop drawing below depth N; 0 draws everything
  --watch DURATION   redraw on an interval, e.g. --watch 10s
  --gui              open the window (the `+"`mx`"+` build only; `+"`mx-tui`"+` says so)
  --version          print the version and exit

The four views match the desktop's compass layout, so view N is what the
command center puts on workspace N: 1 network, 2 storage, 3 compute, 4 host.

A branch whose exporter is not running renders as a line saying so, rather
than not appearing. That is deliberate — a view that hides what is missing is
worse than no view.

Exit: 0 rendered, 1 Prometheus unreachable, 2 usage.
`)
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "host"
	}
	return h
}
