# kldload

**Not an OS. Not a distro. A kernel loader.**

kldload is a build tool that assembles Linux images with kernel modules — ZFS, WireGuard, NVIDIA — bundled and ready on first boot. Pull any distro. Build an image. Boot it. That's it.

**Website & ZFS Wiki:** [kldload.com](https://kldload.com)

---

## What it does

kldload automates the process of building a bootable Linux image with ZFS on root. It does exactly what you'd do by hand — `wget` the packages, install them, configure the kernel modules, assemble the bootloader — just automated. Every step is a readable bash script. Every step is auditable.

**By using kldload, you naturally get:**

- **ZFS on root** — checksummed, compressed, snapshot-capable root filesystem
- **ZFSBootMenu** — boot environment management, 15-second rollback
- **WireGuard** — kernel-level mesh networking
- **NVIDIA drivers** — baked in, loaded on first boot
- **30+ CLI tools** — `kst`, `ksnap`, `kbe`, `kdf`, `kdir`, `kpkg`, and more
- **Automatic snapshots** — before every package change, on schedule
- **Web UI installer** — browser-based, 5-step guided install
- **Offline install** — no internet required at deploy time

You still do all the work — design your storage, configure your network, deploy your applications. kldload just makes it easier to bundle kernel modules into a bootable image so they're there when you need them.

## Supported distros

| Distro | Status |
|--------|--------|
| Debian 13 (Trixie) | Stable |
| CentOS Stream 9 | Stable |
| Rocky Linux 9 | Planned |
| RHEL 9 | Planned |

Same tools, same ZFS layout, same boot environments — regardless of distro.

---

## Build your own

The real way to use kldload is to clone the repo and build your own image.

```bash
git clone https://github.com/kldload/kldload.git
cd kldload

# Build a Debian 13 ISO
./deploy.sh build

# Build a CentOS Stream 9 ISO
DISTRO=centos ./deploy.sh build
```

Swap the package list, change the profile, build whatever you want. À la carte.

## Pre-built ISOs

If you just want to try it without setting up a build environment, pre-built ISOs are available at [kldload.com](https://kldload.com). Same result you'd get building it yourself.

---

## CLI tools

Short names, no flags to memorize, sensible defaults. Work identically on Debian and CentOS.

### Everyday

| Command | What it does |
|---------|-------------|
| `kst` | System status — pool health, dataset usage, compression, snapshots, services |
| `ksnap` | Snapshot management — create, list, rollback, destroy |
| `kclone` | Instant copy-on-write clones of any dataset |
| `kdf` | ZFS-aware disk usage with compression ratios |
| `kdir` | Create a ZFS dataset instead of a directory |
| `kpkg` | Universal package manager (apt/dnf) with automatic pre-snapshot |
| `khelp` | Built-in command reference |

### Boot environments

| Command | What it does |
|---------|-------------|
| `kbe list` | List all boot environments |
| `kbe create <name>` | Snapshot current root as a named boot environment |
| `kbe activate <name>` | Set a boot environment as next boot target |
| `kbe rollback <name>` | Roll back root to a previous snapshot |
| `kupgrade` | Full system upgrade with automatic pre-upgrade snapshot |
| `krecovery` | Emergency recovery — import pools, chroot, reinstall bootloader |

### Administration

| Command | What it does |
|---------|-------------|
| `khold` | Mark critical packages as held (kernel, ZFS, bootloader) |
| `kpoof` | Scrub all sensitive ephemeral data from RAM |

### Shell aliases

50+ context-aware aliases loaded automatically. ZFS, Kubernetes, Helm, Salt, Docker, virsh — each set only appears if the tool is installed.

```
zls     → zfs list
zsnap   → zfs list -t snapshot
zbe     → kbe list
ports   → ss -tuln
```

---

## ZFS dataset layout

Every kldload install creates this hierarchy. Rolling back `/` doesn't affect `/home`, `/var/log`, or `/srv`.

```
rpool
├── ROOT/<hostname>     ← /  (active boot environment)
├── home                ← /home (per-user child datasets)
├── root                ← /root
├── srv                 ← /srv (snapshotted every 15 min)
├── var                 ← /var
│   ├── log             ← /var/log (persists across rollbacks)
│   ├── cache           ← /var/cache
│   └── tmp             ← /var/tmp (excluded from snapshots)
```

Pool properties: `ashift=12`, `compression=lz4`, `autotrim=on`, `xattr=sa`, `acltype=posixacl`, `dnodesize=auto`, `normalization=formD`

---

## Automatic snapshots

No configuration needed. Running from first boot.

| Trigger | Retention | What |
|---------|-----------|------|
| Every `apt`/`dnf` operation | Last 10 | Root filesystem snapshot before package changes |
| Every 15 minutes | Last 4 | `/srv` service data |
| Hourly | Configurable | Boot environment |
| Post-install | Permanent | Factory reset point |

---

## Web UI

Browser-based installer and management interface. Python 3, no framework dependencies. Runs on port 8080.

- **Installer** — 5-step guided install with real-time progress streaming
- **Dashboard** — system health, pool status, service status
- **ZFS** — dataset browser, snapshot management, boot environments
- **Logs** — real-time log streaming with filtering

WebSocket API available on port 8081 for automation.

---

## How it works

kldload automates the standard Linux installation process:

1. **Partition** — EFI + ZFS pool
2. **Bootstrap** — `debootstrap` (Debian) or `dnf --installroot` (CentOS)
3. **DKMS** — build ZFS kernel module against installed kernel
4. **Initramfs** — rebuild with ZFS support (`initramfs-tools` or `dracut`)
5. **Bootloader** — install ZFSBootMenu to EFI partition
6. **Export** — clean pool export for first boot

Every step is a function in `bootstrap.sh` and `bootloader.sh`. Read them.

---

## What you can build on top

kldload is a foundation. What you put on it is up to you.

- **Containers** — Docker/Podman/LXC on ZFS with CoW storage
- **VMs** — KVM + QEMU + libvirt with zvol-backed instant clones
- **Storage servers** — NFS/iSCSI/Samba with self-healing ZFS
- **Media servers** — Jellyfin/Plex on checksummed storage
- **Clusters** — WireGuard mesh + Salt orchestration
- **Whatever you want** — `postinstall.sh` is your hook

See [kldload.com/build](https://kldload.com/#build) for recipes.

---

## Fully auditable

- No compiled binaries
- No vendor SDKs
- No obfuscation
- Every tool is a bash script you can `cat` and read
- You don't trust kldload — you trust your own eyes

---

## License

BSD 3-Clause. See [LICENSE](LICENSE).

Third-party components (Linux kernel, OpenZFS, GNOME, etc.) retain their own licenses.
