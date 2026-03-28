# Appliance Recipe: NAS Server

A kldloadOS file server with ZFS on root, a separate data pool (`tank`) across data disks, Samba shares with shadow copies (Windows Previous Versions from ZFS snapshots), NFS exports, Time Machine support, and offsite replication. The OS is disposable -- if it breaks, export `tank`, reinstall in 2 minutes, import `tank`.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     kldloadOS NAS                               │
│                                                                 │
│  rpool (boot disk)          tank (data disks)                   │
│  └── OS, ZFS on root        ├── nas/media/       1M, lz4       │
│                              │   ├── movies/                    │
│                              │   ├── tv/                        │
│                              │   └── music/                     │
│                              ├── nas/photos/      1M, off       │
│                              ├── nas/documents/   128K, lz4     │
│                              ├── nas/backups/     1M, lz4       │
│                              │   ├── timemachine/               │
│                              │   └── pc-backups/                │
│                              ├── nas/docker/      128K, lz4     │
│                              └── nas/scratch/     1M, sync=off  │
│                                                                 │
│  Samba (:445)  — SMB shares, shadow_copy2, recycle bin          │
│  NFS (:2049)   — NFSv4 exports for Linux clients               │
│  Avahi         — mDNS/Bonjour for macOS Time Machine discovery  │
│  Sanoid        — automated ZFS snapshots + pruning              │
│  Syncoid       — offsite replication over WireGuard              │
└─────────────────────────────────────────────────────────────────┘
```

---

## Step 0: Install kldloadOS

```bash
cat > /tmp/answers.env << 'EOF'
KLDLOAD_DISTRO=debian
KLDLOAD_DISK=/dev/sda
KLDLOAD_HOSTNAME=nas
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=changeme
KLDLOAD_PROFILE=server
KLDLOAD_NET_METHOD=static
KLDLOAD_NET_IP=192.168.1.10/24
KLDLOAD_NET_GW=192.168.1.1
KLDLOAD_NET_DNS=192.168.1.1
EOF
kldload-install-target --config /tmp/answers.env
```

Use static IP -- clients need a stable address for SMB/NFS mounts. The boot disk gets ZFS on root automatically. Your data pool uses separate disks.

---

## Step 1: ZFS pool design

The OS lives on `rpool` (boot drive). NAS data goes on a separate pool called `tank` across your data disks. If the OS breaks, export `tank`, reinstall, import `tank`.

### Pool topologies

```bash
# Mirror — 2 disks, best for small NAS (2-4 bay)
zpool create -o ashift=12 -O compression=lz4 -O atime=off \
    -O xattr=sa -O dnodesize=auto \
    tank mirror /dev/sdb /dev/sdc

# RAIDZ1 — 3+ disks, one parity (like RAID5)
zpool create -o ashift=12 -O compression=lz4 -O atime=off \
    -O xattr=sa -O dnodesize=auto \
    tank raidz1 /dev/sdb /dev/sdc /dev/sdd

# RAIDZ2 — 6+ disks, two parity (recommended for large arrays)
zpool create -o ashift=12 -O compression=lz4 -O atime=off \
    -O xattr=sa -O dnodesize=auto \
    tank raidz2 /dev/sdb /dev/sdc /dev/sdd /dev/sde /dev/sdf /dev/sdg

# Striped mirrors — 4 disks, best IOPS (like RAID10)
zpool create -o ashift=12 -O compression=lz4 -O atime=off \
    -O xattr=sa -O dnodesize=auto \
    tank mirror /dev/sdb /dev/sdc mirror /dev/sdd /dev/sde
```

### NVMe metadata acceleration (optional)

```bash
# Add a mirrored NVMe special vdev to an HDD pool
zpool add tank special mirror /dev/nvme0n1 /dev/nvme1n1
zfs set special_small_blocks=64K tank
```

Always mirror the special vdev. If it dies unmirrored, you lose the pool.

### Dataset layout

```bash
zfs create -o canmount=off tank/nas

# Media — large files, big recordsize
zfs create -o mountpoint=/srv/nas/media -o recordsize=1M -o compression=lz4 tank/nas/media
zfs create tank/nas/media/movies
zfs create tank/nas/media/tv
zfs create tank/nas/media/music

# Photos — already compressed JPEGs/HEICs
zfs create -o mountpoint=/srv/nas/photos -o recordsize=1M -o compression=off tank/nas/photos

