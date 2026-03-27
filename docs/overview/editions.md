# kldload Editions

kldload comes in two editions. Both install ZFS on root with ZFSBootMenu. The difference is what comes on top.

---

## kldload-core

**The kernel and ZFS. Nothing else.**

kldload-core solves the hard problem: getting ZFS on root working properly on any of the seven supported distros. That's it. No tools, no web UI, no darksites, no wrappers. You get a stock distro with ZFS on root and boot environments, and you take it from there.

### What's in core

- Stock CentOS Stream 9, Debian 13, Ubuntu 24.04, Fedora 41, RHEL 9, Rocky Linux 9, or Arch Linux (your choice at install time)
- ZFS on root with proper DKMS module, built against the installed kernel
- Deterministic dataset layout (separate `/home`, `/var/log`, `/var/cache`, `/srv`)
- ZFSBootMenu bootloader with boot environment support
- EFI partition, Secure Boot chain (shim + GRUB), MOK key generation
- Hostid configuration (`zgenhostid`)
- Initramfs with ZFS support (dracut)
- That's it

### What's NOT in core

- No `k*` tools (`kpkg`, `ksnap`, `kbe`, `kst`, `kdf`, `kdir`, `kclone`, `kexport`, `kupgrade`, `krecovery`)
- No web UI
- No offline package mirrors (darksites)
- No sanoid (automatic snapshots)
- No desktop customizations
- No Firefox autostart
- No kldload-webui service
- No installer libraries beyond the base bootstrap

### Who it's for

- People who already know ZFS and want to manage it themselves
- Experienced sysadmins who have their own tooling and automation
- Minimalists who want the smallest possible footprint
- Anyone who looked at kldload-free and thought "I just want the ZFS part"

### Using core

After install, you have a standard Linux system. Use the native tools:

```bash
# Package management
dnf install nginx              # CentOS/Fedora/RHEL/Rocky
apt install nginx              # Debian/Ubuntu
pacman -S nginx                # Arch

# ZFS
zfs snapshot rpool/home@backup
zfs list -t snapshot
zfs rollback rpool/home@backup
zpool status

# Boot environments (manual)
zfs snapshot rpool/ROOT/default@before-upgrade
zfs clone rpool/ROOT/default@before-upgrade rpool/ROOT/rollback-point
zpool set bootfs=rpool/ROOT/rollback-point rpool

# Upgrades
dnf upgrade                    # CentOS/Fedora/RHEL/Rocky
apt dist-upgrade               # Debian/Ubuntu
pacman -Syu                    # Arch
# (no automatic snapshot — manage your own)
```

Everything ZFS gives you is available. Boot environments work through ZFSBootMenu. You just manage it all yourself with `zfs` and `zpool` directly.

---

## kldload-free

**The full experience. ZFS made automatic and seamless.**

kldload-free starts with everything in core and adds a layer of optional tooling designed to make ZFS on root effortless — especially for people who haven't used ZFS before.

### What free adds on top of core

| Addition | What it does |
|----------|-------------|
| `kpkg` | Universal package manager wrapper (calls `apt` or `dnf` underneath, adds automatic ZFS snapshot) |
| `ksnap` | Simplified snapshot management |
| `kbe` | Boot environment management |
| `kst` | One-command system health dashboard |
| `kdf` | ZFS-aware disk usage |
| `kdir` | Create ZFS datasets instead of directories |
| `kclone` | Instant CoW cloning |
| `kexport` | Export to qcow2/VHD/VMDK/OVA/raw |
| `kupgrade` | Safe system upgrade with automatic boot environment snapshot + DKMS verification |
| `krecovery` | Disaster recovery tool |
| Web UI | Python-based installer and management interface on port 8080 |
| Darksites | Complete offline RPM + APT package mirrors baked into the ISO |
| Sanoid | Automatic snapshot rotation (hourly/daily/weekly/monthly) |
| WireGuard | `wireguard-tools` pre-installed |
| eBPF | `bpftrace`, `bpfcc-tools`, `bpftool`, `linux-perf` (Debian) |
| Desktop | GNOME with dark theme, Firefox, screensaver disabled (desktop profile) |

### Who it's for

