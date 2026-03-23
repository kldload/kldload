# ZFS Zero to Hero

Complete operational guide — from empty disk to replicating datasets between nodes. Every command, every option, every config. No shortcuts.

Works on CentOS/RHEL and Debian. Commands are identical on both.

---

## Part 1: Pools

### Create a pool

```bash
# Single disk (no redundancy)
zpool create -o ashift=12 -O compression=lz4 -O acltype=posixacl -O xattr=sa -O relatime=on rpool /dev/sda

# Mirror (2 disks, survives 1 failure)
zpool create -o ashift=12 -O compression=lz4 -O acltype=posixacl -O xattr=sa rpool mirror /dev/sda /dev/sdb

# 3-way mirror (3 disks, survives 2 failures)
zpool create -o ashift=12 -O compression=lz4 rpool mirror /dev/sda /dev/sdb /dev/sdc

# RAIDZ1 (3+ disks, 1 parity, survives 1 failure)
zpool create -o ashift=12 -O compression=lz4 rpool raidz1 /dev/sda /dev/sdb /dev/sdc

# RAIDZ2 (4+ disks, 2 parity, survives 2 failures)
zpool create -o ashift=12 -O compression=lz4 rpool raidz2 /dev/sda /dev/sdb /dev/sdc /dev/sdd

# RAIDZ3 (5+ disks, 3 parity, survives 3 failures)
zpool create -o ashift=12 -O compression=lz4 rpool raidz3 /dev/sd{a,b,c,d,e}

# Striped mirrors (4 disks, 2 mirror vdevs, fast + redundant)
zpool create -o ashift=12 -O compression=lz4 rpool \
  mirror /dev/sda /dev/sdb \
  mirror /dev/sdc /dev/sdd
```

### Pool creation options explained

| Option | Value | Why |
|--------|-------|-----|
| `ashift=12` | 4K sector alignment | Matches modern drives. Never use 9 (512b). Use 13 for some NVMe. |
| `compression=lz4` | Fast, ~1.5-2x ratio | Always on. Zero reason to disable. |
| `acltype=posixacl` | POSIX ACLs | Required for systemd, containers, most apps. |
| `xattr=sa` | Store xattrs in dnodes | Faster than directory-based xattrs. |
| `relatime=on` | Relaxed atime updates | Reduces write amplification. |
| `normalization=formD` | Unicode normalization | Consistent filename handling. |
| `dnodesize=auto` | Variable dnode size | Better metadata performance. |
| `autotrim=on` | Automatic TRIM | For SSDs. Omit for spinning rust. |

### Pool operations

```bash
# List pools
zpool list
zpool list -v                    # verbose — shows vdev layout

# Pool health + config
zpool status rpool
zpool status -v rpool            # verbose — shows individual disk status

# Pool I/O stats (live, 2 second interval)
zpool iostat rpool 2
zpool iostat -v rpool 2          # per-vdev breakdown

# Pool history (every command ever run on this pool)
zpool history rpool
zpool history rpool | tail -20   # last 20 commands

# Scrub (verify all checksums — run weekly)
zpool scrub rpool
zpool status rpool | grep scan   # check scrub progress

# Import / export
zpool export rpool               # detach pool (for migration or unmount)
zpool import                     # list available pools
zpool import rpool               # re-import
zpool import -d /dev/disk/by-id rpool   # import by disk ID (more reliable)

# Upgrade pool features
zpool upgrade rpool

# Destroy pool (DESTRUCTIVE)
zpool destroy rpool
```

### Add devices to existing pool

```bash
# Add a mirror vdev (expand capacity)
zpool add rpool mirror /dev/sde /dev/sdf

# Add a cache device (L2ARC — read cache on SSD)
zpool add rpool cache /dev/nvme0n1

# Add a log device (SLOG — synchronous write log)
zpool add rpool log mirror /dev/nvme1n1 /dev/nvme1n2

# Add a special vdev (metadata + small blocks on fast storage)
zpool add rpool special mirror /dev/nvme0n1p4 /dev/nvme1n1p4
zfs set special_small_blocks=64K rpool

# Replace a failed disk
zpool replace rpool /dev/sda /dev/sdg
zpool status rpool   # watch resilver progress

# Remove a device (mirrors and special vdevs only)
zpool remove rpool /dev/nvme0n1

# Take a device offline / online
zpool offline rpool /dev/sda
zpool online rpool /dev/sda
```

