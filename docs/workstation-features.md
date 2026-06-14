# kldload 1.3.0 "Workstation" — Feature List

*Fedora 44 substrate on the Linux 7.0 kernel (also RHEL/Rocky/CentOS/Debian/
Ubuntu/Arch). A reproducible developer workstation with a datacenter behind the
dock.*

> **The only Linux *workstation* that ships KVM and a full Kubernetes cluster as
> default, click-to-deploy options.**

## Compose your own workstation

kldload doesn't ship fixed "editions." The installer presents **capability
toggles above the Install button** — pick exactly what you want and it's built
for you:

- **KVM** — full libvirt virtualization host (virbr0 + br0, `kvm-create`/snap/clone)
- **Kubernetes** — a real multi-node cluster (control-plane + workers) on ZFS
  instant-clone VMs
- **klab** — multi-distro golden images + blue-green lab
- **AI (Bob)** — local GPU LLM, offline
- **Observability** — Prometheus / Grafana / Tetragon + the eBPF cockpit
- **ZFS lab**, **WireGuard mesh**, and more

Mix-and-match, press Install, and the selected capabilities are provisioned and
wired automatically — point-and-shoot. Same reproducible substrate underneath
every combination.

---

## Substrate & install

- **Fedora 44** primary substrate, **ZFS-on-root** (snapshots, boot environments,
  instant rollback), **dnf5**.
- **Reproducible 100%-darksite install** — every artifact downloaded at build
  time and packed; the install resolves **offline** from the darksite.
- **Critical-package verify gate** — the install **fails loud** if the package
  manager, kernel, NetworkManager, GDM or GNOME shell didn't land (no more
  silent `--skip-broken` shipping a broken system).
- **Public repos enabled after install**, with the **ABI-coupled substrate
  versionlocked** (kernel, kernel-devel, zfs/zfs-dkms, nvidia + akmod-nvidia,
  bcc/bpftrace) so a routine `dnf update` can never jump the kernel and brick
  ZFS/NVIDIA. 5 rescue kernels kept; `dnf-automatic` masked.
- **NVIDIA proprietary** via akmod (signed, Secure-Boot-capable) with a
  **first-boot healing net** that builds + loads the driver → correct native
  resolution instead of 1024×768.
- **Swap disabled** (ZFS-safe — avoids the swap-on-zvol deadlock; zram optional
  for low-RAM boxes).

## Desktop

- **GNOME on Wayland**, each distro wears its **own native default wallpaper**
  (F44 → Fedora day/night).
- **Chrome as the first-class browser**; webui tools open as native-feeling app
  windows with **correct per-tool dock icons** (GTK4 webview, app-id matched).
- Editors: **vim / gvim, nano, gnome-text-editor**; **konsole**; full font +
  codec stack; **Steam**.

## Infrastructure — the datacenter behind the dock

- **KVM / libvirt** virtualization: `kvm-create` / `kvm-snap` / `kvm-clone`,
  NAT `virbr0` + host bridge `br0`.
- **klab**: multi-distro **golden images** (CentOS / Debian / Fedora / Rocky /
  Ubuntu) for blue-green lab testing on ZFS instant clones.
- **Local Kubernetes** (`kube-cluster`): control-plane + workers spun as VMs on
  ZFS clones.
- **ZFS lab** + NFS/iSCSI exports.
- **WireGuard 4-plane mesh** (microsegmented: mgmt / k8s / data / enrollment).

## Observability cockpit (`sysdiag`)

- fastfetch system panel + **F-key eBPF cockpit**.
- **eBPF tracing on modern kernels** via **libbpf-tools (CO-RE/BTF)** — works on
  the F44 7.0 kernel where legacy bcc can't compile — plus **bpftrace**:
  biosnoop, biolatency, execsnoop, tcpconnect, tcplife, runqlat, zfsdist,
  zfsslower, and ~60 more.
- **Prometheus + Grafana + Tetragon** dashboards embedded in the `:8443` web UI.

## AI

- **Bob** — a local, GPU-resident LLM assistant (Ollama, qwen3), **offline**, no
  data leaves the box; voice via Chrome's Web Speech API.

## Control plane

- **kldload-webui** at `https://<host>:8443` (single nginx TLS / HTTP-2 reverse
  proxy): VMs, Kubernetes, klab, Metrics, ZFS dashboards — point-and-shoot infra.

## Reliability / ops

- **firstboot fail-loud** (`set -Eeuo pipefail` + ERR trap — every failure logs
  its exact line/command).
- **firstboot healing nets** (Chrome, NVIDIA, desktop essentials) recover any
  package the install couldn't land.
- Every install pass **verified against the rpm db**, not assumed.
