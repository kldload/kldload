// newvm_live_test.go — the New VM pipeline, end to end, against the real
// host. Gated behind VMX_NEWVM_E2E=1: it creates (and fully removes) a
// scratch domain, uses sudo -n, and boots a guest — not CI material, but
// exactly what "the pipeline works" must mean before anyone claims it.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestNewVMPipelineE2E(t *testing.T) {
	if os.Getenv("VMX_NEWVM_E2E") != "1" {
		t.Skip("set VMX_NEWVM_E2E=1 to run the create-a-real-VM test")
	}
	lv, err := ConnectSystem()
	if err != nil {
		t.Skipf("no libvirt: %v", err)
	}
	defer lv.Close()

	const name = "vmx-e2e"
	cleanup := func() {
		exec.Command("virsh", "-c", "qemu:///system", "destroy", name).Run()
		exec.Command("virsh", "-c", "qemu:///system", "undefine", name, "--nvram").Run()
		exec.Command("sudo", "-n", "zfs", "destroy", "-r", "rpool/vms/"+name).Run()
		exec.Command("sudo", "-n", "rm", "-f",
			"/var/lib/libvirt/images/"+name+"-seed.iso").Run()
	}
	cleanup() // a previous failed run must not wedge this one
	defer cleanup()

	spec := NewVMSpec{
		Name: name, Distro: "fedora",
		VCPUs: 1, RAMMB: 1024, DiskGB: 5,
		User: "admin", Password: "vmx-e2e-test",
	}
	var log []string
	if err := BuildNewVM(spec, "rpool/vms", func(s string) {
		log = append(log, s)
		t.Log(s)
	}); err != nil {
		t.Fatalf("pipeline: %v\n%s", err, strings.Join(log, "\n"))
	}

	// the domain must exist, be persistent, and be running
	out, err := exec.Command("virsh", "-c", "qemu:///system",
		"domstate", name).Output()
	if err != nil || !strings.Contains(string(out), "running") {
		t.Fatalf("domstate after create: %q %v", out, err)
	}
	pers, _ := exec.Command("virsh", "-c", "qemu:///system",
		"dominfo", name).Output()
	if !strings.Contains(string(pers), "Persistent:     yes") {
		t.Fatalf("domain is not persistent — the transient bug is back:\n%s", pers)
	}
	// give the guest a moment before the deferred teardown yanks it
	time.Sleep(2 * time.Second)
	fmt.Println("E2E OK:", name, "created, running, persistent")
}
