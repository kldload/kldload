# kldload

**One USB. Two things, done right: ZFS on Linux across eight distributions, and a bad-ass KVM hypervisor with ZFS underneath.**

kldload assembles any of eight supported Linux distributions from stock vendor repos (dnf, apt, pacman, apk) with **ZFS on root**, **WireGuard**, **Cilium eBPF**, and an optional **KVM hypervisor**, **Kubernetes**, **klab** multi-distro test platform, and **Bob** local AI assistant. Nothing is forked. Nothing is patched. Every package is pulled directly from the vendor's CDN. Most distros install fully offline from package mirrors embedded in the ISO.

Pick a distro, pick a profile, install. The profiles are examples of what the substrate can become — start with one, mix in another with `kpkg add`, or define your own from the primitives.

**Website:** [kldload.com](https://kldload.com) &middot; **Download:** [dl.kldload.com](https://dl.kldload.com/kldload-free-latest.iso) &middot; **Discord:** [discord.gg/QX8wf38N3V](https://discord.gg/QX8wf38N3V)

**Installer**

![kldload Installer](screenshots/installer-ui.png)

**Dashboard (first boot)**

![kldload Dashboard](screenshots/dashboard.png)

---

## Quickstart

```bash
# Download and burn (USB target)
curl -L -o kldload.iso https://dl.kldload.com/kldload-free-latest.iso
sudo wipefs -af /dev/sdX
sudo dd if=kldload.iso of=/dev/sdX bs=4M oflag=direct conv=fsync status=progress && sync

# Or build from source
git clone https://github.com/kldload/kldload.git && cd kldload
PROFILE=desktop ./deploy.sh build
```

Boot the USB &rarr; web UI opens at `:8080` &rarr; pick distro + profile + disk &rarr; install.

---

## Eight distributions, one USB

| Distribution | Install method | Offline |
|---|---|---|
| CentOS Stream 9 | `dnf --installroot` | Yes (RPM darksite) |
| Debian 13 (Trixie) | `debootstrap` | Yes (APT darksite) |
| Ubuntu 24.04 (Noble) | `debootstrap` | Yes (APT darksite, universe enabled) |
| Fedora 44 | `dnf --installroot` | Yes (RPM darksite) |
| Rocky Linux 9 | `dnf --installroot` | Yes (shared RPM darksite) |
| RHEL 10 | `dnf --installroot` | No (Red Hat CDN; subscription required) |
| Arch Linux | `pacstrap` | No (rolling; requires internet) |
| Alpine Linux | `apk add --root` | Partial (apk cache) |

Live environment is **Fedora 44** (kernel 6.19, OpenZFS 2.4.1).

---

## Seven profiles &mdash; examples, not the menu

| Profile | What gets assembled on first boot |
|---|---|
| **Desktop** | GNOME + ZFS + Firefox + GPU drivers + Bob AI + all `k*` tools + sanoid + offline darksites |
| **Server** | Headless SSH + ZFS + all `k*` tools + sanoid + WireGuard + eBPF + offline darksites |
| **KVM Host** | libvirt + qemu-kvm + virtio, every VM on a ZFS zvol, `~100`&nbsp;ms COW clones, atomic snapshots, `zfs send` replication |
| **Kubernetes** | KVM Host + a turnkey single- or three-node K8s cluster, Cilium eBPF, Hubble, Tetragon, MetalLB, ZFS-backed PVs, ArgoCD demo |
| **klab** | KVM Host + golden VMs per supported distro, blue/green via ZFS instant clone, fault injection, Distro Matrix Runner, live Hubble traffic map |
| **OpenZFS Suite** | KVM Host + dedicated test goldens wired into `ztest`/`zloop` for upstream OpenZFS regression hunting |
| **Core** | ZFS on root only. Stock distro. No `k*` tools, no web UI, no darksites. ~200 MB beyond the vendor's base install |

```bash
kube-cluster up           # single- or three-node K8s in < 20 minutes
kube-demo                 # PetClinic + ArgoCD smoke test
klab golden centos        # build the CentOS golden VM
klab matrix run script.sh # run a change against every supported distro in parallel
```

---

## What's wired into the image

- **OpenZFS 2.4.1 on root** — checksummed, compressed, snapshotted, self-healing on mirrors. lz4 default. dedup / encryption optional.
- **ZFSBootMenu** — UEFI bootloader that understands ZFS. Boot environments. 15-second rollback. No GRUB.
- **WireGuard** — kernel-level encrypted networking. One UDP port at the firewall.
- **Cilium eBPF + Hubble + Tetragon** — L3/L4/L7 datapath in the kernel. No kube-proxy. No iptables. No sidecars.
- **KVM hypervisor** — libvirt + qemu-kvm with every VM on a ZFS zvol. `~100`&nbsp;ms clones via COW. Atomic snapshots. fs-freeze app-consistency. Incremental `zfs send` replication.
- **NVIDIA + CUDA** — drivers and CUDA baked in. Time-sliced GPU sharing across Bob and guest VMs. No PCIe passthrough required.
- **Bob** — local AI assistant: Ollama + RAG over the codebase + voice + tmux awareness + ReAct agent loop + eBPF-aware tool registry. No cloud, no telemetry.
- **Observability** — Prometheus + Grafana + Loki + Alertmanager. Four Go exporters. Eight pre-wired dashboards. `zed` events bridged to Loki.
- **Secure Boot + MOK** — per-machine key generation. Automatic module signing. DKMS auto-sign on kernel upgrades.
- **Image export** — `kexport` produces qcow2 / VMDK / VHD / OVA / raw. Auto-sealed with cloud-init multi-datasource config. Ready for Packer or direct hypervisor import.
- **Offline + Air-gap** — RPM and APT mirrors baked in. The USB is the deployment, the recovery, and the air gap.

---

## CLI tools

### Host
| Command | What it does |
|---|---|
| `kldload-overview` | Unified host status — ZFS, VMs, K8s, GPU, eBPF, services |
| `kst` | System health dashboard |
| `kdoctor` | Subsystem health checks |
| `kldload-console` | tmux F-key cockpit with live eBPF panels |

### ZFS
| Command | What it does |
|---|---|
| `ksnap` | Snapshot manager |
| `kclone` | Clone datasets / zvols |
| `kbe` | Boot environment manager |
| `kdf` | ZFS-aware disk usage |
| `kpkg` | Package manager with pre-install snapshots |
| `kupgrade` | Safe upgrade with automatic rollback |
| `krecovery` | Disaster recovery |
| `kexport` | Export golden images (qcow2 / VMDK / VHD / OVA / raw) |

### KVM
| Command | What it does |
|---|---|
| `kvm-create` | Create VM on a ZFS zvol |
| `kvm-clone` | ZFS instant clone (`~100`&nbsp;ms) |
| `kvm-snap` | Snapshot a VM |
| `kvm-list` | List all VMs |
| `kvm-delete` | Destroy VM + zvol |

### Kubernetes
| Command | What it does |
|---|---|
| `kube-cluster up` | Bring up a single- or three-node K8s cluster |
| `kube-cluster destroy` | Tear it down (golden preserved) |
| `kube-demo` | Deploy PetClinic + ArgoCD smoke test |
| `kube-smoke-test` | Automated cluster verification |

### klab
| Command | What it does |
|---|---|
| `klab golden <distro>` | Build / refresh a golden VM image |
| `klab matrix run` | Run a script against every supported distro in parallel |
| `klab-vm-debug-bundle` | Auto-fires on test failure — OpenZFS-ready debug tarball |

---

## deploy.sh

| Subcommand | What it does |
|---|---|
| `build` | Build the ISO (uses cached darksites) |
| `build-debian-darksite` | Build / refresh the Debian APT offline mirror |
| `build-ubuntu-darksite` | Build / refresh the Ubuntu APT offline mirror |
| `builder-image` | Rebuild the builder container image |
| `kvm-deploy` | Deploy the ISO to local KVM via virt-install |
| `proxmox-deploy` | Deploy to a remote Proxmox host via the `qm` API |
| `burn` | Write the ISO to a USB device |
| `smoke-build` | Static checks on the built ISO (size, freshness, content) |
| `smoke-test <distro> <profile>` | Full install lifecycle in KVM, then smoke-test the installed target |
| `clean` | Remove build artifacts |

---

## Architecture

```
Live environment:  Fedora 44 (kernel 6.19, OpenZFS 2.4.1)
Builder:           CentOS Stream 9 container (lorax + squashfs-tools + xorriso + dracut)
Bootstrap paths:   dnf --installroot  (EL / Fedora / Rocky / RHEL)
                   debootstrap        (Debian / Ubuntu)
                   pacstrap           (Arch)
                   apk add --root     (Alpine)

Installer:         single Python file (web UI) + ~10 bash libraries
Web UI:            single HTML file per edition + WebSocket install log stream
Single-port TLS:   kldload-proxy fronts Grafana / Prometheus / Headlamp / Bob / k9s / libvirt-console
                   on one URL with one certificate
```

The user picks the target distro at install time. After install, the system runs upstream packages from the vendor's public repos. There is no kldload package repository. There are no kldload-specific runtime updates &mdash; `dnf update` / `apt upgrade` / `pacman -Syu` just work.

---

## Releases

### 1.2.0 &mdash; Full Stack Automation (in flight)
- PetClinic Microservices + ArgoCD wired into autodeploy
- sanoid / syncoid on by default with sensible policies
- Webui Demo Mode subpage with deploy / disaster / recover buttons
- State &amp; reconciliation layer scaffolding under `/var/lib/kldload/state/`
- Deterministic install ordering (CP &rarr; workers &rarr; Cilium &rarr; observability &rarr; Tetragon &rarr; klab)
- `kldload-zvol-csi` for per-PVC zvols (1.2 roadmap)

### 1.1.0 &mdash; Hardware Reality
- Live env cut over from CentOS Stream 9 to Fedora 44 (kernel 6.19, OpenZFS 2.4.1)
- Single-port TLS reverse proxy fronting every internal service
- Tetragon wired all the way to Grafana panels
- klab graduated to a first-class profile with seven distro goldens
- Install path rewritten end-to-end against real hardware

### 1.0.6 &mdash; Bob Goes Agentic
- ReAct agent loop with bounded reasoning
- `pane_layout` tool spawns tiled tmux for live multi-target observation
- eBPF-aware tool registry: `bpftrace_script`, `bcc_tool`, `kernel_info`, `check_kprobe`, `ftrace_function`, `perf_stat`
- Pattern library (`analyze_zfs_slow_writes`, `analyze_network_tail_latency`, etc.)
- Default model: `qwen3:30b-a3b` (MoE, first-class tool calling)

### 1.0.5 &mdash; Hardware Bundle &amp; Observability
- Universal hardware bundle (~350 MB of laptop hardware + codecs for Desktop)
- Full observability stack: 4 Go exporters + 4 bash exporters + 8 Grafana dashboards
- `zed` &rarr; Loki bridge for every ZFS pool event
- `klab-vm-debug-bundle` auto-fires on test failure
- Install reliability fixes: ZFS hostid propagation, dracut `--no-hostonly`, Fedora firmware split workaround
- SBAT ZFSBootMenu fix (shim v15.8 compatible)

### 1.0.4 &mdash; Kubernetes on ZFS
- `kube-cluster up` &mdash; single- / three-node K8s on ZFS-backed zvol VMs
- Cilium eBPF CNI (no kube-proxy)
- Hubble L3/L4/L7 flow visibility
- Tetragon runtime security
- MetalLB + Gateway API + ZFS-backed PVs

### 1.0.3 &mdash; KVM on ZFS
- KVM hypervisor profile
- ZFS zvol instant clones (`~100`&nbsp;ms)
- Golden image export (qcow2 / VMDK / VHD / OVA)
- NVIDIA CUDA time-slicing for container GPU sharing
- Debian 13 (Trixie) as first-class

### 1.0.2 &mdash; AI + 8 Distros
- Added Alpine Linux + Ubuntu 24.04 offline darksite
- Local AI: Ollama + Open WebUI
- Boot environment manager (`kbe`)
- `kupgrade` with automatic pre-upgrade snapshots

### 1.0.1 &mdash; Arch &amp; Fedora
- 6 distros: CentOS, Debian, Fedora, RHEL, Rocky, Arch
- WireGuard + eBPF from first boot
- sanoid automatic snapshot scheduling

### 1.0.0 &mdash; Initial Release
- Single ISO, 4 distros, ZFS on root
- Offline RPM darksite
- ZFSBootMenu boot environments

---

## License

BSD-3-Clause. See [LICENSE](LICENSE).
