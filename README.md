# kldloadOS

**One ISO. Eight distros. ZFS on root. Kubernetes in 75 milliseconds.**

kldloadOS builds a single bootable ISO that installs CentOS, Debian, Ubuntu, Fedora, Rocky, RHEL, Arch, or Alpine Linux with ZFS on root, WireGuard, and eBPF — from one USB drive. Most install fully offline from embedded package mirrors (darksites).

The KVM profile turns a bare-metal machine into a hypervisor that deploys Kubernetes clusters via ZFS instant clones — 4 nodes in under 100ms each, with Cilium eBPF networking, Hubble observability, MetalLB, and Gateway API, all from one command.

**Website:** [kldload.com](https://kldload.com) | **Download:** [dl.kldload.com](https://dl.kldload.com/kldload-free-latest.iso) | **Discord:** [discord.gg/tkVN6sSU](https://discord.gg/tkVN6sSU)

![kldloadOS Installer](screenshots/installer-ui.png)

---

## Quickstart

```bash
# Download and burn
curl -L -o kldload.iso https://dl.kldload.com/kldload-free-latest.iso
dd if=kldload.iso of=/dev/sdX bs=4M status=progress oflag=direct conv=fsync && sync

# Or build from source
git clone https://github.com/kldload/kldload.git && cd kldload
PROFILE=desktop ./deploy.sh build
```

Boot the USB → web UI opens at `:8080` → pick distro + profile → install.

---

## 8 Distros, One USB

| OS | Method | Offline |
|---|---|---|
| CentOS Stream 9 | dnf --installroot | Yes (RPM darksite) |
| Debian 13 (Trixie) | debootstrap | Yes (APT darksite) |
| Ubuntu 24.04 (Noble) | debootstrap | Yes (APT darksite) |
| Fedora 41 | dnf --installroot | Yes (RPM darksite) |
| Rocky Linux 9 | dnf --installroot | Yes (shared RPM darksite) |
| RHEL 9 | dnf --installroot | No (Red Hat CDN) |
| Arch Linux | pacman --root | No (rolling release) |
| Alpine Linux | apk add --root | Partial (apk cache) |

## Profiles

| Profile | What you get |
|---|---|
| **Desktop** | GNOME + ZFS + all kldloadOS tools |
| **Server** | Headless SSH + ZFS + all kldloadOS tools |
| **KVM** | KVM hypervisor + ZFS zvols + instant cloning + Kubernetes |
| **Core** | ZFS on root + WireGuard — stock distro, nothing else |
| **AI** | Desktop + Ollama + local LLM + NVIDIA GPU |

## The Stack

**ZFS on root** — Boot environments, snapshots, replication, per-dataset encryption, compression, checksums. Every dataset tuned: 8K for databases, 128K for general, instant clones for VMs.

**WireGuard** — Encrypted backplanes from first boot. Management and Kubernetes traffic on separate encrypted planes.

**eBPF** — bcc-tools, bpftrace, bpftool pre-installed. BTF in the kernel. Cilium gets the full eBPF feature set — no fallback to iptables.

**KVM + ZFS instant cloning** — Clone a VM in 75ms. Zero disk cost (copy-on-write). Golden image → fleet deployment in seconds.

**Kubernetes** — One command deploys a production cluster:
```bash
kube-cluster bootstrap --workers 3
```
Golden image → ZFS clone 4 nodes → Cilium CNI → MetalLB → Gateway API → Hubble → done.

**NVIDIA GPU** — Drivers from the installer. Multiple containers share one GPU via CUDA time-slicing. No PCIe passthrough required.

## Tools

### Host Management
| Command | What it does |
|---|---|
| `kldload-overview` | Unified status — ZFS, VMs, K8s, GPU, eBPF, everything |
| `kvm-demo` | Interactive KVM + container demo (GPU, podman, clones) |
| `kube-demo` | Interactive Kubernetes demo (Cilium, Hubble, MetalLB) |
| `kst` | System health dashboard |
| `kst-dashboard` | Live tmux monitoring |

### KVM
| Command | What it does |
|---|---|
| `kvm-create` | Create VM on ZFS zvol |
| `kvm-clone` | ZFS instant clone (~75ms) |
| `kvm-snap` | Snapshot a VM |
| `kvm-list` | List all VMs |
| `kvm-delete` | Destroy VM + zvol |

### Kubernetes
| Command | What it does |
|---|---|
| `kube-cluster bootstrap` | Deploy full K8s cluster on KVM |
| `kube-cluster destroy` | Tear down cluster (golden preserved) |
| `kube-setup` | Install K8s packages on a node |
| `kube-init` | Bootstrap control plane + Cilium stack |
| `kube-join` | Join a worker node |
| `kube-network` | WireGuard mesh between nodes |
| `kube-status` | Cluster health |
| `kube-reset` | Tear down K8s on a node |
| `kube-smoke-test` | 41-point verification |

### ZFS
| Command | What it does |
|---|---|
| `ksnap` | Smart snapshot manager |
| `kclone` | Clone datasets/zvols |
| `kbe` | Boot environment manager |
| `kdf` | ZFS-aware disk usage |
| `kexport` | Export golden images (qcow2, vmdk, vhd, ova, raw) |

## deploy.sh

| Command | What it does |
|---|---|
| `build` | Build ISO (uses cached darksites) |
| `build-debian-darksite` | Build Debian APT offline mirror |
| `build-ubuntu-darksite` | Build Ubuntu APT offline mirror |
| `build-fedora-darksite` | Build Fedora RPM offline mirror |
| `builder-image` | Rebuild builder container |
| `kvm-deploy` | Deploy to local KVM |
| `proxmox-deploy` | Deploy to Proxmox |
| `burn` | Write ISO to USB |
| `clean` | Remove build artifacts |

## Architecture

```
Fully auditable. Zero compiled binaries. Three bootstrap paths: dnf, debootstrap, pacstrap.
Cat any file and read what it does.
```

The live environment is always CentOS Stream 9. The user picks their target distro at install time. Future upgrades use the public repos of the distro you chose. There is no kldload repo. There are no kldload updates.

## Releases

### 1.0.3 — FreeBSD + KVM on ZFS (current)
- FreeBSD 15.0 added to installer (native ZFS, jails, bhyve)
- KVM hypervisor profile: ZFS zvols, instant clones (~100ms), golden image workflow
- `kvm-create`, `kvm-clone`, `kvm-snap`, `kvm-delete`, `kvm-list`, `kvm-demo`
- Debian 13 (Trixie) as first-class citizen
- AI profile: Ollama + Open WebUI + NVIDIA GPU
- Web UI with 5 profiles: Desktop, Server, Core, KVM, AI
- Golden image export (qcow2, vmdk, vhd, ova) with cloud-init
- `kexport` CLI for image sealing and export
- NVIDIA CUDA time-slicing for container GPU sharing

### 1.0.2 — AI + 8 Distros
- Added Alpine Linux, Ubuntu 24.04 offline darksite
- AI assistant: Ollama + Open WebUI + local LLM
- Boot environment manager (`kbe`)
- `kupgrade` with automatic pre-upgrade snapshots

### 1.0.1 — ZFS Everywhere
- 6 distros: CentOS, Debian, Fedora, RHEL, Rocky, Arch
- WireGuard + eBPF from first boot
- `kvm-demo` interactive hypervisor demo
- Sanoid automatic snapshot scheduling

### 1.0.0 — Initial Release
- Single ISO, 4 distros, ZFS on root
- Offline RPM darksite
- ZFSBootMenu boot environments

## License

BSD-3-Clause. Free forever. See [LICENSE](LICENSE).

---

*kldloadOS 1.0.3*
