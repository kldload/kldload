# kldloadOS 1.0.1 — Release Notes

**Date:** March 27, 2026
**License:** BSD-3-Clause
**Download:** https://dl.kldload.com/kldload-free-latest.iso

---

## New Distros

| OS | Method | Offline |
|---|---|---|
| **Fedora 41** | dnf --installroot | Yes (RPM darksite) |
| **Arch Linux** | pacstrap (pacman-static) | Yes (pacman darksite) |

**Total: 7 distros from one USB** — CentOS, Debian, Ubuntu, Fedora, RHEL, Rocky, Arch.

---

## New Features

### Golden Image Export with SCP
- Export images (qcow2, VMDK, VHD, OVA, raw) and SCP them directly to a remote host
- Supports SSH key or password authentication
- Images are sealed for cloning: machine-id cleared, SSH host keys removed, cloud-init enabled
- Cloud-init multi-datasource config (NoCloud, Azure, GCE, EC2)

### Universal Package Manager — Arch Support
- `kpkg` now supports pacman alongside apt and dnf
- `kpkg install nginx` on Arch runs `pacman -S --noconfirm nginx` with a ZFS snapshot first
- Same commands across all 7 distros

### Hardware / Firmware
- `linux-firmware` included on all target installs (NVMe, WiFi, GPU drivers)
- `linux-modules-extra-generic` for Ubuntu (extra kernel modules)
- `nvme-cli`, `pciutils`, `usbutils`, `smartmontools` on all targets
- Firmware packages for Debian (firmware-linux-nonfree, firmware-iwlwifi, firmware-realtek)

### Desktop Fixes
- Xorg installed as fallback — GDM no longer shows black screen on VMs
- Wayland remains the default; Xorg fallback is automatic
- Distro-specific wallpapers set via dconf (Ubuntu, Debian, CentOS, Fedora)
- `epiphany-browser` replaces Firefox on Ubuntu (Firefox is a snapd transitional package)

---

## Bug Fixes

- **Ubuntu darksite** — now auto-built during `./deploy.sh build` (was missing, causing Ubuntu installs to require internet)
- **Ubuntu darksite mirror** — service on port 3143 serves packages correctly
- **Firefox/snapd** — Ubuntu desktop uses epiphany-browser instead of Firefox (which requires snapd)
- **Xorg missing** — added `xserver-xorg` to desktop profile package list
- **websockets** — CentOS 9 RPM lacks `websockets.http11`; pip install restored with better error handling
- **Core profile dotfiles** — skel/.bashrc/.tmux.conf no longer copied on core profile (stock distro only)
- **GDM config path** — Ubuntu/Debian use `/etc/gdm3/`, Fedora/Arch use `/etc/gdm/` — now handled correctly
- **Loop device support** — `storage-zfs.sh` partition prefix handles `/dev/loopN` devices
- **kexport file input** — accepts raw files alongside block devices for OVA size detection

---

## Infrastructure

- **pacman-static** binary embedded in live ISO for Arch bootstrap (no Arch repos needed on live system)
- **Arch darksite builder** — `./deploy.sh build-arch-darksite` downloads packages from Arch + archzfs repos
- **Fedora darksite builder** — `./deploy.sh build-fedora-darksite` downloads packages from Fedora repos
- **Fedora mirror service** — port 3145 for offline Fedora installs
- **Arch mirror service** — port 3144 for offline Arch installs

---

## Website

- Messaging updated: "base image factory" positioning
- Executive summary rewritten with 4-step how-to-use guide
- Canonical ZFS/GRUB deprecation warning (Ubuntu 26.10)
- 7 distros listed throughout
- Removed "100% bash" claims — replaced with "fully auditable"

---

## Known Issues

- Arch darksite must be built separately (`./deploy.sh build-arch-darksite`) — not yet in default build
- Fedora darksite must be built separately (`./deploy.sh build-fedora-darksite`) — not yet in default build
- Ubuntu GDM may hang on first boot with NVIDIA drivers selected (no GPU in VM)
- Exported images write to /tmp (ramdisk) — large images may fail on low-RAM systems

---

## What's Next (1.1)

- Alpine Linux support (core profile only)
- Automated end-to-end test harness
- Cloud upload commands (AWS AMI, Azure, GCP)
- ARM64 build pipeline
- Per-distro ISO builds for smaller images

---

**Download:** https://dl.kldload.com/kldload-free-latest.iso
**Source:** https://github.com/kldload/kldload
**Docs:** https://kldload.com