- People who want ZFS on root without having to learn ZFS administration first
- Teams deploying across multiple distros who want consistent tooling
- Air-gapped environments that need offline installs
- Home labbers who want boot environments and instant rollbacks
- Anyone who's tired of reinstalling Linux because an upgrade broke something

### The key point

**Nothing in free replaces or modifies the base distro.** Every `k*` tool is optional. `apt` and `dnf` work exactly as they do on a stock install. The `k*` tools wrap the native commands, add sensible defaults, and take automatic snapshots. If you uninstalled every `k*` tool and removed the web UI, you'd have exactly what core gives you.

Free is core with guard rails and shortcuts. Core is free without them. The underlying OS is identical.

---

## Comparison

| Feature | kldload-core | kldload-free |
|---------|-------------|-------------|
| ZFS on root | Yes | Yes |
| ZFSBootMenu | Yes | Yes |
| Boot environments | Yes (manual) | Yes (manual + `kbe`) |
| Snapshots | Yes (manual `zfs snapshot`) | Yes (manual + `ksnap` + automatic via sanoid) |
| Package management | Native (`apt`/`dnf`/`pacman`) | Native + optional `kpkg` wrapper |
| Upgrades | Native (`apt dist-upgrade`/`dnf upgrade`/`pacman -Syu`) | Native + optional `kupgrade` with auto-snapshot |
| Offline install | Internet required for packages | Complete offline mirrors baked in |
| Web UI | No | Yes (port 8080) |
| Export to images | Manual (`qemu-img`) | `kexport qcow2/vhd/vmdk/ova/raw` |
| Disaster recovery | Manual (`zpool import`, `chroot`) | `krecovery` guided tool |
| WireGuard | Install it yourself | Pre-installed |
| eBPF tools | Install them yourself | Pre-installed (Debian) |
| Desktop customizations | Stock GNOME | Tuned GNOME (dark theme, no screensaver, Firefox to web UI) |
| ISO size | ~1.5 GB (estimated) | ~4–5 GB (includes darksites) |
| Target audience | Experienced ZFS users | Everyone |

---

## Building each edition

```bash
# kldload-free (current default)
EDITION=free PROFILE=desktop ./deploy.sh build

# kldload-core (planned)
EDITION=core PROFILE=server ./deploy.sh build
```

The `EDITION` variable controls which components are included in the ISO. Core skips the `k*` tools, web UI, darksites, sanoid, and desktop customizations. The build pipeline, container infrastructure, and ZFS/bootloader setup are shared.

---

## Upgrading from core to free

If you start with core and later want the `k*` tools:

```bash
# Clone the kldload repo
git clone https://github.com/kldload/kldload.git /opt/kldload

# Copy the tools
cp /opt/kldload/live-build/config/includes.chroot/usr/local/bin/k* /usr/local/bin/
cp -r /opt/kldload/live-build/config/includes.chroot/usr/lib/kldload-installer /usr/lib/
for tool in kbe krecovery kupgrade; do
  ln -sf /usr/lib/kldload-installer/backend/bin/$tool /usr/local/bin/$tool
done
chmod +x /usr/local/bin/k*

# Install sanoid for automatic snapshots
curl -sL https://github.com/jimsalterjrs/sanoid/archive/refs/tags/v2.2.0.tar.gz | tar xz -C /tmp
cp /tmp/sanoid-2.2.0/{sanoid,syncoid,findoid} /usr/local/sbin/
chmod +x /usr/local/sbin/{sanoid,syncoid,findoid}
```

Or just rebuild with `EDITION=free` next time.

---

## Philosophy

The core edition exists because the hardest part of running ZFS on Linux has always been the initial setup — partitioning, DKMS builds, initramfs, bootloader. That's a 2-hour manual process with many opportunities to brick the install. kldload-core automates that one-time pain and then gets out of the way.

The free edition exists because most people don't just want ZFS on root — they want the benefits of ZFS (snapshots, boot environments, compression, cloning) without having to learn the `zfs` and `zpool` command syntax. The `k*` tools make those benefits accessible to people who've never touched ZFS before, while leaving the native tools untouched for people who have.

Both editions produce the same underlying OS. The difference is how much hand-holding ships on the ISO.
