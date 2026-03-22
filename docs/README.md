# kldloadOS Documentation

The operating environment you get after installing with kldload — ZFS on root, universal CLI tools, boot environments, offline package mirrors, and a unified experience across CentOS/RHEL and Debian.

All guides work on both distro families unless noted.

---

## Getting Started

- [Editions](editions.md) — **core** (just ZFS on root, nothing else) vs **free** (ZFS + optional tools + darksites + web UI)
- [What is kldloadOS](what-kldload-gives-you.md) — what's different from stock Linux
- [CLI Tools Reference](cli-tools-reference.md) — kst, ksnap, kbe, kclone, kdf, kdir, kpkg, kupgrade, kexport, krecovery
- [Unattended Installation](unattended-install.md) — answers files, fleet deployment, post-install hooks

## Storage

- [ZFS Fundamentals](zfs-fundamentals.md) — snapshots, boot environments, clones, compression, encryption, send/receive
- [Backup and Recovery](backup-and-recovery.md) — snapshot strategies, offsite replication, disaster recovery
- [NFS and iSCSI](nfs-and-iscsi.md) — sharing ZFS datasets as file or block storage

## Packages and Upgrades

- [Package Management](package-management.md) — kpkg, offline darksites, kupgrade, adding packages to the ISO

## Networking

- [Networking](networking.md) — static IPs, bridges, VLANs, bonding, firewall
- [WireGuard Basics](wireguard.md) — point-to-point, hub-and-spoke, 4-plane mesh
- [WireGuard Masterclass](wireguard-masterclass.md) — silent backplanes, multi-plane isolation, full mesh, stealth configs, NAT traversal, site-to-site, key management, monitoring

## Virtualization

- [KVM Virtual Machines](kvm-virtual-machines.md) — golden images, CoW cloning, snapshots, migration
- [Docker and Podman on ZFS](docker-on-zfs.md) — ZFS storage driver, per-service datasets, compose workflows
- [Kubernetes on KVM](kubernetes-on-kvm.md) — golden images to K8s cluster, scaling, WireGuard pod networking
- [Proxmox and ZFS](proxmox-and-zfs.md) — double-ZFS tradeoffs, tuning, bare metal vs. VM

## Cluster

- [16-Node Cluster Setup](cluster-setup.md) — hub to 16 workers, WireGuard mesh, blue/green upgrades

## Observability

- [Beginner](observability-beginner.md) — kst, diagnostics, execsnoop, opensnoop, LogHog, first bpftrace one-liners
- [Intermediate](observability-intermediate.md) — socket_snoop, latency_snoop, Prometheus integration, mail-audit
- [Advanced](observability-advanced.md) — write eBPF in C, CO-RE builds, deploy instrumented images to AWS/Azure
- [eBPF Reference](ebpf.md) — bpftrace, BCC tools, tracing, profiling
- [Monitoring Stack](monitoring-and-observability.md) — Prometheus, Grafana, node_exporter, ZFS alerting

## Hardware and Security

- [NVIDIA](nvidia.md) — drivers, CUDA, Secure Boot signing, ARC tuning
- [Secure Boot and Encryption](secure-boot-and-encryption.md) — MOK, ZFS encryption, DKMS signing
- [Export Formats](export-formats.md) — qcow2, raw, VHD, VMDK, OVA