---

## Part 2: Datasets

### Create datasets

```bash
# Basic dataset
zfs create rpool/data

# With mountpoint
zfs create -o mountpoint=/srv/app rpool/srv/app

# With compression
zfs create -o mountpoint=/srv/logs -o compression=zstd rpool/srv/logs

# With quota (limit size)
zfs create -o mountpoint=/home/alice -o quota=50G rpool/home/alice

# With reservation (guaranteed space)
zfs create -o mountpoint=/srv/db -o reservation=100G rpool/srv/db

# With recordsize tuned for workload
zfs create -o mountpoint=/srv/postgres -o recordsize=8k rpool/srv/postgres      # PostgreSQL
zfs create -o mountpoint=/srv/mysql -o recordsize=16k rpool/srv/mysql           # MySQL
zfs create -o mountpoint=/srv/media -o recordsize=1M rpool/srv/media            # large files

# Non-mountable (container for child datasets)
zfs create -o canmount=off -o mountpoint=none rpool/ROOT

# Encrypted dataset
zfs create -o encryption=aes-256-gcm -o keyformat=passphrase rpool/srv/secrets

# All options at once
zfs create \
  -o mountpoint=/srv/production \
  -o compression=lz4 \
  -o quota=500G \
  -o reservation=200G \
  -o recordsize=128k \
  -o atime=off \
  -o logbias=throughput \
  rpool/srv/production
```

### Dataset properties

```bash
# List all datasets
zfs list
zfs list -r rpool                # recursive from rpool
zfs list -o name,used,avail,compress,mountpoint   # custom columns

# Get a property
zfs get compression rpool/data
zfs get all rpool/data           # all properties
zfs get compressratio rpool      # how much compression is saving

# Set a property
zfs set compression=zstd rpool/srv/archive
zfs set quota=100G rpool/home/alice
zfs set atime=off rpool/srv/database
zfs set recordsize=8k rpool/srv/postgres

# Inherit from parent
zfs inherit compression rpool/data

# Mount / unmount
zfs mount rpool/data
zfs unmount rpool/data
zfs mount -a                     # mount all datasets
```

### Dataset properties reference

| Property | Values | Use case |
|----------|--------|----------|
| `compression` | `lz4`, `zstd`, `gzip-9`, `off` | lz4 for general, zstd for archives, off for pre-compressed |
| `recordsize` | `4k`–`1M` | 8k=PostgreSQL, 16k=MySQL, 128k=general, 1M=media |
| `quota` | size or `none` | Limit dataset size |
| `reservation` | size or `none` | Guarantee space for dataset |
| `atime` | `on`, `off` | off for databases and containers |
| `logbias` | `latency`, `throughput` | throughput for sequential writes |
| `sync` | `standard`, `always`, `disabled` | disabled only if you accept data loss |
| `canmount` | `on`, `off`, `noauto` | noauto for boot environments |
| `mountpoint` | path or `none` | where the dataset mounts |
| `encryption` | `aes-256-gcm`, `off` | per-dataset encryption |
| `dedup` | `on`, `off`, `verify` | WARNING: uses massive RAM. Usually not worth it. |
| `snapdir` | `hidden`, `visible` | visible exposes .zfs/snapshot to users |
| `special_small_blocks` | `0`–`1M` | route small blocks to special vdev |

---

## Part 3: Snapshots

### Create snapshots

```bash
# Single dataset
zfs snapshot rpool/data@mysnap

# With timestamp
zfs snapshot rpool/data@$(date +%Y%m%d-%H%M%S)

# Recursive (all child datasets)
zfs snapshot -r rpool@full-backup-$(date +%Y%m%d)

# Multiple datasets
zfs snapshot rpool/home@backup rpool/srv@backup rpool/var/log@backup
```

### List snapshots

```bash
# All snapshots
zfs list -t snapshot

# With size and creation date
zfs list -t snapshot -o name,used,refer,creation -S creation

# Snapshots for a specific dataset
zfs list -t snapshot -r rpool/home

# Count snapshots
zfs list -t snapshot -H | wc -l

# Space used by snapshots
zfs get usedbysnapshots rpool
```

### Access snapshot data

