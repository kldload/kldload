// =============================================================================
// audit.go — read the install logs the way a person would, and say what went
// wrong.
//
// WHAT IT DOES, IN ORDER:
//   1. scans the installer and firstboot logs for the failure shapes that have
//      actually bitten this project;
//   2. runs OUTCOME assertions against the installed system — did the thing
//      the log claimed to do actually happen;
//   3. returns findings sorted worst-first.
//
// WHY IT EXISTS:
//   On 2026-08-15 an install put `steam-installer` in the same apt transaction
//   as the kernel. apt-get install is all-or-nothing, steam-installer is in
//   contrib, the darksite mirror carries main only — so one
//   "E: Unable to locate package" aborted the batch and took linux-image-amd64,
//   linux-headers, shim-signed, grub and mokutil with it. The installer carried
//   on to profile packages and reported success. Two machines installed
//   "cleanly", reached ZFSBootMenu, took the passphrase, and had no kernel to
//   load. The entire failure was ONE line in the middle of a 387 KB log.
//
//   A log nobody reads is not a diagnostic. This turns those logs into a short
//   list, and — more importantly — checks the OUTCOME rather than trusting the
//   log's own account of itself.
//
// INPUTS / OUTPUTS:
//   Reads /var/log/installer/*.log, /var/log/kldload/*.log and a handful of
//   paths on the installed root. Writes nothing.
//
// Notes:
//   - Rules are ordered most-severe-first and the FIRST match wins, so a line
//     that is both an apt error and a generic "error" is reported once, as the
//     specific thing.
//   - Outcome checks are the ones that matter. Every log rule can be defeated
//     by a failure mode nobody has seen yet; "is there a kernel on disk" cannot.
// =============================================================================

package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Severity ranks a finding. The zero value is deliberately not a valid
// severity so an uninitialised Finding cannot masquerade as informational.
type Severity int

const (
	SevInfo Severity = iota + 1
	SevWarning
	SevCritical
)

func (s Severity) String() string {
	switch s {
	case SevCritical:
		return "CRITICAL"
	case SevWarning:
		return "WARNING"
	default:
		return "INFO"
	}
}

// Finding is one thing worth an operator's attention.
type Finding struct {
	Severity Severity
	Source   string // file it came from, or "outcome" for a system assertion
	Line     int    // 1-indexed; 0 for outcome checks
	Message  string // the offending line, trimmed
	Why      string // what it means, in operator terms — never just the regex name
}

// auditRule maps a log line shape to a severity and an explanation.
type auditRule struct {
	re  *regexp.Regexp
	sev Severity
	why string
}

// auditRules is ordered: first match wins. Specific shapes precede generic
// ones so a line is explained by the most informative rule that fits.
var auditRules = []auditRule{
	{
		regexp.MustCompile(`^\s*E:\s*Unable to locate package\s+(\S+)`),
		SevCritical,
		"apt could not find this package. `apt-get install` is all-or-nothing, so " +
			"if this package shared a transaction with the kernel it took the kernel " +
			"down with it. Check what else was in the same 'Installing packages:' line.",
	},
	{
		regexp.MustCompile(`^\s*E:\s*Package '([^']+)' has no installation candidate`),
		SevCritical,
		"the package exists in the index but no version is installable here — " +
			"usually a component (contrib/non-free) the darksite mirror does not carry.",
	},
	{
		regexp.MustCompile(`^\s*E:\s*Couldn't find any package by (glob|regex)`),
		SevWarning,
		"a package pattern matched nothing. Harmless on its own; fatal if it was " +
			"batched with boot-critical packages.",
	},
	{
		regexp.MustCompile(`No match for argument:\s*(\S+)`),
		SevCritical,
		"dnf could not resolve this package — the RPM-side equivalent of " +
			"'Unable to locate package'.",
	},
	{
		// zfsutils-linux's postinst runs `modprobe zfs` from inside the chroot,
		// where uname -r is the LIVE ISO's kernel. It looks in
		// /lib/modules/<live-kernel>/ and finds nothing, because the module it
		// wants is built by DKMS against the TARGET kernel moments later. The
		// pool is created and imported successfully in the same run.
		//
		// The tell is the kernel it names: a Fedora one, from the live image,
		// which the installed system never boots. A real ZFS failure on a
		// Debian target names 7.1.3+deb13 and still matches the generic rule
		// below.
		//
		// HISTORY: 2026-08-18. This one line WAS the entire
		// "1 critical problem(s) with this install" banner, on a machine whose
		// ZFS was demonstrably fine: rpool ONLINE, zfs 2.4.3-2~bpo13+1,
		// zfs.ko present for 7.1.3+deb13-amd64. It was reported as a critical
		// ZFS failure twice in one evening, which is the cost this file's
		// own comments warn about — the operator learns to scroll past the red.
		regexp.MustCompile(`modprobe: FATAL: Module zfs not found in directory /lib/modules/\S*\.fc[0-9]+\.`),
		SevInfo,
		"zfsutils-linux probed for the module inside the chroot, against the " +
			"live ISO's kernel rather than the target's. DKMS builds it for the " +
			"installed kernel separately; the pool import below is the real evidence.",
	},
	{
		// NOT preceded by a hyphen or word character, so "non-fatal" does not
		// match. RE2 has no lookbehind, hence the explicit leading class.
		//
		// HISTORY: 2026-08-15, first run against a real machine. The line
		// "[k8s] ArgoCD install skipped — non-fatal" was reported as the single
		// CRITICAL finding, at the top of the list, above fourteen real ones.
		// An audit whose loudest item is wrong is worse than no audit: the
		// operator learns to scroll past the red.
		regexp.MustCompile(`(?i)(^|[^-[:alnum:]])fatal\b`),
		SevCritical,
		"the installer logged a fatal condition.",
	},
	// A blanket /WARNING|WARN/ used to live here. On a real build it produced
	// 36 of the tab's 48 findings, and all but a handful were upstream
	// compiler noise or lines whose only crime was a file path containing the
	// word "warning". An audit nobody reads catches nothing, so the blanket
	// rule is gone and the warnings that actually mean something are named.
	{
		// Packages installed without signature verification is a
		// supply-chain fact worth surfacing on a platform that ships a
		// darksite and claims reproducibility.
		regexp.MustCompile(`(?i)skipped OpenPGP checks|GPG check FAILED|NO_PUBKEY`),
		SevWarning,
		"packages were accepted without signature verification.",
	},
	{
		// The installer's own voice. Our scripts log with these prefixes, and
		// when they warn it is about this build, not about vendored C.
		// Any number of bracketed prefixes, then WARNING/WARN at the start of
		// the message. The installer logs `[2026-08-15 18:17:13] WARNING: ...`
		// and our scripts log `[kldload] WARN: ...`; an earlier version of this
		// pattern only allowed a lowercase tag and silently missed the
		// timestamped form — which is the common one. Caught by
		// TestAuditSeveritiesAcrossTheIncident, which is exactly what that
		// fixture is for.
		//
		// Anchoring at line start is what keeps upstream compiler noise out:
		// `common.h:5:9: warning: ...` and `[ 73%] Building ...` do not begin
		// with WARNING and so no longer match.
		regexp.MustCompile(`^\s*(\[[^\]]*\]\s*)*(WARNING|WARN)\b`),
		SevWarning,
		"the installer continued past something it did not like.",
	},
	{
		regexp.MustCompile(`^\s*E:\s`),
		SevWarning,
		"an apt error.",
	},
}

