# kldload

**One USB. ZFS on root across eight Linux distributions — plus a GUI-first RHEL workstation, a KVM-on-ZFS hypervisor, Kubernetes, and a local AI assistant, all assembled from stock vendor repos.**

kldload builds any of eight supported Linux distributions from their own package repos (dnf, apt, pacman, apk) onto **ZFS on root**, with **ZFSBootMenu** boot environments, **WireGuard**, **eBPF**, and an optional **KVM hypervisor**, **Kubernetes**, **klab** multi-distro test platform, and **Bob** local AI. Nothing is forked. Nothing is patched. Every package comes straight from the vendor's CDN, and most distros install fully offline from mirrors baked into the ISO.

Pick a distro, pick a profile, install. The profiles are examples of what the substrate can become — start with one, mix in another with `kpkg add`, or build your own from the primitives.

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

Boot the USB &rarr; the web UI opens over TLS at `https://<host>:8443` &rarr; pick distro + profile + disk &rarr; install.

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

Live environment is **Fedora 44** (kernel pinned at 6.19.x, OpenZFS 2.4.x).

> **Fedora 44 + ZFS:** there is no upstream `zfsonlinux` build for Fedora 44 yet, so kldload bridges to the `fc43` OpenZFS repo and pins the target kernel to 6.19.x (F44 ships 7.0.x, which the bridge's DKMS can't build against). When an upstream Fedora 44 OpenZFS source lands, the bridge and the kernel pin go away and the target moves to native fc44 + the GA kernel.

---

## Workstation edition (1.3.0)

The **Desktop** profile is a GUI-first RHEL 10 workstation: expert operations — ZFS replication, KVM, Kubernetes, eBPF observability — exposed as point-and-shoot desktop apps, not CLI rituals.

- **Install-time Platform Options.** Checkboxes for NVIDIA drivers, KVM, Kubernetes, eBPF tooling, and golden-image building. Desktop-only, default-clean — you opt into the heavy stuff.
- **Native app windows.** Each tool (VMs, Kubernetes, ZFS, Metrics, Bob, …) opens as its own chromeless GTK/WebKit window — no browser chrome, no left menu — backed by the same web console the server edition serves.
- **Console as its own app.** The tmux F-key operator cockpit (k9s, ZFS internals, eBPF panels, VM/log streams) is a single Console application — not embedded inside every tool window.
- **Bob.** Local AI assistant (Ollama + RAG + voice) as a desktop app. No cloud, no telemetry.

---

## Profiles &mdash; examples, not the menu

| Profile | What gets assembled on first boot |
|---|---|
| **Desktop** | GNOME + ZFS root + Firefox + GPU drivers + Bob AI + full `k*` tool suite + native app windows + the Console cockpit + offline darksites |
| **Server** | Headless SSH + ZFS root + full `k*` tools + sanoid + WireGuard + eBPF + offline darksites |
| **KVM Host** | libvirt + qemu-kvm + virtio, every VM on a ZFS zvol, `~100`&nbsp;ms COW clones, atomic snapshots, `zfs send` replication |
| **AI (Bob)** | KVM Host + Ollama + RAG + the Bob agent stack on the local GPU |
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

- **OpenZFS on root** — checksummed, compressed, snapshotted, self-healing on mirrors. lz4 default. dedup / encryption optional.
- **ZFSBootMenu** — UEFI bootloader that understands ZFS. Boot environments. Seconds-fast rollback. No GRUB.
- **WireGuard** — kernel-level encrypted networking. One UDP port at the firewall.
- **eBPF observability** — BCC tools + bpftrace + an F-key tmux cockpit on the host; Cilium + Hubble + Tetragon inside the K8s profile (no kube-proxy, no iptables, no sidecars).
- **KVM hypervisor** — libvirt + qemu-kvm with every VM on a ZFS zvol. `~100`&nbsp;ms clones via COW. Atomic snapshots. fs-freeze app-consistency. Incremental `zfs send` replication.
- **NVIDIA + CUDA** — drivers and CUDA optional at install. Time-sliced GPU sharing across Bob and guest VMs. No PCIe passthrough required.
- **Bob** — local AI assistant: Ollama + RAG over the codebase + voice + tmux awareness + ReAct agent loop + eBPF-aware tool registry. No cloud, no telemetry.
- **Observability** — Prometheus + Grafana + Loki + Alertmanager, Go + bash exporters, pre-wired dashboards, `zed` ZFS events bridged to Loki.
- **Secure Boot + MOK** — per-machine key generation, automatic module signing, DKMS auto-sign on kernel upgrades. Off by default.
- **Image export** — `kexport` produces qcow2 / VMDK / VHD / OVA / raw, auto-sealed with cloud-init multi-datasource config. Ready for Packer or direct hypervisor import.
- **Offline + Air-gap** — RPM and APT mirrors baked in. The USB is the deployment, the recovery, and the air gap.

