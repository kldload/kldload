package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// hostileValues are the strings an appliance form must survive. Every one
// of them is a shell metacharacter sequence that would execute if a value
// were ever pasted into the body of a script instead of quoted into a
// variable.
var hostileValues = []string{
	`'; touch /tmp/vmxplore-pwned; #`,
	"$(id)",
	"`id`",
	`" && id && echo "`,
	`back\slash`,
	"it's got a quote",
	"$HOME/../etc/passwd",
	"a'b\"c$d`e\\f",
}

func TestShellSingleQuoteRoundTripsThroughBash(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not available")
	}
	for _, want := range hostileValues {
		// Round-trip through a real shell: whatever we quote must come
		// back byte-identical, and nothing may execute along the way.
		script := "V=" + shellSingleQuote(want) + "\nprintf '%s' \"$V\"\n"
		out, err := exec.Command(bash, "-c", script).Output()
		if err != nil {
			t.Fatalf("bash rejected quoting of %q: %v", want, err)
		}
		if string(out) != want {
			t.Errorf("round-trip mismatch\n  in:  %q\n  out: %q", want, out)
		}
	}
}

// A rendered script must parse. This is the check that catches a broken
// heredoc or an unbalanced quote in a catalog entry before it reaches a
// guest, where the only symptom is a VM that boots without its service.
func TestRenderedScriptsParseAsBash(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not available")
	}
	dir := t.TempDir()
	for _, a := range Appliances() {
		script, err := a.Render(a.Defaults())
		if err != nil {
			t.Fatalf("%s: Render(defaults): %v", a.Name, err)
		}
		path := filepath.Join(dir, a.Name+".sh")
		// The pipeline prepends this preamble in userData(); parsing
		// without it would test a different file than the guest runs.
		body := "#!/usr/bin/env bash\nset -Eeuo pipefail\n" + script
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if out, err := exec.Command(bash, "-n", path).CombinedOutput(); err != nil {
			t.Errorf("%s: bash -n failed: %v\n%s", a.Name, err, out)
		}
	}
}

// bash -n only catches syntax. shellcheck catches the class of bug that
// actually bites an unattended first boot: an unquoted expansion, a
// masked exit status, a variable read before it is set.
func TestRenderedScriptsPassShellcheck(t *testing.T) {
	sc, err := exec.LookPath("shellcheck")
	if err != nil {
		t.Skip("shellcheck not installed")
	}
	dir := t.TempDir()
	for _, a := range Appliances() {
		script, err := a.Render(a.Defaults())
		if err != nil {
			t.Fatalf("%s: Render(defaults): %v", a.Name, err)
		}
		path := filepath.Join(dir, a.Name+".sh")
		body := "#!/usr/bin/env bash\nset -Eeuo pipefail\n" + script
		if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		out, err := exec.Command(sc, "-S", "warning", path).CombinedOutput()
		if err != nil {
			t.Errorf("%s: shellcheck: %v\n%s", a.Name, err, out)
		}
	}
}

// Hostile field values must land in the preamble as inert data. This
// asserts the actual security property rather than the shape of the
// generated text: bash reads the value back unchanged, and the marker
// file a successful injection would create never appears.
func TestRenderKeepsHostileValuesInert(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not available")
	}
	marker := filepath.Join(t.TempDir(), "pwned")
	for _, hostile := range hostileValues {
		vals := writeFreely.Defaults()
		vals["WF_SITE_NAME"] = hostile
		script, err := writeFreely.Render(vals)
		if err != nil {
			t.Fatalf("Render(%q): %v", hostile, err)
		}
		// Keep only the preamble — the body would try to install a real
		// service. The preamble is where injection would have to happen.
		preamble, _, found := strings.Cut(script, "\nWF_VERSION=")
		if !found {
			t.Fatal("rendered script lost its body marker")
		}
		probe := preamble + "\ntouch " + shellSingleQuote(marker) +
			"_never\nprintf '%s' \"$WF_SITE_NAME\"\n"
		out, err := exec.Command(bash, "-c", probe).Output()
		if err != nil {
			t.Fatalf("preamble for %q did not execute: %v", hostile, err)
		}
		if string(out) != hostile {
			t.Errorf("value corrupted\n  in:  %q\n  out: %q", hostile, out)
		}
		if _, err := os.Stat(marker); err == nil {
			t.Fatalf("injection succeeded for %q", hostile)
		}
	}
}

func TestRenderEmitsEveryFieldInOrder(t *testing.T) {
	script, err := writeFreely.Render(writeFreely.Defaults())
	if err != nil {
		t.Fatal(err)
	}
	at := -1
	for _, f := range writeFreely.Fields {
		i := strings.Index(script, "\n"+f.Key+"=")
		if i < 0 {
			t.Fatalf("field %s missing from rendered script", f.Key)
		}
		if i < at {
			t.Errorf("field %s emitted out of order", f.Key)
		}
		at = i
	}
	// The body must follow the assignments, or the script reads empty vars.
	if strings.Index(script, "WF_VERSION=") < at {
		t.Error("script body precedes the field preamble")
	}
}

// A blank Generate field must come back filled, and filled differently
// each time — a shared default password across appliances is exactly the
// failure this field type exists to prevent.
func TestGenerateFieldsProduceFreshSecrets(t *testing.T) {
	vals := writeFreely.Defaults()
	vals["WF_ADMIN_PASS"] = ""
	first, err := writeFreely.resolve(vals)
	if err != nil {
		t.Fatal(err)
	}
	second, err := writeFreely.resolve(vals)
	if err != nil {
		t.Fatal(err)
	}
	if len(first["WF_ADMIN_PASS"]) < 16 {
		t.Errorf("generated password too short: %q", first["WF_ADMIN_PASS"])
	}
	if first["WF_ADMIN_PASS"] == second["WF_ADMIN_PASS"] {
		t.Error("generated password repeated across renders")
	}
}

