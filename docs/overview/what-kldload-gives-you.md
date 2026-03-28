# What kldloadOS Adds to a Stock Distro

**kldload** is the builder/installer. **kldloadOS** is the resulting system -- an optional tooling layer on top of CentOS, Debian, Ubuntu, Fedora, RHEL, Rocky, or Arch with ZFS on root.

The base distro is unmodified. `apt`, `dnf`, `pacman`, `zfs`, `zpool`, `systemctl` all work as stock. The `k*` tools are additions, not replacements. Uninstall them and you have a standard distro with ZFS on root.

> **Core profile:** ZFS on root + ZFSBootMenu only, no `k*` tools. See [Editions](editions.md).

---

## ZFS on Root

Manual ZFS-on-root setup requires: custom partitioning (EFI + ZFS), pool creation with tuned properties (ashift=12, lz4, acltype, xattr=sa), dataset hierarchy, DKMS module build, ZFS-aware initramfs, ZFSBootMenu or patched GRUB, zgenhostid, and correct fstab ordering. kldload automates all of it.

Dataset layout:

```
rpool
├── ROOT/default      /                (OS root)
├── home              /home            (separate snapshots)
├── root              /root
├── srv               /srv             (application data)
└── var
    ├── log           /var/log         (separate snapshots)
    ├── cache         /var/cache       (no auto-snapshot)
    └── tmp           /var/tmp         (no auto-snapshot)
```

Each dataset has independent snapshot schedules, compression settings, quotas, and send/receive replication.

---

## Boot Environments

ZFSBootMenu + `kbe` provides Solaris/FreeBSD-style boot environments on Linux:

```bash
kbe create before-risky-change
kupgrade
# broken? kbe activate before-risky-change && reboot
```

Every upgrade is reversible. Select previous boot environments from the ZFSBootMenu at boot.

---

## Cross-Distro CLI Tools

The `k*` commands abstract package manager differences:

| Command | CentOS/Fedora/RHEL/Rocky | Debian/Ubuntu | Arch |
|---------|----------------------|-------------------|---------|
| `kpkg install nginx` | `dnf install -y nginx` | `apt-get install -y nginx` | `pacman -S --noconfirm nginx` |
| `kpkg remove nginx` | `dnf remove -y nginx` | `apt-get remove -y nginx` | `pacman -R --noconfirm nginx` |
| `kpkg search redis` | `dnf search redis` | `apt-cache search redis` | `pacman -Ss redis` |
| `kpkg upgrade` | `dnf upgrade -y` | `apt-get upgrade -y` | `pacman -Syu --noconfirm` |

Every `kpkg install`, `remove`, and `upgrade` takes an automatic ZFS snapshot first.

Other tools: `ksnap` (snapshots), `kbe` (boot environments), `kst` (health dashboard), `kdf` (ZFS-aware disk usage), `kdir` (create datasets), `kclone` (CoW clones), `kexport` (image export), `kupgrade` (safe upgrade), `krecovery` (disaster recovery).

---

## Automatic Snapshots

Sanoid runs hourly/daily/weekly/monthly snapshot rotation with automatic pruning. The `k*` tools also snapshot before destructive operations:

| Tool | Trigger | Snapshot naming |
|------|---------|-----------------|
| `kpkg install/remove/upgrade` | Package operation | `kpkg-YYYYMMDD-HHMMSS` |
| `kupgrade` | System upgrade | `pre-upgrade-YYYYMMDD-HHMMSS` |
| `ksnap` | Manual | `manual-YYYYMMDD-HHMMSS` |

---

## Offline Package Mirrors (Darksites)

Complete mirrors baked into the ISO:

- ~900 RPMs (CentOS/Fedora/RHEL/Rocky)
- ~2,700 .debs (Debian)
- ~2,500 .debs (Ubuntu)
- Arch packages (Arch Linux)

No internet required. Identical packages across installs -- no mirror drift.

---

## Image Export

`kexport` converts a running system to portable disk images:

```bash
kexport qcow2   # KVM / Proxmox / OpenStack
kexport vhd     # Azure / Hyper-V
kexport vmdk    # VMware ESXi / vSphere
kexport ova     # VMware / VirtualBox
kexport raw     # dd-ready image
```

Images are sealed with cloud-init for golden template cloning. Uses `qemu-img convert` underneath.

---

## Additional Components

| Component | Details |
|-----------|---------|
| **Web UI** | Python + single HTML file on port 8080. Installation and management. |
| **WireGuard** | `wireguard-tools` pre-installed. 4-plane mesh support for cluster deployments. |
| **eBPF** | `bpftrace`, `bpfcc-tools`, `bpftool`, `linux-perf` included on Debian installs. |
| **NVIDIA** | Set `KLDLOAD_NVIDIA_DRIVERS=1` during install. Includes MOK signing on CentOS/RHEL. |
| **Secure Boot** | Shim-signed UEFI chain, automatic MOK key generation for DKMS modules. |
| **Encryption** | Optional ZFS native encryption (AES-256-GCM), passphrase or keyfile. |

---

## What is Not Modified

- **Kernel** -- unmodified distro kernel; ZFS built via DKMS
- **Package managers** -- `apt`, `dnf`, `pacman` untouched
- **Init** -- stock systemd
- **Filesystem tools** -- standard OpenZFS (`zfs`, `zpool`, `zdb`)
- **Network** -- standard NetworkManager, stock WireGuard kernel module
- **License** -- BSD 3-Clause, no proprietary components
