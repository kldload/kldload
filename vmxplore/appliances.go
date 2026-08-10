// appliances.go — the Appliances catalog: push-button self-hosted apps.
//
// What it does, in order:
//  1. Holds a curated catalog of Appliance entries — each one a cloud-image
//     preset, a sizing default, a set of operator-facing fields, and a
//     fixed bash post-installer.
//  2. Renders an entry to a concrete post-install script: required fields
//     are checked, blank generate-fields get a crypto/rand secret, and every
//     value is emitted as a single-quoted bash assignment in a preamble.
//  3. Hands back a NewVMSpec the existing pipeline (newvm.go) builds
//     unchanged — so an appliance is just a New VM with the form pre-filled.
//
// Why: nearly every "how to self-host X" writeup is the same four moves —
// fetch a pinned artifact, write a config, init a database, drop a unit
// file. Encoding that once per app turns a weekend of following a blog post
// into a button, and Make Golden → Clone turns the result into a template.
//
// Notes: operator values are NEVER interpolated into the body of a script.
// The body is fixed bash that reads named variables; Render only prepends
// shell-quoted assignments. That is the whole injection story — a site name
// containing a quote, a `$(…)`, or a backtick is inert data, not code.
// Values are rejected if they contain a newline, since the scripts write
// them into line-oriented config formats.
package main

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"
)

// ─── The catalog types ───────────────────────────────────────────────
//
// An Appliance is deliberately data, not code: a new entry is a struct
// literal plus a bash string, so adding an app never touches the pipeline,
// the GUI, or the tests. Validate is the one escape hatch, for the
// per-app rules that would otherwise only surface as a confusing failure
// deep inside the guest's first boot.

// ApplianceField is one operator-facing input on the appliance form.
//
// Generate means "if left blank, invent a strong value" — used for
// passwords and seeds so the happy path needs no typing. Secret only
// affects presentation (the GUI masks it); it does not change storage,
// since the rendered script necessarily contains the value in clear.
type ApplianceField struct {
	Key         string // variable name in the script; [A-Z0-9_]+
	Label       string // shown on the form
	Placeholder string
	Default     string
	Secret      bool // mask in the UI
	Generate    bool // blank → generated secret
	Required    bool
}

// Appliance is one catalog entry: everything needed to turn a stock cloud
// image into a running service, with no operator decisions beyond Fields.
type Appliance struct {
	Name     string // catalog key, shown in the picker
	Summary  string // one line, shown under the picker
	Homepage string
	License  string

	Distro string // key into cloudImages (newvm.go)
	VCPUs  int
	RAMMB  int
	DiskGB int

	Port    int    // primary service port, opened in the guest firewall
	LandsOn string // human hint: where the service appears once booted

	Fields []ApplianceField

	// Validate runs before Render on the fully-defaulted value set. It
	// exists to fail fast on rules the guest would otherwise only report
	// from inside cloud-init, where nobody is watching.
	Validate func(vals map[string]string) error

	// Script is fixed bash. It reads the Fields by Key as shell variables
	// and must not interpolate anything else.
	Script string

	// Notes is operator-facing caveat text shown beside the form.
	Notes string
}

var fieldKeyRE = regexp.MustCompile(`^[A-Z][A-Z0-9_]*$`)

// ─── Rendering ───────────────────────────────────────────────────────