```bash
# Browse snapshot contents (without rollback)
ls /home/.zfs/snapshot/
ls /home/.zfs/snapshot/mysnap/alice/documents/

# Make .zfs directory visible
zfs set snapdir=visible rpool/home

# Copy a file from a snapshot
cp /home/.zfs/snapshot/mysnap/alice/important.txt /home/alice/important.txt
```

### Rollback

```bash
# Rollback to most recent snapshot
zfs rollback rpool/data@mysnap

# Rollback destroying intermediate snapshots
zfs rollback -r rpool/data@old-snapshot

# Rollback destroying intermediate snapshots AND clones
zfs rollback -rR rpool/data@old-snapshot
```

### Destroy snapshots

```bash
# Single snapshot
zfs destroy rpool/data@mysnap

# Range of snapshots
zfs destroy rpool/data@snap1%snap5

# All snapshots matching a pattern
zfs list -t snapshot -H -o name | grep "auto-" | xargs -n1 zfs destroy

# Destroy recursively
zfs destroy -r rpool@full-backup-20260322
```

---

## Part 4: Clones

### Create clones

```bash
# Snapshot first (required — clones come from snapshots)
zfs snapshot rpool/srv/production@clone-src

# Clone
zfs clone rpool/srv/production@clone-src rpool/srv/staging

# Clone starts at near-zero space
zfs list rpool/srv/staging   # USED will be ~0
```

### Clone properties

```bash
# Clone inherits parent properties but can be changed
zfs set mountpoint=/srv/staging rpool/srv/staging
zfs set quota=50G rpool/srv/staging

# Check clone origin
zfs get origin rpool/srv/staging
```

### Promote a clone

```bash
# Make the clone independent (no longer depends on origin snapshot)
zfs promote rpool/srv/staging

# Now the original depends on the clone's snapshot
# The clone becomes the "real" dataset
```

### Destroy a clone

```bash
# Must destroy the clone before the origin snapshot
zfs destroy rpool/srv/staging
zfs destroy rpool/srv/production@clone-src
```

---

## Part 5: Boot Environments

### How they work

Boot environments are ZFS datasets under `rpool/ROOT/`. ZFSBootMenu detects them and lets you choose which one to boot.

```bash
# Current boot environment
zpool get bootfs rpool

# List all boot environments
zfs list -r rpool/ROOT -o name,used,mountpoint,creation

# The active one has mountpoint=/
zfs get mountpoint rpool/ROOT/default
```

### Create a boot environment

```bash
# Snapshot the current root
zfs snapshot rpool/ROOT/default@before-upgrade

# Clone it as a new BE
zfs clone rpool/ROOT/default@before-upgrade rpool/ROOT/safe-rollback
```

### Switch boot environment

```bash
# Set which BE to boot next
zpool set bootfs=rpool/ROOT/safe-rollback rpool

# Reboot into it
reboot

# At the ZFSBootMenu screen, you can also select BEs interactively
```

### Rollback a broken upgrade

```bash
# Option 1: from command line (if you can still boot)
zpool set bootfs=rpool/ROOT/default@before-upgrade rpool
reboot

# Option 2: from kldload live ISO
krecovery import rpool
krecovery list-be
krecovery activate rpool/ROOT/default@before-upgrade
reboot
```

---

## Part 6: Replication

### Local replication (to a backup disk)

```bash
# Create a backup pool on a second disk
zpool create backup /dev/sdb

# Full initial send
zfs snapshot -r rpool@backup-initial
zfs send -R rpool@backup-initial | zfs receive -F backup/rpool

# Incremental daily send
zfs snapshot -r rpool@backup-day2
zfs send -R -i rpool@backup-initial rpool@backup-day2 | zfs receive -F backup/rpool

# Verify
zfs list -r backup/rpool
```

### Remote replication (over SSH)

```bash
# Full send to remote host
zfs snapshot -r rpool@replicate
zfs send -R rpool@replicate | ssh backup-server zfs receive -F tank/backup/rpool

# Incremental
zfs snapshot -r rpool@replicate-2
zfs send -R -i rpool@replicate rpool@replicate-2 | ssh backup-server zfs receive -F tank/backup/rpool

# Compressed transfer
zfs send -R rpool@replicate | zstd -3 | ssh backup-server "zstd -d | zfs receive -F tank/backup"

# With bandwidth limit (10MB/s)
zfs send -R rpool@replicate | pv -L 10m | ssh backup-server zfs receive -F tank/backup
```

