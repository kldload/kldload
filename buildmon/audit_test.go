package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The 2026-08-15 incident, verbatim from /var/log/installer/bootstrap.log on
// the machine that installed without a kernel. This is the regression test for
// the whole tool: if this excerpt ever stops producing a CRITICAL finding, the
// audit has lost the one failure it was built for.
const incidentLog = `[2026-08-15 18:16:43] Using local darksite APT mirror: http://127.0.0.1:3142/apt
[2026-08-15 18:17:04] Running apt-get update...
[2026-08-15 18:17:04] Installing packages: linux-image-amd64 linux-headers-amd64 efibootmgr mokutil shim-signed grub-efi-amd64-signed steam-installer zfs-dkms
Reading package lists...
Building dependency tree...
E: Unable to locate package steam-installer
[2026-08-15 18:17:04] Installing profile packages: openssh-server sudo curl
Running in chroot, ignoring command 'start'
Package chromium is not available, but is referred to by another package.
E: Package 'chromium' has no installation candidate
E: Unable to locate package lm_sensors
[2026-08-15 18:17:13] WARNING: package firmware-atheros not available — skipping
Processing triggers for libc-bin (2.41-12+deb13u3) ...
`

func writeLog(t *testing.T, dir, name, body string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestAuditCatchesTheSteamInstallerIncident(t *testing.T) {
	dir := t.TempDir()
	p := writeLog(t, dir, "bootstrap.log", incidentLog)

	found, err := ScanLog(p)
	if err != nil {
		t.Fatal(err)
	}

	var steam *Finding
	for i := range found {
		if strings.Contains(found[i].Message, "steam-installer") {
			steam = &found[i]
			break
		}
	}
	if steam == nil {
		t.Fatal("the steam-installer line was not flagged at all — this is the failure the audit exists for")
	}
	if steam.Severity != SevCritical {
		t.Errorf("steam-installer severity = %v, want CRITICAL", steam.Severity)
	}
	if !strings.Contains(steam.Why, "all-or-nothing") {
		t.Errorf("explanation does not tell the operator why it matters: %q", steam.Why)
	}
	if steam.Line != 6 {
		t.Errorf("Line = %d, want 6", steam.Line)
	}
}

func TestAuditSeveritiesAcrossTheIncident(t *testing.T) {
	dir := t.TempDir()
	found, err := ScanLog(writeLog(t, dir, "bootstrap.log", incidentLog))
	if err != nil {
		t.Fatal(err)
	}

	var crit, warn int
	for _, f := range found {
		switch f.Severity {
		case SevCritical:
			crit++
		case SevWarning:
			warn++
		}
	}
	// steam-installer, chromium-no-candidate, lm_sensors → 3 critical.
	if crit != 3 {
		t.Errorf("critical findings = %d, want 3", crit)
	}
	// firmware-atheros WARNING → 1.
	if warn != 1 {
		t.Errorf("warning findings = %d, want 1", warn)
	}
}

// Chroot chatter matches "ignoring"/"warning" shapes but is emitted by design.
// If it is not suppressed the audit is too long to read, which is the same as
// having no audit.
func TestNoiseIsSuppressed(t *testing.T) {
	dir := t.TempDir()
	body := `Running in chroot, ignoring command 'start'
invoke-rc.d: policy-rc.d denied execution of start.
W: Target Packages (non-free/binary-all/Packages) is configured multiple times in /etc/apt/sources.list:1
dpkg: warning: version '7.0.14-201.fc44.x86_64' has bad syntax: invalid character
`
	found, err := ScanLog(writeLog(t, dir, "noise.log", body))
	if err != nil {
		t.Fatal(err)
	}
	if len(found) != 0 {
		t.Errorf("expected no findings from pure noise, got %d: %+v", len(found), found)
	}
}

// First match wins: a FATAL line that also contains "E:" must be reported once.
func TestFirstMatchWinsNoDuplicates(t *testing.T) {
	dir := t.TempDir()
	found, err := ScanLog(writeLog(t, dir, "x.log", "E: Unable to locate package foo\n"))
	if err != nil {
		t.Fatal(err)
	}
	if len(found) != 1 {
		t.Fatalf("got %d findings for one line, want 1", len(found))
	}
	if found[0].Severity != SevCritical {
		t.Errorf("severity = %v, want CRITICAL (the specific rule, not the generic E:)", found[0].Severity)
	}
}

func TestMissingLogIsNotAnError(t *testing.T) {
	f, err := ScanLog(filepath.Join(t.TempDir(), "absent.log"))
	if err != nil {
		t.Errorf("missing log returned error %v; absence is not a defect", err)
	}
	if len(f) != 0 {
		t.Errorf("missing log produced findings: %+v", f)
	}
}

// The outcome checks are the ones that cannot be fooled by a log.
func TestOutcomeChecksFlagAKernellessRoot(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "boot"), 0o755); err != nil {
		t.Fatal(err)
	}

	found := RunOutcomeChecks(root)

	var gotKernel bool
	for _, f := range found {
		if strings.Contains(f.Message, "kernel present") {
			gotKernel = true
			if f.Severity != SevCritical {
				t.Errorf("missing kernel severity = %v, want CRITICAL", f.Severity)
			}
		}
	}
	if !gotKernel {
		t.Fatal("a root with no vmlinuz did not produce a 'kernel present' finding")
	}
}