// shellSingleQuote wraps s so bash sees it as one literal word, whatever
// it contains. Single quotes suppress every form of expansion, and the
// one character they cannot contain — the quote itself — is handled by
// closing the quote, emitting a backslash-escaped quote, and reopening.
// Bash concatenates adjacent quoted runs, so the result stays one word.
func shellSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// randomSecret returns a URL-safe random string of about n characters,
// drawn from crypto/rand. Used for generate-fields (passwords, seeds).
func randomSecret(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("generating secret: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(b)[:n], nil
}

// Defaults returns the field values an unedited form would submit.
func (a Appliance) Defaults() map[string]string {
	vals := make(map[string]string, len(a.Fields))
	for _, f := range a.Fields {
		vals[f.Key] = f.Default
	}
	return vals
}

// resolve fills in defaults and generated secrets, and enforces the
// invariants every appliance script depends on. Returns the completed
// value set; the caller's map is not modified.
//
// Failure modes: a required field left blank, a value containing a
// newline (scripts write these into line-oriented config), or a field key
// that is not a legal shell variable name.
func (a Appliance) resolve(vals map[string]string) (map[string]string, error) {
	out := make(map[string]string, len(a.Fields))
	for _, f := range a.Fields {
		if !fieldKeyRE.MatchString(f.Key) {
			return nil, fmt.Errorf("appliance %s: bad field key %q", a.Name, f.Key)
		}
		v := strings.TrimSpace(vals[f.Key])
		if v == "" {
			v = f.Default
		}
		if v == "" && f.Generate {
			s, err := randomSecret(24)
			if err != nil {
				return nil, err
			}
			v = s
		}
		if v == "" && f.Required {
			return nil, fmt.Errorf("%s is required", f.Label)
		}
		if strings.ContainsAny(v, "\n\r") {
			return nil, fmt.Errorf("%s must be a single line", f.Label)
		}
		out[f.Key] = v
	}
	if a.Validate != nil {
		if err := a.Validate(out); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// Render produces the post-install bash for this appliance: a header, a
// preamble of shell-quoted assignments, then the fixed script body.
//
// The returned script is what lands in the guest as
// /var/lib/vmxplore-postinstall.sh and runs once, as root, on first boot.
func (a Appliance) Render(vals map[string]string) (string, error) {
	resolved, err := a.resolve(vals)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	fmt.Fprintf(&b, "# vmxplore appliance: %s\n", a.Name)
	fmt.Fprintf(&b, "# %s\n", a.Summary)
	if a.Homepage != "" {
		fmt.Fprintf(&b, "# %s\n", a.Homepage)
	}
	b.WriteString("\n")
	// Field order, not map order — a rendered script must be byte-identical
	// for the same inputs so two operators can diff theirs.
	for _, f := range a.Fields {
		fmt.Fprintf(&b, "%s=%s\n", f.Key, shellSingleQuote(resolved[f.Key]))
	}
	b.WriteString("\n")
	b.WriteString(strings.TrimRight(a.Script, "\n"))
	b.WriteString("\n")
	return b.String(), nil
}

// Spec renders the appliance and returns the NewVMSpec that builds it.
// user/password are the guest login (not the app's admin account); the
// caller supplies them so the appliance form can stay app-focused.
func (a Appliance) Spec(vmName, user, password, sshKey string,
	vals map[string]string) (NewVMSpec, error) {
	script, err := a.Render(vals)
	if err != nil {
		return NewVMSpec{}, err
	}
	s := NewVMSpec{
		Name:     strings.TrimSpace(vmName),
		Distro:   a.Distro,
		VCPUs:    a.VCPUs,
		RAMMB:    a.RAMMB,
		DiskGB:   a.DiskGB,
		User:     strings.TrimSpace(user),
		Password: password,
		SSHKey:   strings.TrimSpace(sshKey),
		PostInst: script,
	}
	return s, s.validate()
}

// ─── CLI surface ─────────────────────────────────────────────────────
//
// The rendered script is a useful artifact on its own: it is an ordinary
// bash installer with no vmxplore, libvirt or kldload dependency, so an
// upstream project can publish it as their own "install on a fresh VM"
// path. Printing it also makes the catalog reviewable without building a
// VM — you can read exactly what the button is about to run.

// PrintAppliances writes the catalog to w in operator-readable form.
func PrintAppliances(w *os.File) {
	for _, a := range Appliances() {
		fmt.Fprintf(w, "%s\n  %s\n", a.Name, a.Summary)
		fmt.Fprintf(w, "  %s · %s · %d vCPU, %d MB RAM, %d GB disk\n",
			a.License, a.Distro, a.VCPUs, a.RAMMB, a.DiskGB)
		fmt.Fprintf(w, "  serves: %s\n", a.LandsOn)
		for _, f := range a.Fields {
			req := ""
			if f.Required {
				req = " (required)"
			}
			fmt.Fprintf(w, "    %-14s %s%s\n", f.Key, f.Label, req)
		}
		fmt.Fprintln(w)
	}
}

// applianceOverrides parses KEY=VALUE arguments onto a value set. It
// rejects unknown keys rather than ignoring them, so a typo in a scripted
// invocation fails instead of silently installing the default.
func applianceOverrides(a Appliance, vals map[string]string,
	args []string) error {
	known := map[string]bool{}
	for _, f := range a.Fields {
		known[f.Key] = true
	}
	for _, arg := range args {
		k, v, ok := strings.Cut(arg, "=")
		if !ok {
			return fmt.Errorf("expected KEY=VALUE, got %q", arg)
		}
		if !known[k] {
			return fmt.Errorf("%s has no field %q", a.Name, k)
		}
		vals[k] = v
	}
	return nil
}

// WaitAppliance blocks until a freshly built appliance answers on its
// port, and returns the URL it answered on.
//
// Why this exists: the pipeline returns as soon as the domain is defined,
// but the appliance is not usable until cloud-init has run the installer —
// a minute or three later, on an address nobody knows yet. Without this
// the operator is handed "http://<vm-ip>/" and has to go hunt for the
// lease, which is precisely the seam that stops a deploy feeling like one
// action.
//
// Args: name is the domain; port is the appliance's Port; progress gets a
// line per phase. Returns the URL, or an error describing which phase
// timed out — the two phases fail for entirely different reasons (no DHCP
// lease vs. an installer that died), so they are reported separately.
func WaitAppliance(name string, port int, progress func(string)) (string, error) {
	const (
		leaseTimeout = 3 * time.Minute
		bootTimeout  = 10 * time.Minute
	)
	lv, err := ConnectSystem()
	if err != nil {
		return "", err
	}
	defer lv.Close()

	progress("waiting for " + name + " to get an address")
	var ip string
	for deadline := time.Now().Add(leaseTimeout); time.Now().Before(deadline); {
		if ips, err := lv.LeaseIPs(name); err == nil && len(ips) > 0 {
			ip = ips[0]
			break
		}
		time.Sleep(2 * time.Second)
	}
	if ip == "" {
		return "", fmt.Errorf("%s got no DHCP lease within %s — is its "+
			"network up?", name, leaseTimeout)
	}

	url := fmt.Sprintf("http://%s/", ip)
	if port != 80 && port != 0 {
		url = fmt.Sprintf("http://%s:%d/", ip, port)
	}
	progress("at " + ip + " — waiting for the first boot to finish installing")

	// Any HTTP response counts as ready: a redirect or even a 404 means
	// the service is listening, and only the appliance knows what its own
	// landing page should be.
	client := &http.Client{Timeout: 5 * time.Second}
	for deadline := time.Now().Add(bootTimeout); time.Now().Before(deadline); {
		resp, err := client.Get(url)
		if err == nil {
			resp.Body.Close()
			return url, nil
		}
		time.Sleep(3 * time.Second)
	}
	return url, fmt.Errorf("%s never answered on %s within %s — check "+
		"`journalctl -u cloud-final` in the guest", name, url, bootTimeout)
}

// applianceFlags are the non-KEY=VALUE options --appliance accepts. They
// describe the *guest* (its login), never the app — app configuration is
// the catalog entry's Fields, so the flag set never grows per appliance.
type applianceFlags struct {
	vm       string
	user     string
	password string
	sshKey   string
	noWait   bool
	rest     []string
}

// parseApplianceFlags splits argv into guest options and KEY=VALUE pairs.
// Defaults mirror the GUI dialog so both surfaces build the same VM.
func parseApplianceFlags(args []string) (applianceFlags, error) {
	f := applianceFlags{user: "admin"}
	if b, err := os.ReadFile(os.Getenv("HOME") + "/.ssh/id_ed25519.pub"); err == nil {
		f.sshKey = strings.TrimSpace(string(b))
	}
	need := func(i int, what string) (string, error) {
		if i >= len(args) {
			return "", fmt.Errorf("%s needs a value", what)
		}
		return args[i], nil
	}
	for i := 0; i < len(args); i++ {
		var err error
		switch args[i] {
		case "--vm", "--name":
			i++
			f.vm, err = need(i, args[i-1])
		case "--user":
			i++
			f.user, err = need(i, "--user")
		case "--password":
			i++
			f.password, err = need(i, "--password")
		case "--no-wait":
			f.noWait = true
		case "--ssh-key":
			i++
			var p string
			if p, err = need(i, "--ssh-key"); err == nil {
				var b []byte
				if b, err = os.ReadFile(p); err == nil {
					f.sshKey = strings.TrimSpace(string(b))
				}
			}
		default:
			if strings.HasPrefix(args[i], "-") {
				return f, fmt.Errorf("unknown option %q", args[i])
			}
			f.rest = append(f.rest, args[i])
		}
		if err != nil {
			return f, err
		}
	}
	if f.vm == "" {
		return f, fmt.Errorf("--vm NAME is required")
	}
	return f, nil
}

// RunApplianceBuild deploys one catalog entry as a VM and streams the
// pipeline's steps. This is the headless twin of Build ▸ Appliance… —
// the path someone takes who installed vmxplore five minutes ago and has
// no interest in finding a menu.
//
// Returns a process exit status. Progress goes to stderr so stdout stays
// free for the final URL, which makes the command pipeable.
func RunApplianceBuild(name string, args []string) int {
	a, ok := ApplianceByName(name)
	if !ok {
		fmt.Fprintf(os.Stderr, "vmx: no appliance %q — try --appliances\n", name)
		return 2
	}
	f, err := parseApplianceFlags(args)
	if err != nil {
		fmt.Fprintf(os.Stderr, "vmx: %v\n", err)
		return 2
	}
	vals := a.Defaults()
	if err := applianceOverrides(a, vals, f.rest); err != nil {
		fmt.Fprintf(os.Stderr, "vmx: %v\n", err)
		return 2
	}
	if f.password == "" && f.sshKey == "" {
		// Not fatal — but a guest you cannot log into is almost never what
		// was meant, and the app's own admin account is a separate thing.
		fmt.Fprintln(os.Stderr,
			"vmx: warning: no guest password or ssh key — you will not be "+
				"able to log into the VM itself")
	}
	spec, err := a.Spec(f.vm, f.user, f.password, f.sshKey, vals)
	if err != nil {
		fmt.Fprintf(os.Stderr, "vmx: %v\n", err)
		return 2
	}

	// The ZFS parent is a best-effort optimisation: with it the disk is a
	// sparse zvol that clones instantly, without it a qcow2 file. Never a
	// hard failure — this must work on a plain libvirt box.
	parent := ""
	if lv, err := ConnectSystem(); err == nil {
		defer lv.Close()
		if doms, err := lv.Estate(); err == nil && HasZFS() {
			dss, _ := ListDatasets()
			snaps, _ := ListSnapshots()
			rs, _ := LoadRules("") // built-in profile is fine for grouping
			var rows []Row
			for _, g := range BuildEstate(doms, dss, snaps, rs,
				LoadAnnotations()) {
				rows = append(rows, g.Rows...)
			}
			parent = ZFSVMParent(rows)
		}
	}

	log := func(line string) { fmt.Fprintln(os.Stderr, line) }
	if err := BuildNewVM(spec, parent, log); err != nil {
		fmt.Fprintf(os.Stderr, "vmx: %v\n", err)
		return 1
	}
	if f.noWait {
		fmt.Fprintf(os.Stderr, "\n%s is building %s — it will serve on %s\n",
			spec.Name, a.Name, a.LandsOn)
		return 0
	}
	url, err := WaitAppliance(spec.Name, a.Port, log)
	if err != nil {
		fmt.Fprintf(os.Stderr, "vmx: %v\n", err)
		return 1
	}
	fmt.Fprintf(os.Stderr, "\n%s is ready. Credentials are in "+
		"/root/ inside the guest.\n", a.Name)
	fmt.Println(url)
	return 0
}

// RunApplianceScript renders one catalog entry to stdout. Returns a
// process exit status.
func RunApplianceScript(name string, args []string) int {
	a, ok := ApplianceByName(name)
	if !ok {
		fmt.Fprintf(os.Stderr, "vmx: no appliance %q — try --appliances\n", name)
		return 2
	}
	vals := a.Defaults()
	if err := applianceOverrides(a, vals, args); err != nil {
		fmt.Fprintf(os.Stderr, "vmx: %v\n", err)
		return 2
	}
	script, err := a.Render(vals)
	if err != nil {
		fmt.Fprintf(os.Stderr, "vmx: %v\n", err)
		return 1
	}
	fmt.Print("#!/usr/bin/env bash\nset -Eeuo pipefail\n\n", script)
	return 0
}

// ─── The catalog ─────────────────────────────────────────────────────

// Appliances returns the catalog in menu order.
func Appliances() []Appliance { return applianceCatalog }

// ApplianceByName looks up one entry. ok is false for an unknown name.
func ApplianceByName(name string) (Appliance, bool) {
	for _, a := range applianceCatalog {
		if a.Name == name {
			return a, true
		}
	}
	return Appliance{}, false
}

// ApplianceNames lists the catalog keys in menu order (for the picker).
func ApplianceNames() []string {
	out := make([]string, 0, len(applianceCatalog))
	for _, a := range applianceCatalog {
		out = append(out, a.Name)
	}
	return out
}

var applianceCatalog = []Appliance{writeFreely, writeFreelyDesktop}

// ─── WriteFreely ─────────────────────────────────────────────────────
//
// A minimalist, ActivityPub-federated blogging platform (AGPL-3.0). It is
// close to the ideal appliance workload: a statically linked Go binary,
// SQLite for storage, ~25 MB resident, and built-in Let's Encrypt — so
// there is no database server and no reverse proxy in the base install.
//
// The install deliberately consumes the upstream release tarball rather
// than building from source: the repo gitignores static/css and builds it
// with lessc, so a from-source build would drag a Node toolchain into the
// guest for zero benefit. The tarball ships those assets prebuilt.
//
// Layout splits immutable from mutable so an upgrade is "replace /opt":
//   /opt/writefreely        binary + templates/ static/ pages/  (read-only)
//   /var/lib/writefreely    config.ini, keys/, writefreely.db   (state)

// writeFreelyReserved mirrors reservedUsernames in WriteFreely's
// author/author.go at v0.17.1. Checking it here turns a baffling
// mid-cloud-init failure ("invalid, reserved, or shorter than configured
// minimum length") into an error on the form — note this catches the
// default admin name every other appliance uses. The script still gates
// on the real thing: --create-admin failing aborts the post-install.
var writeFreelyReserved = map[string]bool{
	"a": true, "about": true, "add": true, "admin": true,
	"administrator": true, "adminzone": true, "api": true, "article": true,
	"articles": true, "auth": true, "authenticate": true, "browse": true,
	"c": true, "categories": true, "category": true, "changes": true,
	"community": true, "create": true, "css": true, "data": true,
	"dev": true, "developers": true, "draft": true, "drafts": true,
	"edit": true, "edits": true, "faq": true, "feed": true,
	"feedback": true, "guide": true, "guides": true, "help": true,
	"index": true, "invite": true, "js": true, "login": true,
	"logout": true, "me": true, "media": true, "meta": true,
	"metadata": true, "new": true, "news": true, "oauth": true,
	"post": true, "posts": true, "privacy": true, "publication": true,
	"publications": true, "publish": true, "random": true, "read": true,
	"reader": true, "register": true, "remove": true, "signin": true,
	"signout": true, "signup": true, "start": true, "status": true,
	"summary": true, "support": true, "tag": true, "tags": true,
	"team": true, "template": true, "templates": true, "terms": true,
	"terms-of-service": true, "termsofservice": true, "theme": true,
	"themes": true, "tips": true, "tos": true, "update": true,
	"updates": true, "user": true, "users": true, "yourname": true,
}

var writeFreelyUserRE = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{2,}$`)

var writeFreely = Appliance{
	Name:     "WriteFreely",
	Summary:  "Minimalist federated blogging platform, behind Caddy with automatic HTTPS",
	Homepage: "https://writefreely.org",
	License:  "AGPL-3.0",

	Distro: "debian",
	VCPUs:  1,
	RAMMB:  1024,
	DiskGB: 10,

	Port:    80,
	LandsOn: "http://<vm-ip>/  (admin login at /login)",

	Notes: "Everything is fetched and configured inside the guest: " +
		"WriteFreely, Caddy, TLS. No host tooling is required.\n\n" +
		"Leave the domain blank to serve plain HTTP on port 80 — fine for " +
		"a LAN or a VM behind your own proxy. Set it and Caddy requests a " +
		"Let's Encrypt certificate on first start, which needs the name to " +
		"already resolve to this VM from the public internet and ports " +
		"80/443 reachable. If it does not resolve yet, leave it blank and " +
		"add the domain to /etc/caddy/Caddyfile later.",

	Fields: []ApplianceField{
		{Key: "WF_SITE_NAME", Label: "site name", Default: "My Blog", Required: true},
		{Key: "WF_ADMIN_USER", Label: "admin username",
			Placeholder: "not 'admin' — that name is reserved",
			Default:     "writer", Required: true},
		{Key: "WF_ADMIN_PASS", Label: "admin password",
			Placeholder: "blank = generate one", Secret: true,
			Generate: true, Required: true},
		{Key: "WF_DOMAIN", Label: "public domain (optional, enables HTTPS)",
			Placeholder: "blog.example.com"},
		{Key: "WF_TLS_EMAIL", Label: "email for certificate notices (optional)",
			Placeholder: "you@example.com"},
	},

	Validate: func(v map[string]string) error {
		u := v["WF_ADMIN_USER"]
		if writeFreelyReserved[strings.ToLower(u)] {
			return fmt.Errorf("WriteFreely reserves the username %q — pick another", u)
		}
		if !writeFreelyUserRE.MatchString(u) {
			return fmt.Errorf("admin username %q must be 3+ characters, "+
				"lowercase letters, digits and hyphens only", u)
		}
		if len(v["WF_ADMIN_PASS"]) < 8 {
			return fmt.Errorf("admin password must be at least 8 characters")
		}
		if d := v["WF_DOMAIN"]; d != "" && strings.Contains(d, "/") {
			return fmt.Errorf("domain %q must be a bare hostname, not a URL", d)
		}
		return nil
	},

	Script: writeFreelyScript,
}

// writeFreelyScript is fixed bash — it reads WF_* from the preamble Render
// prepends and interpolates nothing else. Pinned versions and per-arch
// checksums keep the build reproducible and make a tampered or truncated
// download a hard failure rather than a mystery.
//
// Note the two checksum algorithms: WriteFreely publishes no checksum
// manifest, so these are ours, computed from the release assets; Caddy
// publishes a signed manifest and it is SHA-512. Each is verified with
// the tool that matches.
const writeFreelyScript = `WF_VERSION='0.17.1'
WF_SHA256_amd64='b3314ecce0f4b5d15b240b20f06cd8f200aea5f7a4274d64017de20d09cdad26'
WF_SHA256_arm64='8bd6b23742becd663f97d25592784d6d329c5a63e09a09bb8dceeff268e756b5'

CADDY_VERSION='2.11.4'
CADDY_SHA512_amd64='8220d1f013b6f27510247b2360c9e0ca9f018feebd82515f07635318b34ff9777ccc8fd0b6e6f2486ce3a33fe389fbb7db12d05baa474f4587509fb4f5ebf1c9'
CADDY_SHA512_arm64='d5a7c423853c24a799765e0e8210d5c7c22a8f56ed37a3cae2fb9f58be138853c02b4efd6b59d576e6d8c7c0d30b9c1592deeaa6a536ff69bcca23b8c1ea709c'

WF_OPT=/opt/writefreely
WF_VAR=/var/lib/writefreely

# The upstream tarball is published per-arch. Anything else is a hard stop:
# silently installing the wrong binary produces an exec-format error at
# first start, which reads as "the appliance is broken."
case "$(uname -m)" in
    x86_64)
        wf_arch=amd64
        wf_sha="$WF_SHA256_amd64"
        caddy_sha="$CADDY_SHA512_amd64"
        ;;
    aarch64 | arm64)
        wf_arch=arm64
        wf_sha="$WF_SHA256_arm64"
        caddy_sha="$CADDY_SHA512_arm64"
        ;;
    *)
        echo "FATAL: unsupported architecture $(uname -m)" >&2
        exit 1
        ;;
