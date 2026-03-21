#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# snapshot-prune.sh — prune ZFS snapshots beyond a keep limit
# Usage: snapshot-prune.sh <dataset> <prefix> <keep_count>
# ---------------------------------------------------------------------------

DATASET="${1:?Usage: snapshot-prune.sh <dataset> <prefix> <keep_count>}"
PREFIX="${2:?Usage: snapshot-prune.sh <dataset> <prefix> <keep_count>}"
KEEP="${3:?Usage: snapshot-prune.sh <dataset> <prefix> <keep_count>}"

LOG_DIR=/var/log/kldload
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/snapshots.log"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }

log() {
    echo "$(ts) [snapshot-prune] $*" | tee -a "$LOG"
}

die() {
    log "ERROR: $*"
    exit 1
}

# Validate keep_count is a positive integer
if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [[ "$KEEP" -lt 1 ]]; then
    die "keep_count must be a positive integer, got: '$KEEP'"
fi

# List all snapshots of the dataset matching @PREFIX*, sorted oldest first by creation
mapfile -t ALL_SNAPS < <(
    zfs list -H -t snapshot -o name -s creation "$DATASET" 2>/dev/null \
        | grep "@${PREFIX}" \
        || true
)

TOTAL="${#ALL_SNAPS[@]}"
log "Dataset=$DATASET prefix=$PREFIX total=$TOTAL keep=$KEEP"

if [[ "$TOTAL" -le "$KEEP" ]]; then
    log "No pruning needed ($TOTAL <= $KEEP)"
    exit 0
fi

DELETE_COUNT=$(( TOTAL - KEEP ))
log "Pruning $DELETE_COUNT oldest snapshot(s)..."

for (( i=0; i<DELETE_COUNT; i++ )); do
    SNAP="${ALL_SNAPS[$i]}"
    log "Deleting: $SNAP"
    if zfs destroy "$SNAP" 2>&1 | tee -a "$LOG"; then
        log "Deleted: $SNAP"
    else
        log "WARNING: Failed to delete $SNAP — continuing"
    fi
done

log "Prune complete. Remaining: $(( TOTAL - DELETE_COUNT )) snapshot(s)"
