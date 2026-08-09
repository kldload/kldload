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