func TestResolveRejectsBadInput(t *testing.T) {
	cases := []struct {
		name  string
		key   string
		value string
		want  string
	}{
		// The one that matters: every other appliance defaults to "admin",
		// and WriteFreely reserves it. Without this the failure surfaces
		// only in the guest's cloud-init log.
		{"reserved username", "WF_ADMIN_USER", "admin", "reserves"},
		{"reserved username uppercase", "WF_ADMIN_USER", "Admin", "reserves"},
		{"short username", "WF_ADMIN_USER", "ab", "3+ characters"},
		{"username with space", "WF_ADMIN_USER", "matt jones", "3+ characters"},
		{"domain as url", "WF_DOMAIN", "https://blog.example.com", "bare hostname"},
		{"newline in site name", "WF_SITE_NAME", "a\nb", "single line"},
		{"short password", "WF_ADMIN_PASS", "short", "at least 8"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			vals := writeFreely.Defaults()
			vals[tc.key] = tc.value
			_, err := writeFreely.Render(vals)
			if err == nil {
				t.Fatalf("accepted %s=%q", tc.key, tc.value)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error %q does not mention %q", err, tc.want)
			}
		})
	}
}

// A required field with a Default can never be blank — clearing it just
// restores the default. The rule only bites on a required field with
// neither a default nor Generate, so the test needs its own entry.
func TestResolveRequiresRequiredFields(t *testing.T) {
	a := Appliance{
		Name: "test", Distro: "debian", VCPUs: 1, RAMMB: 512, DiskGB: 5,
		Fields: []ApplianceField{
			{Key: "MUST_SET", Label: "must set", Required: true},
			{Key: "OPTIONAL", Label: "optional"},
		},
		Script: "true",
	}
	if _, err := a.Render(map[string]string{"MUST_SET": ""}); err == nil {
		t.Fatal("accepted a blank required field with no default")
	}
	// The optional one may stay empty, and still gets an assignment so
	// the script body can test it without tripping `set -u`.
	script, err := a.Render(map[string]string{"MUST_SET": "x"})
	if err != nil {
		t.Fatalf("rejected a satisfied form: %v", err)
	}
	if !strings.Contains(script, "OPTIONAL=''") {
		t.Errorf("empty optional field not assigned:\n%s", script)
	}
}

// Spec must produce something BuildNewVM will accept — the appliance path
// bypasses the New VM form, so nothing else validates it.
func TestSpecProducesValidNewVMSpec(t *testing.T) {
	for _, a := range Appliances() {
		s, err := a.Spec("blog", "admin", "guestpass", "", a.Defaults())
		if err != nil {
			t.Fatalf("%s: Spec: %v", a.Name, err)
		}
		if s.install() {
			t.Errorf("%s: appliances must build in cloud mode", a.Name)
		}
		if _, ok := cloudImages[s.Distro]; !ok {
			t.Errorf("%s: distro %q is not a cloud preset", a.Name, s.Distro)
		}
		if s.VCPUs < 1 || s.RAMMB < 512 || s.DiskGB < 5 {
			t.Errorf("%s: implausible sizing %+v", a.Name, s)
		}
		if s.PostInst == "" {
			t.Errorf("%s: empty post-install", a.Name)
		}
	}
}

// The rendered script travels inside a cloud-config YAML block scalar, so
// it must survive userData()'s indentation with its content intact.
func TestApplianceScriptSurvivesCloudConfig(t *testing.T) {
	s, err := writeFreely.Spec("blog", "admin", "guestpass", "", writeFreely.Defaults())
	if err != nil {
		t.Fatal(err)
	}
	ud := userData(s)
	if !strings.HasPrefix(ud, "#cloud-config\n") {
		t.Fatal("not a cloud-config")
	}
	for _, line := range strings.Split(s.PostInst, "\n") {
		if line == "" {
			continue
		}
		if !strings.Contains(ud, "      "+line+"\n") {
			t.Fatalf("post-install line lost in cloud-config: %q", line)
		}
	}
}

func TestCatalogEntriesAreWellFormed(t *testing.T) {
	seen := map[string]bool{}
	for _, a := range Appliances() {
		if a.Name == "" || a.Summary == "" {
			t.Errorf("catalog entry missing name or summary: %+v", a.Name)
		}
		if seen[a.Name] {
			t.Errorf("duplicate catalog entry %q", a.Name)
		}
		seen[a.Name] = true
		keys := map[string]bool{}
		for _, f := range a.Fields {
			if !fieldKeyRE.MatchString(f.Key) {
				t.Errorf("%s: field key %q is not a shell variable name", a.Name, f.Key)
			}
			if keys[f.Key] {
				t.Errorf("%s: duplicate field key %q", a.Name, f.Key)
			}
			keys[f.Key] = true
			if f.Label == "" {
				t.Errorf("%s: field %s has no label", a.Name, f.Key)
			}
		}
		if got, ok := ApplianceByName(a.Name); !ok || got.Name != a.Name {
			t.Errorf("ApplianceByName(%q) did not round-trip", a.Name)
		}
	}
	if _, ok := ApplianceByName("no such appliance"); ok {
		t.Error("ApplianceByName invented an entry")
	}
	if len(ApplianceNames()) != len(Appliances()) {
		t.Error("ApplianceNames and Appliances disagree")
	}
}
