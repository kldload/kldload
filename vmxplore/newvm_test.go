package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// userData must stay valid #cloud-config; the post-install block is the
// part most likely to break it (indentation inside the YAML scalar).
func TestUserDataPostInstall(t *testing.T) {
	s := NewVMSpec{
		Name: "web", User: "admin", Password: "x",
		PostInst: "dnf install -y nginx\nsystemctl enable --now nginx",
	}
	ud := userData(s)
	if !strings.HasPrefix(ud, "#cloud-config\n") {
		t.Fatal("must start with #cloud-config")
	}
	for _, want := range []string{
		"write_files:",
		"path: /var/lib/vmxplore-postinstall.sh",
		"      dnf install -y nginx", // 6-space block indent
		"      systemctl enable --now nginx",
		"runcmd:",
		"[ bash, /var/lib/vmxplore-postinstall.sh ]",
	} {
		if !strings.Contains(ud, want) {
			t.Errorf("post-install cloud-config missing %q in:\n%s", want, ud)
		}
	}
	// no post-install → no runcmd/write_files at all
	if strings.Contains(userData(NewVMSpec{Name: "n", User: "a"}), "runcmd") {
		t.Error("empty post-install must not emit runcmd")
	}
}

// waitZvolNode is the guard on the devtmpfs bug: qemu-img creates a plain
// file at a missing path, so a New VM that raced udev put the guest's
// whole disk in RAM. A non-device at the zvol path must be a hard error,
// never something to overwrite.
func TestWaitZvolNodeRejectsNonDevice(t *testing.T) {
	f := filepath.Join(t.TempDir(), "fake-zvol")
	if err := os.WriteFile(f, []byte("not a block device"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := waitZvolNode(f, func(string) {})
	if err == nil {
		t.Fatal("accepted a regular file as a zvol node")
	}
	if !strings.Contains(err.Error(), "not a block device") {
		t.Errorf("error should name the cause, got: %v", err)
	}
}

// A path that never appears must time out with an actionable message
// rather than hanging or, worse, proceeding.
func TestWaitZvolNodeTimesOut(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "never-appears")
	start := time.Now()
	err := waitZvolNodeFor(missing, 300*time.Millisecond, func(string) {})
	if err == nil {
		t.Fatal("accepted a path that does not exist")
	}
	if !strings.Contains(err.Error(), "did not appear") {
		t.Errorf("error should say the node never appeared, got: %v", err)
	}
	if time.Since(start) < 300*time.Millisecond {
		t.Error("returned without actually waiting")
	}
}

// Whatever /dev/zvol nodes this host already has must be accepted, so the
// guard cannot reject a legitimately-published zvol.
func TestWaitZvolNodeAcceptsRealZvol(t *testing.T) {
	// Datasets nest arbitrarily deep (rpool/vms/<name>), so try each depth
	// rather than assuming a layout.
	var matches []string
	for _, pat := range []string{"/dev/zvol/*/*", "/dev/zvol/*/*/*",
		"/dev/zvol/*/*/*/*"} {
		m, _ := filepath.Glob(pat)
		matches = append(matches, m...)
	}
	var dev string
	for _, m := range matches {
		if fi, err := os.Stat(m); err == nil && fi.Mode()&os.ModeDevice != 0 {
			dev = m
			break
		}
	}
	if dev == "" {
		t.Skip("no zvol block devices on this host")
	}
	if err := waitZvolNode(dev, func(string) {}); err != nil {
		t.Errorf("rejected real zvol %s: %v", dev, err)
	}
}

// TestUserDataAlwaysReachable guards the wf-desk incident (2026-08-09): the
// appliance dialog's guest-login fields were left empty, cloud-init made an
// account with no password and no key, and the finished VM could not be
// entered at the console or over ssh — only destroyed.
func TestUserDataAlwaysReachable(t *testing.T) {
	s := NewVMSpec{Name: "x", Distro: "debian", User: "admin",
		VCPUs: 1, RAMMB: 512, DiskGB: 4}
	ud := userData(s)
	if !strings.Contains(ud, "chpasswd:") ||
		!strings.Contains(ud, DefaultGuestPassword) {
		t.Errorf("no password and no key must fall back to a default:\n%s", ud)
	}
	s.SSHKey = "ssh-ed25519 AAAA test"
	if strings.Contains(userData(s), "chpasswd:") {
		t.Error("a key on its own must not force a password")
	}
	s.SSHKey, s.Password = "", "hunter2"
	if !strings.Contains(userData(s), "hunter2") {
		t.Error("an explicit password must be used verbatim")
	}
}

// TestUserDataQuotesOperatorValues pins the wf-desktop incident
// (2026-08-09): an ssh key whose comment contained a colon —
// "ek-debug: dev login to appliances" — was emitted as a bare YAML
// scalar, parsed as a mapping, and cloud-init threw out the entire users
// block. The VM booted, the app worked, and the key was never installed.
func TestUserDataQuotesOperatorValues(t *testing.T) {
	key := "ssh-ed25519 AAAAC3Nz test ek-debug: dev login to appliances"
	s := NewVMSpec{Name: "x", Distro: "debian", User: "admin",
		Password: `p, w"d}`, SSHKey: key, VCPUs: 1, RAMMB: 512, DiskGB: 4}
	ud := userData(s)
	if !strings.Contains(ud, `- "`+key+`"`) {
		t.Errorf("ssh key must be a quoted scalar:\n%s", ud)
	}
	// the password carries a comma and a brace — both fatal unquoted
	// inside the chpasswd flow mapping
	if !strings.Contains(ud, `password: "p, w\"d}"`) {
		t.Errorf("password must be quoted and escaped:\n%s", ud)
	}
	for _, line := range strings.Split(ud, "\n") {
		if strings.HasPrefix(line, "hostname:") && !strings.Contains(line, `"`) {
			t.Errorf("hostname must be quoted: %q", line)
		}
	}
}
