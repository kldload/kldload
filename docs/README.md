# kldloadOS Documentation

Your Linux construction kit — ZFS on root, universal CLI tools, boot environments, offline package mirrors, and a unified experience across CentOS, Debian, RHEL, and Rocky.

---

## Overview

| Guide | Description |
|-------|-------------|
| [What is kldloadOS](overview/what-kldload-gives-you.md) | What's different from stock Linux — nothing removed, everything optional |
| [Editions & Profiles](overview/editions.md) | Desktop vs Server vs Core — what's included in each |
| [Architecture](../ARCHITECTURE.md) | Build pipeline, installer internals, how the ISO is assembled |
| [Known Issues](../KNOWN-ISSUES.md) | Compatibility matrix, tested platforms, known bugs |

---

## Tutorials

### Getting Started

| Guide | Level | Description |
|-------|-------|-------------|
| [Unattended Installation](tutorials/getting-started/unattended-install.md) | Beginner | Answers files, fleet deployment, post-install hooks |
| [CLI Tools Reference](tutorials/getting-started/cli-tools-reference.md) | Beginner | kst, ksnap, kbe, kclone, kdf, kdir, kpkg, kupgrade, kexport, krecovery |
| [Package Management](tutorials/getting-started/package-management.md) | Beginner | kpkg, offline darksites, kupgrade, adding packages to the ISO |

### Storage & ZFS

| Guide | Level | Description |
|-------|-------|-------------|
| [ZFS Zero to Hero](tutorials/storage/zfs-zero-to-hero.md) | All levels | Complete guide — pools, datasets, snapshots, clones, boot environments, replication, two-node setup, monitoring |
| [NFS and iSCSI](tutorials/storage/nfs-and-iscsi.md) | Intermediate | Sharing ZFS datasets as file or block storage |

### Networking

| Guide | Level | Description |
|-------|-------|-------------|
| [Networking](tutorials/networking/networking.md) | Beginner | Static IPs, bridges, VLANs, bonding, firewall (firewalld + nftables) |
| [WireGuard Basics](tutorials/networking/wireguard.md) | Beginner | Point-to-point tunnels, hub-and-spoke, 4-plane mesh |
| [WireGuard Masterclass](tutorials/networking/wireguard-masterclass.md) | Advanced | Silent backplanes, multi-plane isolation, full mesh, stealth, NAT traversal |

### Virtualization & Containers

| Guide | Level | Description |
|-------|-------|-------------|
| [KVM Virtual Machines](tutorials/virtualization/kvm-virtual-machines.md) | Beginner | Golden images, CoW cloning, snapshots, migration |
| [Docker & Podman on ZFS](tutorials/virtualization/docker-on-zfs.md) | Intermediate | ZFS storage driver, per-service datasets, compose workflows |
| [Kubernetes on KVM](tutorials/virtualization/kubernetes-on-kvm.md) | Advanced | Golden images to K8s cluster, scaling, WireGuard pod networking |
| [Proxmox and ZFS](tutorials/virtualization/proxmox-and-zfs.md) | Intermediate | Double-ZFS tradeoffs, tuning, when to use bare metal instead |

### Infrastructure & Cloud

| Guide | Level | Description |
|-------|-------|-------------|
| [Cloud & Packer Integration](tutorials/infrastructure/cloud-and-packer.md) | Intermediate | Use kldload Core as Packer base image, deploy with Terraform to AWS/Azure/Proxmox |
| [Export Formats](tutorials/infrastructure/export-formats.md) | Intermediate | qcow2, raw, VHD, VMDK, OVA — export and import on any platform |
| [16-Node Cluster Setup](tutorials/infrastructure/cluster-setup.md) | Advanced | Full walkthrough — hub to 16 workers, WireGuard mesh, blue/green upgrades |

### Observability

| Guide | Level | Description |
|-------|-------|-------------|
| [Beginner](tutorials/observability/observability-beginner.md) | Beginner | kst, diagnostics, execsnoop, opensnoop, LogHog, first bpftrace one-liners |
| [Intermediate](tutorials/observability/observability-intermediate.md) | Intermediate | socket_snoop, latency_snoop, Prometheus, mail-audit |
| [Advanced](tutorials/observability/observability-advanced.md) | Advanced | Write eBPF in C, CO-RE builds, deploy instrumented images to AWS/Azure |

### Security & Hardware

| Guide | Level | Description |
|-------|-------|-------------|
| [Secure Boot & Encryption](tutorials/security/secure-boot-and-encryption.md) | Intermediate | MOK enrollment, ZFS encryption, DKMS signing |
| [NVIDIA](tutorials/security/nvidia.md) | Intermediate | Driver install (CentOS + Debian), CUDA, Secure Boot signing, ARC tuning |

---

## Reference

| Reference | Description |
|-----------|-------------|
| [CLI Tools](tutorials/getting-started/cli-tools-reference.md) | All `k*` commands with usage and examples |
| [eBPF Reference](reference/ebpf.md) | bpftrace one-liners, BCC tools, kernel tracing |
| [Monitoring Stack](reference/monitoring-and-observability.md) | Prometheus, Grafana, node_exporter setup, ZFS alerting rules |
| [Export Formats](tutorials/infrastructure/export-formats.md) | Format details, size comparison, import instructions per platform |
| [Unattended Install Variables](tutorials/getting-started/unattended-install.md) | All `KLDLOAD_*` environment variables |
