# Appliance Recipes

Step-by-step guides for building specific appliances on kldloadOS. Each recipe covers architecture, ZFS dataset layout, service configuration, and verification.

## Cloud Platform

| Recipe | Description |
|--------|-------------|
| [homelab-cloud.md](homelab-cloud.md) | Self-hosted cloud replacing Google Drive, Photos, passwords, chat, git, and S3 with Nextcloud, Immich, Vaultwarden, Gitea, Matrix, MinIO |
| [multi-site-cloud.md](multi-site-cloud.md) | Three-site WireGuard mesh with ZFS replication, automated failover via keepalived, and bare-metal-as-a-service ephemeral environments |
| [production-cloud.md](production-cloud.md) | Production cloud fabric with VXLAN + Open vSwitch, FRRouting (BGP/OSPF), HAProxy, PowerDNS, Keycloak, and multi-tenant isolation |

## Storage and Network

| Recipe | Description |
|--------|-------------|
| [nas-server.md](nas-server.md) | ZFS NAS with Samba shadow copies (Windows Previous Versions), NFS exports, Time Machine support, and offsite replication |
| [draid-storage.md](draid-storage.md) | Petabyte-scale ZFS dRAID for 12+ disk arrays with parallel resilvers measured in minutes instead of hours |
| [firewall-gateway.md](firewall-gateway.md) | Zone-based nftables firewall with Unbound DNS sinkhole, Kea DHCP, WireGuard VPN, and ZFS-backed config snapshots |
| [iot-gateway.md](iot-gateway.md) | Quad-NIC gateway capturing BACnet/Modbus traffic, encrypting it over WireGuard, and delivering to RabbitMQ |

## Media and Entertainment

| Recipe | Description |
|--------|-------------|
| [plex-on-zfs.md](plex-on-zfs.md) | Plex with per-movie ZFS datasets, instant clones for transcoding, and incremental replication to backup/edge nodes |
| [live-tv-streaming.md](live-tv-streaming.md) | Capture card to SRT/HLS/DASH/IPTV multicast using ffmpeg with software or NVENC encoding |
| [satellite-dvr.md](satellite-dvr.md) | DVB-S2 satellite TV, SDR-based ADS-B/ACARS/weather imagery, wideband spectrum scanning, and forensic watermarking |
| [radio-station.md](radio-station.md) | Multi-station internet radio with Icecast, Liquidsoap playlist automation, crossfade mixing, and per-station ZFS datasets |
| [seedbox.md](seedbox.md) | Automated seedbox with rtorrent, Flexget RSS, FileBot renaming, and ZFS replication to a Plex host |
| [game-servers.md](game-servers.md) | Minecraft, Valheim, Palworld, Rust, Terraria on ZFS with 15-minute snapshots, instant rollback, and anti-grief toolkit |
| [ham-radio.md](ham-radio.md) | IRLP ham radio node bridging voice over WireGuard using SvxLink and CM108 USB audio PTT |
