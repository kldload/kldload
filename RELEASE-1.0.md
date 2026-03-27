# kldloadOS 1.0 "Du-Nn" — Release Notes

**Date:** March 26, 2026
**License:** BSD-3-Clause
**Download:** https://dl.kldload.com/kldload-free-latest.iso

---

## What is kldloadOS?

A base image factory for Linux. One USB installs five distros with ZFS on root — offline, in 2 minutes. Choose your distro, choose your profile, export to any platform.

---

## 5 Distros, One USB

| OS | Method | Offline |
|---|---|---|
| CentOS Stream 9 | dnf --installroot | Yes (RPM darksite) |
| Debian 13 (Trixie) | debootstrap | Yes (APT darksite) |
| Ubuntu 24.04 LTS | debootstrap | Yes (APT darksite) |
| Rocky Linux 9 | dnf --installroot | Yes (RPM darksite) |
| RHEL 9 | dnf --installroot | No (Red Hat CDN) |

---

## 4 Profiles

- **Desktop** — GNOME workstation + ZFS + all kldloadOS tools
- **Server** — Headless SSH + ZFS + all kldloadOS tools
- **Core** — ZFS on root + WireGuard — stock distro, nothing else
- **AI** — Local LLM assistant + voice control + ZFS + WireGuard (active edition)

---

## ZFS on Root

- Automatic pool creation, dataset hierarchy, boot environments
- ZFSBootMenu for 30-second OS rollback
- Sanoid/syncoid for automated snapshots and replication
- Per-dataset AES-256-GCM encryption with independent keys
- lz4 compression (improves performance, not just saves space)
- Self-healing storage — every block checksummed

---

## Image Factory

Export any installed disk to any platform:

- **qcow2** — KVM, Proxmox, OpenStack
- **VMDK** — VMware ESXi, vSphere
- **VHD** — Azure, Hyper-V
- **OVA** — VMware, VirtualBox
- **raw** — dd to bare metal, AWS AMI

cloud-init baked in for Terraform/Packer integration.

---

## Built-in Stack

- **WireGuard** — kernel-level encrypted mesh networking
- **eBPF** — execsnoop, tcplife, opensnoop, biolatency (optional)
- **NVIDIA** — GPU drivers + CUDA (optional)
- **Modern CLI** — fzf, btop, eza, ripgrep, fd, zoxide, bat, tmux

---

## 30+ kldload Tools

| Tool | Purpose |
|---|---|
| kst | System health dashboard |
| ksnap | ZFS snapshot manager |
| kclone | Instant CoW clone |
| kdf | ZFS-aware disk usage |
| kdir | Create ZFS datasets |
| kpkg | Universal package manager (auto-detects apt/dnf/pacman) |
| kexport | Disk image export |
| kbe | Boot environment manager |
| krecovery | Emergency pool repair |
| kupgrade | Upgrade with auto-snapshot |

---

## Architecture

- Live environment: CentOS Stream 9
- Build pipeline: containerized (podman/docker)
- Fully auditable. Zero compiled binaries. `cat` any file and read what it does.
- BSD-3-Clause. Free forever.

---

**Download:** https://dl.kldload.com/kldload-free-latest.iso
**Source:** https://github.com/kldload/kldload
**Docs:** https://kldload.com
