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
| CentOS Stream 10 | `dnf --installroot` | Network (no EL darksite yet) |
| Debian 13 (Trixie) | `debootstrap` | Yes (APT darksite) |
| Ubuntu 24.04 (Noble) | `debootstrap` | Yes (APT darksite, universe enabled) |
| Fedora 44 | `dnf --installroot` | Yes (RPM darksite) |
| Rocky Linux 10 | `dnf --installroot` | Network (no EL darksite yet) |
| RHEL 10 | `dnf --installroot` | No (Red Hat CDN; subscription required) |
| Arch Linux | `pacstrap` | No (rolling; requires internet) |
| Alpine Linux | `apk add --root` | Partial (apk cache) |

Live environment is **Fedora 44** (kernel 7.0.x — currently `7.0.12` — with OpenZFS `2.4.3` on root).

> **Fedora 44 + ZFS:** OpenZFS now ships a native `fc44` build (`2.4.3`) that builds against Fedora 44's stock 7.0 kernel, so there is no `fc43` bridge and no kernel pin — the live ISO and the installed target ride the GA kernel. The shipped kernel + OpenZFS + NVIDIA are **versionlocked at first boot**, so a routine `dnf update` can't pull a kernel ZFS can't build for. (OpenZFS 2.4.x caps at kernel ≤ 7.0.x; the substrate only moves to a newer kernel once a matching ZFS build exists.)

---

## Workstation edition (1.3.1)

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
| `builder-image` | Rebuild the Fedora 44 builder container |
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
Live environment:  Fedora 44 (kernel 7.0.x, OpenZFS 2.4.3)
Builder:           Fedora 44 container (lorax + squashfs-tools + xorriso + dracut)
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

### 1.3.1 &mdash; The Kernel-Loaded Desktop (current)
- **CentOS Stream + Rocky moved to EL10** (kernel 6.12, OpenZFS 2.3) to match RHEL 10 &mdash; retires the EL9 (5.14) path that wedged dracut/NVIDIA on first boot
- Per-tool **native-app dashboards** (each web tool opens as its own dock-iconed window) and **VM restore-on-reboot** (running VMs return after a reboot; stopped stay stopped)
- Live env corrected to Fedora 44 **kernel 7.0.12 / OpenZFS 2.4.3** (the old 6.19 pin is gone; ZFS 2.4.3 builds against the GA 7.0 kernel)
- Substrate (kernel + OpenZFS + NVIDIA) **versionlocked at first boot** so `dnf update` can't brick ZFS boot
- KVM / Kubernetes / lab profiles now warn they need hardware virtualization (VT-x / AMD-V or nested virt)

### 1.3.0 &mdash; Workstation+
The Full Stack Automation work-in-progress that was tagged 1.2.0 internally
was never released as a separate version &mdash; it shipped as part of 1.3.0
alongside the Workstation polish. "+" is the hotrod mark on the default
wallpaper: same RHEL 10 desktop image, steel-blue tint, faint &lsquo;+&rsquo;
in the lower-right corner saying *this isn't stock*.

**Workstation (the GUI layer):**
- GUI-first RHEL 10 workstation: expert ops (ZFS / KVM / K8s / eBPF) as point-and-shoot desktop apps
- Install-time **Platform Options** &mdash; NVIDIA / KVM / Kubernetes / eBPF / golden-image building, desktop-only, default-clean
- Native per-tool app windows (chromeless GTK/WebKit), NVIDIA + Wayland render fixes (GSK_RENDERER=ngl pre-baked; firstboot also reloads running user sessions so the fix lands without a re-login &mdash; no first-session Nautilus segfault)
- Console (tmux cockpit) promoted to its own application, de-duplicated from every tool window
- VM serial console embedded in the web UI via the same ttyd-k9s session
- RHEL 10 desktop package + TLS fixes (ptyxis, zenity, glib-networking)
- Steam (Flathub) + nvidia-settings + gvim as default workstation apps
- Refined icon set: per-family colour with one warm accent per glyph, hotrodded RHEL 10 wallpaper, dock pinned to Files / Firefox / Konsole on installed systems (empty on the live ISO so the installer is the focus)

**Full Stack Automation (the install-time layer):**
- PetClinic Microservices + ArgoCD wired into autodeploy
- sanoid / syncoid on by default with sensible policies
- Web UI Demo Mode with deploy / disaster / recover buttons
- State & reconciliation layer under `/var/lib/kldload/state/`
- Deterministic install ordering (CP &rarr; workers &rarr; Cilium &rarr; observability &rarr; Tetragon &rarr; klab)
- Installer auto-generates + bakes an admin SSH key into every install &mdash; nodes are peer-reachable out of the box

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
