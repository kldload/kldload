# ZFS examples

Recipes for the ZFS surfaces kldload leans on most: snapshot policy,
replication, encryption, off-site backup, and per-workload tuning.

| File | What it shows |
|---|---|
| `01-sanoid-template.conf` | Drop-in sanoid template (5-min / 1-hr / 1-day / monthly retention) — copy into /etc/sanoid/sanoid.d/ |
| `02-syncoid-replication.sh` | Periodic block-level replication to a backup pool or remote host |
| `03-encrypted-dataset-tpm.sh` | Create a native-encrypted dataset with the key sealed to TPM (auto-unlock at boot) |
| `04-send-recv-to-rclone.sh` | Pipe `zfs send` through `rclone` to S3 / B2 / R2 / any rclone remote |
| `05-tuning-by-workload.md` | Recommended ZFS properties per workload type (postgres / sqlite / bigfiles / timeseries / git / vm) |

## Apply

Copy + edit + place:

```bash
sudo cp 01-sanoid-template.conf /etc/sanoid/sanoid.d/myapp.conf
# sanoid runs every minute from /etc/cron.d/sanoid — no service restart needed
```

```bash
sudo cp 02-syncoid-replication.sh /usr/local/sbin/syncoid-myapp.sh
sudo chmod +x /usr/local/sbin/syncoid-myapp.sh
# Add to /etc/cron.d/syncoid-myapp:
#   */15 * * * * root /usr/local/sbin/syncoid-myapp.sh >> /var/log/syncoid.log 2>&1
```

## Verify

```bash
zfs list -t snapshot rpool/path/to/dataset | head     # snapshots present?
sanoid --monitor-snapshots                            # health check
zfs send rpool/path@snap | wc -c                      # size estimate
```
