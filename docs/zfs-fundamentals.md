# ZFS Fundamentals on kldload

Every kldload system uses ZFS on root. This guide covers the ZFS operations you'll use daily — snapshots, clones, boot environments, compression, and datasets — using the kldload CLI tools and native ZFS commands.

All examples work identically on CentOS/RHEL and Debian installs.

---

## The dataset layout

After a kldload install, your ZFS layout looks like this:

```bash
zfs list -o name,mountpoint,used,avail,compress
```

```
NAME                    MOUNTPOINT       USED  AVAIL  COMPRESS
rpool                   none             8.2G  31.8G  lz4
rpool/ROOT              none             4.1G  31.8G  lz4
rpool/ROOT/default      /                4.1G  31.8G  lz4
rpool/home              /home            120M  31.8G  lz4
rpool/root              /root            24K   31.8G  lz4
rpool/srv               /srv             24K   31.8G  lz4
rpool/var               /var             3.9G  31.8G  lz4
rpool/var/cache         /var/cache       2.1G  31.8G  lz4
rpool/var/log           /var/log         1.8G  31.8G  lz4
rpool/var/tmp           /var/tmp         24K   31.8G  lz4
```

Key facts:
- `rpool/ROOT/default` is your root filesystem — ZFSBootMenu boots from here
- Each directory is a separate dataset with its own snapshots and properties
- `compression=lz4` is on by default everywhere — saves 30–50% on typical Linux files

---

## Snapshots

Snapshots are instant, zero-cost point-in-time copies. They grow only as the original data changes.

### Using ksnap (kldload tool)

```bash
# Snapshot all key datasets
ksnap

# Snapshot a specific path
ksnap /home

# List all snapshots
ksnap list

# Roll back /home to the last snapshot
ksnap rollback /home

# Destroy a specific snapshot
ksnap destroy rpool/home@manual-20260321-143000
```

### Using native ZFS commands

```bash
# Create a named snapshot
zfs snapshot rpool/home@before-big-change

# Snapshot all datasets recursively
zfs snapshot -r rpool@full-backup-$(date +%Y%m%d)

# List snapshots with size
zfs list -t snapshot -o name,used,creation -s creation

# Roll back
zfs rollback rpool/home@before-big-change

# Destroy
zfs destroy rpool/home@before-big-change
```

### Automatic snapshots

kldload configures `sanoid` for automatic snapshot rotation:

```bash
# Check sanoid timer
systemctl status sanoid.timer

# View sanoid config
cat /etc/sanoid/sanoid.conf
```

Sanoid handles hourly, daily, weekly, and monthly snapshot retention automatically.

---

## Boot environments

A boot environment is a snapshot of the root filesystem that you can boot into. If an upgrade breaks your system, reboot into the previous environment.

### Using kbe (kldload tool)

```bash
# List boot environments
kbe list

# Create a named boot environment
kbe create before-kernel-update

# Activate a boot environment (next reboot uses it)
kbe activate before-kernel-update

# Roll back to a boot environment
kbe rollback before-kernel-update

# Delete a boot environment
kbe delete old-environment
```

### How it works

Boot environments live under `rpool/ROOT/`:

```bash
zfs list -r rpool/ROOT
```

```
NAME                                   USED  AVAIL  REFER  MOUNTPOINT
rpool/ROOT                             4.1G  31.8G    24K  none
rpool/ROOT/default                     4.1G  31.8G   4.1G  /
rpool/ROOT/default@before-kernel-upd   0B    -       4.1G  -
```

ZFSBootMenu detects all datasets under `rpool/ROOT/` and lets you choose which one to boot at startup.

---

## Creating datasets

Use `kdir` instead of `mkdir` to create ZFS datasets at any mount point:

```bash
# Instead of: mkdir /srv/myproject
kdir /srv/myproject

# With compression and quota
kdir -o compression=zstd -o quota=50G /srv/database

# Create parent datasets automatically
kdir -p /srv/apps/frontend/static
```

Each `kdir` path becomes its own ZFS dataset with independent snapshots, compression, and quotas.

---

## Cloning

ZFS clones are instant, space-efficient copies backed by copy-on-write:

```bash
# Clone a dataset using kclone
kclone /srv/production /srv/staging

# The clone starts at ~0 bytes and grows only as you change data
kdf /srv/staging   # shows near-zero used space
```

