// =============================================================================
// bundle.go — the support bundle: everything a diagnosis needs, nothing that
// would leak.
//
// WHAT IT DOES, IN ORDER:
//   1. Runs a fixed list of read-only commands and captures each one.
//   2. Copies a fixed ALLOWLIST of on-disk artifacts.
//   3. Scrubs the collected text for secrets that leaked in anyway.
//   4. Writes one .tar.gz and prints its path.
//
// WHY THIS EXISTS:
//   Diagnosing the 2026-08-19 install took an hour, and almost none of it was
//   thinking. It was finding things: the smoke report is /root/kldload-smoke-
//   report.txt, the installer logs are /root/kldload-install-logs/, the
//   firstboot log is /var/log/kldload/firstboot.log, the boot chain is
//   efibootmgr plus a grub.cfg on the ESP, and whether the machine double-
//   prompts for a passphrase is a property on rpool/ROOT. An operator filing a
//   bug knows none of those paths, so a report arrives as "the desktop failed"
//   and the first three replies are requests for files.
//
//   This makes that one command.
//
// WHY AN ALLOWLIST AND NOT `cp -r /root`:
//   /root holds ca.key, .klab-rhel-creds and the installer's SSH private key.
//   A support bundle is the single most likely file on the system to be mailed
//   to a stranger, so it may never contain a secret — not "unlikely to", may
//   not. Every artifact is named individually below, secrets are NOTED as
//   present-but-withheld (their existence and mode are diagnostic; their
//   contents never are), and everything collected is scrubbed on the way in.
//
// Inputs:  the live system, read-only. Nothing here mutates anything.
// Outputs: /var/log/kldload/support-bundle-<host>-<stamp>.tar.gz, or $TMPDIR
//          when that is not writable.
//
// Notes:
//   - A collector that fails records the failure INTO the bundle and carries
//     on. A bundle that aborts because one command is missing is worth less
//     than a bundle with one file that says "efibootmgr: not installed" —
//     that absence is itself a finding.
//   - Output is deterministic apart from the timestamp in the name.
// =============================================================================

package main

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// bundleCmd is one captured command. `Name` becomes the filename in the
// bundle, so it doubles as the index an operator reads first.
type bundleCmd struct {
	Name string
	Argv []string
}

// bundleCmds is the evidence that is not already a file on disk.
//
// Ordered by how often it settled a question during the 2026-08-19 debug:
// failed units first (the headline nobody looks at), then the boot chain
// (which explained both the GRUB stage and the double passphrase prompt),
// then storage, network and the desktop session.
var bundleCmds = []bundleCmd{
	{"systemd-failed.txt", []string{"systemctl", "list-units", "--state=failed", "--no-pager"}},
	{"systemd-units-kldload.txt", []string{"systemctl", "list-units", "kldload*", "klab*", "--all", "--no-pager"}},
	{"journal-boot-errors.txt", []string{"journalctl", "-b", "-p", "err", "--no-pager", "-n", "400"}},
	{"journal-kldload.txt", []string{"journalctl", "-b", "-u", "kldload-firstboot", "-u", "kldload-autodeploy",
		"-u", "kldload-smoke-firstboot", "-u", "klab-firstboot", "--no-pager", "-n", "600"}},

	{"boot-cmdline.txt", []string{"cat", "/proc/cmdline"}},
	{"boot-efibootmgr.txt", []string{"efibootmgr", "-v"}},
	{"boot-esp.txt", []string{"find", "/boot/efi", "-maxdepth", "3"}},
	{"boot-secureboot.txt", []string{"mokutil", "--sb-state"}},

	{"zfs-list.txt", []string{"zfs", "list", "-o", "name,used,avail,refer,mountpoint,canmount,encryption,keystatus"}},
	{"zpool-status.txt", []string{"zpool", "status", "-v"}},
	{"zpool-get.txt", []string{"zpool", "get", "all"}},
	// The properties that decide whether the machine boots and how often it
	// asks for a passphrase. keylocation/keyformat are names, never key material.
	{"zfs-boot-props.txt", []string{"zfs", "get", "-r",
		"org.zfsbootmenu:commandline,org.zfsbootmenu:keysource,canmount,keylocation,keyformat,encryptionroot",
		"rpool"}},

	{"net-addr.txt", []string{"ip", "-br", "addr"}},
	{"net-route.txt", []string{"ip", "route"}},
	{"net-link.txt", []string{"ip", "-br", "link"}},

	{"hw-lspci.txt", []string{"lspci", "-nn"}},
	{"hw-lscpu.txt", []string{"lscpu"}},
	{"hw-memory.txt", []string{"free", "-h"}},
	{"hw-blockdev.txt", []string{"lsblk", "-o", "NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT"}},
	{"hw-dmesg-tail.txt", []string{"dmesg", "--level=err,warn", "--nopager"}},

	{"pkg-holds.txt", []string{"apt-mark", "showhold"}},
	{"virt-domains.txt", []string{"virsh", "list", "--all"}},
	{"virt-networks.txt", []string{"virsh", "net-list", "--all"}},
}

