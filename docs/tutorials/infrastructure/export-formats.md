# Export Formats

kldload includes `kexport` — a tool that converts a running ZFS-on-root system into portable disk images for any hypervisor or cloud platform.

---

## Quick reference

```bash
# Export to a specific format
kexport qcow2       # KVM / Proxmox / OpenStack
kexport raw          # dd-ready sparse image
kexport vhd          # Azure / Hyper-V
kexport vmdk         # VMware ESXi / vSphere
kexport ova          # VMware / VirtualBox portable

# Export all formats at once
kexport all

# Custom output name
KEXPORT_NAME=myserver kexport qcow2
# → myserver.qcow2
```

Output lands in the current directory. Files are named `kldload-export-YYYYMMDD-HHMMSS.<ext>` by default. Images can also be SCP'd directly to a remote host and sealed as golden images with cloud-init for template cloning.

---

## Formats in detail

### qcow2 — QEMU Copy-On-Write

```bash
kexport qcow2
```

- **Use with:** KVM, Proxmox, OpenStack, libvirt
- **Features:** Compressed, sparse, supports snapshots
- **Typical size:** 3–6GB (from a 40GB disk)

Import into Proxmox:

```bash
# SCP to Proxmox host
scp kldload-export-*.qcow2 root@proxmox:/var/lib/vz/images/

# Import as a new disk (on Proxmox host)
qm importdisk 100 /var/lib/vz/images/kldload-export-*.qcow2 local-lvm
```

Import into libvirt/KVM:

```bash
cp kldload-export-*.qcow2 /var/lib/libvirt/images/my-server.qcow2

virt-install \
  --name my-server \
  --ram 4096 --vcpus 4 \
  --disk path=/var/lib/libvirt/images/my-server.qcow2 \
  --os-variant centos-stream9 \
  --boot uefi \
  --import --noautoconsole
```

---

### raw — Sparse disk image

```bash
kexport raw
```

- **Use with:** `dd` to physical disk, any hypervisor, cloud providers that accept raw
- **Features:** Sparse (doesn't consume full disk size on filesystem)
- **Typical size:** Sparse file reports full size but uses only written blocks

Write to a physical disk:

```bash
dd if=kldload-export-*.raw of=/dev/sda bs=4M status=progress conv=sparse oflag=sync
sync
```

Convert to any other format later with `qemu-img`:

```bash
qemu-img convert -f raw -O qcow2 kldload-export-*.raw output.qcow2
```

---

### vhd — Virtual Hard Disk

```bash
kexport vhd
```

- **Use with:** Microsoft Azure, Hyper-V, VirtualBox
- **Features:** Fixed subformat (required by Azure)
- **Typical size:** Full disk size (fixed format, not sparse)

Upload to Azure:

```bash
# Install Azure CLI
az login

# Create a managed disk from VHD
az disk create \
  --resource-group mygroup \
  --name kldload-disk \
  --source kldload-export-*.vhd \
  --os-type Linux

# Create VM from the disk
az vm create \
  --resource-group mygroup \
  --name kldload-vm \
  --attach-os-disk kldload-disk \
  --os-type Linux \
  --size Standard_B2ms
```

Import into Hyper-V (PowerShell):

```powershell
New-VM -Name "kldload" -MemoryStartupBytes 4GB -Generation 2
Add-VMHardDiskDrive -VMName "kldload" -Path "C:\VMs\kldload-export.vhd"
```

---

### vmdk — VMware Virtual Machine Disk

```bash
kexport vmdk
```

- **Use with:** VMware ESXi, vSphere, Workstation, Fusion
- **Features:** streamOptimized subformat (efficient for transfer)
- **Typical size:** 3–6GB compressed

Upload to ESXi datastore:

```bash
scp kldload-export-*.vmdk root@esxi:/vmfs/volumes/datastore1/kldload/

# On ESXi, convert streamOptimized to thick/thin:
vmkfstools -i kldload-export-*.vmdk -d thin kldload-disk.vmdk
```

Or import via vSphere UI: **New VM → Custom → Existing disk → Upload VMDK**

---

### ova — Open Virtual Appliance

```bash
kexport ova
```

- **Use with:** VMware, VirtualBox, any OVF-compatible hypervisor
- **Features:** Self-contained tarball with OVF metadata + VMDK disk
- **Typical size:** 3–6GB

The OVA bundles:
- `kldload.ovf` — VM configuration (CPU, RAM, disk, OS type)
- `kldload-disk.vmdk` — The disk image

Import into VirtualBox:

```bash
VBoxManage import kldload-export-*.ova
VBoxManage startvm kldload --type headless
```

Import into VMware Workstation: **File → Open → select .ova**

---

## Export all formats

```bash
kexport all
```

Produces all five formats sequentially. Useful for publishing releases that cover every hypervisor.

---

## How it works under the hood

`kexport` uses `qemu-img convert` for all format conversions:

```
Source: /dev/zd0 (or ZFS zvol) or block device snapshot
  │
  ├─→ qcow2:  qemu-img convert -c -f raw -O qcow2
  ├─→ raw:    qemu-img convert -f raw -O raw (sparse via conv=sparse)
  ├─→ vhd:    qemu-img convert -f raw -O vpc -o subformat=fixed
  ├─→ vmdk:   qemu-img convert -f raw -O vmdk -o subformat=streamOptimized
  └─→ ova:    vmdk + OVF XML descriptor → tar
```

The OVF descriptor includes hardware hints: 4 vCPUs, 4GB RAM, 1 SCSI disk, UEFI boot. These are defaults — the importing hypervisor lets you override them.

---

## Snapshot before export

Always snapshot before exporting to ensure a consistent image:

```bash
# Snapshot the entire root pool
ksnap /

# Then export
kexport qcow2
```

---

## Automating exports

Build an ISO, install to a VM, export — all scripted:

```bash
#!/bin/bash
# build-and-export.sh — produce a qcow2 from a fresh kldload install

# 1. Build the ISO
PROFILE=server ./deploy.sh build

# 2. Create a temporary VM and install
ISO=$(ls -t live-build/output/*.iso | head -1)
virt-install \
  --name export-build \
  --ram 4096 --vcpus 4 \
  --disk size=40,format=qcow2 \
  --cdrom "$ISO" \
  --os-variant centos-stream9 \
  --boot uefi \
  --noautoconsole --wait

# 3. Export the VM disk
cp /var/lib/libvirt/images/export-build.qcow2 ./kldload-server-$(date +%Y%m%d).qcow2

# 4. Clean up
virsh undefine export-build --nvram --remove-all-storage
```

---

## Size comparison (40GB disk, desktop profile, lz4 compression)

| Format | Typical size | Notes |
|--------|-------------|-------|
| qcow2 | 3.5 GB | Compressed, sparse |
| raw | 40 GB (apparent) / 4 GB (actual) | Sparse on ZFS |
| vhd | 40 GB | Fixed format (Azure requirement) |
| vmdk | 3.2 GB | streamOptimized compression |
| ova | 3.3 GB | VMDK + OVF metadata in tar |
