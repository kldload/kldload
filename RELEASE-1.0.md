# kldloadOS 1.0 — Release Notes

**Date:** March 2026
**Codename:** Du-Nn
**License:** BSD-3-Clause
**Download:** https://dl.kldload.com/kldload-free-latest.iso

---

## What is kldloadOS?

A distro construction kit. One USB installs 10 operating systems with ZFS on root — offline, in 2 minutes. Choose your distro, choose your profile, export to any platform. The first operating system with a built-in AI assistant.

---

## 10 Operating Systems, One USB

| OS | Method | Offline |
|---|---|---|
| CentOS Stream 9 | dnf --installroot | Yes (RPM darksite) |
| Debian 13 (Trixie) | debootstrap | Yes (APT darksite) |
| Rocky Linux 9 | dnf --installroot | Yes (RPM darksite) |
| RHEL 9 | dnf --installroot | No (Red Hat CDN) |
| Ubuntu 24.04 LTS | debootstrap | Planned |
| FreeBSD 14.4 | base.txz extraction | Yes (base sets) |
| OpenBSD 7.8 | base set extraction | Yes (base sets) |
| GhostBSD | FreeBSD base + desktop | Partial |
| illumos (OpenIndiana) | Chain-boot installer | Yes (ISO embedded) |
| Windows | WIM extraction via wimlib | User provides ISO |

---

## 4 Profiles

- **Desktop** — GNOME workstation + ZFS + all kldloadOS tools
- **Server** — Headless SSH + ZFS + all kldloadOS tools
- **Core** — ZFS on root only, stock distro, nothing else
- **AI** — Local LLM assistant + voice control + ZFS + WireGuard

---

## AI Assistant (first OS to include this)

- **Ollama** with llama3.1:8b, auto-installed on firstboot
- **kldload-ai** custom model trained on 96 pages of kldload.com documentation
- **kai** — text queries with live system context (kst, zpool status, ARC stats)
- **kai-voice** — voice control via whisper.cpp (local, no cloud, no API key)
- **kai-do** — AI generates infrastructure commands, shows them, asks to confirm, executes
- **kai-remote** — query and manage remote hosts over SSH
- GPU-accelerated inference with NVIDIA (seconds instead of minutes)
- All local. All offline. No data leaves your machine.

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
4 distros × 3 profiles × 6 formats = 72 deployable configurations from one USB.

---

## Built-in Stack

- **WireGuard** — kernel-level encrypted mesh networking
- **eBPF** — execsnoop, tcplife, opensnoop, biolatency (optional)
- **NVIDIA** — GPU drivers + CUDA + container GPU sharing (optional)
- **Docker on ZFS** — each container layer is a ZFS dataset
- **Firecracker** — microVM support on KVM profile
- **Grafana/Prometheus** — monitoring stack tutorials
- **Salt** — configuration management (standalone mode)

---

## Modern CLI

- **fzf** — fuzzy Ctrl-R history, file finder
- **btop** — system monitor (replaces htop)
- **eza** — modern ls with git status
- **ripgrep** — fast grep
- **fd** — fast find
- **zoxide** — smart cd
- **fastfetch** — system info banner on login
- **tmux** — available with kldload theme (not forced)

---

## 30+ kldload Tools

| Tool | Purpose |
|---|---|
| kst | System health dashboard (pool, snapshots, services, IP) |
| kst-dashboard | 4-pane tmux monitoring |
| ksnap | ZFS snapshot manager |
| kclone | Instant CoW clone |
| kdf | ZFS-aware disk usage |
| kdir | Create ZFS datasets (not directories) |
| kpkg | Universal package manager (auto-detects apt/dnf) |
| kexport | Disk image export |
| kldload-help | Command reference with examples |
| kbe | Boot environment manager |
| krecovery | Emergency pool repair |
| kupgrade | Upgrade with auto-snapshot |
| kai | AI assistant (text) |
| kai-voice | AI assistant (voice) |
| kai-do | AI command execution on remote hosts |
| kai-remote | AI remote host query |

---

## Web UI Installer

- Browser-based, runs on localhost:8080
- 10 distro selector with icons
- 4 profile cards (Desktop, Server, Core, AI)
- RHEL authentication (username/password or activation key)
- Windows edition picker
- NVIDIA, WireGuard, eBPF, ZFS dedup checkboxes
- Export format dropdown
- Real-time install log streaming via WebSocket

---

## Offline / Air-Gap

- 3,600+ Debian packages baked in
- 900+ RPM packages baked in
- FreeBSD/OpenBSD base sets embedded
- ZFSBootMenu EFI binary included
- No internet required for any Linux or BSD install

---

## Documentation

96 pages at kldload.com:

- Tutorials: ZFS, WireGuard, eBPF, NVIDIA, Docker, KVM, Kubernetes, networking, export formats, secure boot, unattended install
- Build guides: edge server, CI runner, workstation, security appliance, classroom, DR, serverless/Firecracker, Grafana, databases, containers, VDI
- AI: getting started, train on your infra, AI for ZFS/eBPF/WireGuard/Docker/KVM/Kubernetes, voice & vision
- Appliance recipes: IoT gateway, ham radio, live TV streaming, Plex on ZFS, game servers
- ZFS wiki: 14 reference pages
- The Bridge: BSD/Linux crossover document

---

## Architecture

- Live environment: CentOS Stream 9
- Build pipeline: containerized (podman/docker)
- Installer: 100% bash, one Python file for web UI
- Zero compiled binaries. `cat` any file and read what it does.
- BSD-3-Clause. Free forever.

---

## Known Limitations (1.0)

- FreeBSD/OpenBSD bootstrap untested — base sets are embedded but install path needs QC
- Windows WIM extraction untested — wimlib is included but needs real hardware testing
- illumos chain-boots its own installer (not a native kldloadOS install)
- Ubuntu darksite not in default ISO (available as separate build)
- eBPF optional packages on CentOS require checkbox selection
- AI profile requires internet on firstboot (Ollama + model download)
- AI profile requires 16GB+ RAM for 8B model inference
- kldload-webui service may fail on some CentOS installs (WorkingDirectory issue)

---

## What's Next (1.1)

- FreeBSD/OpenBSD install QC and fixes
- ARM64 build pipeline
- AI-controlled FreeBSD jails
- Smaller model option for 8GB systems
- Voice command auto-execute mode (no confirmation prompt)
- Ubuntu darksite in default ISO
- Windows install QC

---

*Built by one person who just knows the primitives.*
*Learn the primitives — they'll outlast any product.*

**Download:** https://dl.kldload.com/kldload-free-latest.iso
**Source:** https://github.com/kldload/kldload
**Docs:** https://kldload.com
