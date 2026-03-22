# KVM Virtual Machines on kldload

kldload systems make excellent KVM hypervisors — ZFS gives you instant snapshots, CoW cloning, and compression for VM disk images.

Works the same on CentOS/RHEL and Debian.

---

## Install KVM

### CentOS/RHEL

```bash
kpkg install qemu-kvm libvirt virt-install libguestfs-tools
systemctl enable --now libvirtd
```

### Debian

```bash
kpkg install qemu-kvm libvirt-daemon-system virtinst libguestfs-tools
systemctl enable --now libvirtd
```

### Verify

```bash
virsh list --all
virt-host-validate
```

---

## Set up ZFS storage for VMs

```bash
# Create a dataset for VM images
zfs create -o mountpoint=/var/lib/libvirt/images \
           -o compression=lz4 \
           -o recordsize=64k \
           rpool/vms
```

`recordsize=64k` is a good balance for VM disk I/O (mix of small and large operations).

---

## Create a VM from the kldload ISO

```bash
ISO=$(ls -t ~/kldload-free/live-build/output/*.iso 2>/dev/null | head -1)

virt-install \
  --name my-server \
  --ram 4096 \
  --vcpus 4 \
  --disk path=/var/lib/libvirt/images/my-server.qcow2,size=40,format=qcow2 \
  --cdrom "$ISO" \
  --os-variant centos-stream9 \
  --network bridge=br0 \
  --graphics vnc,listen=0.0.0.0 \
  --boot uefi \
  --noautoconsole
```

Connect via VNC to complete the install:

```bash
virsh vncdisplay my-server
# :0  → connect to host:5900
```

---

## Create a VM from a cloud image

### CentOS Stream 9

```bash
curl -LO https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2
cp CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2 /var/lib/libvirt/images/centos-cloud.qcow2

# Resize the disk
qemu-img resize /var/lib/libvirt/images/centos-cloud.qcow2 40G

# Set a root password with virt-customize
virt-customize -a /var/lib/libvirt/images/centos-cloud.qcow2 \
  --root-password password:changeme \
  --hostname my-centos-vm

virt-install \
  --name centos-cloud \
  --ram 2048 --vcpus 2 \
  --disk /var/lib/libvirt/images/centos-cloud.qcow2 \
  --os-variant centos-stream9 \
  --network bridge=br0 \
  --boot uefi \
  --import --noautoconsole
```

### Debian

```bash
curl -LO https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-generic-amd64-daily.qcow2
cp debian-13-generic-amd64-daily.qcow2 /var/lib/libvirt/images/debian-cloud.qcow2
qemu-img resize /var/lib/libvirt/images/debian-cloud.qcow2 40G

virt-customize -a /var/lib/libvirt/images/debian-cloud.qcow2 \
  --root-password password:changeme \
  --hostname my-debian-vm

virt-install \
  --name debian-cloud \
  --ram 2048 --vcpus 2 \
  --disk /var/lib/libvirt/images/debian-cloud.qcow2 \
  --os-variant debian12 \
  --network bridge=br0 \
  --boot uefi \
  --import --noautoconsole
```

---

## Golden images and CoW cloning

Create one base image, then clone it instantly for each new VM:

### Build the golden image

```bash
# Install a VM, configure it how you want, then shut it down
virsh shutdown my-server

# Generalize it (remove machine-specific state)
virt-sysprep -d my-server \
  --operations defaults,-ssh-userdir \
  --hostname localhost

# Mark it as a template (prevent accidental boot)
virsh dominfo my-server
```

### Clone with qemu-img (fastest)

```bash
# CoW clone — near-instant, near-zero space
qemu-img create -f qcow2 \
  -b /var/lib/libvirt/images/my-server.qcow2 \
  -F qcow2 \
  /var/lib/libvirt/images/web-1.qcow2

# Register the clone as a new VM
virt-install \
  --name web-1 \
  --ram 2048 --vcpus 2 \
  --disk /var/lib/libvirt/images/web-1.qcow2 \
  --os-variant centos-stream9 \
  --network bridge=br0 \
  --boot uefi \
  --import --noautoconsole
```