esac

# curl and ca-certificates are not universal across cloud images; sqlite3
# is not needed at all (the binary embeds its own driver).
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends curl ca-certificates
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

tarball="writefreely_${WF_VERSION}_linux_${wf_arch}.tar.gz"
url="https://github.com/writefreely/writefreely/releases/download/v${WF_VERSION}/${tarball}"
echo "fetching $url"
curl -fsSL --retry 3 --retry-delay 5 -o "$tmp/$tarball" "$url"
echo "${wf_sha}  $tmp/$tarball" | sha256sum -c -

# Immutable half. Replacing this directory wholesale is the upgrade path,
# which is why keys/ is moved out of it — the tarball ships an empty keys/
# that would otherwise shadow the real one on every upgrade.
rm -rf "$WF_OPT"
mkdir -p "$WF_OPT"
tar xzf "$tmp/$tarball" -C "$WF_OPT" --strip-components=1
rm -rf "$WF_OPT/keys"
chmod 0755 "$WF_OPT/writefreely"

id -u writefreely >/dev/null 2>&1 ||
    useradd --system --home-dir "$WF_VAR" --shell /usr/sbin/nologin writefreely
mkdir -p "$WF_VAR"

# Mutable half. hash_seed is generated per install: it salts public post
# IDs, so a shared value across appliances would make them guessable.
# WriteFreely wants the literal 'sqlite3' here — 'sqlite' is rejected, and
# only at --init-db time.
wf_seed="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
# Caddy owns the public listener and TLS; WriteFreely stays on loopback.
# Its built-in autocert could do 443 directly, but then the app is the
# edge — no security headers, no HTTP redirect, and a cert renewal
# failure takes the whole site down instead of just TLS.
if [ -n "$WF_DOMAIN" ]; then
    wf_host="https://${WF_DOMAIN}"
