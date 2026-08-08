// libvirt_xml_test.go — XML parsing against a trimmed real dumpxml: zvol
// disk, file disk, cdrom (skipped), and shut-off memory/vcpu fallbacks.
package main

import "testing"

const sampleXML = `<domain type='kvm'>
  <name>klab-blue-fedora</name>
  <memory unit='KiB'>4194304</memory>
  <currentMemory unit='KiB'>4194304</currentMemory>
  <vcpu placement='static'>2</vcpu>
  <devices>
    <disk type='block' device='disk'>
      <source dev='/dev/zvol/rpool/vms/klab-blue-fedora'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='disk'>
      <source file='/var/lib/libvirt/images/scratch.qcow2'/>
      <target dev='vdb' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <source file='/tmp/seed.iso'/>
      <target dev='sda' bus='sata'/>
    </disk>
  </devices>
</domain>`

func TestParseDomainXML(t *testing.T) {
	info, err := parseDomainXML(sampleXML)
	if err != nil {
		t.Fatal(err)
	}
	if len(info.disks) != 2 {
		t.Fatalf("got %d disks, want 2 (cdrom must be skipped): %+v",
			len(info.disks), info.disks)
	}
	if info.disks[0].Dev != "/dev/zvol/rpool/vms/klab-blue-fedora" ||
		info.disks[0].Target != "vda" {
		t.Errorf("zvol disk wrong: %+v", info.disks[0])
	}
	if info.disks[1].File != "/var/lib/libvirt/images/scratch.qcow2" {
		t.Errorf("file disk wrong: %+v", info.disks[1])
	}
	if info.memKiB != 4194304 || info.vcpus != 2 {
		t.Errorf("mem/vcpu fallback wrong: %d KiB, %d vcpus",
			info.memKiB, info.vcpus)
	}
}

func TestZvolDataset(t *testing.T) {
	if got := zvolDataset("/dev/zvol/rpool/vms/x"); got != "rpool/vms/x" {
		t.Errorf("zvolDataset = %q", got)
	}
	if got := zvolDataset("/var/lib/libvirt/images/x.qcow2"); got != "" {
		t.Errorf("non-zvol path yielded %q", got)
	}
}
