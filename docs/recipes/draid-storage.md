# Appliance Recipe: Distributed Storage with ZFS dRAID

Large-array ZFS storage using dRAID for massively parallel resilvers. For 12+ disk arrays where traditional RAIDZ resilver time is unacceptable. dRAID distributes parity AND spare capacity across every disk -- a 12-hour RAIDZ2 resilver becomes 30 minutes on dRAID.

---

## How dRAID works

dRAID distributes parity and spare blocks across all disks in the vdev. When a disk fails, every surviving disk participates in the rebuild (reads AND writes), shifting the bottleneck from a single replacement disk to the aggregate bandwidth of the entire vdev.

```
RAIDZ2 (8 disks):
  [D1][D2][D3][D4][D5][D6][P1][P2]
  Resilver: ONE disk writes — hours to days

dRAID2 (8 disks, 1 distributed spare):
  [D+P+S scattered across all 8 disks]
  Resilver: ALL 7 surviving disks read AND write — minutes
```

---

## When to use dRAID

**Use dRAID when:**
- 12+ disks -- below that, RAIDZ resilver time is acceptable
- Resilver time is critical -- cannot afford extended degraded state
- Large sequential workloads -- video, backups, media archives, surveillance
- Second failure during resilver is a real risk (48 spinning disks)

**Do NOT use dRAID for:**
- Small random I/O -- databases belong on mirror vdevs
- Fewer than 8 disks -- RAIDZ is simpler
- Pools where you add individual disks -- dRAID requires adding whole vdevs

---

## dRAID topologies

### Syntax

```
zpool create tank draid<parity>:<spares>s[:<data>d][:<children>c] devices...

  parity   = 1, 2, or 3
  spares   = distributed spare count (e.g., 1s, 2s, 3s)
  data     = (optional) data disks per group
  children = (optional) expected number of children
```

### dRAID1 -- single parity

```bash
# 12 disks, single parity, 1 distributed spare
zpool create tank draid1:1s /dev/sd{a..l}
```

### dRAID2 -- double parity (recommended)

```bash
# 12 disks, double parity, 1 distributed spare
zpool create tank draid2:1s /dev/sd{a..l}

# 24 disks, double parity, 2 distributed spares
zpool create tank draid2:2s /dev/sd{a..x}
```

### dRAID3 -- triple parity

```bash
# 48 disks, triple parity, 3 distributed spares
zpool create tank draid3:3s /dev/sd{a..av}
```

---

## Resilver speed comparison

| Config | Disks | Disk Size | Pool Used | Resilver Time |
|--------|-------|-----------|-----------|---------------|
| RAIDZ2 | 8x 16TB | 16TB replacement | ~60% | ~12 hours |
| dRAID2:1s | 8x 16TB | distributed | ~60% | ~45 minutes |
| RAIDZ2 | 24x 16TB | 16TB replacement | ~60% | ~18 hours |
| dRAID2:2s | 24x 16TB | distributed | ~60% | ~20 minutes |
| RAIDZ2 | 48x 16TB | 16TB replacement | ~60% | ~24 hours |
| dRAID3:3s | 48x 16TB | distributed | ~60% | ~15 minutes |

---

## Dataset layout for large storage

```bash
zfs create -o mountpoint=/tank/archive -o recordsize=1M \
    -o compression=zstd tank/archive
zfs create tank/archive/video-raw
zfs create tank/archive/video-edit
zfs create tank/archive/video-final

zfs create -o mountpoint=/tank/backup-targets -o recordsize=1M \
    -o compression=lz4 tank/backup-targets
zfs create tank/backup-targets/site-a
zfs create tank/backup-targets/site-b

# Cold storage: maximum compression, write-once-read-rarely
zfs create -o mountpoint=/tank/cold-storage -o recordsize=1M \
    -o compression=zstd-19 tank/cold-storage

# Scratch: fast writes, data is expendable
zfs create -o mountpoint=/tank/scratch -o recordsize=1M \
    -o sync=disabled tank/scratch
```

Use `recordsize=1M` for large sequential workloads (video, backups, archives). Do not use 1M for databases -- those belong on mirror vdevs with 8K-16K recordsize.

---

## Monitoring

