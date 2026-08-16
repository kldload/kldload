// =============================================================================
// dashboards.go — handing off to Grafana, on purpose.
//
// WHAT IT DOES, IN ORDER:
//   1. Names the ZFS dashboards this substrate ships, by Grafana uid.
//   2. Checks whether Grafana is actually up.
//   3. Opens one in the operator's browser, as the operator — not as root.
//
// WHY HAND OFF RATHER THAN REDRAW:
//   Grafana already renders these well, and more importantly it is where a
//   developer EDITS them. The point of shipping dashboards is that somebody
//   takes one, adds a panel, and makes it theirs; a Go reimplementation of
//   the panels is a dead end for that — you cannot edit a compiled window.
//   So the tool shows the numbers inline (prom.go, which works headless and
//   when Grafana is down) and hands off to the real thing for the rest.
//
// WHY NOT AN EMBEDDED WEB VIEW:
//   This toolkit has no browser widget, and Grafana refuses to be framed
//   unless allow_embedding is turned on. The operator's own browser is
//   already configured, already authenticated, and already the place their
//   bookmarks and edits live.
//
// Notes:
//   - Opening as the invoking user matters: the console elevates itself so
//     it can read the kernel ring buffer, and a browser launched from a root
//     process either refuses to start or starts a second, root-owned profile
//     with none of the operator's sessions in it.
// =============================================================================

package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// GrafanaEndpoint is where kldload's Grafana listens.
const GrafanaEndpoint = "http://127.0.0.1:3000"

// Dashboard is one shipped board worth opening from here.
type Dashboard struct {
	UID   string // Grafana's uid, from the shipped JSON
	Title string
	Why   string // what question it answers, in the operator's terms
}

// ZFSDashboards are the ones relevant to somebody working on OpenZFS.
//
// Kept to the ZFS and lab boards deliberately: this console is laser-focused,
// and a list of every dashboard on the box would make it a launcher.
var ZFSDashboards = []Dashboard{
	// First and default: every ZFS and lab panel on one board, composed from
	// the ones below rather than rewritten, so a panel improved on a source
	// board is the same panel here. This is what the Metrics tab opens.
	{"ztxplore-metrics", "OpenZFS Test Lab — Metrics (everything)",
		"all the ZFS and test-lab panels on one board — start here"},
	{"kldload-zfs-live", "OpenZFS — Live Test Bench",
		"what the ARC and the pools are doing while the matrix runs"},
	{"klab-test-matrix", "ZFS Test Lab — Run Matrix",
		"pass/fail per distro across runs"},
	{"klab-test-debug", "ZFS Test Lab — VM Debug",
		"per-guest detail when one distro misbehaves"},
	{"zfs-pool-health", "Storage — ZFS Pool Health",
		"ARC hit rate, pool capacity, dataset usage"},
	{"compression-trend", "Storage — ZFS Compression Trends",
		"logical vs physical, and what compression is saving"},
	{"scrub-history", "Storage — ZFS Scrub History",
		"scrub duration and errors over time"},
	{"kldload-ebpf-deep", "Observability — eBPF Deep Dive",
		"the tracing probes, graphed — the model to copy for your own"},
	{"kernel-messages", "Host — Kernel & System Logs",
		"the ring buffer with history, beyond what the Kernel tab holds"},
}

// URL is the address of the dashboard.
//
// Args: kiosk, whether to hide Grafana's own chrome. Kiosk is right when the
// board is being read; it is WRONG when somebody means to edit it, which is
// the entire reason these are shipped.
func (d Dashboard) URL(kiosk bool) string {
	u := fmt.Sprintf("%s/d/%s", GrafanaEndpoint, d.UID)
	if kiosk {
		u += "?kiosk"
	}
	return u
}

// GrafanaUp reports whether Grafana is answering, and why not.
func GrafanaUp(timeout time.Duration) (bool, string) {
	if timeout <= 0 {
		timeout = 3 * time.Second
	}
	if _, err := runCapture(timeout, "curl", "-fsS", "--max-time", "2",
		GrafanaEndpoint+"/api/health"); err != nil {
		return false, "Grafana is not answering on :3000 — the readings above " +
			"come straight from Prometheus and still work. Start it with: " +
			"systemctl start grafana-server"
	}
	return true, ""
}

// desktopUser returns the account whose session should own the browser, and
// whether one was found.
//
// WHY: this console re-executes itself under sudo so it can read the kernel
// ring buffer. Everything after that runs as root, and a browser started by
// root either refuses outright or opens a root-owned profile with none of the
// operator's logins, bookmarks or Grafana session in it. SUDO_USER is what
// sudo leaves behind to undo exactly this.
func desktopUser() (string, bool) {
	for _, k := range []string{"SUDO_USER", "PKEXEC_UID"} {
		if v := os.Getenv(k); v != "" && v != "root" {
			return v, true
		}
	}
	return "", false
}

// OpenInBrowser opens a URL in the operator's browser.
//
// Returns: an error naming what to do by hand when no opener exists — a
// console on a headless box has no browser, and saying "here is the URL" is
// more useful than failing silently.
func OpenInBrowser(url string) error {
	if _, err := exec.LookPath("xdg-open"); err != nil {
		return fmt.Errorf("no xdg-open on this host — open it yourself: %s", url)
	}
	// Drop back to the desktop user when we are root, so the browser joins
	// the session that has the operator's Grafana login.
	if user, ok := desktopUser(); ok && os.Geteuid() == 0 {
		// --preserve-env carries the display; without it the browser has no
		// screen to open on and exits with a message nobody sees.
		cmd := exec.Command("sudo", "-u", user,
			"--preserve-env=DISPLAY,WAYLAND_DISPLAY,XAUTHORITY,XDG_RUNTIME_DIR,DBUS_SESSION_BUS_ADDRESS",
			"xdg-open", url)
		if err := cmd.Start(); err != nil {
			return fmt.Errorf("could not open a browser as %s: %w", user, err)
		}
		go func() { _ = cmd.Wait() }() // reap; the opener returns immediately
		return nil
	}
	cmd := exec.Command("xdg-open", url)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("could not open a browser: %w", err)
	}
	go func() { _ = cmd.Wait() }()
	return nil
}

// DashboardByUID looks one up.
func DashboardByUID(uid string) (Dashboard, bool) {
	for _, d := range ZFSDashboards {
		if d.UID == uid {
			return d, true
		}
	}
	return Dashboard{}, false
}

// DashboardTitles is the display list, derived so the two cannot disagree.
func DashboardTitles() []string {
	out := make([]string, 0, len(ZFSDashboards))
	for _, d := range ZFSDashboards {
		out = append(out, strings.TrimSpace(d.Title))
	}
	return out
}
