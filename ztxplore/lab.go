// =============================================================================
// lab.go — what the OpenZFS test lab is made of.
//
// WHAT IT DOES, IN ORDER:
//   1. Names the distro matrix the lab tests across, and how each one is
//      addressed (its VM name, its package family).
//   2. Models the ZFS SOURCE — the thing that makes this a test lab rather
//      than a fleet of VMs: which OpenZFS you are about to put under test.
//   3. Validates a source spec before anything is built, and renders it back
//      into the ZFS_SOURCE string kzfs-test already understands.
//
// WHY IT EXISTS:
//   The lab's whole question is "does THIS OpenZFS pass THESE tests on THAT
//   distro". Two of those three are already data in kzfs-test; this makes the
//   third one data too, so a version can be picked from a list instead of
//   remembered as an environment variable.
//
// WHY IT WRAPS kzfs-test RATHER THAN REPLACING IT:
//   kzfs-test is ~2000 lines that already builds goldens, clones them, runs
//   zfs-tests.sh across the matrix and writes results. Reimplementing that in
//   Go would be a second implementation to keep correct, and the two would
//   drift the first time someone fixed one of them. This layer owns the model
//   and the presentation; the shell owns the machinery.
//
// Notes:
//   - ZFS_SOURCE's grammar is kzfs-test's, not ours: "repo",
//     "version:X.Y.Z", "git:owner/repo@ref", "tarball:/path". Parsing it here
//     means a typo is refused by a dialog instead of by a VM twenty minutes
//     into a build.
// =============================================================================

package main

import (
	"fmt"
	"regexp"
	"strings"
)

// Distro is one substrate in the test matrix.
//
// The matrix exists to catch what only shows up on one package family: a
// dkms hook that only Debian runs, a kmod signing path only EL has, an
// initramfs generator that differs everywhere. Testing one distro tests one
// distro.
type Distro struct {
	Key    string // kzfs-test's name for it, and ours
	Label  string // what a human calls it
	Family string // dnf | apt | pacman | apk — the package manager
}

// Distros is the matrix, in the order the UI lists them.
//
// This mirrors kzfs-test's DISTROS array plus the two it carries images for
// but leaves out of the default run. Keep them in step: a distro listed here
// that kzfs-test cannot build is a button that fails, which is worse than a
// button that is missing.
// WHY NO VERSION NUMBERS: the web console's copy of this list says
// "Fedora 43" and "CentOS Stream 10" while kzfs-test builds F44 and
// CentOS 9 — two hardcoded lists that drifted apart and now disagree
// about what the lab tests. A release number belongs to the golden that
// was actually built, so it is read off the guest and shown beside it,
// never typed here.
// WHY ONLY SIX — and why arch and alpine are not coming back:
//
// A rolling release has no stable kernel to build a module against. The
// kernel moves under you between the image being fetched and the module
// being compiled, so there is no install path that reliably produces a
// working ZFS on either, and a test result from a box where the module
// failed to build tells you nothing about ZFS (operator, 2026-08-15).
//
// kzfs-test agrees: it carries cloud images for both in CLOUD_IMAGES but
// its DISTROS array is these six, and anything else is answered with
// "[FATAL] Unknown distro: arch". Taking the list from the image map rather
// than from DISTROS produced checkboxes whose only possible outcome was a
// fatal error — the exact failure the note above warns about.
var Distros = []Distro{
	{"centos", "CentOS Stream", "dnf"},
	{"rocky", "Rocky Linux", "dnf"},
	{"fedora", "Fedora", "dnf"},
	{"rhel", "RHEL", "dnf"},
	{"debian", "Debian", "apt"},
	{"ubuntu", "Ubuntu", "apt"},
}

// DistroByKey looks one up. Returns ok=false rather than a zero Distro so a
// caller cannot silently act on "".
func DistroByKey(k string) (Distro, bool) {
	for _, d := range Distros {
		if d.Key == k {
			return d, true
		}
	}
	return Distro{}, false
}

// DistroKeys is the flat list, derived so the two cannot disagree.
func DistroKeys() []string {
	out := make([]string, 0, len(Distros))
	for _, d := range Distros {
		out = append(out, d.Key)
	}
	return out
}