---

## CLI tools

### Host
| Command | What it does |
|---|---|
| `kldload-overview` | Unified host status — ZFS, VMs, K8s, GPU, eBPF, services |
| `kst` | System health dashboard |
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
| `full` | Rebuild the builder image + all darksites, then build the ISO |
| `clean` | Remove build artifacts |
| `burn` | Write the ISO to a USB device |
| `builder-image` | Rebuild the CentOS Stream 9 builder container |
| `smoke-build` | Static checks on the built ISO (size, freshness, content) |
| `smoke-test <distro> <profile>` | Full install lifecycle in KVM, then smoke-test the installed target |
| `build-debian-darksite` / `build-ubuntu-darksite` | Build / refresh the APT offline mirrors |
| `build-fedora-darksite` | Build / refresh the RPM offline mirror |
| `build-ollama-darksite` | Cache the Bob/Ollama model bundle |
| `kvm-deploy` / `kvm-deploy-bob` | Deploy the ISO to local KVM via virt-install |
| `proxmox-deploy` | Deploy to a remote Proxmox host via the `qm` API |
| `deploy-all` | Build + deploy across the configured targets |

---

## Architecture

```
Live environment:  Fedora 44 (kernel 6.19.x, OpenZFS 2.4.x)
Builder:           CentOS Stream 9 container (lorax + squashfs-tools + xorriso + dracut)
Bootstrap paths:   dnf --installroot  (CentOS / Fedora / Rocky / RHEL)
                   debootstrap        (Debian / Ubuntu)
                   pacstrap           (Arch)
                   apk add --root     (Alpine)

Installer:         Python web UI + ~10 bash libraries (lib/) + backend/bin tools
Web UI:            single HTML file per edition + WebSocket install-log stream
Single-port TLS:   kldload-proxy fronts the web UI, Grafana, Prometheus, Headlamp,
                   Bob, k9s/ttyd, and the libvirt console on one URL (:8443) with one cert
```

The user picks the target distro at install time. After install the system runs upstream packages from the vendor's public repos. There is no kldload package repository and no kldload-specific runtime updates — `dnf update` / `apt upgrade` / `pacman -Syu` just work.

---

## Releases

### 1.3.0 &mdash; Workstation (current)
- GUI-first RHEL 10 workstation: expert ops (ZFS / KVM / K8s / eBPF) as point-and-shoot desktop apps
- Install-time **Platform Options** — NVIDIA / KVM / Kubernetes / eBPF / golden-image building, desktop-only, default-clean
- Native per-tool app windows (chromeless GTK/WebKit), NVIDIA + Wayland render fixes
- Console (tmux cockpit) promoted to its own application, de-duplicated from every tool window
- RHEL 10 desktop package + TLS fixes (ptyxis, zenity, glib-networking)

### 1.2.0 &mdash; Full Stack Automation (release candidate; folded into 1.3.0)
- PetClinic Microservices + ArgoCD wired into autodeploy
- sanoid / syncoid on by default with sensible policies
- Web UI Demo Mode with deploy / disaster / recover buttons
- State & reconciliation layer under `/var/lib/kldload/state/`
- Deterministic install ordering (CP &rarr; workers &rarr; Cilium &rarr; observability &rarr; Tetragon &rarr; klab)

### 1.1.0 &mdash; Hardware Reality
- Live env cut over from CentOS Stream 9 to Fedora 44 (kernel 6.19, OpenZFS 2.4.x)
- Single-port TLS reverse proxy fronting every internal service
- Tetragon wired through to Grafana panels
- klab graduated to a first-class profile with per-distro goldens
- Install path rewritten end-to-end against real hardware

### 1.0.x &mdash; Foundations
ZFS on root + ZFSBootMenu, the offline RPM/APT darksites, KVM-on-ZFS with instant zvol clones, `kube-cluster` (K8s on ZFS-backed VMs with Cilium/Hubble/Tetragon), the Bob agent, the observability stack, and the growth from 4 to all eight distributions.

---

## License

BSD-3-Clause. See [LICENSE](LICENSE).
