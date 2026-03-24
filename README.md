# kldload

![kldloadOS — 4 distros installed from one USB](https://kldload.com/screenshots/installed-4-distros.png)

**10 operating systems. One USB. ZFS on root. AI-powered. Free.**

kldload builds a single bootable ISO that installs CentOS, Debian, Rocky, RHEL, Ubuntu, FreeBSD, OpenBSD, GhostBSD, illumos, or Windows — with ZFS on root, offline, from a USB stick. Both RPM and APT package mirrors are baked into the image. No internet required.

The first operating system with a built-in local AI assistant — voice-controlled, trained on its own documentation, running entirely on your hardware. No cloud. No API key.

**Website:** [kldload.com](https://kldload.com) | **Download:** [dl.kldload.com](https://dl.kldload.com/kldload-free-latest.iso) | **Release Notes:** [RELEASE-1.0.md](RELEASE-1.0.md)

---

## Quickstart

```bash
# Download and burn
curl -L -o kldload.iso https://dl.kldload.com/kldload-free-latest.iso
dd if=kldload.iso of=/dev/sdX bs=4M status=progress oflag=sync && sync

# Or build from source
git clone https://github.com/kldload/kldload.git && cd kldload
./deploy.sh build-debian-darksite && PROFILE=desktop ./deploy.sh build
```

Boot the USB → web UI opens → pick distro + profile → install. Two minutes.

---

## 10 Distros, One USB

| OS | Method | Offline |
|---|---|---|
| CentOS Stream 9 | dnf --installroot | Yes |
| Debian 13 | debootstrap | Yes |
| Rocky Linux 9 | dnf --installroot | Yes |
| RHEL 9 | dnf --installroot | Internet |
| Ubuntu 24.04 | debootstrap | Planned |
| FreeBSD 14.4 | base.txz | Yes |
| OpenBSD 7.8 | base sets | Yes |
| GhostBSD | FreeBSD + desktop | Partial |
| illumos | Chain-boot | Yes |
| Windows | WIM extraction | User ISO |

## 3 Profiles + AI

| Profile | What you get |
|---|---|
| **Desktop** | GNOME + ZFS + all kldloadOS tools |
| **Server** | Headless SSH + ZFS + all kldloadOS tools |
| **Core** | ZFS on root only — stock distro |

**AI checkbox** — adds Ollama + voice control to any profile. Needs internet on first boot + 16GB RAM.

## What's Inside

- **ZFS on root** — boot environments, snapshots, replication, per-dataset encryption
- **AI assistant** — Ollama + whisper.cpp, voice-controlled, trained on kldload.com docs
- **WireGuard** — kernel-level encrypted mesh networking
- **eBPF** — execsnoop, tcplife, opensnoop, biolatency
- **NVIDIA** — GPU drivers + CUDA + container GPU sharing
- **Image export** — qcow2, VMDK, VHD, OVA, raw from one install
- **cloud-init** — Terraform/Packer ready
- **30+ CLI tools** — kst, ksnap, kclone, kdf, kdir, kpkg, kexport
- **Modern terminal** — fzf, btop, eza, ripgrep, zoxide, fastfetch
- **96 pages of docs** at kldload.com

## deploy.sh

| Command | What it does |
|---|---|
| `build` | Build ISO (caches darksites) |
| `build-debian-darksite` | Rebuild Debian APT mirror |
| `build-bsd-darksite` | Download BSD base sets |
| `build-ubuntu-darksite` | Rebuild Ubuntu APT mirror |
| `builder-image` | Rebuild builder container |
| `kvm-deploy` | Deploy to local KVM (2 VMs) |
| `proxmox-deploy` | Deploy to Proxmox |
| `burn` | Write ISO to USB |
| `clean` | Remove build artifacts |

## Architecture

```
100% bash. One Python file. Zero compiled binaries.
cat any file and read what it does.
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for internals.

## License

BSD-3-Clause. Free forever. See [LICENSE](LICENSE).

---

*Built by one person who just knows the primitives.*
*Learn the primitives — they'll outlast any product.*
