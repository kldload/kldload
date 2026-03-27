# kldload

![kldloadOS — RHEL 9 Desktop with ZFS on root](https://kldload.com/screenshots/rhel-desktop-zfs.png)

**The base image factory. ZFS + WireGuard + kernel, any distro, any platform. Free.**

kldload builds a single bootable ISO that installs CentOS, Debian, Ubuntu, Fedora, Rocky, RHEL, or Arch Linux with ZFS on root. Seven distros, one USB, two minutes. Most install fully offline from embedded darksites.

Build golden images for Packer, Terraform, and cloud deployment — or install directly to bare metal.

**Website:** [kldload.com](https://kldload.com) | **Download:** [dl.kldload.com](https://dl.kldload.com/kldload-free-latest.iso) | **Discord:** [discord.gg/tkVN6sSU](https://discord.gg/tkVN6sSU)

---

## Quickstart

```bash
# Download and burn
curl -L -o kldload.iso https://dl.kldload.com/kldload-free-latest.iso
dd if=kldload.iso of=/dev/sdX bs=4M status=progress oflag=sync && sync

# Or build from source
git clone https://github.com/kldload/kldload.git && cd kldload
PROFILE=desktop ./deploy.sh build
```

Boot the USB → web UI opens at `:8080` → pick distro + profile → install.

---

## 7 Distros, One USB

| OS | Method | Offline |
|---|---|---|
| CentOS Stream 9 | dnf --installroot | Yes (RPM darksite) |
| Debian 13 (Trixie) | debootstrap | Yes (APT darksite) |
| Ubuntu 24.04 (Noble) | debootstrap | Yes (APT darksite) |
| Fedora 41 | dnf --installroot | Yes (RPM darksite) |
| Rocky Linux 9 | dnf --installroot | Yes (shared RPM darksite) |
| RHEL 9 | dnf --installroot | No (Red Hat CDN) |
| Arch Linux | pacstrap | Yes (pacman darksite) |

## 4 Profiles

| Profile | What you get |
|---|---|
| **Desktop** | GNOME + ZFS + all kldloadOS tools |
| **Server** | Headless SSH + ZFS + all kldloadOS tools |
| **Core** | ZFS on root + WireGuard — stock distro, nothing else |
| **AI** | Core + Ollama + local LLM + voice control |

## Two Primitives

**Encrypted L3 networking** — WireGuard in the kernel from boot. Every profile, including core.

**Self-healing storage** — ZFS on root with boot environments, snapshots, replication, per-dataset AES-256 encryption, lz4 compression, checksummed self-healing.

Everything else follows from these two.

## What's Included

- **30+ CLI tools** — `kst`, `ksnap`, `kclone`, `kdf`, `kdir`, `kpkg`, `kupgrade`, `kbe`, `kexport`, `krecovery`
- **Image export** — qcow2, VMDK, VHD, OVA, raw — one install, any platform
- **eBPF observability** — bpftrace, execsnoop, tcplife, opensnoop, biolatency
- **NVIDIA support** — GPU drivers + CUDA from the installer
- **WiFi firmware** — linux-firmware for laptop/Surface hardware support
- **cloud-init** — Packer/Terraform ready
- **Modern terminal** — fzf, btop, eza, ripgrep, zoxide, bat
- **107+ pages of documentation** at [kldload.com](https://kldload.com)

## deploy.sh

| Command | What it does |
|---|---|
| `build` | Build ISO (uses cached darksites) |
| `build-debian-darksite` | Build Debian APT offline mirror |
| `build-ubuntu-darksite` | Build Ubuntu APT offline mirror |
| `build-fedora-darksite` | Build Fedora RPM offline mirror |
| `build-arch-darksite` | Build Arch pacman offline mirror |
| `builder-image` | Rebuild builder container |
| `kvm-deploy` | Deploy to local KVM |
| `proxmox-deploy` | Deploy to Proxmox |
| `burn` | Write ISO to USB |
| `clean` | Remove build artifacts |

## Architecture

```
Fully auditable. Zero compiled binaries. Three bootstrap paths: dnf, debootstrap, pacstrap.
cat any file and read what it does.
```

Future upgrades use the public repos of the distro you chose. There is no kldload repo. There are no kldload updates. That's handled by the OS owner. kldload just lays down the plumbing.

## License

BSD-3-Clause. Free forever. See [LICENSE](LICENSE).

---

*kldloadOS 1.0 "Du-Nn" — Released March 26, 2026*
