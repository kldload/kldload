# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

kldload-free builds a single bootable ISO that installs CentOS, Debian, or RHEL with ZFS on root — offline, from USB. Both RPM and APT package mirrors ("darksites") are baked into the image. The live environment is always CentOS Stream 9; the user picks their target distro at install time.

## Build commands

All builds go through `deploy.sh`. It auto-detects podman or docker.

```bash
# Full rebuild from scratch
./deploy.sh clean
./deploy.sh builder-image
./deploy.sh build-debian-darksite   # slow — cached after first run
PROFILE=desktop ./deploy.sh build

# Incremental rebuild (skips debian darksite if cache exists)
PROFILE=desktop ./deploy.sh build

# Deploy
./deploy.sh kvm-deploy              # local KVM via virt-install
./deploy.sh proxmox-deploy          # remote Proxmox via qm API
./deploy.sh burn                    # dd to USB (/dev/sda)
./deploy.sh deploy-all              # all three
```

Output lands in `live-build/output/`. Environment variables (`PROFILE`, `ARCH`, `VMID`, etc.) are set in `kldload.env` or passed on the command line.

## Architecture

**Build pipeline** (4 stages, all containerized):

1. **Builder image** — CentOS Stream 9 container with lorax, squashfs-tools, xorriso, dracut, mtools (`builder/Dockerfile`)
2. **Debian darksite** — Runs in `debian:trixie-slim` to resolve+download APT packages (`build/darksite-debian/build-darksite-debian.sh`). Cached at `live-build/darksite-debian-cache/`
3. **RPM darksite** — `dnf download --resolve --alldeps` inside builder container (`build/darksite/build-darksite.sh`)
4. **ISO assembly** — `builder/build-iso.sh` runs inside builder: bootstraps rootfs via `dnf --installroot`, builds ZFS DKMS, embeds both darksites, creates squashfs+EFI+ISO with xorriso

**Installer** (runs on booted ISO):

- Web UI: single Python file (`live-build/config/includes.chroot/usr/local/bin/kldload-webui`) + single HTML file per edition (`usr/local/share/kldload-webui/{active,free}/index.html`)
- Backend: `kldload-install-target` sources 9 bash libraries from `usr/lib/kldload-installer/lib/` — dispatches to `dnf --installroot` (CentOS/RHEL) or `debootstrap` (Debian)
- Configuration is purely environment variables written to an answers file

**Key directories:**

- `live-build/config/includes.chroot/` — everything here mirrors into the live ISO root filesystem
- `build/darksite/config/package-sets/` — RPM package lists (one name per line)
- `build/darksite-debian/config/package-sets/` — APT package lists
- `profiles/` — YAML profiles (desktop.yaml, server.yaml)

## Adding packages

Add names to the `.txt` files in `build/darksite/config/package-sets/` (RPM) or `build/darksite-debian/config/package-sets/` (APT). Dependencies resolve automatically. Rebuild the ISO.

## No tests or linter

There is no test suite or linter. The build is validated by booting the ISO and running the installer.
