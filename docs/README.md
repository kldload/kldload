# kldloadOS Documentation

Your Linux construction kit — ZFS on root, universal CLI tools, boot environments, offline package mirrors, and a unified experience across CentOS, Debian, RHEL, and Rocky.

---

## Overview

Understand what kldloadOS is, how it's built, and what it gives you.

| Guide | Description |
|-------|-------------|
| [What is kldloadOS](what-kldload-gives-you.md) | What's different from stock Linux — nothing removed, everything optional |
| [Editions & Profiles](editions.md) | Desktop vs Server vs Core — what's included in each |
| [Architecture](../ARCHITECTURE.md) | Build pipeline, installer internals, how the ISO is assembled |
| [Known Issues](../KNOWN-ISSUES.md) | Compatibility matrix, tested platforms, known bugs |

---

## Tutorials

Step-by-step guides — from first install to production clusters.

### Getting Started

| Guide | Level | Description |
|-------|-------|-------------|
| [Unattended Installation](unattended-install.md) | Beginner | Answers files, fleet deployment, post-install hooks |
| [CLI Tools Reference](cli-tools-reference.md) | Beginner | kst, ksnap, kbe, kclone, kdf, kdir, kpkg, kupgrade, kexport, krecovery |
| [Package Management](package-management.md) | Beginner | kpkg, offline darksites, kupgrade, adding packages to the ISO |

### Storage & ZFS

| Guide | Level | Description |
|-------|-------|-------------|
| [ZFS Fundamentals](zfs-fundamentals.md) | Beginner | Snapshots, boot environments, clones, compression, encryption, send/receive |
| [Backup and Recovery](backup-and-recovery.md) | Intermediate | Snapshot strategies, offsite replication, disaster recovery |
| [NFS and iSCSI](nfs-and-iscsi.md) | Intermediate | Sharing ZFS datasets as file or block storage |

### Networking

| Guide | Level | Description |
|-------|-------|-------------|
| [Networking](networking.md) | Beginner | Static IPs, bridges, VLANs, bonding, firewall (firewalld + nftables) |
| [WireGuard Basics](wireguard.md) | Beginner | Point-to-point tunnels, hub-and-spoke, 4-plane mesh |
| [WireGuard Masterclass](wireguard-masterclass.md) | Advanced | Silent backplanes, multi-plane isolation, full mesh, stealth, NAT traversal, key management |

### Virtualization & Containers

| Guide | Level | Description |
|-------|-------|-------------|
| [KVM Virtual Machines](kvm-virtual-machines.md) | Beginner | Golden images, CoW cloning, snapshots, migration |
| [Docker & Podman on ZFS](docker-on-zfs.md) | Intermediate | ZFS storage driver, per-service datasets, compose workflows |
| [Kubernetes on KVM](kubernetes-on-kvm.md) | Advanced | Golden images to K8s cluster, scaling, WireGuard pod networking |
| [Proxmox and ZFS](proxmox-and-zfs.md) | Intermediate | Double-ZFS tradeoffs, tuning, when to use bare metal instead |

### Infrastructure

| Guide | Level | Description |
|-------|-------|-------------|
| [16-Node Cluster Setup](cluster-setup.md) | Advanced | Full walkthrough — hub to 16 workers, WireGuard mesh, blue/green upgrades |
| [Export Formats](export-formats.md) | Intermediate | qcow2, raw, VHD, VMDK, OVA — export and import on any platform |

### Observability

| Guide | Level | Description |
|-------|-------|-------------|
| [Observability — Beginner](observability-beginner.md) | Beginner | kst, diagnostics, execsnoop, opensnoop, LogHog, first bpftrace one-liners |
| [Observability — Intermediate](observability-intermediate.md) | Intermediate | socket_snoop, latency_snoop, Prometheus, mail-audit |
| [Observability — Advanced](observability-advanced.md) | Advanced | Write eBPF in C, CO-RE builds, deploy instrumented images to AWS/Azure |

### Security & Hardware

| Guide | Level | Description |
|-------|-------|-------------|
| [Secure Boot & Encryption](secure-boot-and-encryption.md) | Intermediate | MOK enrollment, ZFS encryption, DKMS signing |
| [NVIDIA](nvidia.md) | Intermediate | Driver install (CentOS + Debian), CUDA, Secure Boot signing, ARC tuning |

---

## Reference

Quick-access reference material.

| Reference | Description |
|-----------|-------------|
| [CLI Tools](cli-tools-reference.md) | All `k*` commands with usage and examples |
| [eBPF Reference](ebpf.md) | bpftrace one-liners, BCC tools, kernel tracing |
| [Monitoring Stack](monitoring-and-observability.md) | Prometheus, Grafana, node_exporter setup, ZFS alerting rules |
| [Export Formats](export-formats.md) | Format details, size comparison, import instructions per platform |
| [Unattended Install Variables](unattended-install.md) | All `KLDLOAD_*` environment variables |