Under the hood, `kclone` creates a snapshot of the source and then a ZFS clone from that snapshot.

### Clone for testing

```bash
# Snapshot production database
zfs snapshot rpool/srv/database@clone-source

# Create a test clone
zfs clone rpool/srv/database@clone-source rpool/srv/database-test

# Test clone is writable, at near-zero space
# ... run tests ...

# Destroy when done
zfs destroy rpool/srv/database-test
zfs destroy rpool/srv/database@clone-source
```

---

## Disk usage

### Using kdf (kldload tool)

```bash
kdf
```

Shows all datasets with used/available space, compression ratios (color-coded), quotas, and mountpoints.

```bash
kdf /home   # Show just one path
```

### Native ZFS

```bash
# Basic usage
zfs list

# Detailed with compression savings
zfs get compressratio rpool

# What's consuming the most space?
zfs list -o name,used,refer -S used | head -20

# Pool-level overview
zpool list
zpool status
```

---

## Compression

All kldload datasets use lz4 by default. You can change it per-dataset:

```bash
# Check current compression
zfs get compression,compressratio rpool/home

# Switch to zstd for better ratios (slower, ~2x better compression)
zfs set compression=zstd rpool/srv/archive

# Turn off compression for already-compressed data (videos, images)
zfs set compression=off rpool/srv/media
```

| Algorithm | Speed | Ratio | Best for |
|-----------|-------|-------|----------|
| `lz4` | Very fast | 1.5–2x | General use (default) |
| `zstd` | Fast | 2–3x | Archives, logs, cold data |
| `gzip-9` | Slow | 2.5–3.5x | Archival storage |
| `off` | — | 1x | Pre-compressed data (video, JPEG, zip) |

---

## Encryption

kldload supports ZFS native encryption (AES-256-GCM). Enable it during install with `KLDLOAD_ZFS_ENCRYPT=1`.

```bash
# Check if your pool is encrypted
zfs get encryption rpool

# Create an encrypted dataset on an unencrypted pool
zfs create -o encryption=aes-256-gcm -o keyformat=passphrase rpool/srv/secrets
# Enter passphrase when prompted

# Lock/unlock
zfs unload-key rpool/srv/secrets   # lock
zfs load-key rpool/srv/secrets     # unlock (prompts for passphrase)
zfs mount rpool/srv/secrets
```

---

## Sending and receiving (replication)

ZFS send/receive replicates datasets between systems — perfect for backups or migrations:

```bash
# Full send to a remote host
zfs snapshot rpool/home@replicate
zfs send rpool/home@replicate | ssh backup-server zfs receive tank/backup/home

# Incremental send (much faster after the first full send)
zfs snapshot rpool/home@replicate-2
zfs send -i rpool/home@replicate rpool/home@replicate-2 \
  | ssh backup-server zfs receive tank/backup/home

# Recursive send (all child datasets)
zfs send -R rpool/srv@backup | ssh backup-server zfs receive tank/backup/srv
```

---

## Quotas and reservations

```bash
# Limit /home to 100GB
zfs set quota=100G rpool/home

# Guarantee 50GB for /srv/database (reserved even if pool fills up)
zfs set reservation=50G rpool/srv/database

# Per-user quotas (via child datasets)
zfs create -o quota=20G rpool/home/alice
zfs create -o quota=20G rpool/home/bob
```

---

## Scrub and health monitoring

```bash
# Run a data integrity check (reads every block, verifies checksums)
zpool scrub rpool

# Check scrub progress
zpool status rpool

# Check pool health
zpool status -v rpool
# ONLINE = healthy, DEGRADED = disk failed but redundant, FAULTED = data at risk
```

Schedule regular scrubs:

```bash
# Scrub weekly via systemd timer (usually already configured)
systemctl status zfs-scrub-weekly@rpool.timer
```

---

## Recovery

If something goes wrong, use `krecovery`:

```bash
# Boot from the kldload ISO, then:
krecovery import rpool              # import the pool
krecovery list-be                   # list boot environments
krecovery activate <snapshot>       # set which BE to boot
krecovery chroot                    # enter the system for manual fixes
krecovery reinstall-bootloader /dev/sda   # fix ZFSBootMenu
krecovery export-logs /mnt/usb      # grab logs for debugging
```
