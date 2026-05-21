#!/usr/bin/env bash
# 02-syncoid-replication.sh — block-level incremental replication.
#
# Two modes (pick one by editing TARGET below):
#   LOCAL: send to a second pool on the same host (cheap, fast)
#   REMOTE: send to another kldload box over SSH (the proper backup
#           story — disaster survives the host going up in flames)
#
# Idempotent: re-runnable every N minutes via cron. Each run sends only
# the BLOCKS that changed since the previous run. ~50 MB/hr is typical
# for an active Postgres dataset.
#
# Drop into /usr/local/sbin/ + a cron entry:
#   */15 * * * * root /usr/local/sbin/syncoid-myapp.sh >> /var/log/syncoid.log 2>&1
set -euo pipefail

# ── Edit these ────────────────────────────────────────────────────────
SOURCE_DATASET="rpool/myapp/data"

# Choose ONE:
TARGET="backup/myapp/data"                      # LOCAL: second zpool on this host
# TARGET="root@backup-host:backup/myapp/data"   # REMOTE: another kldload box over ssh

# Optional tuning
NO_SYNC_SNAP=""             # set to --no-sync-snap to skip the "syncoid_" working snapshot
QUIET=""                    # set to --quiet for cron logs (default verbose)

# ── Pre-flight ────────────────────────────────────────────────────────
if [[ "$TARGET" == *":"* ]]; then
  # Remote target — verify SSH reachability
  REMOTE_HOST="${TARGET%%:*}"
  REMOTE_DS="${TARGET#*:}"
  ssh -o ConnectTimeout=5 -o BatchMode=yes "$REMOTE_HOST" "zfs list $(dirname $REMOTE_DS) >/dev/null 2>&1" || {
    echo "ERROR: cannot reach $REMOTE_HOST or parent dataset doesn't exist on remote"
    exit 1
  }
else
  # Local target — verify the parent pool exists
  zfs list "$(dirname "$TARGET")" >/dev/null 2>&1 || {
    echo "ERROR: target parent dataset $(dirname "$TARGET") doesn't exist (zfs create it first)"
    exit 1
  }
fi

# ── Replicate ─────────────────────────────────────────────────────────
echo "[$(date '+%F %T')] syncoid $SOURCE_DATASET → $TARGET"
syncoid \
    --no-privilege-elevation \
    --compress=lz4 \
    --sshcipher=aes128-gcm@openssh.com \
    $NO_SYNC_SNAP \
    $QUIET \
    "$SOURCE_DATASET" "$TARGET"
echo "[$(date '+%F %T')] done"

# ── On disaster, restore via ────────────────────────────────────────
#   zfs send TARGET@latest | ssh source-host zfs recv -F SOURCE_DATASET
# OR roll forward from the syncoid bookmarks:
#   syncoid --no-sync-snap TARGET SOURCE_DATASET