else
    wf_host="http://$(hostname -I | awk '{print $1}')"
fi

cat >"$WF_VAR/config.ini" <<EOF
[server]
port                 = 8080
bind                 = 127.0.0.1
autocert             = false
templates_parent_dir = ${WF_OPT}
static_parent_dir    = ${WF_OPT}
pages_parent_dir     = ${WF_OPT}
keys_parent_dir      = ${WF_VAR}
hash_seed            = ${wf_seed}
gopher_port          = 0

[database]
type     = sqlite3
filename = ${WF_VAR}/writefreely.db

[app]
site_name         = ${WF_SITE_NAME}
host              = ${wf_host}
theme             = write
single_user       = true
open_registration = false
federation        = true
public_stats      = true
min_username_len  = 3
max_blogs         = 1
update_checks     = false
EOF

chown -R writefreely:writefreely "$WF_VAR"
chmod 0750 "$WF_VAR"
chmod 0640 "$WF_VAR/config.ini"

wf_run() { runuser -u writefreely -- "$WF_OPT/writefreely" -c "$WF_VAR/config.ini" "$@"; }

cd "$WF_VAR"
wf_run --gen-keys
wf_run --init-db
# Ordering matters: with single_user = true the site 404s at / until the
# first user's blog exists, so this is what makes the appliance "up."
wf_run --create-admin "${WF_ADMIN_USER}:${WF_ADMIN_PASS}"

