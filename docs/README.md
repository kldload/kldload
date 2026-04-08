# kldloadOS Documentation

Single bootable ISO that installs CentOS Stream 9, Debian 13, Ubuntu 24.04, Fedora 41, RHEL 9, Rocky Linux 9, Arch Linux, or Alpine Linux with ZFS on root. Eight distros, one USB, offline.

## Overview

| Document | Description |
|----------|-------------|
| [What is kldloadOS](overview/what-kldload-gives-you.md) | Technical overview — what it adds to a stock distro |
| [Editions & Profiles](overview/editions.md) | Core vs Free, Desktop vs Server vs KVM vs AI profile |
| [The Bridge](the-bridge.md) | BSD-to-Linux perspective, ZFS on Linux tradeoffs |
| [Architecture](ARCHITECTURE.md) | Build pipeline, installer internals, ISO assembly |
| [Known Issues](KNOWN-ISSUES.md) | Compatibility matrix, tested platforms, known bugs |
| [Changelog](CHANGELOG.md) | Release history |

## Getting Started

| Guide | Description |
|-------|-------------|
| [Unattended Installation](tutorials/getting-started/unattended-install.md) | Answers files, fleet deployment, post-install hooks |
| [CLI Tools Reference](tutorials/getting-started/cli-tools-reference.md) | All `k*` commands: kst, ksnap, kbe, kclone, kdf, kdir, kpkg, kupgrade, kexport, krecovery |
| [Package Management](tutorials/getting-started/package-management.md) | kpkg, offline darksites, kupgrade, adding packages to the ISO |

## Storage & ZFS

| Guide | Description |
|-------|-------------|
| [ZFS Zero to Hero](tutorials/storage/zfs-zero-to-hero.md) | Pools, datasets, snapshots, clones, boot environments, replication, monitoring |
| [NFS and iSCSI](tutorials/storage/nfs-and-iscsi.md) | Sharing ZFS datasets as file or block storage |

## Networking

| Guide | Description |
|-------|-------------|
| [Networking](tutorials/networking/networking.md) | Static IPs, bridges, VLANs, bonding, firewalld + nftables |
| [WireGuard Basics](tutorials/networking/wireguard.md) | Point-to-point tunnels, hub-and-spoke, 4-plane mesh |
| [WireGuard Masterclass](tutorials/networking/wireguard-masterclass.md) | Silent backplanes, multi-plane isolation, full mesh, NAT traversal |

## Virtualization

| Guide | Description |
|-------|-------------|
| [KVM Virtual Machines](tutorials/virtualization/kvm-virtual-machines.md) | Golden images, CoW cloning, snapshots, migration |
| [Docker & Podman on ZFS](tutorials/virtualization/docker-on-zfs.md) | ZFS storage driver, per-service datasets, compose workflows |
| [Kubernetes on KVM](tutorials/virtualization/kubernetes-on-kvm.md) | Golden images to K8s cluster, WireGuard pod networking |
| [Proxmox and ZFS](tutorials/virtualization/proxmox-and-zfs.md) | Double-ZFS tradeoffs, tuning, bare metal alternatives |

## Cloud & Infrastructure

| Guide | Description |
|-------|-------------|
| [Packer & Terraform](cloud/packer-and-terraform.md) | kldload Core as Packer base image, deploy to AWS/Azure/Proxmox |
| [Export Formats](cloud/export-formats.md) | qcow2, raw, VHD, VMDK, OVA -- export and import per platform |
| [Multi-Site Deployment](cloud/multi-site.md) | WireGuard mesh, ZFS replication topology, failover, DR runbook |
| [16-Node Cluster Setup](cloud/cluster-setup.md) | Hub to 16 workers, WireGuard mesh, blue/green upgrades |

## Observability

| Guide | Description |
|-------|-------------|
| [Beginner](tutorials/observability/observability-beginner.md) | kst, diagnostics, execsnoop, opensnoop, LogHog, bpftrace one-liners |
| [Intermediate](tutorials/observability/observability-intermediate.md) | socket_snoop, latency_snoop, Prometheus, mail-audit |
| [Advanced](tutorials/observability/observability-advanced.md) | eBPF in C, CO-RE builds, deploy instrumented images to AWS/Azure |

