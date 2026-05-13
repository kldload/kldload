# kldload Tool Reference — Bob's Knowledge Base
# Auto-generated from tool source code. Bob uses this to answer questions
# and execute commands on the kldload platform.

## Available Commands

### klab
══════════════════════════════════════════════════════════════════════════
klab — Multi-Distro Test Platform
══════════════════════════════════════════════════════════════════════════

Turns any hardware into a one-click multi-distro test bay. Golden images
for 7 Linux distros, ZFS instant clones (~75ms per VM), blue-green
deployment, pluggable payloads (ZFS tests, Kubernetes, custom playbooks),
full observability stack (Prometheus/Grafana/Loki), eBPF tracing, and
NVIDIA GPU support when detected.

Architecture:
Golden images → ZFS clones → Blue/Green sites → Payloads → Results
Each golden is built once (cloud image + ZFS + eBPF + dev tools),
then cloned instantly for every test run. Blue-green lets you test
changes in green while blue stays as the known-good baseline.

Distros:  CentOS Stream 9, Rocky 9, Fedora 41, Debian 13, Ubuntu 24.04,
Arch Linux, Alpine Linux (+RHEL 10 via Red Hat CDN + subscription)

Usage:
  - klab 00
  - klab 10
  - klab 11
  - klab 12
  - klab 13
  - klab 14
  - klab 15
  - klab all
  - klab apk
  - klab apt
  - klab deploy
  - klab destroy
  - klab dnf
  - klab git
  - klab golden
  - klab goldens
  - klab kubernetes
  - klab menu
  - klab pacman
  - klab promote

### klab-exporter

### kvm-create
kvm-create — create a VM on ZFS zvol with sensible defaults
Auto-elevate to root (ZFS + libvirt require it)
Usage: kvm-create <name> [options]

### kvm-clone
kvm-clone — instant CoW clone of a VM using ZFS
Auto-elevate to root (ZFS + libvirt require it)
Usage: kvm-clone <source-vm> <new-name> [--snap <snapshot>]
Verify source exists
Check dest doesn't exist

### kvm-snap
kvm-snap — ZFS snapshot a VM's zvol
Auto-elevate to root (ZFS + libvirt require it)
Usage: kvm-snap <vm-name> [action]
Verify zvol exists
  - kvm-snap rollback

### kvm-delete
kvm-delete — cleanly remove a VM and its ZFS zvol
Auto-elevate to root (ZFS + libvirt require it)
Usage: kvm-delete <vm-name> [--force]
Check VM exists

### kvm-list
kvm-list — show all VMs with ZFS zvol status
Auto-elevate to root (ZFS + libvirt require it)

### kvm-demo
kldload 1.0.4 — Superpower Demo for Screenshots
64GB RAM / 24 cores / RTX 3080
── Platform detection ─────────────────────────────────────
eBPF tool paths: CentOS=/usr/share/bcc/tools/<name>, Debian=/usr/sbin/<name>-bpfcc
Resolve VNC IP from default route
── GLOBAL CLEANUP ─────────────────────────────────────────
  - kvm-demo 10
  - kvm-demo 11
  - kvm-demo 12
  - kvm-demo 13
  - kvm-demo 14
  - kvm-demo 15
  - kvm-demo 16
  - kvm-demo 17
  - kvm-demo 18
  - kvm-demo 19
  - kvm-demo 20
  - kvm-demo 21
  - kvm-demo 22
  - kvm-demo 23
  - kvm-demo 24
  - kvm-demo 99

### kube-cluster
══════════════════════════════════════════════════════════════════════════════
kube-cluster — deploy a Kubernetes cluster on KVM using ZFS instant clones
══════════════════════════════════════════════════════════════════════════════

Deploys a production-grade Kubernetes cluster in a single command. The core
insight is ZFS copy-on-write: a "golden image" zvol is prepared once (cloud
image + K8s packages), snapshotted, then cloned per-node in ~100ms at near
zero disk cost. Each clone gets its own cloud-init ISO to establish a unique
identity (hostname, machine-id, SSH host keys).

Architecture:
cloud qcow2 → ZFS zvol → cloud-init boot → kube-setup → seal → snapshot
↓
clone CP ─┐  (each clone = ZFS instant clone of golden@golden snapshot)
clone W1 ─┤  (each gets a per-node cloud-init ISO for unique identity)
clone W2 ─┤
clone W3 ─┘→ WireGuard mesh → kubeadm init/join → Cilium eBPF → done

