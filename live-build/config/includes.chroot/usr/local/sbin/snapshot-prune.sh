#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# snapshot-prune.sh — prune ZFS snapshots beyond a keep limit
# Usage: snapshot-prune.sh <dataset> <prefix> <keep_count>
# ---------------------------------------------------------------------------

# --help answers first, before anything is created, installed or run (rule
# 9; found by the sandboxed --help capture, 2026-09-30: this ran or wrote
# something instead).
case "${1:-}" in
-h | --help)
    awk 'NR > 1 && /^#/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0"
    exit 0
    ;;
esac

DATASET="${1:?Usage: snapshot-prune.sh <dataset> <prefix> <keep_count>}"
PREFIX="${2:?Usage: snapshot-prune.sh <dataset> <prefix> <keep_count>}"
KEEP="${3:?Usage: snapshot-prune.sh <dataset> <prefix> <keep_count>}"

LOG_DIR="${KLDLOAD_LOG_DIR:-/var/log/kldload}" # the variable is for tests
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
    zfs list -H -t snapshot -o name -s creation "$DATASET" 2>/dev/null |
        grep "@${PREFIX}" ||
        true
)

TOTAL="${#ALL_SNAPS[@]}"
log "Dataset=$DATASET prefix=$PREFIX total=$TOTAL keep=$KEEP"

if [[ "$TOTAL" -le "$KEEP" ]]; then
    log "No pruning needed ($TOTAL <= $KEEP)"
    exit 0
fi

DELETE_COUNT=$((TOTAL - KEEP))
log "Pruning $DELETE_COUNT oldest snapshot(s)..."

# Counted, not assumed: the summary was TOTAL - DELETE_COUNT, so a snapshot
# zfs refused to destroy still counted as gone -- "Remaining: 2" with three
# left, on onyx with a throwaway dataset whose oldest snapshot had a clone
# (2026-09-30). That refusal is the normal case after a rollback, so it is
# named for what it is rather than logged as a failure.
#
# Still exit 0 when one cannot go: snapshot-create.sh runs this under set -e
# as its last step, inside apt's and dnf's pre-transaction hook, and a
# non-zero there makes the hook announce "proceeding without a rollback
# point" for a snapshot that was in fact taken.
deleted=0 kept=0 failed=0
for ((i = 0; i < DELETE_COUNT; i++)); do
    SNAP="${ALL_SNAPS[$i]}"
    if out="$(zfs destroy "$SNAP" 2>&1)"; then
        log "Deleted: $SNAP"
        deleted=$((deleted + 1))
    elif [[ "$out" == *"dependent clones"* ]]; then
        log "Kept: $SNAP -- a boot environment or clone was made from it"
        kept=$((kept + 1))
    else
        log "WARNING: could not delete $SNAP: ${out}"
        failed=$((failed + 1))
    fi
done

log "Prune complete: ${deleted} deleted, ${kept} kept (cloned from), ${failed} failed; $((TOTAL - deleted)) remain"
