// verbs_test.go — the plan builders are the safety layer; test the gates.
package main

import (
	"os/exec"
	"strings"
	"testing"
)

func runningRow() Row {
	return Row{D: Dom{Name: "klab-blue-fedora", State: "running",
		Persistent: true, VCPUs: 1, MaxMemKiB: 384 * 1024},
		DS: &Dataset{Name: "rpool/vms/klab-blue-fedora", Type: "volume"}}
}

func offRow() Row {
	r := runningRow()
	r.D.State = "shut off"
	return r
}

func TestPlanStartAndShutdownGates(t *testing.T) {
	if _, err := planStart(runningRow()); err == nil {
		t.Error("start of a running domain must refuse")
	}
	p, err := planStart(offRow())
	if err != nil || strings.Join(p.cmds[0], " ") != "virsh -c qemu:///system start klab-blue-fedora" {
		t.Errorf("start plan wrong: %v %v", p.cmds, err)
	}
	if _, err := planShutdown(offRow()); err == nil {
		t.Error("shutdown of a stopped domain must refuse")
	}
}

func TestPlanForceOffGates(t *testing.T) {
	p, err := planForceOff(runningRow())
	if err != nil {
		t.Fatal(err)
	}
	if p.retype != "klab-blue-fedora" {
		t.Error("force-off must retype-gate on the domain name")
	}
	// the webui lesson: destroy on a transient domain erases it
	tr := runningRow()
	tr.D.Persistent = false
	if _, err := planForceOff(tr); err == nil {
		t.Error("force-off of a transient domain must refuse")
	}
}

func TestPlanSnapshot(t *testing.T) {
	p, err := planSnapshot(offRow(), "before-upgrade")
	if err != nil {
		t.Fatal(err)
	}
	want := "zfs snapshot rpool/vms/klab-blue-fedora@manual-before-upgrade"
	if strings.Join(p.cmds[0], " ") != want {
		t.Errorf("snapshot cmd = %v", p.cmds[0])
	}
	if !p.needsRoot {
		t.Error("zfs snapshot must be marked needsRoot")
	}
	if _, err := planSnapshot(offRow(), "bad name"); err == nil {
		t.Error("snapshot suffix with a space must refuse")
	}
	if p, _ := planSnapshot(runningRow(), "x"); p.warn == "" {
		t.Error("running-domain snapshot must warn crash-consistent")
	}
}

func TestPlanRollbackGates(t *testing.T) {
	if _, err := planRollback(runningRow(), "manual-x", 3); err == nil {
		t.Error("rollback of a running domain must refuse")
	}
	p, err := planRollback(offRow(), "manual-x", 3)
	if err != nil {
		t.Fatal(err)
	}
	if p.retype == "" || !strings.Contains(p.warn, "3 snapshot") {
		t.Errorf("rollback gates wrong: retype=%q warn=%q", p.retype, p.warn)
	}
	want := "zfs rollback -r rpool/vms/klab-blue-fedora@manual-x"
	if strings.Join(p.cmds[0], " ") != want {
		t.Errorf("rollback cmd = %v", p.cmds[0])
	}
}

func TestPlanSpecs(t *testing.T) {
	p, err := planSpecs(offRow(), 4, 8)
	if err != nil {
		t.Fatal(err)
	}
	joined := ""
	for _, c := range p.cmds {
		joined += strings.Join(c, " ") + ";"
	}
	for _, want := range []string{
		"virsh -c qemu:///system setvcpus klab-blue-fedora 4 --config --maximum",
		"virsh -c qemu:///system setvcpus klab-blue-fedora 4 --config",
		"virsh -c qemu:///system setmaxmem klab-blue-fedora 8G --config",
		"virsh -c qemu:///system setmem klab-blue-fedora 8G --config",
	} {
		if !strings.Contains(joined, want+";") {
			t.Errorf("specs plan missing %q in %s", want, joined)
		}
	}
	if _, err := planSpecs(offRow(), 0, 8); err == nil {
		t.Error("0 vcpus must refuse")
	}
	if p, _ := planSpecs(runningRow(), 2, 4); p.warn == "" {
		t.Error("running-domain spec change must warn next-start")
	}
}

func TestPlanClone(t *testing.T) {
	if _, err := exec.LookPath("virt-clone"); err != nil {
		t.Skip("virt-clone not installed on this host")
	}
	p, err := planClone(offRow(), "klab-copy")
	if err != nil {
		t.Fatal(err)
	}
	joined := ""
	for _, c := range p.cmds {
		joined += strings.Join(c, " ") + ";"
	}
	for _, want := range []string{
		"zfs snapshot rpool/vms/klab-blue-fedora@clone-klab-copy",
		"zfs clone rpool/vms/klab-blue-fedora@clone-klab-copy rpool/vms/klab-copy",
		"virt-clone --connect qemu:///system --original klab-blue-fedora" +
			" --name klab-copy --preserve-data --file /dev/zvol/rpool/vms/klab-copy",
	} {
		if !strings.Contains(joined, want+";") {
			t.Errorf("clone plan missing %q in %s", want, joined)
		}
	}
	if !p.needsRoot {
		t.Error("clone must be marked needsRoot (zfs)")
	}
	if _, err := planClone(offRow(), "bad name"); err == nil {
		t.Error("clone name with a space must refuse")
	}
	if _, err := planClone(offRow(), "klab-blue-fedora"); err == nil {
		t.Error("clone onto the source name must refuse")
	}
	noDS := offRow()
	noDS.DS = nil
	if _, err := planClone(noDS, "x"); err == nil {
		t.Error("clone without a dataset must refuse")
	}
}

func TestPlanAutostartToggle(t *testing.T) {
	p, _ := planAutostart(offRow())
	if strings.Join(p.cmds[0], " ") != "virsh -c qemu:///system autostart klab-blue-fedora" {
		t.Errorf("autostart enable cmd = %v", p.cmds[0])
	}
	on := offRow()
	on.D.Autostart = true
	p, _ = planAutostart(on)
	if strings.Join(p.cmds[0], " ") != "virsh -c qemu:///system autostart --disable klab-blue-fedora" {
		t.Errorf("autostart disable cmd = %v", p.cmds[0])
	}
}
