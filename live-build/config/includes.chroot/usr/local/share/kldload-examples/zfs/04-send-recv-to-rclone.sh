#!/usr/bin/env bash
# 04-send-recv-to-rclone.sh — pipe a `zfs send` stream through `rclone`
# to S3 / B2 / Backblaze / Cloudflare R2 / any rclone remote. Object
# storage replaces the traditional backup tape: cheap, durable, off-site,
# accessible from anywhere with the rclone config.
#
# Encryption: ZFS send streams can be sent ENCRYPTED via `zfs send -w`
# (raw mode) if the source dataset has native encryption. The object
# store sees ciphertext — even AWS doesn't have plaintext access. The
# operator only needs the ZFS key to recover.
#
# Idempotent + incremental — keeps a state file with the last-sent
# snapshot name so the next run is a `zfs send -i <last> <new>` delta.
set -euo pipefail

SOURCE_DATASET="${1:?usage: $0 <dataset> [remote] [bucket-path]}"
REMOTE="${2:-r2}"                   # rclone remote name (configured in ~/.config/rclone/rclone.conf)
BUCKET_PATH="${3:-kldload-backups}" # bucket + prefix within the remote
STATE_FILE="/var/lib/kldload/rclone-backup-state/$(echo "$SOURCE_DATASET" | tr '/' '_')"
mkdir -p "$(dirname "$STATE_FILE")"

# ── Find or create the working snapshot ───────────────────────────────
NEW_SNAP="$SOURCE_DATASET@rclone-$(date +%F-%H%M)"
echo "[1/3] Creating snapshot $NEW_SNAP"
zfs snapshot "$NEW_SNAP"

# ── Compose the send command ──────────────────────────────────────────
if [[ -f "$STATE_FILE" ]]; then
    LAST_SNAP=$(cat "$STATE_FILE")
    echo "[2/3] Incremental send: $LAST_SNAP → $NEW_SNAP"
    SEND_CMD=(zfs send -w -i "$LAST_SNAP" "$NEW_SNAP")
    OBJECT_NAME="$(basename "$NEW_SNAP")-incremental-from-$(basename "$LAST_SNAP").zfs"
else
    echo "[2/3] Initial full send: $NEW_SNAP (this is the big one)"
    SEND_CMD=(zfs send -w "$NEW_SNAP")
    OBJECT_NAME="$(basename "$NEW_SNAP")-full.zfs"
fi

# ── Stream to rclone ──────────────────────────────────────────────────
echo "[3/3] Streaming to ${REMOTE}:${BUCKET_PATH}/${OBJECT_NAME}"
"${SEND_CMD[@]}" | rclone rcat "${REMOTE}:${BUCKET_PATH}/${OBJECT_NAME}"

# ── Update state ──────────────────────────────────────────────────────
echo "$NEW_SNAP" >"$STATE_FILE"

# ── Prune old snapshots that already shipped ──────────────────────────
# Keep the last 7 days of "rclone-" snapshots locally as restore anchors;
# anything older has already shipped + can be recreated from the incremental chain.
zfs list -t snapshot -o name -s creation -r "$SOURCE_DATASET" |
    grep "@rclone-" |
    head -n -7 |
    while read -r old_snap; do
        echo "  pruning local snapshot $old_snap (already in object storage)"
        zfs destroy "$old_snap" || true
    done

echo "Done."
echo "  Restore: rclone cat ${REMOTE}:${BUCKET_PATH}/${OBJECT_NAME} | zfs recv -F ${SOURCE_DATASET}-restored"
