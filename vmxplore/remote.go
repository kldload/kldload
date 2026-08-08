// remote.go — the connection target: local or a remote host over ssh.
//
// vmxplore reads the estate through go-libvirt (which speaks qemu+ssh://
// natively over a pure-Go dialer — no cgo, the static story holds). But
// the verbs, the consoles and the ZFS join shell out to virsh/zfs/vnc, and
// those must run WHERE THE HYPERVISOR IS. This file centralizes that: one
// Target, set at connect, that every exec path consults.
//
//	local:   virsh -c qemu:///system … ; zfs … ; vnc 127.0.0.1:port
//	remote:  virsh -c qemu+ssh://host/system … ; ssh host zfs … ;
//	         vnc <host>:port   (kldload guests listen 0.0.0.0 by design)
//
// Why one global rather than threading a handle: the whole GUI/TUI is a
// single connection at a time; a global set once at connect keeps the verb
// plan builders pure (they call virsh()/zfsArgv() without carrying state)
// and is trivially correct for the one-connection model. Reconnecting to a
// different host re-sets it.
//
// Notes: the ssh host is parsed from the libvirt URI's user@host, so a
// working `virsh -c qemu+ssh://…` implies working `ssh host` — same key,
// same known_hosts. VNC over a remote host needs the guest's VNC port
// reachable (kldload's virt-install uses listen=0.0.0.0); a future step is
// an ssh -L tunnel for locked-down hosts.
package main

import (
	"net/url"
	"os"
	"strings"
	"syscall"
)

// reexec replaces the current process with argv[0] argv[1:], inheriting the
// environment — used by the GUI's Connect button to relaunch pointed at a
// different host (a live reconnect would have to rebuild every pane).
func reexec(exe string, argv []string) error {
	return syscall.Exec(exe, argv, os.Environ())
}

// Target is where operations run.
type Target struct {
	LibvirtURI string // qemu:///system  |  qemu+ssh://user@host/system
	SSHHost    string // "" local; "user@host" remote (zfs, future tunnels)
	Host       string // display: "local" or "host"
}

// target is the process-wide connection, set by ConnectTarget. Defaults to
// local so non-GUI paths and tests need no setup.
var target = Target{LibvirtURI: "qemu:///system", Host: "local"}

// ParseTarget turns a user-typed destination into a Target. Accepts a bare
// host ("fiend.unixbox.net" → qemu+ssh://fiend.unixbox.net/system), a
// user@host, or a full libvirt URI. Empty or "local" stays local.
func ParseTarget(s string) Target {
	s = strings.TrimSpace(s)
	if s == "" || s == "local" || s == "qemu:///system" {
		return Target{LibvirtURI: "qemu:///system", Host: "local"}
	}
	if strings.Contains(s, "://") {
		t := Target{LibvirtURI: s, Host: s}
		if u, err := url.Parse(s); err == nil && strings.Contains(u.Scheme, "ssh") {
			t.SSHHost = u.Host // user@host:port form preserved by url.User+Host
			if u.User != nil {
				t.SSHHost = u.User.Username() + "@" + u.Host
			}
			t.Host = u.Hostname()
		}
		return t
	}
	// bare host or user@host → ssh transport to /system
	host := s
	if i := strings.IndexByte(s, '@'); i >= 0 {
		host = s[i+1:]
	}
	return Target{
		LibvirtURI: "qemu+ssh://" + s + "/system",
		SSHHost:    s,
		Host:       host,
	}
}

// virsh builds a virsh argv pinned to the target's libvirt URI — the
// connection the whole tool reads from. Bare virsh as a non-root
// libvirt-group user defaults to qemu:///session (an empty estate); the
// explicit -c also carries us to a remote host unchanged.
func virsh(args ...string) []string {
	return append([]string{"virsh", "-c", target.LibvirtURI}, args...)
}

// zfsArgv builds a zfs argv that runs on the hypervisor: locally when the
// target is local, over ssh when remote (the pool lives on the remote box,
// not here).
func zfsArgv(args ...string) []string {
	if target.SSHHost == "" {
		return append([]string{"zfs"}, args...)
	}
	return append([]string{"ssh", target.SSHHost, "zfs"}, args...)
}

// vncDialHost is where the RFB client connects for a guest's VNC port:
// loopback locally, the hypervisor host when remote.
func vncDialHost() string {
	if target.Host == "local" || target.SSHHost == "" {
		return "127.0.0.1"
	}
	h := target.Host
	if i := strings.IndexByte(target.SSHHost, '@'); i >= 0 {
		h = target.SSHHost[i+1:]
	}
	// strip any :port from the ssh host spec
	if i := strings.IndexByte(h, ':'); i >= 0 {
		h = h[:i]
	}
	return h
}