Network topology (dual WireGuard planes):
wg-mgmt  (10.251.0.0/24) — management plane: SSH, kubelet, API server
  - kube-cluster aarch64
  - kube-cluster bootstrap
  - kube-cluster debian
  - kube-cluster destroy
  - kube-cluster golden
  - kube-cluster scale
  - kube-cluster status
  - kube-cluster ubuntu
  - kube-cluster x86_64

### kube-init
kube-init — bootstrap a Kubernetes control plane with Cilium CNI
Run on the first control plane node after kube-setup
Auto-elevate to root
── Pre-flight checks ─────────────────────────────────────────────────────
── Detect node IP ─────────────────────────────────────────────────────────
── ZFS snapshot before init ───────────────────────────────────────────────

### kube-setup
kube-setup — install Kubernetes packages on any kldload node (apt or dnf)
Installs: containerd, kubeadm, kubelet, kubectl, cri-tools, Helm, Cilium CLI
Works on: CentOS, RHEL, Rocky, Fedora (dnf) and Debian, Ubuntu (apt)
Auto-elevate to root
── Detect package manager ─────────────────────────────────────────────────
── Kernel modules & sysctl ────────────────────────────────────────────────

### kube-join
kube-join — join a worker node to an existing kldload Kubernetes cluster
Usage: kube-join <control-plane-ip>
Auto-elevate to root
Usage: kube-join <control-plane-ip>
── Pre-flight ─────────────────────────────────────────────────────────────
── ZFS snapshot before join ───────────────────────────────────────────────
── Get join command from control plane ────────────────────────────────────

### kube-reset
kube-reset — tear down Kubernetes on this node (safely, with ZFS rollback option)
Auto-elevate to root
ZFS snapshot before reset
Clean iptables/nftables rules left by kube-proxy or Cilium
Remove CNI state

### kube-status
kube-status — comprehensive Kubernetes cluster health check
Auto-elevate to root
Cluster info
Nodes
Component status
System pods
All namespaces summary
Resource usage

### kube-demo
kldload 1.0.4 — Kubernetes Demo
Shows the full K8s stack running on ZFS instant clones
Usage: kube-demo [--no-pause]
── Detect cluster ─────────────────────────────────────────
Run kubectl — always local (kubeconfig points to CP API)
  - kube-demo 00
  - kube-demo 10
  - kube-demo 11
  - kube-demo 12
  - kube-demo 13
  - kube-demo 14
  - kube-demo 15
  - kube-demo 16
  - kube-demo 17
  - kube-demo 18
  - kube-demo 19
  - kube-demo 20
  - kube-demo 21
  - kube-demo 22
  - kube-demo 23
  - kube-demo 24
  - kube-demo 99

### kube-smoke-test
kube-smoke-test — comprehensive audit and smoke test for kldload Kubernetes
Tests every layer: packages, containerd, kernel, ZFS, WireGuard, kubeadm, Cilium
Run on a node after kube-setup to verify readiness, or after kube-init to verify cluster
── 1. Package Manager ────────────────────────────────────────────────────
── 2. Kernel Modules ────────────────────────────────────────────────────
── 3. Sysctl ──────────────────────────────────────────────────────────────
── 4. Swap ────────────────────────────────────────────────────────────────

### kube-network
kube-network — configure WireGuard backplane for Kubernetes cluster
Sets up encrypted mesh between K8s nodes with dedicated planes:
wg-mgmt (10.250.0.x)  — SSH, management, monitoring
wg-k8s  (10.251.0.x)  — kubelet, API server, Cilium, pod-to-pod

Usage:
kube-network init <node-id>           — generate keys, create configs (node-id: 1-254)
kube-network add-peer <peer-ip> <peer-pubkey> <peer-id>  — add a peer to the mesh
kube-network status                   — show WireGuard status
kube-network pin-kubelet              — pin kubelet to wg-k8s interface
kube-network nft                      — apply K8s-aware nftables rules
Usage: kube-network <command> [args]
  - kube-network add-peer
  - kube-network init
  - kube-network nft
  - kube-network pin-kubelet
  - kube-network show-keys
  - kube-network status

### kube-load-images
kube-load-images — import pre-pulled container images from darksite into containerd
Run before kube-init on offline/air-gapped systems

### kzfs-lab
══════════════════════════════════════════════════════════════════════════
kzfs-lab — ZFS Development Lab on KVM with Blue-Green Deployment
══════════════════════════════════════════════════════════════════════════

Deploys 6 Linux distros as KVM virtual machines on a ZFS-backed hypervisor,
each provisioned with the full OpenZFS source tree, zfs-tests.sh test suite,
eBPF tracing tools, and C/kernel dev toolchains.