cat >/etc/systemd/system/writefreely.service <<EOF
[Unit]
Description=WriteFreely
Documentation=https://writefreely.org/docs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=writefreely
Group=writefreely
WorkingDirectory=${WF_VAR}
ExecStart=${WF_OPT}/writefreely -c ${WF_VAR}/config.ini
Restart=always
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${WF_VAR}
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
RestrictSUIDSGID=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now writefreely.service

# ─── The edge: Caddy ─────────────────────────────────────────────────
#
# Caddy rather than nginx because an appliance should not ship a config
# language its owner has to learn: five lines get automatic Let's Encrypt,
# HTTP→HTTPS redirect, OCSP stapling and renewal, with no cron job and no
# certbot. It is also a single static binary, so this stays a download and
# a unit file on every distro instead of a per-distro package hunt.
caddy_tar="caddy_${CADDY_VERSION}_linux_${wf_arch}.tar.gz"
caddy_url="https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/${caddy_tar}"
echo "fetching $caddy_url"
curl -fsSL --retry 3 --retry-delay 5 -o "$tmp/$caddy_tar" "$caddy_url"
# Caddy's published manifest is SHA-512, unlike WriteFreely's SHA-256.
echo "${caddy_sha}  $tmp/$caddy_tar" | sha512sum -c -
tar xzf "$tmp/$caddy_tar" -C "$tmp" caddy
install -m 0755 "$tmp/caddy" /usr/local/bin/caddy

id -u caddy >/dev/null 2>&1 ||
    useradd --system --home-dir /var/lib/caddy --create-home \
        --shell /usr/sbin/nologin caddy
mkdir -p /etc/caddy /var/lib/caddy
chown -R caddy:caddy /var/lib/caddy

# With a domain, the site address alone turns on automatic HTTPS. Without
# one there is no name to get a certificate for, so this serves plain HTTP
# on :80 and the operator can add the domain later by editing one line.
if [ -n "$WF_DOMAIN" ]; then
    caddy_site="$WF_DOMAIN"
else
    caddy_site=":80"
fi
{
    if [ -n "$WF_TLS_EMAIL" ]; then
        printf '{\n\temail %s\n}\n\n' "$WF_TLS_EMAIL"
    fi
    cat <<EOF
${caddy_site} {
	encode zstd gzip
	header {
		X-Content-Type-Options nosniff
		X-Frame-Options SAMEORIGIN
		Referrer-Policy strict-origin-when-cross-origin
	}
	reverse_proxy 127.0.0.1:8080
}
EOF
} >/etc/caddy/Caddyfile

cat >/etc/systemd/system/caddy.service <<'EOF'
[Unit]
Description=Caddy reverse proxy
Documentation=https://caddyserver.com/docs/
After=network-online.target writefreely.service
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
Restart=on-abnormal
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/caddy
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
RestrictSUIDSGID=yes

[Install]
WantedBy=multi-user.target
EOF

# Validate before enabling: a rejected Caddyfile should fail the install
# loudly here, not leave a dead unit and an unreachable site.
runuser -u caddy -- /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile
systemctl daemon-reload
systemctl enable --now caddy.service