// bundleFiles is the on-disk allowlist. Every entry was a file somebody had to
// be TOLD the path of during a real debug.
//
// Directories are copied one level deep, files verbatim. Nothing here is
// selected by glob over a directory that also holds secrets.
var bundleFiles = []string{
	"/root/kldload-smoke-report.txt",
	"/root/kldload-install-logs",
	"/var/log/kldload",
	"/boot/efi/EFI/BOOT/grub.cfg",
	"/etc/kldload",
}

// secretPaths are recorded as present-or-absent, with mode, and never read.
//
// Their EXISTENCE is diagnostic — an install that never wrote /root/ca.crt did
// not finish its CA step — and a wrong mode on one of these is itself a
// finding worth reporting. Their contents are never a support artifact.
var secretPaths = []string{
	"/root/ca.key",
	"/root/ca.crt",
	"/root/ca.der",
	"/root/.klab-rhel-creds",
	"/root/.ssh/id_kldload",
	"/root/.ssh/id_kldload.pub",
	"/root/.kube/config",
}

// scrubbers run over every byte of collected TEXT before it enters the archive.
//
// The allowlist above is the primary defence; this is the second one, for
// secrets that travel inside a file that is otherwise safe — a passphrase
// echoed into a log, a token in a kernel command line, a key in an env dump.
// Belt and braces, because the cost of being wrong here is unrecoverable:
// once a bundle is mailed, it cannot be unmailed.
var scrubbers = []struct {
	re   *regexp.Regexp
	with string
}{
	{regexp.MustCompile(`(?i)(pass(word|phrase)?|passwd)\s*[=:]\s*\S+`), "${1}=[REDACTED]"},
	{regexp.MustCompile(`(?i)(secret|token|api[_-]?key)\s*[=:]\s*\S+`), "${1}=[REDACTED]"},
	{regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----`),
		"[REDACTED PRIVATE KEY]"},
	{regexp.MustCompile(`(?i)\bcfat_[A-Za-z0-9]{20,}`), "[REDACTED CLOUDFLARE TOKEN]"},
	{regexp.MustCompile(`(?i)(aws_secret_access_key|r2_secret_access_key)\s*[=:]\s*\S+`), "${1}=[REDACTED]"},
}

func scrub(b []byte) []byte {
	for _, s := range scrubbers {
		b = s.re.ReplaceAll(b, []byte(s.with))
	}
	return b
}

// runCollector executes one command with a hard timeout and returns its output.
//
// A missing binary or a non-zero exit is NOT an error: the text explaining
// that is exactly what the reader needs. Only the caller's archive write can
// actually fail.
func runCollector(c bundleCmd) []byte {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, c.Argv[0], c.Argv[1:]...)
	out, err := cmd.CombinedOutput()
	head := fmt.Sprintf("$ %s\n\n", strings.Join(c.Argv, " "))
	if err != nil {
		out = append(out, []byte(fmt.Sprintf("\n[collector: %v]\n", err))...)
	}
	if ctx.Err() != nil {
		out = append(out, []byte("\n[collector: timed out after 20s]\n")...)
	}
	return append([]byte(head), out...)
}

// tarWriter bundles the two writers so the callers below stay short.
type tarWriter struct {
	tw *tar.Writer
	n  int
}

func (t *tarWriter) add(name string, body []byte, mode int64) error {
	body = scrub(body)
	if err := t.tw.WriteHeader(&tar.Header{
		Name: name, Mode: mode, Size: int64(len(body)), ModTime: time.Now(),
	}); err != nil {
		return err
	}
	if _, err := t.tw.Write(body); err != nil {
		return err
	}
	t.n++
	return nil
}

// addPath copies one file, or one level of a directory, into the archive.
//
// Failure modes callers must handle: none — an unreadable path becomes a note
// inside the bundle, because "permission denied on /var/log/kldload" is a
// finding and a silently missing file is not.
func (t *tarWriter) addPath(prefix, src string) {
	info, err := os.Stat(src)
	if err != nil {
		_ = t.add(filepath.Join(prefix, filepath.Base(src)+".MISSING"),
			[]byte(fmt.Sprintf("%s: %v\n", src, err)), 0o644)
		return
	}
	if !info.IsDir() {
		body, err := os.ReadFile(src)
		if err != nil {
			body = []byte(fmt.Sprintf("%s: %v\n", src, err))
		}
		_ = t.add(filepath.Join(prefix, filepath.Base(src)), body, 0o644)
		return
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		_ = t.add(filepath.Join(prefix, filepath.Base(src)+".UNREADABLE"),
			[]byte(fmt.Sprintf("%s: %v\n", src, err)), 0o644)
		return
	}
	for _, e := range entries {
		if e.IsDir() {
			continue // one level: the log dirs are flat, and recursion invites surprises
		}
		full := filepath.Join(src, e.Name())
		body, err := os.ReadFile(full)
		if err != nil {
			body = []byte(fmt.Sprintf("%s: %v\n", full, err))
		}
		_ = t.add(filepath.Join(prefix, filepath.Base(src), e.Name()), body, 0o644)
	}
}

// secretInventory records what exists without reading any of it.
func secretInventory() []byte {
	var b strings.Builder
	b.WriteString("Sensitive paths — recorded as present/absent with mode.\n")
	b.WriteString("Contents are deliberately NOT included in this bundle.\n\n")
	for _, p := range secretPaths {
		info, err := os.Stat(p)
		switch {
		case err != nil:
			fmt.Fprintf(&b, "  absent   %s\n", p)
		default:
			fmt.Fprintf(&b, "  present  %s  mode %04o  %d bytes\n",
				p, info.Mode().Perm(), info.Size())
		}
	}
	return []byte(b.String())
}

// WriteBundle collects everything and returns the path it wrote.
func WriteBundle(opt GatherOpts, dest string) (string, error) {
	host, _ := os.Hostname()
	stamp := time.Now().UTC().Format("20060102-150405")

	if dest == "" {
		dir := "/var/log/kldload"
		if err := os.MkdirAll(dir, 0o755); err != nil {
			dir = os.TempDir()
		} else if f, err := os.CreateTemp(dir, ".wtest"); err == nil {
			_ = f.Close()
			_ = os.Remove(f.Name())
		} else {
			dir = os.TempDir()
		}
		dest = filepath.Join(dir, fmt.Sprintf("support-bundle-%s-%s.tar.gz", host, stamp))
	}

	f, err := os.OpenFile(dest, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return "", err
	}
	defer f.Close()

	gz := gzip.NewWriter(f)
	defer gz.Close()
	tw := tar.NewWriter(gz)
	defer tw.Close()

	root := fmt.Sprintf("support-bundle-%s-%s", host, stamp)
	t := &tarWriter{tw: tw}

	// The audit's own verdict leads, so a reader sees the conclusion before
	// the evidence.
	snap := Gather(opt)
	if err := t.add(filepath.Join(root, "00-VERDICT.txt"),
		[]byte(bundleVerdict(snap)), 0o644); err != nil {
		return "", err
	}
	if err := t.add(filepath.Join(root, "00-README.txt"), bundleReadme(host, stamp), 0o644); err != nil {
		return "", err
	}
	if err := t.add(filepath.Join(root, "01-sensitive-paths.txt"), secretInventory(), 0o644); err != nil {
		return "", err
	}

	for _, c := range bundleCmds {
		if err := t.add(filepath.Join(root, "cmd", c.Name), runCollector(c), 0o644); err != nil {
			return "", err
		}
	}
	for _, p := range bundleFiles {
		t.addPath(filepath.Join(root, "files"), p)
	}

	if err := tw.Close(); err != nil {
		return "", err
	}
	if err := gz.Close(); err != nil {
		return "", err
	}
	return dest, nil
}

func bundleReadme(host, stamp string) []byte {
	return []byte(fmt.Sprintf(`kldload support bundle
======================

Host:    %s
Taken:   %s UTC
Tool:    kldload-buildmon %s b%s

WHAT IS IN HERE

  00-VERDICT.txt          the audit's own conclusion — read this first
  01-sensitive-paths.txt  which secrets exist, with mode. Never their contents.
  cmd/                    one file per diagnostic command, named for what it answers
  files/                  installer and first-boot logs, and the smoke report

WHAT IS NOT IN HERE, ON PURPOSE

  Private keys, the local CA key, stored credentials and kubeconfig contents.
  Collected text is also scrubbed for password=, secret=, token= and PEM
  private key blocks. If you find a secret in this bundle, that is a bug worth
  reporting on its own.

SAFE TO SHARE

  This bundle is built to be attachable to a bug report. It still describes
  your machine — hostnames, IP addresses, dataset names and hardware — so
  treat it as you would a verbose log, not as public data.
`, host, stamp, version, buildNum))
}

// bundleVerdict is the audit's conclusion as plain text, for the top of the
// bundle.
//
// It deliberately leads with the same three things the GUI ranks first —
// verdict, failed units, then findings — so an operator who reads only this
// file and a maintainer who reads the whole bundle start from one story.
func bundleVerdict(s Snapshot) string {
	var b strings.Builder
	lvl, msg := s.Verdict()
	state := map[Level]string{
		LevelBuilding: "BUILDING", LevelReady: "READY", LevelProblem: "PROBLEM",
	}[lvl]

	fmt.Fprintf(&b, "VERDICT: %s — %s\n", state, msg)
	fmt.Fprintf(&b, "Taken:   %s\n\n", s.Taken.UTC().Format(time.RFC3339))

	if len(s.FailedUnits) > 0 {
		fmt.Fprintf(&b, "FAILED UNITS (%d)\n", len(s.FailedUnits))
		for _, u := range s.FailedUnits {
			fmt.Fprintf(&b, "  %s\n", u)
		}
		b.WriteString("\n")
	}

	if bad := s.Doctor.Bad(); len(bad) > 0 {
		fmt.Fprintf(&b, "DOCTOR — checks needing action (%d)\n", len(bad))
		for _, c := range bad {
			fmt.Fprintf(&b, "  [%s] %s/%s: %s\n", c.Severity, c.Subsystem, c.Name, c.Actual)
			if c.Remediation != "" {
				fmt.Fprintf(&b, "      fix: %s\n", c.Remediation)
			}
		}
		b.WriteString("\n")
	}
	if s.DoctorErr != nil {
		fmt.Fprintf(&b, "DOCTOR: unavailable — %v\n\n", s.DoctorErr)
	}

	if len(s.Findings) > 0 {
		fmt.Fprintf(&b, "LOG FINDINGS (%d)\n", len(s.Findings))
		for _, f := range s.Findings {
			fmt.Fprintf(&b, "  %s:%d  %s\n", f.Source, f.Line, f.Message)
			if f.Why != "" {
				fmt.Fprintf(&b, "      %s\n", f.Why)
			}
		}
		b.WriteString("\n")
	}

	if len(s.Components) > 0 {
		fmt.Fprintf(&b, "COMPONENTS (%d)\n", len(s.Components))
		for _, c := range s.Components {
			fmt.Fprintf(&b, "  %+v\n", c)
		}
	}
	return b.String()
}
