# Backup and Recovery

ZFS makes backups fast and reliable — snapshots are instant, and `zfs send/receive` handles replication. This guide covers backup strategies, offsite replication, and disaster recovery with kldload tools.

All examples work on CentOS/RHEL and Debian.

---

## Strategy overview

| Method | Speed | Use case |
|--------|-------|----------|
| ZFS snapshots | Instant | Local point-in-time recovery |
| `zfs send` to local disk | Fast | Onsite backup to second drive |
| `zfs send` over SSH | Network speed | Offsite replication |
| `kexport` | Minutes | Full disk image for migration |
| Boot environments | Instant | Rollback after upgrades |

---

## Local snapshots (first line of defense)

### Automatic snapshots with sanoid

kldload configures sanoid out of the box:

```bash
# Check the timer
systemctl status sanoid.timer

# View the config
cat /etc/sanoid/sanoid.conf
```

Typical retention policy:

```ini
[rpool/ROOT/default]
  frequently = 0
  hourly = 24
  daily = 30
  weekly = 4
  monthly = 12
  yearly = 0
  autosnap = yes
  autoprune = yes
```

### Manual snapshots with ksnap

```bash
# Before a risky operation
ksnap                           # snapshot all key datasets
ksnap /srv/database             # snapshot a specific path

# Check what you have
ksnap list

# Roll back
ksnap rollback /srv/database
```

### Recover a deleted file

```bash
# ZFS snapshots are accessible via the .zfs directory
ls /home/.zfs/snapshot/

# Find the file in a snapshot
ls /home/.zfs/snapshot/autosnap_2026-03-21_12:00:00_hourly/alice/important-file.txt

# Copy it back
cp /home/.zfs/snapshot/autosnap_2026-03-21_12:00:00_hourly/alice/important-file.txt \
   /home/alice/important-file.txt
```

If `.zfs` directories aren't visible:

```bash
zfs set snapdir=visible rpool/home
```

---

## Backup to a second disk

Plug in a USB drive or add a second internal disk:

```bash
# Create a backup pool on the second disk
zpool create backup /dev/sdb

# Full initial send
zfs snapshot -r rpool@backup-initial
zfs send -R rpool@backup-initial | zfs receive -F backup/rpool

# Incremental daily backup
zfs snapshot -r rpool@backup-$(date +%Y%m%d)
zfs send -R -i rpool@backup-initial rpool@backup-$(date +%Y%m%d) \
  | zfs receive -F backup/rpool
```

### Automate with a script

```bash
cat > /usr/local/sbin/kldload-backup.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail

POOL="rpool"
BACKUP_POOL="backup"
TODAY="backup-$(date +%Y%m%d)"

# Find yesterday's snapshot
PREV=$(zfs list -t snapshot -o name -H -r "$POOL" | grep "^${POOL}@backup-" | tail -1)

# New snapshot
zfs snapshot -r "${POOL}@${TODAY}"

if [[ -n "$PREV" ]]; then
  # Incremental
  zfs send -R -i "${PREV##*/}" "${POOL}@${TODAY}" | zfs receive -F "${BACKUP_POOL}/${POOL}"
else
  # Full
  zfs send -R "${POOL}@${TODAY}" | zfs receive -F "${BACKUP_POOL}/${POOL}"
fi

echo "Backup complete: ${POOL}@${TODAY}"
SCRIPT
chmod +x /usr/local/sbin/kldload-backup.sh
```

Schedule it:

```bash
cat > /etc/systemd/system/kldload-backup.timer << 'EOF'
[Unit]
Description=Daily ZFS backup

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/kldload-backup.service << 'EOF'
[Unit]
Description=Daily ZFS backup

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kldload-backup.sh
EOF

systemctl daemon-reload
systemctl enable --now kldload-backup.timer
```

---

## Offsite backup over SSH

Send snapshots to a remote server running ZFS:

