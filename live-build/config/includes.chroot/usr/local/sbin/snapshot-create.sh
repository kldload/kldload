#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# snapshot-create.sh — create a ZFS snapshot for the given context
# Usage: snapshot-create.sh <context> [dataset]
# Contexts: apt-pre, apt-post, srv, manual
# ---------------------------------------------------------------------------

CONTEXT="${1:-manual}"
LOG_DIR=/var/log/kldload
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/snapshots.log"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }

log() {
    echo "$(ts) [snapshot-create] $*" | tee -a "$LOG"
}

die() {
    log "ERROR: $*"
    exit 1
}

# Detect the active root boot environment dataset
_active_root() {
    zfs list -H -o name rpool/ROOT 2>/dev/null | head -1 || true
    zfs list -H -o name -r rpool/ROOT 2>/dev/null |
        awk 'NR==2{print; exit}' || true
}
ROOT_DS="$(zfs list -H -o name "$(zpool get -H -o value bootfs rpool 2>/dev/null)" 2>/dev/null ||
    zfs list -H -o name -r rpool/ROOT 2>/dev/null | grep -v '^rpool/ROOT$' | head -1 ||
    echo 'rpool/ROOT/kldload')"

case "$CONTEXT" in
apt-pre)
    DS="${ROOT_DS}"
    PREFIX=apt-pre
    KEEP=10
    ;;
apt-post)
    DS="${ROOT_DS}"
    PREFIX=apt-post
    KEEP=10
    ;;
srv)
    DS=rpool/srv
    PREFIX=srv
    KEEP=4
    ;;
manual)
    DS="${2:-${ROOT_DS}}"
    PREFIX=manual
    KEEP=10
    ;;
*)
    die "Unknown context: '$CONTEXT'. Valid: apt-pre, apt-post, srv, manual"
    ;;
esac

# Only proceed if the dataset exists
if ! zfs list -H "$DS" >/dev/null 2>&1; then
    log "Dataset $DS not found — skipping snapshot (context: $CONTEXT)"
    exit 0
fi

SNAP="${DS}@${PREFIX}-$(date +%Y%m%d-%H%M%S)"
log "Creating snapshot: $SNAP"
zfs snapshot "$SNAP"
log "Snapshot created: $SNAP"

# Prune old snapshots beyond the keep limit
/usr/local/sbin/snapshot-prune.sh "$DS" "$PREFIX" "$KEEP"