# Cloud images ship whichever firewall their distro prefers, or none.
# Only the edge ports open; WriteFreely is on loopback and stays there.
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp
    ufw allow 443/tcp
fi

# The credentials the operator needs, where they will look for them. Root
# only: this is a cleartext password.
cat >/root/writefreely-credentials.txt <<EOF
WriteFreely ${WF_VERSION} — ${WF_SITE_NAME}
url:      ${wf_host}
admin:    ${WF_ADMIN_USER}
password: ${WF_ADMIN_PASS}
config:   ${WF_VAR}/config.ini
edge:     /etc/caddy/Caddyfile (Caddy ${CADDY_VERSION})
logs:     journalctl -u writefreely -u caddy
EOF
chmod 0600 /root/writefreely-credentials.txt

echo "WriteFreely ${WF_VERSION} is up at ${wf_host} — sign in as ${WF_ADMIN_USER}"
`

// ─── WriteFreely Desktop ─────────────────────────────────────────────
//
// The same blog, plus a machine to write on: the VM boots straight into a
// full-screen editor with no login prompt and no desktop to navigate, so
// vmxplore's Screen tab *is* the writing surface. Zero to writing in one
// action, on any Linux with KVM — nothing kldload-specific in the guest.
//
// Why a second entry rather than a flag on the first: the two have
// genuinely different shapes. The server is a 1 GB headless box you reach
// from your own browser; this is a workstation whose whole job is to
// render one application. Sizing, package set and failure modes all
// differ, and a boolean hiding that would make both worse.
//
// The desktop is deliberately not GNOME. Measured on the built appliance,
// gnome-core costs 802 additional packages; X plus a kiosk window manager
// plus a browser is a fraction of that, and every one of those packages
// exists to put a single window on screen.
var writeFreelyDesktop = Appliance{
	Name: "WriteFreely Desktop",
	Summary: "A writing machine: the blog plus a full-screen editor, " +
		"booting straight into it",
	Homepage: "https://writefreely.org",
	License:  "AGPL-3.0",

	Distro: "debian",
	VCPUs:  2,
	RAMMB:  3072,
	DiskGB: 16,

	Port: 80,
	LandsOn: "the Screen tab — it boots into the editor, signed in. " +
		"Also http://<vm-ip>/",

	Notes: "Boots with no login prompt straight into a full-screen editor, " +
		"already signed in as the admin you set up here — the Screen " +
		"tab is the whole interface. The blog is also served on the " +
		"network exactly as the headless entry does.\n\n" +
		"There is no desktop and nothing to navigate away into — the " +
		"browser is policy-locked to the local app, so a stray link " +
		"cannot strand the machine on the public internet, and alt+Home " +
		"always returns to the editor. " +
		"ctrl+alt+F2 gives an ordinary console login if you need one, " +
		"ctrl+alt+F1 comes back. Power off from the console you are " +
		"reading this in — the guest answers the ACPI button with a " +
		"clean shutdown.\n\n" +
		"Heavier than the server appliance — it carries X, a kiosk window " +
		"manager and a browser — so give it the 2 vCPU / 3 GB it asks for. " +
		"First boot installs those packages and reboots once into a " +
		"kernel that has graphics drivers, so it takes a few minutes.",

	Fields:   writeFreely.Fields,
	Validate: writeFreely.Validate,

	// Composed, not copied: the desktop layer is appended to the exact
	// server script the headless entry ships, so a fix to the install
	// reaches both and the two can never drift.
	Script: writeFreelyScript + "\n" + writingDesktopScript,
}

// writingDesktopScript turns the freshly installed server into a writing
// station. It runs after writeFreelyScript, so WriteFreely and Caddy are
// already up on loopback and :80 respectively.
const writingDesktopScript = `
# ─── The writing desktop ─────────────────────────────────────────────
#
# X, a kiosk window manager and a browser — nothing else. matchbox is a
# window manager built for exactly this: it forces every window
# full-screen and has no decorations, menus or desktop, so there is
# nothing to navigate away into and no way to land on a bare root window
# if the browser restarts.
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends \
        xserver-xorg-core xserver-xorg-video-fbdev \
        xserver-xorg-input-libinput xinit x11-xserver-utils \
        matchbox-window-manager firefox-esr fonts-dejavu-core unclutter

    # WHY: Debian's cloud images run linux-image-cloud-amd64, a kernel
    # flavour built with no DRM subsystem and no framebuffer at all — no
    # virtio_gpu module, no /dev/dri/card0, no /dev/fb0. Xorg probes
    # modesetting, falls back to fbdev, finds neither and dies with
    # "no screens found"; agetty then re-runs startx forever and the
    # Screen tab shows a black 720x400 VGA text screen. The generic
    # kernel carries the drivers, so a graphical appliance on a cloud
    # image has to install it and boot into it once.
    # HISTORY: wf-desk, 2026-08-09 — installed cleanly, served the blog on
    # :80, and never put a pixel on screen.
    wf_arch="$(dpkg --print-architecture)"
    if dpkg-query -W -f='${Status}' "linux-image-cloud-$wf_arch" \
        2>/dev/null | grep -q '^install ok installed$'; then
        apt-get install -y "linux-image-$wf_arch"

        # Installing it is not enough. Both flavours carry the SAME
        # version, and grub's sort puts "…-cloud-amd64" after
        # "…-amd64", so the newest-kernel default picks the cloud one and
        # the machine boots straight back into a kernel with no DRM.
        # HISTORY: wf-desk, 2026-08-09 — installed the generic kernel,
        # rebooted, came up on the cloud one, X died again.
        #
        # Purging the cloud kernel is NOT the way out: its prerm refuses
        # with "Aborting removal of the running kernel", and it is by
        # definition the running one at this point. So point grub at the
        # generic entry explicitly. The id path is submenu>entry, both
        # read out of the generated grub.cfg rather than guessed, and
        # update-grub bakes it into grub.cfg's "set default=" line.
        # Glob, not ls|grep: the cloud images are the ones whose name
        # ends -cloud-<arch>, so everything else in /boot is a candidate
        # and the newest by version sort wins.
        wf_gen=""
        for wf_k in /boot/vmlinuz-*; do
            case "$wf_k" in *-cloud-*) continue ;; esac
            wf_gen="$wf_k"
        done
        wf_ver="${wf_gen#/boot/vmlinuz-}"
        if [ -z "$wf_ver" ]; then
            echo "FATAL: generic kernel installed but no vmlinuz for it" >&2
            exit 1
        fi
        wf_sub="$(grep -o 'gnulinux-advanced-[a-f0-9-]*' /boot/grub/grub.cfg | head -1)"
        wf_ent="$(grep -o "gnulinux-$wf_ver-advanced-[a-f0-9-]*" /boot/grub/grub.cfg | head -1)"
        if [ -z "$wf_sub" ] || [ -z "$wf_ent" ]; then
            echo "FATAL: cannot find the generic kernel's grub menu id" >&2
            exit 1
        fi
        sed -i '/^GRUB_DEFAULT=/d' /etc/default/grub
        echo "GRUB_DEFAULT=\"$wf_sub>$wf_ent\"" >>/etc/default/grub

        # And stop grub sitting at the menu for half a minute.
        #
        # grub sets recordfail at boot and grub-common clears it once the
        # boot succeeds, so any boot that does not get that far — a
        # plug-pull, a reset, the reboot this very script performs at the
        # wrong moment — leaves the flag set and the NEXT boot waits 30
        # seconds at a menu nobody is watching. Debian's generated config
        # spells it out: "if recordfail = 1, set timeout=30", against a
        # normal-path timeout of 0.
        #
        # For a machine whose whole promise is power-on-and-write, 30
        # seconds of nothing is the most visible thing it does. The
        # recovery the timeout exists to offer is a menu on a VM with no
        # keyboard attached during a build.
        sed -i '/^GRUB_RECORDFAIL_TIMEOUT=/d' /etc/default/grub
        echo 'GRUB_RECORDFAIL_TIMEOUT=0' >>/etc/default/grub

        # And put the boot on the screen, at a size worth looking at.
        #
        # console=tty0: the cloud image's cmdline sends every kernel
        # message to the serial port only, so the Screen tab is blank
        # from power-on until X claims it — which reads as a hang on the
        # one boot where the operator is watching hardest. tty0 first and
        # ttyS0 last, because kernel messages go to every console= listed
        # but the LAST one wins /dev/console for userspace, and the serial
        # console should stay the interactive one.
        #
        # video=: a virtual GPU has no monitor to ask, so DRM picks a
        # small safe mode and the whole machine — text console and X
        # alike — comes up at 1280x800. Naming the mode on the cmdline
        # sets it once, before anything has drawn, so the install output
        # and the editor are both full size. Virtual-1 is virtio-gpu's
        # connector; if a future kernel names it differently the argument
        # is ignored and the guest keeps its default, which is why the
        # session also asks for the mode at runtime below.
        if ! grep -q 'console=tty0' /etc/default/grub; then
            sed -i 's/^GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="console=tty0 video=Virtual-1:2560x1440 /' \
                /etc/default/grub
        fi

        # The meta package goes even though the running image cannot:
        # left in place it pulls a NEWER cloud kernel on the next upgrade,
        # which would out-sort the generic one and undo all of this. Only
        # the meta is named here, so the running kernel is untouched and
        # the machine stays bootable either way; a failure is reported but
        # is not fatal, since grub already points at the generic entry.
        apt-get purge -y "linux-image-cloud-$wf_arch" ||
            echo "WARN: could not drop the cloud kernel meta package" >&2
        update-grub
        wf_need_reboot=1
    fi
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y --setopt=install_weak_deps=False \
        xorg-x11-server-Xorg xorg-x11-xinit matchbox-window-manager \
        firefox dejavu-sans-fonts unclutter
