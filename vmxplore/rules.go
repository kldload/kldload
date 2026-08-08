// rules.go — estate grouping & snapshot classification, driven by a rules file.
//
// The load-bearing design rule (docs/VM-CONSOLE-DESIGN.md): grouping and
// classification are DATA, not Go. The compiled core must not know any site's
// naming convention — kldload's lives in rules/kldload.rules, embedded as one
// profile among several and overridable at /etc/vmxplore/rules or --rules.
//
// Inputs:  a rules file (see rules/kldload.rules for the format).
// Outputs: Ruleset.GroupFor(domain) → estate group label ("" = ungrouped),
//
//	Ruleset.ClassifySnap(name) → class string,
//	Ruleset.SnapSummary(snaps) → per-class counts.
//
// Notes: first match wins in both tables, so order in the file matters —
// goldens before cluster patterns. A snapshot matching no rule is class
// "human": on every convention observed, automation always prefixes, so an
// unprefixed name is an operator's.
package main

import (
	_ "embed"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
)

//go:embed rules/kldload.rules
var kldloadRules string

//go:embed rules/generic.rules
var genericRules string

// SnapHuman is the class of operator-made snapshots — the ✎ count in the
// estate table — and the default for names no rule matches.
const SnapHuman = "human"

// SnapNoise is the class collapsed to a bare count everywhere in the UI.
const SnapNoise = "noise"

type snapRule struct {
	class  string
	prefix string
}

type groupRule struct {
	re    *regexp.Regexp
	label string // may contain $1…$9 capture expansions
}

// Ruleset is a parsed rules file. Zero value = everything human, ungrouped.
type Ruleset struct {
	snaps  []snapRule
	groups []groupRule
	Source string // where it came from, for --version/status display
}

// ParseRules parses the rules-file format. Unknown directives and syntax
// errors fail loudly — a silently half-loaded ruleset misclassifies 16k
// snapshots without anyone noticing.
func ParseRules(src, origin string) (*Ruleset, error) {
	rs := &Ruleset{Source: origin}
	for ln, line := range strings.Split(src, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Fields(line)
		switch {
		case f[0] == "snap" && len(f) == 3:
			rs.snaps = append(rs.snaps, snapRule{class: f[1], prefix: f[2]})
		case f[0] == "group" && len(f) >= 3:
			re, err := regexp.Compile(f[1])
			if err != nil {
				return nil, fmt.Errorf("%s:%d: bad regex %q: %w", origin, ln+1, f[1], err)
			}
			rs.groups = append(rs.groups, groupRule{re: re, label: strings.Join(f[2:], " ")})
		default:
			return nil, fmt.Errorf("%s:%d: unrecognized rule %q", origin, ln+1, line)
		}
	}
	return rs, nil
}

// LoadRules picks the ruleset: explicit path → /etc/vmxplore/rules →
// embedded kldload profile (on a kldload host) → embedded generic profile.
// Only the explicit path is fatal on error — it was asked for by name.
func LoadRules(path string) (*Ruleset, error) {
	if path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		return ParseRules(string(b), path)
	}
	if b, err := os.ReadFile("/etc/vmxplore/rules"); err == nil {
		return ParseRules(string(b), "/etc/vmxplore/rules")
	}
	if IsKldload() {
		return ParseRules(kldloadRules, "builtin:kldload")
	}
	return ParseRules(genericRules, "builtin:generic")
}

// ClassifySnap classifies a snapshot by name (the part after '@').
func (rs *Ruleset) ClassifySnap(name string) string {
	for _, r := range rs.snaps {
		if strings.HasPrefix(name, r.prefix) {
			return r.class
		}
	}
	return SnapHuman
}

// SnapSummary counts snapshots per class. Callers render class "noise" as a
// bare count and class "human" as the ✎ figure.
func (rs *Ruleset) SnapSummary(snaps []string) map[string]int {
	m := make(map[string]int, 4)
	for _, s := range snaps {
		m[rs.ClassifySnap(s)]++
	}
	return m
}

// GroupFor returns the estate group label for a domain name, expanding
// $1…$9 from the matching rule's capture groups. "" means ungrouped.
func (rs *Ruleset) GroupFor(domain string) string {
	for _, g := range rs.groups {
		m := g.re.FindStringSubmatchIndex(domain)
		if m == nil {
			continue
		}
		return string(g.re.ExpandString(nil, g.label, domain, m))
	}
	return ""
}

// ─── kldload detection ──────────────────────────────────────────────────────
// Copied shape from zxplore (zfs.go): detection gates cosmetic flair and the
// default ruleset ONLY — never whether a capability exists. Capabilities gate
// on LookPath/probes (HasZFS, kldload-db present, …), per the design rule
// that build-iso.sh once violated with profile-name gating.

// IsKldload reports whether this is a kldload host, so vmx can pick the
// kldload ruleset and light up k-command delegation. Fully generic otherwise.
func IsKldload() bool {
	for _, p := range []string{"/usr/local/bin/kbe", "/etc/kldload"} {
		if _, err := os.Stat(p); err == nil {
			return true
		}
	}
	return false
}

// vmKTools are the kldload VM tools vmx surfaces delegation flair for when it
// detects them. vmx stays fully generic without them.
var vmKTools = []string{
	"klab", "kube-cluster", "kspawn",
	"kvm-create", "kvm-clone", "kvm-delete", "kvm-snap", "kvm-list",
	"kimage", "kexport", "kvm-win", "ksnap",
	"kvm-demo", "kube-demo",
}

// KldloadTools returns the kldload VM tools present on this host (nil on a
// generic system).
func KldloadTools() []string {
	if !IsKldload() {
		return nil
	}
	var found []string
	for _, t := range vmKTools {
		if _, err := exec.LookPath(t); err == nil {
			found = append(found, t)
		}
	}
	return found
}