### Replication over WireGuard

This is where kldload shines — two kldloadOS nodes with WireGuard form a private encrypted channel. Replication traffic never touches the public internet.

```bash
# Setup: Node A (10.200.0.1) and Node B (10.200.0.2) connected via wg0

# On Node A: send to Node B over the WireGuard tunnel
zfs snapshot -r rpool@replicate
zfs send -R rpool@replicate | ssh 10.200.0.2 zfs receive -F rpool-backup

# Incremental replication (daily cron job)
zfs snapshot -r rpool@daily-$(date +%Y%m%d)
PREV=$(zfs list -t snapshot -H -o name -S creation | grep "rpool@daily-" | sed -n '2p')
zfs send -R -i "$PREV" rpool@daily-$(date +%Y%m%d) | \
  ssh 10.200.0.2 zfs receive -F rpool-backup
```

### Automated replication with syncoid

```bash
# Install syncoid (part of sanoid, pre-installed on kldloadOS free)
# syncoid handles incremental tracking automatically

# Replicate a dataset
syncoid rpool/srv/data backup-server:tank/backup/data

# Replicate recursively
syncoid -r rpool backup-server:tank/backup/rpool

# Replicate over WireGuard
syncoid -r rpool 10.200.0.2:rpool-backup

# Dry run (show what would be sent)
syncoid -r --no-sync-snap --dryrun rpool backup-server:tank/backup

# Cron job — every hour
echo '0 * * * * root syncoid -r rpool 10.200.0.2:rpool-backup' >> /etc/crontab
```

### Replication patterns

#### Pattern 1: Push backup (A → B)

Node A pushes snapshots to Node B.

```bash
# On Node A (cron)
syncoid -r rpool nodeB:tank/backup
```

#### Pattern 2: Pull backup (B pulls from A)

Node B pulls snapshots from Node A. Better for security — backup server initiates.

```bash
# On Node B (cron)
syncoid -r nodeA:rpool tank/backup
```

#### Pattern 3: Bidirectional (A ↔ B)

Both nodes replicate to each other. Different datasets in each direction.

```bash
# On Node A
syncoid rpool/srv/app nodeB:rpool/srv/app-replica

# On Node B
syncoid rpool/srv/db nodeA:rpool/srv/db-replica
```

#### Pattern 4: Fan-out (A → B, C, D)

One source replicates to multiple targets.

```bash
# On Node A
for target in nodeB nodeC nodeD; do
  syncoid -r rpool/srv/data ${target}:tank/backup/data &
done
wait
```

#### Pattern 5: Chain (A → B → C)

A replicates to B, B replicates to C. Geographic distribution.

```bash
# On Node A
syncoid -r rpool nodeB:tank/replica

# On Node B
syncoid -r tank/replica nodeC:tank/offsite
```

---

## Part 7: Two-Node Setup (Complete Example)

Build two kldloadOS nodes, connect them with WireGuard, and replicate data between them.

### Step 1: Install both nodes

Boot the kldload ISO on two machines. Install with Server profile.

- **Node A:** hostname `node-a`, IP `10.100.10.10`
- **Node B:** hostname `node-b`, IP `10.100.10.20`

### Step 2: Set up WireGuard

**On Node A:**
```bash
umask 077
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
cat /etc/wireguard/public.key   # copy this
```

**On Node B:**
```bash
umask 077
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
cat /etc/wireguard/public.key   # copy this
```

**Node A — /etc/wireguard/wg0.conf:**
```ini
[Interface]
Address = 10.200.0.1/24
ListenPort = 51820
PrivateKey = <node-a-private-key>

[Peer]
PublicKey = <node-b-public-key>
AllowedIPs = 10.200.0.2/32
Endpoint = 10.100.10.20:51820
PersistentKeepalive = 25
```

**Node B — /etc/wireguard/wg0.conf:**
```ini
[Interface]
Address = 10.200.0.2/24
ListenPort = 51820
PrivateKey = <node-b-private-key>

[Peer]
PublicKey = <node-a-public-key>
AllowedIPs = 10.200.0.1/32
Endpoint = 10.100.10.10:51820
PersistentKeepalive = 25
```

