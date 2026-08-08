package main

import (
	"strings"
	"testing"
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