```bash
# Pool status including distributed spare state
zpool status tank

# Per-disk I/O during resilver -- every disk should be busy
zpool iostat -v tank 5

# eBPF latency monitoring during rebuild
bpftrace -e '
tracepoint:block:block_rq_complete {
    @lat[args->dev] = hist(args->nr_sector);
}
interval:s:10 { print(@lat); clear(@lat); }
'

# ZFS event daemon for alerts
# Configure in /etc/zfs/zed.d/zed.rc:
ZED_EMAIL_ADDR="admin@example.com"
ZED_NOTIFY_VERBOSE=1
```

---

## Expanding dRAID pools

You cannot add individual disks. Growth means adding entire vdevs.

```bash
# Start with one 12-disk dRAID2 vdev
zpool create tank draid2:1s /dev/sd{a..l}

# Add a second 12-disk dRAID2 vdev -- pool doubles in size
zpool add tank draid2:1s /dev/sd{m..x}
```

ZFS does not automatically rebalance data across new vdevs. New writes go to the vdev with the most free space. To rebalance existing data:

```bash
zfs snapshot tank/archive@rebalance
zfs send tank/archive@rebalance | zfs recv tank/archive-new
zfs rename tank/archive tank/archive-old
zfs rename tank/archive-new tank/archive
zfs destroy -r tank/archive-old
```

---

## Replication

```bash
# syncoid for offsite backup over WireGuard
cat > /etc/cron.d/draid-replicate << 'EOF'
0 * * * * root syncoid -r --no-sync-snap tank/archive remote-host:backup/archive 2>&1 | logger -t zfs-replicate
0 * * * * root syncoid -r --no-sync-snap tank/backup-targets remote-host:backup/targets 2>&1 | logger -t zfs-replicate
EOF
```

---

## Complete build: 24-disk dRAID2 storage server

```bash
# Install kldloadOS
cat > /tmp/answers.env << 'EOF'
KLDLOAD_DISTRO=centos
KLDLOAD_DISK=/dev/nvme0n1
KLDLOAD_HOSTNAME=storage01
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=changeme
KLDLOAD_PROFILE=server
KLDLOAD_NET_METHOD=dhcp
EOF
kldload-install-target --config /tmp/answers.env

# Create the dRAID pool (24x 16TB SAS disks on LSI 9400 HBA)
zpool create \
    -o ashift=12 -o autotrim=on \
    -O compression=lz4 -O atime=off \
    -O xattr=sa -O dnodesize=auto -O recordsize=1M \
    tank draid2:2s /dev/sd{a..x}

# NVMe special vdev for metadata acceleration
zpool add tank special mirror /dev/nvme1n1p1 /dev/nvme2n1p1
zfs set special_small_blocks=64k tank

# Mirrored SLOG for synchronous writes (NFS, iSCSI)
zpool add tank log mirror /dev/nvme1n1p2 /dev/nvme2n1p2

# Dataset hierarchy
zfs create -o mountpoint=/tank/archive -o compression=zstd tank/archive
zfs create tank/archive/video-raw
zfs create tank/archive/video-edit
zfs create tank/archive/video-final
zfs create -o mountpoint=/tank/backup-targets -o compression=lz4 tank/backup-targets
zfs create -o mountpoint=/tank/cold-storage -o compression=zstd-19 tank/cold-storage
zfs create -o mountpoint=/tank/scratch -o sync=disabled tank/scratch

systemctl enable --now zfs-zed
zpool status tank
```

---

## Hardware notes

**HBA cards:** Use HBA in IT mode, never hardware RAID. ZFS needs direct disk access. Recommended: Broadcom (LSI) SAS 9300/9400 series.

**ECC RAM:** 1 GB per TB of storage (for ARC). Always ECC -- non-ECC can silently corrupt data in the ARC.

| Disks | Raw Capacity | Minimum RAM | Recommended RAM |
|-------|-------------|-------------|-----------------|
| 12x 16TB | 192TB | 64 GB | 150 GB |
| 24x 16TB | 384TB | 128 GB | 300 GB |
| 48x 16TB | 768TB | 256 GB | 512 GB |

**Special vdev:** Always mirror. If the special vdev dies unmirrored, you lose the pool.

---

## Limitations

- Higher overhead for small random I/O than RAIDZ
- Cannot add individual disks -- must add whole vdevs
- Distributed spares cannot be removed once allocated
- Fixed redundancy group size -- cannot change parity or spare count after creation
- Minimum 3 disks per vdev, but do not use below 8 disks in practice
- Requires OpenZFS 2.1.0+ (kldloadOS ships current OpenZFS)