```bash
# First time — full send
zfs snapshot -r rpool@offsite-initial
zfs send -R rpool@offsite-initial | ssh backup-server zfs receive -F tank/offsite/rpool

# Daily incremental
zfs snapshot -r rpool@offsite-$(date +%Y%m%d)
zfs send -R -i rpool@offsite-initial rpool@offsite-$(date +%Y%m%d) \
  | ssh backup-server zfs receive -F tank/offsite/rpool
```

### Compress the stream

```bash
zfs send -R rpool@offsite-$(date +%Y%m%d) \
  | zstd -3 \
  | ssh backup-server "zstd -d | zfs receive -F tank/offsite/rpool"
```

### Use syncoid for automated replication

[syncoid](https://github.com/jimsalterjrs/sanoid) (part of the sanoid package) handles incremental sends automatically:

```bash
# Replicate to a remote server
syncoid rpool/ROOT/default backup-server:tank/offsite/root
syncoid rpool/home backup-server:tank/offsite/home
syncoid rpool/srv backup-server:tank/offsite/srv

# Recursive (all child datasets)
syncoid -r rpool backup-server:tank/offsite/rpool
```

Schedule with cron or a systemd timer. syncoid tracks which snapshots have been sent and only sends the deltas.

---

## Disaster recovery

### Boot from the kldload ISO

If the system won't boot, boot from the kldload USB and use `krecovery`:

```bash
# Import the pool
krecovery import rpool

# List boot environments
krecovery list-be

# Activate a working boot environment
krecovery activate rpool/ROOT/default@autosnap_2026-03-20_12:00:00_hourly

# Or enter the system for manual fixes
krecovery chroot
# You're now inside the installed system — fix grub, fstab, etc.
# Type 'exit' when done

# Reinstall the bootloader
krecovery reinstall-bootloader /dev/sda

# Export logs for diagnosis
krecovery export-logs /mnt/usb
```

### Restore from a backup pool

```bash
# Boot from kldload ISO
# Import the backup pool
zpool import backup

# Check what's there
zfs list -r backup/rpool

# Send from backup to a fresh disk
zpool create rpool /dev/sda2    # create new pool on new disk
zfs send -R backup/rpool@latest | zfs receive -F rpool

# Set bootfs
zpool set bootfs=rpool/ROOT/default rpool

# Reinstall bootloader
krecovery reinstall-bootloader /dev/sda
reboot
```

### Restore from an offsite backup

```bash
# Boot from kldload ISO, connect to network
# Pull from backup server
ssh backup-server zfs send -R tank/offsite/rpool@latest | zfs receive -F rpool
```

---

## Export for disaster recovery

Use `kexport` to create portable disk images you can store offsite:

```bash
# Take a snapshot first
ksnap

# Export as qcow2 (compressed, smallest size)
kexport qcow2

# Upload to cloud storage
aws s3 cp kldload-export-*.qcow2 s3://my-backups/
# or
rclone copy kldload-export-*.qcow2 remote:backups/
```

To restore from an export: import the qcow2 into any KVM/Proxmox host and boot it.

---

## Backup verification

Never trust unverified backups:

```bash
# Verify the backup pool's data integrity
zpool scrub backup
zpool status backup   # wait for scrub to complete, check for errors

# Test-mount a backup snapshot
mkdir -p /mnt/backup-test
zfs clone backup/rpool/home@backup-20260321 backup/test-mount
zfs set mountpoint=/mnt/backup-test backup/test-mount
ls /mnt/backup-test   # verify files are there

# Clean up
zfs destroy backup/test-mount
```

---

## How much space do backups use?

```bash
# Snapshot space usage
zfs list -t snapshot -o name,used,refer -S used | head -20

# Total snapshot overhead
zfs get usedbysnapshots rpool
```

Snapshots only store changed blocks. A daily snapshot of a mostly-static server might use <100MB. A busy database might use several GB per snapshot.