// ─── Which OpenZFS is under test ─────────────────────────────────────
//
// SourceKind is deliberately closed. "Whatever string the operator typed"
// is how you end up running the distro's packaged ZFS while believing you
// are testing a git branch, and then trusting the result.

type SourceKind int

const (
	// SourceRepo installs whatever the distro ships. The baseline: it is
	// what a user of that distro would actually get.
	SourceRepo SourceKind = iota
	// SourceVersion builds a tagged OpenZFS release.
	SourceVersion
	// SourceGit builds a branch, tag or commit from a GitHub repo — the
	// mode that answers "does this PR break Debian".
	SourceGit
	// SourceTarball builds from a local tarball, for a source tree that is
	// not published anywhere.
	SourceTarball
)

// ZFSSource is the answer to "which OpenZFS am I testing".
type ZFSSource struct {
	Kind    SourceKind
	Version string // SourceVersion: 2.4.3
	Repo    string // SourceGit: openzfs/zfs
	Ref     string // SourceGit: master, a tag, or a commit
	Path    string // SourceTarball: /path/to/zfs-x.y.z.tar.gz
}

// versionRE is OpenZFS's own shape: three dotted numbers, optionally with a
// release-candidate suffix. Anything else is a typo, and a typo here costs a
// full matrix run before it is discovered.
var versionRE = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$`)

// repoRE is owner/repo. Deliberately not a URL: the string is handed to a
// shell as part of a git clone, and an allowlist of what a GitHub path may
// contain is a smaller thing to get right than a URL parser.
var repoRE = regexp.MustCompile(`^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`)

// refRE covers branches, tags and commit hashes without admitting the
// characters that would mean something else to git or to a shell.
var refRE = regexp.MustCompile(`^[A-Za-z0-9._/-]+$`)

// Validate reports why a source cannot be used, or nil.
//
// It runs BEFORE anything is built. Every failure it catches is one that
// would otherwise surface inside a guest, mid-run, in a log nobody is
// watching.
func (s ZFSSource) Validate() error {
	switch s.Kind {
	case SourceRepo:
		return nil
	case SourceVersion:
		if !versionRE.MatchString(s.Version) {
			return fmt.Errorf("version %q must look like 2.4.3 or 2.4.3-rc1", s.Version)
		}
		return nil
	case SourceGit:
		if !repoRE.MatchString(s.Repo) {
			return fmt.Errorf("repo %q must be owner/repo, e.g. openzfs/zfs", s.Repo)
		}
		if s.Ref == "" {
			return fmt.Errorf("give a branch, tag or commit to build from")
		}
		if !refRE.MatchString(s.Ref) {
			return fmt.Errorf("ref %q may only contain letters, digits, . _ - /", s.Ref)
		}
		return nil
	case SourceTarball:
		if !strings.HasPrefix(s.Path, "/") {
			return fmt.Errorf("tarball path %q must be absolute", s.Path)
		}
		if strings.ContainsAny(s.Path, " \t\n'\"$`\\") {
			return fmt.Errorf("tarball path %q contains characters that are not safe to pass on", s.Path)
		}
		return nil
	}
	return fmt.Errorf("unknown source kind %d", s.Kind)
}

// String renders the ZFS_SOURCE value kzfs-test expects.
//
// Returns: the spec string. Callers must Validate first — this does not,
// because a String() that can fail is a String() nobody checks.
func (s ZFSSource) String() string {
	switch s.Kind {
	case SourceVersion:
		return "version:" + s.Version
	case SourceGit:
		return "git:" + s.Repo + "@" + s.Ref
	case SourceTarball:
		return "tarball:" + s.Path
	default:
		return "repo"
	}
}

// Describe is the one-line human form, for a header that has to say what is
// under test without the operator reading a config.
func (s ZFSSource) Describe() string {
	switch s.Kind {
	case SourceVersion:
		return "OpenZFS " + s.Version + " (release tarball)"
	case SourceGit:
		return "OpenZFS " + s.Repo + " @ " + s.Ref + " (built from git)"
	case SourceTarball:
		return "OpenZFS from " + s.Path
	default:
		return "the distro's own ZFS packages"
	}
}