func TestOutcomeChecksQuietOnAHealthyRoot(t *testing.T) {
	root := t.TempDir()
	boot := filepath.Join(root, "boot")
	if err := os.MkdirAll(filepath.Join(boot, "efi", "EFI", "BOOT"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "lib", "modules", "7.1.3+deb13-amd64"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{
		filepath.Join(boot, "vmlinuz-7.1.3+deb13-amd64"),
		filepath.Join(boot, "initrd.img-7.1.3+deb13-amd64"),
		filepath.Join(boot, "efi", "EFI", "BOOT", "BOOTX64.EFI"),
	} {
		if err := os.WriteFile(f, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	if found := RunOutcomeChecks(root); len(found) != 0 {
		t.Errorf("healthy root produced findings: %+v", found)
	}
}

// Worst-first, so the thing that ruined the install is the first thing shown.
func TestSortFindingsPutsCriticalFirst(t *testing.T) {
	f := []Finding{
		{Severity: SevInfo, Source: "a", Line: 1},
		{Severity: SevWarning, Source: "a", Line: 2},
		{Severity: SevCritical, Source: "z", Line: 99},
	}
	SortFindings(f)
	if f[0].Severity != SevCritical {
		t.Errorf("first finding severity = %v, want CRITICAL", f[0].Severity)
	}
	if f[2].Severity != SevInfo {
		t.Errorf("last finding severity = %v, want INFO", f[2].Severity)
	}
}

// Real lines from the first run against .145. Each one was a defect in this
// tool, found only by pointing it at a machine rather than a fixture.
func TestRealWorldFalsePositivesAndNoise(t *testing.T) {
	dir := t.TempDir()
	body := "" +
		// 1. "non-fatal" must NOT be critical. It was reported as the single
		//    CRITICAL finding, above fourteen real ones.
		"[2026-08-15 18:56:12] [autodeploy] [k8s] ArgoCD install skipped — non-fatal\n" +
		// 2. Colour codes must be stripped from the stored message.
		"\x1b[1;32m[klab]\x1b[0m DKMS status: WARNING! Diff between built and installed module!\n" +
		// 3. A line that is ONLY colour codes must not become an empty finding.
		"\x1b[0m\x1b[1;32m\n" +
		// 4. A genuine FATAL must still be caught.
		"[2026-08-15 18:17:04] FATAL: no kernel in /target/boot after the base package install.\n"
	found, err := ScanLog(writeLog(t, dir, "autodeploy.log", body))
	if err != nil {
		t.Fatal(err)
	}

	for _, f := range found {
		if strings.Contains(f.Message, "non-fatal") && f.Severity == SevCritical {
			t.Error("'non-fatal' was reported as CRITICAL — the false positive is back")
		}
		if strings.Contains(f.Message, "\x1b") {
			t.Errorf("ANSI escapes survived into a message: %q", f.Message)
		}
		if strings.TrimSpace(f.Message) == "" {
			t.Error("a colour-only line produced an empty finding")
		}
	}

	var gotRealFatal bool
	for _, f := range found {
		if strings.Contains(f.Message, "no kernel in") {
			gotRealFatal = true
			if f.Severity != SevCritical {
				t.Errorf("a genuine FATAL was downgraded to %v", f.Severity)
			}
		}
	}
	if !gotRealFatal {
		t.Fatal("tightening the FATAL rule lost a real FATAL — that is the one it exists for")
	}
}