The 6 distros are chosen to cover all three Linux package manager families:
- dnf family:    CentOS Stream 9, Rocky Linux 9, Fedora 41
- apt family:    Debian 13 (Trixie), Ubuntu 24.04 (Noble)
- pacman family: Arch Linux (rolling)
This ensures OpenZFS is tested against every major packaging ecosystem —
the same kernel module, different userlands, different DKMS integrations.

Blue-Green Deployment Concept:
Golden images are base templates built once (download cloud image, install
ZFS + dev tools, seal for cloning). From goldens, two identical "sites"
can be deployed:
- Blue  = production baseline (known-good state)
  - kzfs-lab 10
  - kzfs-lab 11
  - kzfs-lab 12
  - kzfs-lab 13
  - kzfs-lab 14
  - kzfs-lab 15
  - kzfs-lab all
  - kzfs-lab apt
  - kzfs-lab build
  - kzfs-lab demo
  - kzfs-lab deploy
  - kzfs-lab destroy
  - kzfs-lab dnf
  - kzfs-lab ebpf-arc
  - kzfs-lab ebpf-latency
  - kzfs-lab goldens
  - kzfs-lab health
  - kzfs-lab pacman
  - kzfs-lab promote
  - kzfs-lab rollback

### kzfs-test
══════════════════════════════════════════════════════════════════════════
kzfs-test — OpenZFS Test Lab
══════════════════════════════════════════════════════════════════════════

OpenZFS Test Lab — runs zfs-tests.sh across 7 Linux distros in parallel
using ZFS instant clones on KVM. Each distro VM is cloned from a sealed
golden image in ~75ms, booted, tested, and destroyed.

Distros:  CentOS Stream 9, Rocky 9, Fedora 41, Debian 13, Ubuntu 24.04,
Arch Linux, Alpine Linux

Usage:
kzfs-test golden [distro|all]            Build golden images
kzfs-test run [--quick|--full] [--distro d1,d2,...]  Run tests
kzfs-test status                         Show VMs, goldens, running tests
kzfs-test results [run-id]               Show test matrix from last run
kzfs-test destroy [--all]                Destroy test VMs (--all = goldens too)
kzfs-test verify [distro|all]            Quick smoke test — ZFS loads? tests exist?
── Configuration ─────────────────────────────────────────────────────────
ZFS source mode: "repo" (default), "version:X.Y.Z", "git:owner/repo@ref", "tarball:/path"
  - kzfs-test 00
  - kzfs-test 10
  - kzfs-test 11
  - kzfs-test 12
  - kzfs-test 13
  - kzfs-test apk
  - kzfs-test apt
  - kzfs-test destroy
  - kzfs-test dnf
  - kzfs-test git
  - kzfs-test golden
  - kzfs-test menu
  - kzfs-test pacman
  - kzfs-test results
  - kzfs-test run
  - kzfs-test status
  - kzfs-test tarball
  - kzfs-test verify
  - kzfs-test version

### ksnap
ksnap — simplified ZFS snapshot interface
Usage:
ksnap                     # snapshot all key datasets
ksnap /home/admin         # snapshot a specific path
ksnap list                # show all snapshots with ages
ksnap rollback /path      # roll back a dataset to its last snapshot
ksnap destroy <snap>      # destroy a specific snapshot
Resolve a path to its ZFS dataset
    target="${2:?Usage: ksnap rollback /path}"
    snap="${2:?Usage: ksnap destroy <snapshot-name>}"
  - ksnap all
  - ksnap destroy
  - ksnap list
  - ksnap rollback

### kclone
kclone — CoW clone a ZFS dataset (near-instant, near-zero space)
Usage:
kclone /home/admin /home/admin-backup
kclone /srv/database /srv/database-test
src_path="${1:?Usage: kclone <source-path> <dest-path>}"
dst_path="${2:?Usage: kclone <source-path> <dest-path>}"
Resolve source path to dataset
Derive destination dataset name from the destination path
e.g., /home/admin-backup → rpool/home/admin-backup
Check destination doesn't already exist

### kdf
kdf — ZFS-aware disk usage (shows compression ratio and quotas)
Pool summary

### kdir
kdir — create a ZFS dataset instead of a plain directory
Usage: kdir [-p] [-o property=value] ... <mountpoint> [<mountpoint> ...]

Examples:
kdir /home/alice               → zfs create rpool/home/alice
kdir /srv/myapp/data           → zfs create rpool/srv/myapp/data
kdir -p /srv/a/b/c             → create intermediate datasets as needed
kdir -o compression=zstd /data → set extra ZFS properties
Usage: kdir [-p] [-o property=value] ... <mountpoint> [<mountpoint> ...]
── Resolve the ZFS dataset name for a given absolute path ───────────────────
Walks up the path to find the ZFS dataset that owns it, then appends the
relative suffix to form the new dataset name.