### Clone with virt-clone (copies everything)

```bash
# Full copy (slower but independent — no backing file dependency)
virt-clone \
  --original my-server \
  --name web-2 \
  --auto-clone
```

### Customize after cloning

```bash
# Set unique hostname on the clone
virt-customize -d web-1 --hostname web-1.infra.local

# Or SSH in after boot:
virsh start web-1
ssh root@<ip> hostnamectl set-hostname web-1.infra.local
```

---

## Snapshots

### ZFS-level snapshots (recommended)

Faster and more reliable than libvirt snapshots:

```bash
# Snapshot a VM's disk
zfs snapshot rpool/vms@web-1-before-update

# Roll back
virsh shutdown web-1
zfs rollback rpool/vms@web-1-before-update
virsh start web-1
```

### Libvirt snapshots

```bash
# Create
virsh snapshot-create-as web-1 --name before-update --description "pre-update snapshot"

# List
virsh snapshot-list web-1

# Revert
virsh snapshot-revert web-1 before-update

# Delete
virsh snapshot-delete web-1 before-update
```

---

## VM lifecycle

```bash
# Start / stop / restart
virsh start web-1
virsh shutdown web-1       # graceful
virsh destroy web-1        # force stop (like pulling the power cord)
virsh reboot web-1

# Pause / resume
virsh suspend web-1
virsh resume web-1

# Auto-start on host boot
virsh autostart web-1
virsh autostart --disable web-1

# Delete VM and its disk
virsh undefine web-1 --nvram --remove-all-storage

# Console access
virsh console web-1        # serial console (Ctrl+] to exit)
```

---

## Resource management

```bash
# Change RAM (requires shutdown)
virsh setmaxmem web-1 8G --config
virsh setmem web-1 8G --config

# Change vCPUs (requires shutdown)
virsh setvcpus web-1 4 --config --maximum
virsh setvcpus web-1 4 --config

# Hot-add a disk
qemu-img create -f qcow2 /var/lib/libvirt/images/web-1-data.qcow2 100G
virsh attach-disk web-1 /var/lib/libvirt/images/web-1-data.qcow2 vdb \
  --driver qemu --subdriver qcow2 --persistent

# Hot-add a network interface
virsh attach-interface web-1 bridge br0 --model virtio --persistent
```

---

## Monitoring

```bash
# List all VMs with state
virsh list --all

# CPU/memory stats
virt-top

# Disk I/O stats
virsh domblkstat web-1 vda

# Network stats
virsh domifstat web-1 vnet0

# Get IP address of a VM (requires qemu-guest-agent)
virsh domifaddr web-1
```

---

## Migrate VMs between hosts

```bash
# Live migration (VM stays running)
virsh migrate --live web-1 qemu+ssh://other-host/system

# Offline migration (VM is shut down)
virsh shutdown web-1
# Copy the disk over ZFS send/receive:
zfs snapshot rpool/vms@migrate
zfs send rpool/vms@migrate | ssh other-host zfs receive tank/vms
# Then define the VM on the other host
```

---

## Troubleshooting

```bash
# VM won't start — check logs
virsh start web-1 2>&1
journalctl -u libvirtd --since "5 minutes ago"
cat /var/log/libvirt/qemu/web-1.log

# Permission denied on disk
ls -la /var/lib/libvirt/images/web-1.qcow2
# Should be owned by qemu:qemu (CentOS) or libvirt-qemu:kvm (Debian)
chown qemu:qemu /var/lib/libvirt/images/web-1.qcow2  # CentOS
chown libvirt-qemu:kvm /var/lib/libvirt/images/web-1.qcow2  # Debian

# SELinux blocking (CentOS only)
ausearch -m avc --ts recent
restorecon -Rv /var/lib/libvirt/images/
```