# Documents — small files, high compressibility
zfs create -o mountpoint=/srv/nas/documents -o recordsize=128K -o compression=lz4 tank/nas/documents

# Backups
zfs create -o canmount=off tank/nas/backups
zfs create -o mountpoint=/srv/nas/backups/timemachine -o recordsize=1M \
    -o compression=lz4 tank/nas/backups/timemachine
zfs create -o mountpoint=/srv/nas/backups/pc-backups -o recordsize=1M \
    -o compression=lz4 tank/nas/backups/pc-backups

# Docker application data
zfs create -o mountpoint=/srv/nas/docker -o recordsize=128K -o compression=lz4 tank/nas/docker

# Scratch — temp files, no snapshots, sync disabled for speed
zfs create -o mountpoint=/srv/nas/scratch -o recordsize=1M \
    -o compression=off -o sync=disabled tank/nas/scratch
```

---

## Step 2: Samba (SMB/CIFS)

```bash
apt install -y samba samba-vfs-modules

# Create NAS users
useradd -M -s /usr/sbin/nologin nas-alice
useradd -M -s /usr/sbin/nologin nas-bob
smbpasswd -a nas-alice
smbpasswd -a nas-bob

mkdir -p /srv/nas/homes/{alice,bob}
chown nas-alice: /srv/nas/homes/alice
chown nas-bob: /srv/nas/homes/bob
```

```ini
# /etc/samba/smb.conf
[global]
    workgroup = WORKGROUP
    server string = kldloadOS NAS
    server role = standalone server
    map to guest = Bad User
    guest account = nobody
    use sendfile = yes
    aio read size = 16384
    aio write size = 16384
    vfs objects = fruit streams_xattr
    fruit:metadata = stream
    fruit:model = MacSamba
    fruit:posix_rename = yes
    fruit:veto_appledouble = no
    fruit:nfs_aces = no
    fruit:wipe_intentionally_left_blank_rfork = yes
    fruit:delete_empty_adfiles = yes
    log file = /var/log/samba/log.%m
    max log size = 1000
    load printers = no
    printing = bsd
    printcap name = /dev/null
    disable spoolss = yes

[homes]
    path = /srv/nas/homes/%U
    browseable = no
    writable = yes
    valid users = %U
    create mask = 0600
    directory mask = 0700
    vfs objects = recycle
    recycle:repository = .recycle/%U
    recycle:keeptree = yes
    recycle:versions = yes

[documents]
    path = /srv/nas/documents
    browseable = yes
    writable = yes
    valid users = nas-alice, nas-bob
    force group = users
    vfs objects = recycle shadow_copy2
    recycle:repository = .recycle/%U
    recycle:keeptree = yes
    shadow:snapdir = .zfs/snapshot
    shadow:sort = desc
    shadow:format = autosnap_%Y-%m-%d_%H:%M:%S_hourly
    shadow:localtime = no

[media]
    path = /srv/nas/media
    browseable = yes
    read only = yes
    guest ok = yes

[media-admin]
    path = /srv/nas/media
    browseable = yes
    writable = yes
    valid users = nas-alice, nas-bob
    force group = users
    vfs objects = recycle
    recycle:repository = .recycle/%U
    recycle:keeptree = yes

[photos]
    path = /srv/nas/photos
    browseable = yes
    writable = yes
    valid users = nas-alice, nas-bob
    vfs objects = recycle shadow_copy2
    shadow:snapdir = .zfs/snapshot
    shadow:sort = desc
    shadow:format = autosnap_%Y-%m-%d_%H:%M:%S_hourly
    shadow:localtime = no

[timemachine]
    path = /srv/nas/backups/timemachine
    browseable = yes
    writable = yes
    valid users = nas-alice, nas-bob
    vfs objects = fruit streams_xattr
    fruit:time machine = yes
    fruit:time machine max size = 1T
    create mask = 0600
    directory mask = 0700

[backups]
    path = /srv/nas/backups/pc-backups
    browseable = yes
    writable = yes
    valid users = nas-alice, nas-bob
    vfs objects = shadow_copy2
    shadow:snapdir = .zfs/snapshot
    shadow:sort = desc
    shadow:format = autosnap_%Y-%m-%d_%H:%M:%S_daily
    shadow:localtime = no
