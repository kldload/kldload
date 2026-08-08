package main

import "testing"

func TestParseTarget(t *testing.T) {
	cases := []struct {
		in       string
		wantURI  string
		wantSSH  string
		wantHost string
	}{
		{"", "qemu:///system", "", "local"},
		{"local", "qemu:///system", "", "local"},
		{"fiend.unixbox.net", "qemu+ssh://fiend.unixbox.net/system",
			"fiend.unixbox.net", "fiend.unixbox.net"},
		{"admin@fiend", "qemu+ssh://admin@fiend/system", "admin@fiend", "fiend"},
		{"qemu+ssh://root@box/system", "qemu+ssh://root@box/system",
			"root@box", "box"},
		{"qemu:///system", "qemu:///system", "", "local"},
	}
	for _, c := range cases {
		got := ParseTarget(c.in)
		if got.LibvirtURI != c.wantURI || got.SSHHost != c.wantSSH ||
			got.Host != c.wantHost {
			t.Errorf("ParseTarget(%q) = %+v, want uri=%q ssh=%q host=%q",
				c.in, got, c.wantURI, c.wantSSH, c.wantHost)
		}
	}
}

// virsh() and zfsArgv() must route through the target.
func TestArgvRouting(t *testing.T) {
	defer func() { target = Target{LibvirtURI: "qemu:///system", Host: "local"} }()

	target = ParseTarget("local")
	if v := virsh("start", "x"); v[2] != "qemu:///system" {
		t.Errorf("local virsh uri = %q", v[2])
	}
	if z := zfsArgv("list"); z[0] != "zfs" {
		t.Errorf("local zfs = %v", z)
	}

	target = ParseTarget("admin@box")
	if v := virsh("start", "x"); v[2] != "qemu+ssh://admin@box/system" {
		t.Errorf("remote virsh uri = %q", v[2])
	}
	if z := zfsArgv("list"); z[0] != "ssh" || z[1] != "admin@box" || z[2] != "zfs" {
		t.Errorf("remote zfs = %v", z)
	}
	if vncDialHost() != "box" {
		t.Errorf("remote vnc host = %q", vncDialHost())
	}
}