## Security

| Guide | Description |
|-------|-------------|
| [Secure Boot & Encryption](tutorials/security/secure-boot-and-encryption.md) | MOK enrollment, ZFS encryption, DKMS signing |
| [NVIDIA](tutorials/security/nvidia.md) | Driver install (CentOS + Debian), CUDA, Secure Boot signing, ARC tuning |

## Appliance Recipes

Complete build guides: [recipes/README.md](recipes/README.md)

### Cloud Platform

| Recipe | Description |
|--------|-------------|
| [Homelab Cloud](recipes/homelab-cloud.md) | Self-hosted Nextcloud, Immich, Vaultwarden, Gitea, Matrix, MinIO on ZFS |
| [Multi-Site Cloud](recipes/multi-site-cloud.md) | Three-site WireGuard mesh, ZFS replication, failover, BMaaS |
| [Production Cloud](recipes/production-cloud.md) | VXLAN + OVS, FRRouting (BGP/OSPF), HAProxy, PowerDNS, Keycloak |

### Storage & Network

| Recipe | Description |
|--------|-------------|
| [NAS Server](recipes/nas-server.md) | Samba, NFS, Time Machine, shadow copies, offsite replication |
| [dRAID Storage](recipes/draid-storage.md) | Petabyte-scale ZFS dRAID, 12+ disk arrays, fast resilver |
| [Firewall & Gateway](recipes/firewall-gateway.md) | nftables zones, Unbound DNS, Kea DHCP, WireGuard VPN |
| [IoT Gateway](recipes/iot-gateway.md) | BACnet/Modbus capture, WireGuard backhaul, RabbitMQ |

### Media & Entertainment

| Recipe | Description |
|--------|-------------|
| [Plex on ZFS](recipes/plex-on-zfs.md) | Per-movie datasets, instant clones, incremental replication |
| [Live TV Streaming](recipes/live-tv-streaming.md) | Capture card, ffmpeg, SRT/HLS/DASH/IPTV |
| [Satellite DVR](recipes/satellite-dvr.md) | DVB-S2 satellite TV, SDR, ADS-B, spectrum scanning |
| [Radio Station](recipes/radio-station.md) | Icecast, Liquidsoap automation, per-station ZFS datasets |
| [Seedbox](recipes/seedbox.md) | rtorrent, Flexget RSS, FileBot, ZFS replication to Plex |
| [Game Servers](recipes/game-servers.md) | Minecraft, Valheim, Palworld, Rust on ZFS with instant rollback |
| [Ham Radio (IRLP)](recipes/ham-radio.md) | SvxLink, CM108 USB audio, WireGuard backhaul |

## Reference

| Document | Description |
|----------|-------------|
| [CLI Tools](tutorials/getting-started/cli-tools-reference.md) | All `k*` commands with usage and examples |
| [eBPF Reference](reference/ebpf.md) | bpftrace one-liners, BCC tools, kernel tracing |
| [Monitoring Stack](reference/monitoring-and-observability.md) | Prometheus, Grafana, node_exporter, ZFS alerting rules |

## Kubernetes

| Guide | Description |
|-------|-------------|
| [Kubernetes on KVM](tutorials/virtualization/kubernetes-on-kvm.md) | Golden images to K8s cluster, WireGuard pod networking |
| [kube-cluster](tutorials/virtualization/kube-cluster.md) | One-command cluster: ZFS clones → Cilium → Hubble → MetalLB |

## Releases

| Release | Description |
|---------|-------------|
| [1.0.3](releases/RELEASE-1.0.3.md) | KVM hypervisor, NVIDIA GPU sharing, eBPF cross-distro |
| [1.0.2](releases/RELEASE-1.0.2.md) | AI assistant, Alpine Linux, 12+ profiles |
| [1.0.1](releases/RELEASE-1.0.1.md) | Fedora, Arch, golden image export |
| [1.0](releases/RELEASE-1.0.md) | Initial release |
