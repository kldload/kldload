# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

kldload-free builds a single bootable ISO that installs CentOS Stream 9, Debian 13, Ubuntu 24.04, Fedora 41, RHEL 9, Rocky Linux 9, Arch Linux, or Alpine Linux with ZFS on root. RPM and APT package mirrors ("darksites") are baked into the image for offline install. Arch Linux requires internet (rolling release — no darksite). Alpine has a partial apk cache. The live environment is always CentOS Stream 9; the user picks their target distro at install time. The KVM profile includes Kubernetes tools (kube-cluster, kube-init, kube-demo) that deploy production K8s clusters on ZFS instant clones with Cilium eBPF networking.

## Build commands

All builds go through `deploy.sh`. It auto-detects podman or docker.

```bash
# Full rebuild from scratch
./deploy.sh clean
./deploy.sh builder-image
./deploy.sh build-debian-darksite   # slow — cached after first run
./deploy.sh build-ubuntu-darksite   # slow — cached after first run
PROFILE=desktop ./deploy.sh build

# Incremental rebuild (skips darksites if cache exists)
PROFILE=desktop ./deploy.sh build

# Deploy
./deploy.sh kvm-deploy              # local KVM via virt-install
./deploy.sh proxmox-deploy          # remote Proxmox via qm API
./deploy.sh burn                    # dd to USB (/dev/sda)
./deploy.sh deploy-all              # all three
```

Output lands in `live-build/output/`. Environment variables (`PROFILE`, `EDITION`, `ARCH`, `VMID`, etc.) are set in `kldload.env` or passed on the command line.

## Editions and profiles

Two editions: `EDITION=free` (default, full kldloadOS) and `EDITION=core` (stripped, ZFS only).

Three install profiles shown in the web UI:
- **desktop** — GNOME + ZFS + all kldloadOS tools
- **server** — headless SSH + ZFS + all kldloadOS tools
- **core** — ZFS on root only, stock distro, no k* tools/webui/sanoid/darksites

The `core` profile gates are in `profiles.sh` (`k_profile_packages` and `k_install_system_files`) and `build-iso.sh` (package list, tool copies, darksite embedding). Both use `!= "core"` checks.

## Architecture

**Build pipeline** (5 stages, all containerized):

1. **Builder image** — CentOS Stream 9 container with lorax, squashfs-tools, xorriso, dracut, mtools (`builder/Dockerfile`)
2. **Debian darksite** — Runs in `debian:trixie-slim` to resolve+download APT packages (`build/darksite-debian/build-darksite-debian.sh`). Cached at `live-build/darksite-debian-cache/`
3. **Ubuntu darksite** — Runs in `ubuntu:noble` using the Debian builder script with Ubuntu package sets (`build/darksite-ubuntu/build-darksite-ubuntu.sh`). Cached at `live-build/darksite-ubuntu-cache/`. Requires universe component for ZFS packages.
4. **RPM darksite** — `dnf download --resolve --alldeps` inside builder container (`build/darksite/build-darksite.sh`)
5. **ISO assembly** — `builder/build-iso.sh` runs inside builder: bootstraps rootfs via `dnf --installroot`, builds ZFS DKMS, embeds all darksites, creates squashfs+EFI+ISO with xorriso

**Darksite serving** (live ISO):
- Port 3142 — Debian APT mirror (`/root/darksite/debian/`)
- Port 3143 — Ubuntu APT mirror (`/root/darksite/ubuntu/`)
- RPM distros use `file:///root/darksite/` directly (no HTTP server)

**Installer** (runs on booted ISO):

- Web UI: single Python file (`live-build/config/includes.chroot/usr/local/bin/kldload-webui`) + single HTML file per edition (`usr/local/share/kldload-webui/{active,free}/index.html`)
- Backend: `kldload-install-target` sources 9 bash libraries from `usr/lib/kldload-installer/lib/` — dispatches to `dnf --installroot` (CentOS/Fedora/RHEL/Rocky), `debootstrap` (Debian/Ubuntu), or `pacstrap` (Arch)
- Configuration is purely environment variables written to an answers file

**Image export** (golden image workflow):

When the user selects an export format (qcow2, vmdk, vhd, ova, raw) in the web UI:
1. OS installs to the VM's disk normally (ZFS on root, WireGuard, eBPF, etc.)
2. Image is sealed for cloning: machine-id cleared, SSH host keys removed, cloud-init enabled with multi-datasource config
3. ZFS pools exported, `qemu-img convert` produces the image
4. Image is SCP'd to a remote host (if configured) or saved locally
5. Result is a cloud-init-ready golden template for Packer or direct hypervisor import

Key files: `k_seal_image_for_clone()` in `kldload-install-target`, `kexport` CLI tool, SCP params from web UI.

**Key directories:**

- `live-build/config/includes.chroot/` — everything here mirrors into the live ISO root filesystem
- `build/darksite/config/package-sets/` — RPM package lists (one name per line)
- `build/darksite-debian/config/package-sets/` — Debian APT package lists
- `build/darksite-ubuntu/config/package-sets/` — Ubuntu APT package lists
- `profiles/` — YAML profiles (desktop.yaml, server.yaml)

## Adding packages

Add names to the `.txt` files in:
- `build/darksite/config/package-sets/` — RPM (CentOS, RHEL, Rocky)
- `build/darksite-debian/config/package-sets/` — Debian APT
- `build/darksite-ubuntu/config/package-sets/` — Ubuntu APT

Dependencies resolve automatically. Rebuild the ISO.

## Live ISO credentials

- User `live`, password `live` (autologin on desktop, sudo NOPASSWD)
- User `root`, password `kldload`
- SSH password auth enabled, root login disabled

## Key dependencies

- The web UI requires `websockets` Python module with `websockets.http11` API (v11+). The CentOS 9 RPM (`python3-websockets`) lacks this — `build-iso.sh` removes the RPM and pip-installs a compatible version during build. The builder container needs network access for this.

## No tests or linter

There is no test suite or linter. The build is validated by booting the ISO and running the installer.
