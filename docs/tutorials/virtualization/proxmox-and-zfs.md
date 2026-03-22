# Running kldload Inside Proxmox

kldload installs on ZFS. Proxmox also uses ZFS. Running kldload as a Proxmox VM means you have **two ZFS layers** — Proxmox's pool and kldload's pool inside the virtual disk. This works, but there are tradeoffs.

This guide covers when double-ZFS makes sense, when to use KVM instead, and how to tune both for best performance.

---

## The double-ZFS problem

```
┌─────────────────────────────────────────────────┐
│  Proxmox host                                   │
│  zpool: rpool (ZFS on physical NVMe)            │
│    └── vm-100-disk-0.qcow2                      │
│         ┌──────────────────────────────────┐     │
│         │  kldload VM                       │     │
│         │  zpool: rpool (ZFS on /dev/vda)   │     │
│         │    ├── ROOT/default               │     │
│         │    ├── home                       │     │
│         │    └── srv                        │     │
│         └──────────────────────────────────┘     │
└─────────────────────────────────────────────────┘
```

**Two ARC caches**: Both ZFS layers maintain their own ARC (Adaptive Replacement Cache). The host caches the VM's virtual disk blocks, and the guest caches its own filesystem blocks. This means the same data can sit in memory twice.

**Double compression**: If both layers use lz4, the guest compresses data, then the host tries to compress the already-compressed blocks (gaining nothing but burning CPU).

**Double checksumming**: Both layers verify block integrity. Redundant for data correctness, costs CPU.

**Write amplification**: The guest writes to its pool, which generates I/O to the virtual disk. The host's pool then processes that I/O, potentially amplifying the number of physical writes due to COW on both layers.

---

## When double-ZFS is fine

- **Development and testing** — you want the real kldload ZFS experience in a disposable VM
- **Small workloads** — the overhead is negligible when VM I/O is low
- **You need kldload's ZFS features** — boot environments, snapshots, ksnap, kbe, kupgrade — these only work with ZFS on root

---

## When to avoid double-ZFS

- **Production storage nodes** — if the VM is an NFS/iSCSI server or runs databases with heavy I/O
- **Memory-constrained hosts** — two ARCs eating RAM is wasteful
- **High-throughput workloads** — write amplification hurts

### Alternative: bare-metal kldload + KVM

For production, install kldload directly on the hardware (bare metal) and run VMs on top using KVM/libvirt. You get one ZFS layer with full performance:

```
┌──────────────────────────────────────────────────┐
│  kldload bare metal (ZFS on physical NVMe)       │
│  zpool: rpool                                    │
│    ├── ROOT/default (host OS)                    │
│    ├── vms/web-1.qcow2    → KVM VM              │
│    ├── vms/web-2.qcow2    → KVM VM              │
│    └── srv/database        → direct dataset      │
└──────────────────────────────────────────────────┘
```

The VMs inside can run ext4 — they don't need their own ZFS. The host's ZFS handles compression, snapshots, and CoW for the VM disk images.

---

## If you do run on Proxmox: tuning tips

### Disable compression on one layer

```bash
# Option A: disable on the Proxmox side (let kldload handle it)
# On the Proxmox host:
zfs set compression=off rpool/data/vm-100-disk-0

# Option B: disable on the kldload guest side (let Proxmox handle it)
# Inside the kldload VM:
zfs set compression=off rpool
```

Option A is usually better — let the guest control its own compression settings per-dataset.

### Cap the guest ARC

Inside the kldload VM, reduce the ARC so the host has more memory for its own ARC:

```bash
# Inside the kldload VM — limit ARC to 1GB
echo "options zfs zfs_arc_max=1073741824" > /etc/modprobe.d/zfs-arc.conf

# Rebuild initramfs and reboot
dracut --force   # CentOS/RHEL
update-initramfs -u   # Debian
reboot
```

### Use virtio-scsi with discard

In Proxmox VM settings:
- **Bus:** SCSI (virtio-scsi-single)
- **Discard:** On (enables TRIM passthrough)
- **IO Thread:** On

```bash
# Proxmox CLI
qm set 100 --scsi0 local-zfs:vm-100-disk-0,discard=on,iothread=1,ssd=1
```

Inside the kldload VM, enable autotrim:

```bash
zpool set autotrim=on rpool
```

This lets the guest's ZFS tell the host "I'm not using these blocks anymore," which the host's ZFS can then free.

### Allocate fixed RAM (no ballooning)

Ballooning and ZFS ARC don't mix well — the ARC doesn't shrink gracefully when the balloon inflates:

```bash
# Proxmox CLI — fixed 8GB, no balloon
qm set 100 --memory 8192 --balloon 0
```

### Use raw disk format instead of qcow2

On Proxmox with ZFS storage, raw format avoids the qcow2 layer:

```bash
# Create VM with raw disk on ZFS
qm set 100 --scsi0 local-zfs:40,format=raw
```

Proxmox's ZFS storage backend uses zvols for raw disks — this means the guest's ZFS writes go through a zvol, which is more efficient than going through a qcow2 file on top of a ZFS dataset.

---

## ZFS special devices (Proxmox host)

If your Proxmox host has NVMe SSDs, consider using ZFS special vdevs to accelerate metadata operations:

```bash
# On the Proxmox host — add a special vdev (metadata + small blocks)
zpool add rpool special mirror /dev/nvme0n1p4 /dev/nvme1n1p4

# Set small block threshold (blocks ≤64K go to the special vdev)
zfs set special_small_blocks=64K rpool
```

This accelerates `ls`, `find`, `zfs list`, and any metadata-heavy operation, which benefits VMs because their virtual disk metadata is served from fast storage.

---

## Recommended Proxmox VM settings for kldload

```bash
# Create the VM
qm create 100 \
  --name kldload-node \
  --machine q35 \
  --cpu host \
  --cores 4 \
  --memory 8192 \
  --balloon 0 \
  --bios ovmf \
  --efidisk0 local-zfs:1,efitype=4m,pre-enrolled-keys=0 \
  --tpmstate0 local-zfs:1,version=v2.0 \
  --scsi0 local-zfs:40,discard=on,iothread=1,ssd=1 \
  --scsihw virtio-scsi-single \
  --ide2 local:iso/kldload-free-latest.iso,media=cdrom \
  --net0 virtio,bridge=vmbr0 \
  --serial0 socket \
  --boot order="ide2;scsi0" \
  --ostype l26
```

These settings match the kldload `deploy.sh proxmox-deploy` defaults: q35 machine, host CPU passthrough, OVMF UEFI, TPM 2.0, virtio-scsi with discard, serial console.

---

## Migrating from Proxmox VM to bare metal

If you outgrow the double-ZFS setup:

```bash
# Inside the Proxmox kldload VM
kexport raw

# Write the raw image to bare-metal disk
dd if=kldload-export-*.raw of=/dev/nvme0n1 bs=4M status=progress conv=sparse oflag=sync
sync
```

Or use `zfs send/receive`:

```bash
# Inside the VM — send the pool to a USB backup disk
zfs snapshot -r rpool@migrate
zfs send -R rpool@migrate | ssh bare-metal zfs receive -F rpool
```

Then reinstall the bootloader on the bare-metal disk:

```bash
# Boot from kldload ISO on bare metal
krecovery import rpool
krecovery reinstall-bootloader /dev/nvme0n1
reboot
```