**Both nodes:**
```bash
systemctl enable --now wg-quick@wg0
ping 10.200.0.2   # from Node A
ping 10.200.0.1   # from Node B
```

### Step 3: Set up SSH keys

```bash
# On Node A
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
ssh-copy-id admin@10.200.0.2

# On Node B
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
ssh-copy-id admin@10.200.0.1
```

### Step 4: Create application datasets

**On Node A:**
```bash
zfs create -o mountpoint=/srv/app rpool/srv/app
zfs create -o mountpoint=/srv/db -o recordsize=8k rpool/srv/db
echo "production data" > /srv/app/config.txt
```

### Step 5: Initial replication

```bash
# On Node A — full send to Node B over WireGuard
zfs snapshot -r rpool/srv@initial
zfs send -R rpool/srv@initial | ssh 10.200.0.2 zfs receive -F rpool/srv-replica
```

**Verify on Node B:**
```bash
zfs list -r rpool/srv-replica
cat /srv-replica/app/config.txt   # should show "production data"
```

### Step 6: Incremental replication

```bash
# On Node A — make changes
echo "updated config" > /srv/app/config.txt
echo "new data" > /srv/db/records.csv

# Snapshot and send incremental
zfs snapshot -r rpool/srv@update1
zfs send -R -i rpool/srv@initial rpool/srv@update1 | \
  ssh 10.200.0.2 zfs receive -F rpool/srv-replica
```

**Verify on Node B:**
```bash
cat /srv-replica/app/config.txt   # should show "updated config"
```

### Step 7: Automate with syncoid

```bash
# On Node A — set up hourly replication
cat > /etc/cron.d/zfs-replicate << 'EOF'
0 * * * * root syncoid -r rpool/srv 10.200.0.2:rpool/srv-replica 2>&1 | logger -t zfs-replicate
EOF
```

### Step 8: Failover

If Node A dies, Node B has the replica:

```bash
# On Node B
zfs set mountpoint=/srv/app rpool/srv-replica/app
zfs set mountpoint=/srv/db rpool/srv-replica/db

# Node B is now serving production data
# When Node A recovers, reverse the replication direction
```

---

## Part 8: Monitoring

```bash
# Pool health (add to monitoring)
zpool status -x   # only shows pools with problems

# Space usage
zfs list -o name,used,avail,refer,compressratio

# Snapshot space
zfs get usedbysnapshots rpool

# ARC stats
arc_summary   # if available
cat /proc/spl/kstat/zfs/arcstats | grep -E "^hits|^misses|^size|^c_max"

# ARC hit rate calculation
awk '/^hits/{h=$3} /^misses/{m=$3} END{printf "ARC hit rate: %.1f%%\n", h/(h+m)*100}' /proc/spl/kstat/zfs/arcstats

# I/O latency (with eBPF)
zfsslower 1        # operations slower than 1ms
biolatency         # block device latency histogram

# Prometheus node_exporter ZFS metrics
curl -s localhost:9100/metrics | grep zfs
```

---

## Quick Reference

| I want to... | Command |
|---|---|
| Create a pool | `zpool create -o ashift=12 -O compression=lz4 rpool mirror /dev/sda /dev/sdb` |
| Create a dataset | `zfs create -o mountpoint=/srv/app rpool/srv/app` |
| Snapshot everything | `zfs snapshot -r rpool@$(date +%Y%m%d-%H%M%S)` |
| List snapshots | `zfs list -t snapshot -o name,used,creation -S creation` |
| Rollback | `zfs rollback rpool/srv/app@before-change` |
| Clone | `zfs snapshot rpool/x@src && zfs clone rpool/x@src rpool/x-clone` |
| Replicate to remote | `zfs send -R rpool@snap \| ssh remote zfs receive -F tank/backup` |
| Incremental replicate | `zfs send -R -i @snap1 rpool@snap2 \| ssh remote zfs receive -F tank/backup` |
| Automated replication | `syncoid -r rpool remote:tank/backup` |
| Pool health | `zpool status rpool` |
| Scrub | `zpool scrub rpool` |
| Check compression | `zfs get compressratio rpool` |
| Boot environment | `zfs snapshot rpool/ROOT/default@safe && zpool set bootfs=rpool/ROOT/default rpool` |