e.g.  /srv/apps  →  rpool/srv/apps  (if /srv is rpool/srv)

### kpkg
kpkg — universal package manager wrapper
Auto-detects apt/dnf/pacman and runs the right command.
Takes a ZFS snapshot before install/upgrade/remove operations.
  - kpkg apt-get
  - kpkg dnf
  - kpkg info
  - kpkg install
  - kpkg list
  - kpkg pacman
  - kpkg remove
  - kpkg search
  - kpkg update
  - kpkg upgrade

### kexport
kexport — export a disk to qcow2, raw, VHD, VMDK, or OVA
Usage: kexport /dev/sda qcow2
kexport /dev/vda vmdk
kexport /dev/sda all
  echo "Usage: kexport <disk> <format> [output-dir]"
  - kexport ova
  - kexport qcow2
  - kexport raw
  - kexport vhd
  - kexport vmdk

### kimage
kimage — build, export, and deploy golden cloud-init images
Usage:
kimage build                     Prep this system as a golden image
kimage export [format] [outdir]  Export disk to image (default: qcow2)
kimage deploy <image> <count>    Stamp out N VMs from an image
kimage full [count]              Build + export + deploy in one shot
Auto-detect the root disk
Detect virt-install --os-variant from the running distro
  - kimage all
  - kimage build
  - kimage centos
  - kimage debian
  - kimage deploy
  - kimage export
  - kimage full
  - kimage qcow2
  - kimage raw
  - kimage rhel
  - kimage rocky
  - kimage ubuntu
  - kimage vhd
  - kimage vmdk

### kst
kst — system health at a glance
Shows pool health, disk usage, snapshots, boot environments, and services.
── Pool health ───────────────────────────────────────────────────────────────
── Disk usage ────────────────────────────────────────────────────────────────
── Snapshots ─────────────────────────────────────────────────────────────────
── Boot environments ────────────────────────────────────────────────────────
── Services ──────────────────────────────────────────────────────────────────
  - kst active
  - kst DEGRADED
  - kst inactive
  - kst ONLINE

### kst-dashboard
kst-dashboard — live tmux dashboard for kldloadOS
Launches a multi-pane tmux session with system monitoring.

Usage:
kst-dashboard             # create/attach dashboard session
kst-dashboard --detach    # create in background
kst-dashboard --kill      # destroy the dashboard
    echo "Usage: kst-dashboard [--detach|--kill|--help]"
If session exists, just attach
Colors
  - kst-dashboard active
  - kst-dashboard inactive

### kldload-help
kldload-help — command reference with examples

### kldload-overview
kldload-overview — unified status of everything on this host
VMs, containers, K8s cluster, ZFS, GPU, networking
── Header ─────────────────────────────────────────────────────
── ZFS ────────────────────────────────────────────────────────
  - kldload-overview active
  - kldload-overview inactive

## Installer Profiles
- desktop: GNOME workstation + ZFS on root
- server: Headless SSH + ZFS on root
- core: ZFS only, stock distro
- kvm: KVM hypervisor + ZFS instant clones
- k8s: Kubernetes with Cilium eBPF + MetalLB
- ai: Desktop + Ollama + Open WebUI
- devops/klab: Multi-distro test platform

## Supported Distros
CentOS Stream 9, Rocky Linux 9, Fedora 41, Debian 13, Ubuntu 24.04, Arch Linux, Alpine Linux, RHEL 10, FreeBSD 15

## Key Architecture
- Golden images: ZFS snapshots, clone in ~75ms
- Blue-green: test in green, promote to blue atomically
- WireGuard mesh: 4 planes (mgmt, storage, k8s, external)
- Darksites: offline RPM + APT mirrors baked into ISO
- Secure Boot: MOK auto-enrolled in VM NVRAM
- eBPF: bpftrace + bcc-tools on every golden VM
- Prometheus: klab-exporter on :9101

## SSH Access
- All klab VMs: root / kldload (password auth enabled)
- SSH key: /root/.ssh/id_ed25519 (auto-generated)
- Blue VMs: 192.168.122.101-106
- Green VMs: 192.168.122.201-206

## Common Workflows
1. Build goldens: klab golden all
2. Deploy blue site: klab deploy blue
3. Run ZFS tests: klab test --quick
4. Deploy K8s: klab kubernetes --workers 3
5. Check status: klab status
6. Promote green to blue: klab promote green
7. Rollback: klab rollback
8. Destroy everything: klab destroy all
9. Run playbook on all: klab run-playbook /path/to/script.sh
10. Clone a VM: kvm-clone klab-blue-centos my-test-vm
11. Snapshot: ksnap
12. System health: kst