```

```bash
testparm -s
systemctl enable --now smbd nmbd
```

### Windows Previous Versions

The `shadow_copy2` VFS module exposes ZFS snapshots as Windows Previous Versions. Users right-click a file or folder in Explorer, go to Properties, Previous Versions, and see every snapshot as a point-in-time version. The `shadow:format` must match sanoid snapshot naming.

### Time Machine

```bash
# Per-user Time Machine datasets with quotas
zfs create -o mountpoint=/srv/nas/backups/timemachine/alice \
    -o quota=500G tank/nas/backups/timemachine/alice
zfs create -o mountpoint=/srv/nas/backups/timemachine/bob \
    -o quota=500G tank/nas/backups/timemachine/bob
chown nas-alice: /srv/nas/backups/timemachine/alice
chown nas-bob: /srv/nas/backups/timemachine/bob

# Avahi for mDNS/Bonjour auto-discovery
apt install -y avahi-daemon
cat > /etc/avahi/services/smb.service << 'AVAHI'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">%h</name>
  <service>
    <type>_smb._tcp</type>
    <port>445</port>
  </service>
  <service>
    <type>_device-info._tcp</type>
    <port>9</port>
    <txt-record>model=TimeCapsule8,119</txt-record>
  </service>
</service-group>
AVAHI
systemctl restart avahi-daemon
```

---

## Step 3: NFS (Linux/Unix clients)

```bash
apt install -y nfs-kernel-server

cat > /etc/exports << 'NFSEOF'
/srv/nas        192.168.1.0/24(rw,fsid=0,no_subtree_check,crossmnt)
/srv/nas/media      192.168.1.0/24(ro,no_subtree_check,all_squash,anonuid=65534,anongid=65534)
/srv/nas/documents  192.168.1.0/24(rw,no_subtree_check,no_root_squash)
/srv/nas/photos     192.168.1.0/24(rw,no_subtree_check,no_root_squash)
/srv/nas/docker     192.168.1.0/24(rw,no_subtree_check,no_root_squash)
NFSEOF

exportfs -ra
systemctl enable --now nfs-server
```

Client-side mounts:

```bash
# /etc/fstab on Linux clients (NFSv4)
nas:/media      /mnt/nas/media      nfs4  ro,soft,intr,timeo=30   0 0
nas:/documents  /mnt/nas/documents  nfs4  rw,soft,intr,timeo=30   0 0
```

---

## Step 4: Automated snapshots (sanoid)

```ini
# /etc/sanoid/sanoid.conf
[tank/nas/documents]
  use_template = production
  recursive = yes

[tank/nas/photos]
  use_template = production
  recursive = yes

[tank/nas/backups]
  use_template = production
  recursive = yes

[tank/nas/media]
  use_template = media
  recursive = yes

[template_production]
  hourly = 48
  daily = 30
  monthly = 6
  yearly = 0
  autosnap = yes
  autoprune = yes

[template_media]
  hourly = 24
  daily = 14
  monthly = 3
  yearly = 0
  autosnap = yes
  autoprune = yes
```

```bash
systemctl enable --now sanoid.timer
```

---

## Step 5: Offsite replication

```bash
# WireGuard tunnel to backup NAS (see firewall-gateway recipe)
# Replicate every night at 2am
cat > /etc/cron.d/nas-replicate << 'EOF'
0 2 * * * root syncoid -r --no-sync-snap tank/nas 10.200.0.2:tank/nas-replica 2>&1 | logger -t nas-replicate
EOF
```

---

## Step 6: Firewall

```bash
cat > /etc/nftables.d/nas.nft << 'NFTEOF'
table inet filter {
  chain input {
    # SMB
    tcp dport 445 accept
    # NFS
    tcp dport 2049 accept
    # Avahi/mDNS
    udp dport 5353 accept
    # SSH
    tcp dport 22 accept
    # WireGuard
    udp dport 51820 accept
  }
}
NFTEOF
systemctl reload nftables
```

---

## Verify

```bash
# Test SMB
smbclient -L //nas -U nas-alice

# Test NFS
showmount -e nas

# Check snapshots
zfs list -t snapshot -r tank/nas | tail -10

# Check compression savings
zfs get compressratio tank/nas/documents

# Check pool health
zpool status tank
```

---

## Bill of materials

| Component | Cost |
|-----------|------|
| Mini PC / server (4+ cores, 8GB+ RAM) | $200-500 |
| Data disks (4x 4TB HDD, RAIDZ1) | $200-400 |
| NVMe special vdev (optional, 2x 256GB) | $60-100 |
| kldloadOS on USB | Free |
| **Total** | **~$400-1,000** |