// ansiRe matches SGR/CSI escape sequences. Several kldload scripts colour
// their output and those logs are read back here, so without stripping, a
// finding's message arrives as "\x1b[1;32m[klab]\x1b[0m DKMS status:" — which
// is unreadable in a GUI label and prints as raw escapes in a pipe. Stripping
// also prevents a line that is ONLY colour codes from being reported as an
// empty finding, which happened on .145 (kube-join-*.log:40 rendered as a
// severity and a blank line).
var ansiRe = regexp.MustCompile(`\x1b\[[0-9;?]*[a-zA-Z]`)

// noiseRe drops lines that match a rule but carry no signal. Every entry here
// is a line the chroot emits by design, not a problem: suppressing them is
// what keeps the audit short enough to actually be read.
var noiseRe = regexp.MustCompile(
	`Running in chroot, ignoring|` +
		`invoke-rc\.d: policy-rc\.d denied|` +
		`^\s*W: Target \S+ is configured multiple times|` +
		`dpkg: warning: version .* has bad syntax|` +
		// Compiler and build-system chatter from vendored sources (whisper.cpp,
		// llama.cpp). These are upstream's warnings about upstream's code; we
		// are not going to fix them and they are not signal about THIS build.
		// Measured on an 18,334-line desktop build: they were 30 of 36
		// "warnings" reported, which is what made the Audit tab unreadable.
		`^\S+\.(c|h|cc|cpp|hpp|cxx):[0-9]+:[0-9]+: warning:|` +
		`^\s*CMake (Deprecation )?Warning|` +
		`ccache not found - consider installing it|` +
		// Build-progress lines matched only because a PATH contains the word
		// "warning" — e.g. examples/deprecation-warning/CMakeFiles/main.dir/...
		// Nine of the reported findings were this and nothing else.
		`^\s*\[\s*[0-9]+%\]`)

// ScanLog reads one log file and returns its findings.
//
// Args: path — a log file. A missing file yields no findings and no error;
// not every profile writes every log, and absence is not a defect.
//
// Returns: findings in file order. The error is only non-nil when the file
// exists but cannot be read, which IS worth surfacing.
func ScanLog(path string) ([]Finding, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()

	var out []Finding
	sc := bufio.NewScanner(f)
	// Installer logs carry very long apt lines; the default 64 KB token limit
	// truncates them into false negatives.
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)

	base := filepath.Base(path)
	for n := 1; sc.Scan(); n++ {
		// Strip colour BEFORE matching and before storing: a rule must not fire
		// on an escape sequence, and a stored message must be plain text.
		line := strings.TrimRight(ansiRe.ReplaceAllString(sc.Text(), ""), "\r\n")
		if strings.TrimSpace(line) == "" || noiseRe.MatchString(line) {
			continue
		}
		for _, r := range auditRules {
			if r.re.MatchString(line) {
				out = append(out, Finding{
					Severity: r.sev,
					Source:   base,
					Line:     n,
					Message:  strings.TrimSpace(line),
					Why:      r.why,
				})
				break // first match wins — report it once, as the specific thing
			}
		}
	}
	return out, sc.Err()
}

