// engine.go — one-shot text output and the kernel verbs.
//
// What lives here:
//
//	wgx show                     peer dossiers, handshake-age colouring
//	wgx dump                     the privileged read, pkexec's target
//	wgx attach <iface> <ctr>     move a live wg interface into a container
//	                             netns (the kernel trick)
//
// WHY this file is a third of its former size: everything that MINTED or
// DECLARED identity was deleted on 2026-08-10 when the console moved into
// kldload. `net create` generated every member's keypair and wrote the
// private keys into one JSON on one box; kldload already generates a
// keypair per host at install time (bootstrap.sh) so the private key never
// crosses a boundary and dies with the machine. Two identity systems, and
// the one deleted here was the weaker of the two — a central private-key
// store is exactly what the per-host design exists to avoid.
//
// What that leaves is a console: it reads, it joins, it explains. It cannot
// create a network, which is the point — it can now adopt ANY network,
// including the ones kldload built, hand-rolled wg0.conf files, and hosts
// it has never seen before. See estate.go for how membership is derived
// without a registry.
//
// Every privileged action still shells out to plain `wg`/`ip` with the
// exact command echoed first — primitives, not abstractions.
package main

import (
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const (
	cG = "\x1b[1;32m"
	cY = "\x1b[1;33m"
	cR = "\x1b[1;31m"
	cC = "\x1b[1;36m"
	cD = "\x1b[2m"
	cN = "\x1b[0m"
)

// run echoes then executes — every mutation shows its exact command,
// zxplore-style. Output is returned for parsing, stderr passes through.
func run(args ...string) (string, error) {
	fmt.Printf("%s$ %s%s\n", cD, strings.Join(args, " "), cN)
	out, err := exec.Command(args[0], args[1:]...).Output()
	return string(out), err
}

// ─── wgx show ── dossiers from `wg show all dump` ────────────────────────

func cmdShow() error {
	out, err := localDump() // elevates via sudo -n / pkexec when needed
	if err != nil {
		return err
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) == 0 || lines[0] == "" {
		fmt.Println("no WireGuard interfaces up")
		return nil
	}
	cur := ""
	for _, l := range lines {
		f := strings.Split(l, "\t")
		if len(f) == 5 { // interface line: iface priv pub port fwmark
			cur = f[0]
			fmt.Printf("\n%s━━ %s%s  %sport %s%s\n", cC, cur, cN, cD, f[3], cN)
			continue
		}
		if len(f) < 9 || f[0] != cur && cur == "" {
			continue
		}
		// peer line: iface pub psk endpoint allowed-ips handshake rx tx keepalive
		hs, _ := strconv.ParseInt(f[5], 10, 64)
		age, col, state := "never", cR, "no handshake"
		if hs > 0 {
			d := time.Since(time.Unix(hs, 0)).Round(time.Second)
			age = d.String()
			switch {
			case d < 3*time.Minute:
				col, state = cG, "alive"
			case d < 30*time.Minute:
				col, state = cY, "quiet"
			default:
				col, state = cR, "stale"
			}
		}
		rx, _ := strconv.ParseInt(f[6], 10, 64)
		tx, _ := strconv.ParseInt(f[7], 10, 64)
		fmt.Printf("  peer %s…%s\n", f[1][:16], f[1][len(f[1])-6:])
		fmt.Printf("    endpoint    %s\n", orDash(f[3]))
		fmt.Printf("    allowed-ips %s\n", f[4])
		fmt.Printf("    handshake   %s%s (%s)%s   rx %s  tx %s\n",
			col, age, state, cN, human(rx), human(tx))
	}
	return nil
}

func orDash(s string) string {
	if s == "" || s == "(none)" {
		return "—"
	}
	return s
}

func human(b int64) string {
	switch {
	case b > 1<<30:
		return fmt.Sprintf("%.1fGiB", float64(b)/(1<<30))
	case b > 1<<20:
		return fmt.Sprintf("%.1fMiB", float64(b)/(1<<20))
	case b > 1<<10:
		return fmt.Sprintf("%.1fKiB", float64(b)/(1<<10))
	}
	return fmt.Sprintf("%dB", b)
}

// short renders a public key as a stable 8-character handle. Keys are 44
// characters of base64 and unreadable at a glance; every view needs a token
// short enough to sit in a column and stable enough to compare between two
// hosts by eye.
func short(s string) string {
	h := base64.RawURLEncoding.EncodeToString([]byte(s))
	if len(h) > 8 {
		h = h[:8]
	}
	return strings.ToLower(h)
}

// cmdDump is the privileged read helper invoked via pkexec by an
// unprivileged console (see localDump). Raw `wg show all dump` on stdout so
// the parent parses exactly what it would have read itself.
func cmdDump() error {
	out, err := exec.Command("wg", "show", "all", "dump").Output()
	if err != nil {
		return err
	}
	_, err = os.Stdout.Write(out)
	return err
}

// ─── wgx attach ── the kernel trick ──────────────────────────────────────

// cmdAttach moves a live WireGuard interface into a container's network
// namespace.
//
// The trick worth knowing: a WireGuard interface keeps working after the
// move because its UDP socket stays anchored in the namespace where the
// interface was CREATED. So the container gets the tunnel — the encrypted
// endpoint — while the host keeps the underlay routing that carries it. No
// bridge, no port publishing, no second key.
//
// Args:   iface     an existing wg interface on this host (`wg show`)
//
//	ctr       a running podman/docker container name or id
//
// Returns: nil once the interface is inside the container's netns.
// Failure modes callers must handle: not root (CAP_NET_ADMIN), the
// container is not running (no pid), the interface does not exist, or the
// interface was already moved (ip reports "Cannot find device").
//
// HISTORY: this used to take a network+member from /etc/wgx and look the
// interface up in a declaration. It takes the interface directly now — the
// declaration model is gone, and pointing at what the kernel already has is
// both simpler and the only version that works on an adopted host.
func cmdAttach(iface, ctr string) error {
	if os.Geteuid() != 0 {
		return fmt.Errorf("moving %s into a netns needs root — try: sudo wgx attach %s %s", iface, iface, ctr)
	}
	// The container's pid IS its netns handle: /proc/<pid>/ns/net is what
	// `ip link set netns <pid>` resolves against, so no nsenter needed.
	pid, err := containerPID(ctr)
	if err != nil {
		return err
	}
	if _, err := run("ip", "link", "set", iface, "netns", pid); err != nil {
		return fmt.Errorf("moving %s into %s (pid %s) failed: %w — is %s a wg interface on this host?",
			iface, ctr, pid, err, iface)
	}
	fmt.Printf("%s✓ %s now lives in %s%s\n", cG, iface, ctr, cN)
	fmt.Printf("%s  address and routes are the container's to set:%s\n", cD, cN)
	fmt.Printf("%s  podman exec %s ip addr add <cidr> dev %s && ip link set %s up%s\n",
		cD, ctr, iface, iface, cN)
	return nil
}

// containerPID resolves a container name to its init pid, trying podman
// then docker. Returns an error naming both when neither knows the name —
// on a kldload host podman is the one that will answer, but this tool is
// meant to run on strangers' machines too.
func containerPID(ctr string) (string, error) {
	var tried []string
	for _, engine := range []string{"podman", "docker"} {
		if _, err := exec.LookPath(engine); err != nil {
			continue
		}
		tried = append(tried, engine)
		out, err := exec.Command(engine, "inspect", "-f", "{{.State.Pid}}", ctr).Output()
		pid := strings.TrimSpace(string(out))
		// A stopped container inspects fine and reports pid 0 — that is a
		// different failure from "no such container" and deserves saying so.
		if err == nil && pid != "" && pid != "0" {
			return pid, nil
		}
		if err == nil && pid == "0" {
			return "", fmt.Errorf("container %q is not running (%s reports pid 0)", ctr, engine)
		}
	}
	if len(tried) == 0 {
		return "", fmt.Errorf("no container engine found — install podman or docker")
	}
	return "", fmt.Errorf("container %q not found by %s", ctr, strings.Join(tried, " or "))
}