else
    echo "FATAL: no supported package manager for the desktop layer" >&2
    exit 1
fi

# A dedicated session user. This is not the cloud-init login: that account
# keeps its password and ssh key for administration, while this one exists
# only to own the X session. It needs no password because it is
# autologged in, and its password is locked so it cannot be used to log in
# anywhere else.
wf_desk=writer
id -u "$wf_desk" >/dev/null 2>&1 ||
    useradd --create-home --shell /bin/bash "$wf_desk"
passwd -l "$wf_desk"
wf_home="$(getent passwd "$wf_desk" | cut -d: -f6)"

# Autologin on tty1, as a drop-in rather than an edit so a getty package
# upgrade cannot silently revert it.
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Unit]
# A kiosk must keep trying. The default 5-starts-in-10s limit exists to
# stop a broken service thrashing; here the "thrash" IS the retry loop
# that recovers the session, so the limit is what breaks it.
StartLimitIntervalSec=0

[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${wf_desk} --noclear %I \$TERM
EOF

# tty1 starts X and nothing else. Guarding on the tty matters: without it
# an ssh login would try to start a second X server.
cat >"$wf_home/.bash_profile" <<'PROFILE'
# Not exec, and never instant: if X cannot start, an exec'd startx exits
# the login shell immediately, agetty respawns, and systemd kills the
# getty for good after 5 restarts in 10s — turning a recoverable X
# failure into a console that is dead until someone reboots it. The sleep
# turns the same loop into a retry every 5 seconds, which is what heals
# a kiosk once the reason X failed goes away.
# HISTORY: wf-desk, 2026-08-09 — getty@tty1 start-limit-hit, black screen.
if [ "$(tty)" = "/dev/tty1" ] && [ -z "${DISPLAY:-}" ]; then
    startx -- -nocursor || sleep 5
    exit
fi
PROFILE

# ─── Signed in, not just pointed at a login page ──────────────────────
#
# The appliance asked for an admin username and password during setup;
# making the operator type them again at a login form on every fresh boot
# is asking the same question twice. The machine has exactly one user by
# construction, so it signs that user in and lands in the editor.
#
# How, and why this way: WriteFreely's session is an HttpOnly cookie set
# by a form POST to /auth/login, which no script can hand to a browser
# after the fact. So the kiosk opens a local page that submits that exact
# form — alias, pass, and the "to" field the login handler honours — and
# the browser stores the cookie itself, in its own jar, exactly as if a
# human had typed it. Verified against WriteFreely v0.17.1: the POST
# answers 302 to /me/new with a six-month wfu cookie.
#
# The page is a local file, never served: Caddy serves WriteFreely's own
# root on :80 and knows nothing about $wf_home. It is 0600 and owned by
# the session user, which is the same exposure the rendered post-install
# script already carries — one machine, one user, credentials the
# operator chose.
#
# WARN: values are HTML-escaped before they land in an attribute. A
# password containing a quote or an angle bracket would otherwise break
# out of value="..." — the same discipline the script banner demands for
# shell quoting, one layer out.
wf_esc() {
    printf '%s' "$1" |
        sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}
cat >"$wf_home/autologin.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<title>signing in…</title>
<body onload="document.forms[0].submit()">
<form action="http://localhost/auth/login" method="post">
<input type="hidden" name="alias" value="$(wf_esc "$WF_ADMIN_USER")">
<input type="hidden" name="pass" value="$(wf_esc "$WF_ADMIN_PASS")">
<input type="hidden" name="to" value="/me/new">
<noscript><button type="submit">Continue</button></noscript>
</form>
</body>
HTML
chmod 0600 "$wf_home/autologin.html"

# ─── The writing machine only reaches the writing app ────────────────
#
# A kiosk with no address bar, no back button and no tabs is a one-way
# door: WriteFreely's own pages link out to writefreely.org and
# developers.write.as, and one click leaves the operator stranded on the
# public internet with no chrome to navigate back with. Observed exactly
# that — a machine whose whole job is writing, parked on a pricing page,
# with keystrokes going nowhere anybody wanted.
#
# Firefox's enterprise policy fixes it at the browser rather than by
# asking people not to click: everything is blocked except the local app,
# and a Homepage is set so alt+Home always comes back. The policy file is
# read at startup from /etc/firefox-esr/policies on Debian's ESR build.
#
# Note the file:// exception — Firefox's WebsiteFilter does not police
# file:// URLs, and the sign-in page lives there, so it is listed for
# clarity rather than because the filter would otherwise catch it.
mkdir -p /etc/firefox-esr/policies
cat >/etc/firefox-esr/policies/policies.json <<'POLICY'
{
  "policies": {
    "WebsiteFilter": {
      "Block": ["<all_urls>"],
      "Exceptions": ["http://localhost/*", "http://127.0.0.1/*", "file:///*"]
    },
    "Homepage": {
      "URL": "file:///home/writer/autologin.html",
      "StartPage": "homepage",
      "Locked": true
    },
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "DisableProfileImport": true,
    "DisableFirefoxAccounts": true,
    "DisableTelemetry": true,
    "DisablePocket": true,
    "NoDefaultBookmarks": true
  }
}
POLICY

# A way out that is not a desktop. There is deliberately no launcher, no
# taskbar and no window to close — but a machine with no escape hatch is
# a machine you can only fix by destroying it, so tty2 carries an
# ordinary login prompt reachable with ctrl+alt+F2 (ctrl+alt+F1 returns
# to the editor). Power off is the host's job: the VM answers the ACPI
# power button, so "Shut down" in any console does a clean systemd
# poweroff.
systemctl enable getty@tty2.service

# The session. The browser is restarted if it ever exits, because a kiosk
# that can be quit into a black screen is a broken appliance. It opens the
# sign-in page above, which lands on /me/new — the compose view, not the
# public page — and re-establishes the session if it ever expires.
cat >"$wf_home/.xinitrc" <<'XINIT'
#!/bin/sh
xset s off -dpms          # a writing machine must not blank mid-sentence

# Ask for the desktop-sized mode. A virtual GPU has no monitor to ask, so
# it advertises a fixed list that happens NOT to include 2560x1440 (it
# offers 1280x800, 1920x1200, 3840x2160 and friends) and comes up at the
# smallest of them. The mode has to be constructed and added by hand.
#
# gtf, not cvt: cvt is not installed in a Debian cloud image and neither
# is the package that carries it, while gtf ships in x11-xserver-utils,
# which this appliance already installs for xset. Its modeline is quoted
# and xrandr takes the quotes literally into the mode NAME, so they are
# stripped before use — with them left in, --newmode succeeds and every
# later reference fails to find the mode it just made.
#
# Every step may fail without consequence: a writing machine that will
# not start because it could not get the resolution it wanted is worse
# than one at 1280x800.
wf_out=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
if [ -n "$wf_out" ]; then
    wf_ml=$(gtf 2560 1440 60 2>/dev/null |
        sed -n -e 's/^[[:space:]]*Modeline //p' | tr -d '"')
    if [ -n "$wf_ml" ]; then
        wf_mode=$(printf '%s' "$wf_ml" | cut -d' ' -f1)
        # shellcheck disable=SC2086 # a modeline IS a list of arguments
        xrandr --newmode $wf_ml 2>/dev/null
        xrandr --addmode "$wf_out" "$wf_mode" 2>/dev/null
        xrandr --output "$wf_out" --mode "$wf_mode" 2>/dev/null
    fi
fi

unclutter -idle 3 &
matchbox-window-manager -use_titlebar no &
while :; do
    firefox --kiosk "file://$HOME/autologin.html"
    sleep 2
done
XINIT
chmod 0755 "$wf_home/.xinitrc"
chown -R "$wf_desk:$wf_desk" "$wf_home"

# Debian's X is not setuid root; a console user needs this to start it.
if [ -f /etc/X11/Xwrapper.config ]; then
    sed -i '/^allowed_users=/d;/^needs_root_rights=/d' /etc/X11/Xwrapper.config
fi
printf 'allowed_users=anybody\nneeds_root_rights=yes\n' \
    >>/etc/X11/Xwrapper.config

systemctl daemon-reload
systemctl set-default multi-user.target   # no display manager; tty1 owns X
systemctl restart getty@tty1.service

echo "writing desktop ready — the Screen tab boots into the editor"

# One reboot, and only when the kernel actually changed underneath us: the
# running cloud kernel has no DRM, so X cannot come up until the generic
# kernel is the one booted. cloud-init is gated on instance-id and will not
# run this script again, so this cannot become a reboot loop. The blog is
# already installed and enabled, so it comes back on its own.
if [ "${wf_need_reboot:-0}" = 1 ]; then
    echo "rebooting once into the generic kernel — X needs its DRM drivers"
    systemctl reboot
fi
`