// ScanLogDirs walks the given directories and audits every *.log inside them.
func ScanLogDirs(dirs ...string) []Finding {
	var out []Finding
	for _, d := range dirs {
		entries, err := os.ReadDir(d)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".log") {
				continue
			}
			fs, err := ScanLog(filepath.Join(d, e.Name()))
			if err != nil {
				out = append(out, Finding{
					Severity: SevWarning,
					Source:   e.Name(),
					Why:      fmt.Sprintf("could not read this log: %v", err),
					Message:  "log unreadable",
				})
				continue
			}
			out = append(out, fs...)
		}
	}
	return out
}

// outcomeCheck is an assertion about the installed system rather than about
// what a log claims. These are the checks that cannot be fooled.
type outcomeCheck struct {
	name string
	// pass reports whether the system is in the expected state, plus a detail
	// string for the failure message.
	pass func(root string) (bool, string)
	sev  Severity
	why  string
}

var outcomeChecks = []outcomeCheck{
	{
		name: "kernel present",
		pass: func(root string) (bool, string) {
			m, _ := filepath.Glob(filepath.Join(root, "boot", "vmlinuz*"))
			return len(m) > 0, fmt.Sprintf("%d vmlinuz in /boot", len(m))
		},
		sev: SevCritical,
		why: "there is no kernel in /boot. The machine cannot boot: ZFSBootMenu " +
			"will take the passphrase and then have nothing to load. This is the " +
			"exact shape of the 2026-08-15 steam-installer failure.",
	},
	{
		name: "initramfs present",
		pass: func(root string) (bool, string) {
			m, _ := filepath.Glob(filepath.Join(root, "boot", "initrd.img*"))
			if len(m) == 0 {
				m, _ = filepath.Glob(filepath.Join(root, "boot", "initramfs*"))
			}
			return len(m) > 0, fmt.Sprintf("%d initramfs in /boot", len(m))
		},
		sev: SevCritical,
		why: "no initramfs to match the kernel — the root filesystem cannot be mounted.",
	},
	{
		name: "kernel modules present",
		pass: func(root string) (bool, string) {
			e, err := os.ReadDir(filepath.Join(root, "lib", "modules"))
			return err == nil && len(e) > 0, "/lib/modules"
		},
		sev: SevCritical,
		why: "/lib/modules is empty — the kernel package never unpacked.",
	},
	{
		name: "bootloader on the ESP",
		pass: func(root string) (bool, string) {
			m, _ := filepath.Glob(filepath.Join(root, "boot", "efi", "EFI", "*", "*.EFI"))
			m2, _ := filepath.Glob(filepath.Join(root, "boot", "efi", "EFI", "*", "*.efi"))
			n := len(m) + len(m2)
			return n > 0, fmt.Sprintf("%d EFI payloads", n)
		},
		sev: SevWarning,
		why: "no EFI payload found on the ESP. If the ESP is simply not mounted " +
			"right now this is a false alarm — check `mountpoint /boot/efi`.",
	},
}

// RunOutcomeChecks asserts the installed system is actually bootable.
//
// Args: root — the filesystem root to check; "" means "/". Tests point it at
// a fixture tree.
//
// Returns: one finding per FAILED check. A passing check is not news.
func RunOutcomeChecks(root string) []Finding {
	if root == "" {
		root = "/"
	}
	var out []Finding
	for _, c := range outcomeChecks {
		ok, detail := c.pass(root)
		if ok {
			continue
		}
		out = append(out, Finding{
			Severity: c.sev,
			Source:   "outcome",
			Message:  fmt.Sprintf("%s: FAILED (%s)", c.name, detail),
			Why:      c.why,
		})
	}
	return out
}

// SortFindings orders findings worst-first, then by source and line, so the
// thing most likely to have ruined the install is the first thing on screen.
func SortFindings(f []Finding) {
	sort.SliceStable(f, func(i, j int) bool {
		if f[i].Severity != f[j].Severity {
			return f[i].Severity > f[j].Severity
		}
		if f[i].Source != f[j].Source {
			return f[i].Source < f[j].Source
		}
		return f[i].Line < f[j].Line
	})
}

// Audit is the whole install audit: outcome assertions first, then the logs.
func Audit(root string, logDirs ...string) []Finding {
	if len(logDirs) == 0 {
		logDirs = []string{
			filepath.Join(root, "var/log/installer"),
			filepath.Join(root, "var/log/kldload"),
		}
	}
	out := append(RunOutcomeChecks(root), ScanLogDirs(logDirs...)...)
	SortFindings(out)
	return out
}