// ParseZFSSource reads a ZFS_SOURCE string back into a ZFSSource.
//
// Args:    spec, in kzfs-test's grammar; "" means the default.
// Returns: the parsed source, or an error naming what was wrong.
//
// This exists so the GUI can open showing whatever a previous run used,
// rather than resetting to the default and quietly testing something else
// than the operator last asked for.
func ParseZFSSource(spec string) (ZFSSource, error) {
	spec = strings.TrimSpace(spec)
	switch {
	case spec == "" || spec == "repo":
		return ZFSSource{Kind: SourceRepo}, nil

	case strings.HasPrefix(spec, "version:"):
		s := ZFSSource{Kind: SourceVersion, Version: strings.TrimPrefix(spec, "version:")}
		return s, s.Validate()

	case strings.HasPrefix(spec, "git:"):
		rest := strings.TrimPrefix(spec, "git:")
		repo, ref, ok := strings.Cut(rest, "@")
		if !ok {
			// Defaulting a missing ref to master would test something the
			// operator did not name, which is the one thing a test lab
			// must never do.
			return ZFSSource{}, fmt.Errorf("git source %q needs a ref: git:owner/repo@branch", spec)
		}
		s := ZFSSource{Kind: SourceGit, Repo: repo, Ref: ref}
		return s, s.Validate()

	case strings.HasPrefix(spec, "tarball:"):
		s := ZFSSource{Kind: SourceTarball, Path: strings.TrimPrefix(spec, "tarball:")}
		return s, s.Validate()
	}
	return ZFSSource{}, fmt.Errorf("unrecognised ZFS source %q — expected repo, "+
		"version:X.Y.Z, git:owner/repo@ref or tarball:/path", spec)
}

// ─── Do the goldens the run needs actually exist? ────────────────────
//
// WHY THIS EXISTS AT ALL: kzfs-test warns once per missing golden and then
// carries on — "Phase 3: Running full tests in parallel... Total time: 0s"
// with an empty results directory. A run that tests NOTHING and reports no
// error is the single worst thing a test lab can do, because the next thing
// anybody does is trust it. Reported as "the test tool fails right away"
// (fiend, 2026-08-15); it did not fail, which was the problem.

// GoldenName is the domain kzfs-test clones for a distro.
//
// It mirrors kzfs-test's golden_name(): "${PREFIX}-golden-${distro}" with
// PREFIX=kzfstest. Keep them in step — a mismatch here reports goldens as
// missing when they exist, or as present when they do not.
func GoldenName(distro string) string { return "kzfstest-golden-" + distro }

// GoldenState lists which of the requested distros can actually be tested.
//
// Args:    distros, the keys to check (empty = the whole matrix);
//
//	domains, every domain name libvirt knows.
//
// Returns: present and missing, in the matrix's order.
//
// Split from the libvirt call so it is testable without a hypervisor.
func GoldenState(distros []string, domains []string) (present, missing []string) {
	if len(distros) == 0 {
		distros = DistroKeys()
	}
	have := make(map[string]bool, len(domains))
	for _, d := range domains {
		have[strings.TrimSpace(d)] = true
	}
	for _, d := range distros {
		if have[GoldenName(d)] {
			present = append(present, d)
		} else {
			missing = append(missing, d)
		}
	}
	return present, missing
}

// GoldenGap reports why a run cannot proceed, or nil when it can.
//
// The message names the command that fixes it, because "no goldens" without
// the remedy sends somebody back to the documentation.
func GoldenGap(present, missing []string) error {
	switch {
	case len(present) == 0 && len(missing) > 0:
		return fmt.Errorf("none of the selected distros have a golden image yet, so this "+
			"run would test nothing and report success in about a second.\n\n"+
			"Build them first — the Lab tab's \"Build goldens\", or:\n"+
			"    kzfs-test golden %s", missing[0])
	case len(missing) > 0:
		return fmt.Errorf("no golden image for: %s\n\n"+
			"Those distros would be silently skipped. Untick them, or build them "+
			"first from the Lab tab.", strings.Join(missing, ", "))
	}
	return nil
}
