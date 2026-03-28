# Editions & Profiles

## Editions

kldload ships two editions. Both install ZFS on root with ZFSBootMenu on any of the seven supported distros.

**kldload-core** -- ZFS on root, ZFSBootMenu, DKMS, deterministic dataset layout, Secure Boot chain. No `k*` tools, no web UI, no darksites, no sanoid. Stock distro after install. Use native `zfs`/`zpool`/`apt`/`dnf`/`pacman` directly.

**kldload-free** -- Everything in core, plus the full `k*` toolset, web UI, offline package mirrors (darksites), sanoid automatic snapshots, WireGuard, eBPF tools (Debian), and desktop customizations (desktop profile).

## Profiles

Selected at install time. All three are available for all seven distros in both editions.

| Profile | Display | SSH | `k*` Tools (free) | Darksites (free) | Web UI (free) |
|---------|---------|-----|-------------------|-----------------|---------------|
| **Desktop** | GNOME | Yes | Yes | Yes | Yes |
| **Server** | None | Yes | Yes | Yes | Yes |
| **Core** | None | Yes | No | No | No |

## Feature Comparison

| Feature | kldload-core | kldload-free |
|---------|-------------|-------------|
| ZFS on root | Yes | Yes |
| ZFSBootMenu | Yes | Yes |
| Boot environments | Manual (`zfs snapshot`/`clone`) | Manual + `kbe` |
| Snapshots | Manual (`zfs snapshot`) | Manual + `ksnap` + sanoid (automatic) |
| Package management | Native only | Native + `kpkg` wrapper |
| Upgrades | Native only | Native + `kupgrade` (auto-snapshot + DKMS verify) |
| Offline install | No (internet required) | Yes (darksites baked into ISO) |
| Web UI | No | Yes (port 8080) |
| Image export | Manual (`qemu-img`) | `kexport qcow2/vhd/vmdk/ova/raw` |
| Disaster recovery | Manual (`zpool import`, chroot) | `krecovery` |
| WireGuard | Not pre-installed | Pre-installed |
| eBPF tools | Not pre-installed | Pre-installed (Debian) |
| Desktop (desktop profile) | Stock GNOME | Tuned GNOME (dark theme, no screensaver) |
| ISO size | ~1.5 GB | ~4-5 GB |

## kldload-core Details

Included:
- Stock CentOS Stream 9, Debian 13, Ubuntu 24.04, Fedora 41, RHEL 9, Rocky Linux 9, or Arch Linux
- ZFS on root with DKMS module built against installed kernel
- Deterministic dataset layout (`/home`, `/var/log`, `/var/cache`, `/srv`)
- ZFSBootMenu bootloader
- EFI partition, Secure Boot chain (shim + GRUB), MOK key generation
- Hostid configuration (`zgenhostid`), dracut initramfs with ZFS

Not included: `k*` tools, web UI, darksites, sanoid, desktop customizations.

## kldload-free Additions

| Component | Function |
|-----------|----------|
| `kpkg` | Cross-distro package manager wrapper, auto-snapshots |
| `ksnap` | Snapshot management |
| `kbe` | Boot environment management |
| `kst` | System health dashboard |
| `kdf` | ZFS-aware disk usage |
| `kdir` | Create ZFS datasets as directories |
| `kclone` | Instant CoW cloning |
| `kexport` | Export to qcow2/VHD/VMDK/OVA/raw |
| `kupgrade` | Safe upgrade with auto-snapshot + DKMS verification |
| `krecovery` | Guided disaster recovery |
| Web UI | Python-based installer/management on port 8080 |
| Darksites | Offline RPM + APT + pacman mirrors |
| Sanoid | Automatic snapshot rotation |
| WireGuard | `wireguard-tools` pre-installed |
| eBPF | `bpftrace`, `bpfcc-tools`, `bpftool`, `linux-perf` (Debian) |

## Build Commands

```bash
# kldload-free
EDITION=free PROFILE=desktop ./deploy.sh build

# kldload-core
EDITION=core PROFILE=server ./deploy.sh build
```

The `EDITION` variable controls which components are included. Core skips `k*` tools, web UI, darksites, sanoid, and desktop customizations. The build pipeline and ZFS/bootloader setup are shared.

## Upgrading Core to Free

```bash
git clone https://github.com/kldload/kldload.git /opt/kldload

cp /opt/kldload/live-build/config/includes.chroot/usr/local/bin/k* /usr/local/bin/
cp -r /opt/kldload/live-build/config/includes.chroot/usr/lib/kldload-installer /usr/lib/
for tool in kbe krecovery kupgrade; do
  ln -sf /usr/lib/kldload-installer/backend/bin/$tool /usr/local/bin/$tool
done
chmod +x /usr/local/bin/k*
```

Or rebuild with `EDITION=free`.
