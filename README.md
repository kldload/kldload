# kldloadOS

**One USB. Any distro. ZFS on root.**

kldloadOS assembles any Linux distribution from stock vendor repos (DNF, APT, pacman) with ZFS on root, WireGuard, and eBPF — on a single bootable ISO. Nothing forked, nothing patched. Every package pulled directly from vendor CDNs. Most distros install fully offline from embedded package mirrors (darksites).

Install profiles include KVM hypervisor with ZFS-backed instant clones, Kubernetes on ZFS with Cilium eBPF networking, AI assistant (Ollama + Open WebUI), desktop, server, and more.

**Website:** [kldload.com](https://kldload.com) | **Download:** [dl.kldload.com](https://dl.kldload.com/kldload-free-latest.iso) | **Demo:** [YouTube](https://www.youtube.com/watch?v=egFffrFa6Ss) | **Discord:** [discord.gg/tkVN6sSU](https://discord.gg/tkVN6sSU)

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
| **KVM** | KVM hypervisor + ZFS zvols + instant cloning |
| **AI** | Desktop + Ollama + local LLM + NVIDIA GPU |
| **Core** | ZFS on root + WireGuard — stock distro, nothing else |

The KVM profile includes Kubernetes templates: one command deploys a production cluster with Cilium eBPF networking, Hubble observability, MetalLB, Gateway API, and WireGuard encrypted backplanes — all on ZFS instant-cloned nodes.

```bash
kube-cluster bootstrap --workers 3
```

## What's Inside

**ZFS on root** — Boot environments, snapshots, replication, per-dataset encryption, compression, checksums. Every dataset tuned: 8K for databases, 128K for general, instant clones for VMs.

**WireGuard** — Encrypted mesh networking from first boot. Kubernetes clusters get dual encrypted backplanes (management + data).

**eBPF** — bcc-tools, bpftrace, bpftool pre-installed. BTF in the kernel. Cilium gets the full eBPF feature set — no fallback to iptables.

**KVM + ZFS instant cloning** — Clone a VM in ~100ms. Zero disk cost (copy-on-write). Golden image → snapshot → clone a fleet in seconds.

**Kubernetes (KVM profile)** — Golden image → ZFS clone N nodes → Cilium CNI (replaces kube-proxy with eBPF) → MetalLB → Gateway API → Hubble → WireGuard mesh → done. Nodes are cattle — destroy and re-clone in under a second.

**NVIDIA GPU** — Drivers from the installer. Multiple containers share one GPU via CUDA time-slicing. No PCIe passthrough required.

**AI assistant (AI profile)** — Ollama + Open WebUI + local LLM, pre-loaded and ready to chat on first boot.

**Offline install** — RPM and APT darksites baked into the ISO. No internet required for most distros.

## Tools

### Host Management
| Command | What it does |
|---|---|
| `kldload-overview` | Unified status — ZFS, VMs, K8s, GPU, eBPF, everything |
| `kvm-demo` | Interactive KVM + container demo (GPU, podman, clones) |
| `kube-demo` | Interactive Kubernetes demo (24 demos — Cilium, Hubble, eBPF internals) |
| `kst` | System health dashboard |
| `kst-dashboard` | Live tmux monitoring |

### KVM
| Command | What it does |
|---|---|
| `kvm-create` | Create VM on ZFS zvol |
| `kvm-clone` | ZFS instant clone (~100ms) |
| `kvm-snap` | Snapshot a VM |
| `kvm-list` | List all VMs |
| `kvm-delete` | Destroy VM + zvol |

### Kubernetes (KVM profile)
| Command | What it does |
|---|---|
| `kube-cluster bootstrap` | Deploy full K8s cluster from golden image |
| `kube-cluster destroy` | Tear down cluster (golden preserved) |
| `kube-demo` | 24 interactive demos (networking, storage, resilience, eBPF) |
| `kube-smoke-test` | Automated cluster verification |

### ZFS
| Command | What it does |
|---|---|
| `ksnap` | Smart snapshot manager |
| `kclone` | Clone datasets/zvols |
| `kbe` | Boot environment manager |
| `kdf` | ZFS-aware disk usage |
| `kpkg` | Package manager with pre-install snapshots |
| `kupgrade` | Safe upgrade with automatic rollback |
| `krecovery` | Disaster recovery |
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

### 1.0.4 — Kubernetes on ZFS (current)
- **200+ commits.** Kubernetes templates for the KVM profile.
- `kube-cluster bootstrap --workers N` — golden image → ZFS clones → full cluster
- Cilium eBPF CNI — no kube-proxy, no iptables, pure kernel datapath
- Hubble eBPF observability — L3/L4/L7 flow visibility from first boot
- 24 interactive kube-demo scenarios (networking, storage, resilience, eBPF internals)
- Dual WireGuard encrypted backplanes — management + data plane
- ZFS instant clones — nodes provision in ~100ms via copy-on-write
- MetalLB + Gateway API + OpenEBS ZFS CSI
- Secure Boot — MOK-signed ZFS modules, end-to-end verified boot
- ZFSBootMenu — native boot environments, GRUB eliminated
- 190+ automated smoke test checks
- CentOS Stream 9 and RHEL 9 tested with full K8s stack
- [Demo video](https://www.youtube.com/watch?v=egFffrFa6Ss)

### 1.0.3 — KVM on ZFS
- KVM hypervisor profile: ZFS zvols, instant clones (~100ms), golden image workflow
- `kvm-create`, `kvm-clone`, `kvm-snap`, `kvm-delete`, `kvm-list`, `kvm-demo`
- Debian 13 (Trixie) as first-class citizen
- AI profile: Ollama + Open WebUI + NVIDIA GPU
- Golden image export (qcow2, vmdk, vhd, ova) with cloud-init
- NVIDIA CUDA time-slicing for container GPU sharing

### 1.0.2 — AI + 8 Distros
- Added Alpine Linux, Ubuntu 24.04 offline darksite
- AI assistant: Ollama + Open WebUI + local LLM
- Boot environment manager (`kbe`)
- `kupgrade` with automatic pre-upgrade snapshots

### 1.0.1 — ZFS Everywhere
- 6 distros: CentOS, Debian, Fedora, RHEL, Rocky, Arch
- WireGuard + eBPF from first boot
- Sanoid automatic snapshot scheduling

### 1.0.0 — Initial Release
- Single ISO, 4 distros, ZFS on root
- Offline RPM darksite
- ZFSBootMenu boot environments

## License

BSD-3-Clause. Free forever. See [LICENSE](LICENSE).

---

*kldloadOS 1.0.4 — built from the kernel up.*
