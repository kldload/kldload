// setup.go — turn the machine you are on into a hypervisor.
//
// What it does, in order:
//  1. Reads /etc/os-release and picks the package manager for this distro.
//  2. PRINTS every command it is about to run, in order, before running
//     any of them.
//  3. Installs the KVM stack, enables libvirtd, starts and autostarts the
//     default network, and adds the operator to the libvirt group.
//  4. Says plainly what still needs a human — the group does not take
//     effect until the next login.
//
// Why: the gap between "this tool is good" and "this tool gets used" was
// never a missing feature. It was a README with six packages and a
// toolchain, standing between a stranger and the first screen. A static
// binary that can make its own substrate turns that into: download it,
// run it, answer one question.
//
// Inputs:  /etc/os-release, and sudo if not already root.
// Outputs: a host that can run VMs, or a loud explanation of what failed.
//
// Notes: this is deliberately the SAME package list the manual documents,
// so the two cannot drift into disagreeing about what a hypervisor needs.
// Nothing here is kldload-specific: it is the stock KVM stack every
// distribution ships.
package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// setupPlan is one distro's answer to "make this a hypervisor".
type setupPlan struct {
	Family   string   // what we detected, for the operator to sanity-check
	Install  []string // the package-manager argv, packages included
	Packages []string // listed separately so the summary can name them
}

// osRelease reads ID and ID_LIKE, the two fields that actually identify a
// distribution's family. Returns empty strings when the file is missing,
// which is itself an answer: an unknown system gets manual instructions
// rather than a guessed package manager.
func osRelease() (id, like string) {
	f, err := os.Open("/etc/os-release")
	if err != nil {
		return "", ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		v := strings.Trim(strings.TrimPrefix(line[strings.IndexByte(line, '=')+1:], "="), `"`)
		switch {
		case strings.HasPrefix(line, "ID="):
			id = v
		case strings.HasPrefix(line, "ID_LIKE="):
			like = v
		}
	}
	return id, like
}

// planSetup maps a distribution onto its KVM stack.
//
// The package sets are not interchangeable guesses — each is the stock
// virtualisation stack that distribution ships, plus the one thing New VM
// needs that is easy to forget: a tool that can write an ISO9660 image for
// the cloud-init seed. Without it every cloud-image build fails at the
// last step with a message about mkisofs.
func planSetup(id, like string) (setupPlan, bool) {
	has := func(names ...string) bool {
		for _, n := range names {
			if id == n || strings.Contains(like, n) {
				return true
			}
		}
		return false
	}
	switch {
	case has("debian", "ubuntu"):
		pk := []string{
			"qemu-system-x86", "qemu-utils", "libvirt-daemon-system",
			"libvirt-clients", "virtinst", "xorriso",
		}
		return setupPlan{
			Family:   "debian",
			Packages: pk,
			Install:  append([]string{"apt-get", "install", "-y"}, pk...),
		}, true
	case has("fedora", "rhel", "centos", "rocky", "almalinux"):
		pk := []string{
			"qemu-kvm", "libvirt", "libvirt-client", "virt-install", "xorriso",
		}
		return setupPlan{
			Family:   "rhel",
			Packages: pk,
			Install:  append([]string{"dnf", "install", "-y"}, pk...),
		}, true
	case has("arch"):
		pk := []string{"qemu-full", "libvirt", "virt-install", "xorriso"}
		return setupPlan{
			Family:   "arch",
			Packages: pk,
			Install:  append([]string{"pacman", "-S", "--needed", "--noconfirm"}, pk...),
		}, true
	case has("suse", "opensuse"):
		pk := []string{"qemu-kvm", "libvirt", "libvirt-client", "virt-install", "xorriso"}
		return setupPlan{
			Family:   "suse",
			Packages: pk,
			Install:  append([]string{"zypper", "--non-interactive", "install"}, pk...),
		}, true
	}
	return setupPlan{}, false
}

// RunSetup installs the KVM stack. It is the --setup subcommand.
//
// Every command is printed before the first one runs. That is the same
// contract every verb in this tool keeps: nothing happens that the
// operator could not have typed, and they see it first.
func RunSetup() int {
	id, like := osRelease()
	plan, ok := planSetup(id, like)
	if !ok {
		fmt.Fprintf(os.Stderr,
			"vmxplore: unrecognised distribution (ID=%q ID_LIKE=%q).\n\n"+
				"Install these by hand and re-run:\n"+
				"  qemu-kvm  libvirt  libvirt-clients  virt-install  xorriso\n"+
				"then: systemctl enable --now libvirtd\n", id, like)
		return 1
	}

	sudo := []string{}
	if os.Geteuid() != 0 {
		sudo = []string{"sudo"}
	}

	// Refreshing the index first matters on a fresh cloud image, where the
	// package lists can be older than the archive and an install resolves
	// to nothing.
	var refresh []string
	switch plan.Family {
	case "debian":
		refresh = []string{"apt-get", "update"}
	case "rhel":
		refresh = []string{"dnf", "makecache"}
	case "suse":
		refresh = []string{"zypper", "--non-interactive", "refresh"}
	}

	user := os.Getenv("SUDO_USER")
	if user == "" {
		user = os.Getenv("USER")
	}

	steps := [][]string{}
	if len(refresh) > 0 {
		steps = append(steps, refresh)
	}
	steps = append(steps,
		plan.Install,
		[]string{"systemctl", "enable", "--now", "libvirtd"},
		[]string{"virsh", "-c", "qemu:///system", "net-autostart", "default"},
		[]string{"virsh", "-c", "qemu:///system", "net-start", "default"},
	)
	if user != "" && user != "root" {
		steps = append(steps, []string{"usermod", "-aG", "libvirt", user})
	}

	fmt.Printf("vmxplore --setup: making this %s host a hypervisor.\n\n", plan.Family)
	fmt.Println("These commands will run, in order:")
	for _, s := range steps {
		fmt.Printf("  $ %s\n", strings.Join(append(append([]string{}, sudo...), s...), " "))
	}
	fmt.Println()

	for _, s := range steps {
		argv := append(append([]string{}, sudo...), s...)
		fmt.Printf("→ %s\n", strings.Join(argv, " "))
		cmd := exec.Command(argv[0], argv[1:]...)
		cmd.Stdout, cmd.Stderr, cmd.Stdin = os.Stdout, os.Stderr, os.Stdin
		if err := cmd.Run(); err != nil {
			// The network steps are allowed to fail: on a host where the
			// default network already runs, net-start returns non-zero and
			// that is success by any useful definition. Everything else is
			// fatal, because a half-installed hypervisor that reports
			// success is worse than one that stops.
			if len(s) > 1 && s[0] == "virsh" {
				fmt.Printf("  (already done — continuing)\n")
				continue
			}
			fmt.Fprintf(os.Stderr, "\nvmxplore: %s failed: %v\n", s[0], err)
			return 1
		}
	}

	fmt.Println("\nDone. This host can run VMs.")
	if user != "" && user != "root" {
		fmt.Printf("\nOne thing left, and it needs you: %s was added to the\n"+
			"libvirt group, which does not take effect until the next login.\n"+
			"Log out and back in, or run `newgrp libvirt` in this shell.\n", user)
	}
	fmt.Println("\nThen: vmxplore   (or `vmx --tui` on a headless box)")
	return 0
}
