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
	"os"
	"regexp"
	"strings"
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

// applianceFlags are the non-KEY=VALUE options --appliance accepts. They
// describe the *guest* (its login), never the app — app configuration is
// the catalog entry's Fields, so the flag set never grows per appliance.
type applianceFlags struct {
	vm       string
	user     string
	password string
	sshKey   string
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

	err = BuildNewVM(spec, parent, func(line string) {
		fmt.Fprintln(os.Stderr, line)
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "vmx: %v\n", err)
		return 1
	}
	fmt.Fprintf(os.Stderr, "\n%s is building %s. First boot installs and\n"+
		"configures it — give it a few minutes, then it serves on:\n",
		spec.Name, a.Name)
	fmt.Println(a.LandsOn)
	fmt.Fprintf(os.Stderr, "Credentials land in /root/ inside the guest.\n")
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

var applianceCatalog = []Appliance{writeFreely}

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
