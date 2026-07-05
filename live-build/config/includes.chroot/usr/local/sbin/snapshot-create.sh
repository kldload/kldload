#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# snapshot-create.sh — create a ZFS snapshot for the given context
# Usage: snapshot-create.sh <context> [dataset]
# Contexts: {apt,dnf,pacman}-{pre,post}, srv, manual
#
# The {apt,dnf,pacman}-pre contexts are invoked automatically by each distro's
# native package-manager hook (apt Pre-Invoke / a dnf pre_transaction plugin /
# a pacman PreTransaction hook) so EVERY package transaction — not just `kpkg` —
# drops a labelled, bootable root-BE snapshot you can pick in ZFSBootMenu to roll
# back a bad upgrade. The label IS the context (e.g. @dnf-pre-<ts>), so the
# pre-upgrade rollback point is greppable and distinct from the hourly auto/
# sanoid snapshot streams that otherwise flood the ZBM picker.
# ---------------------------------------------------------------------------

CONTEXT="${1:-manual}"
LOG_DIR=/var/log/kldload
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/snapshots.log"

ts() { date '+%Y-%m-%dT%H:%M:%S'; }

# Log to STDERR, never stdout. The dnf5 actions plugin captures each
# action's stdout and parses every line as a plugin directive (tmp.*=,
# conf.*=, stop=, error=, …) — human-readable log lines on stdout are
# reported as plugin errors on EVERY dnf5 transaction, and would abort
# transactions outright if raise_error=1 is ever set. stderr passes
# through untouched for all callers (apt/pacman/dnf4/dnf5/manual).
log() {
    echo "$(ts) [snapshot-create] $*" | tee -a "$LOG" >&2
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
# Pre/post hooks for every supported package manager snapshot the root BE.
# PREFIX is the full context so the snapshot name self-documents which manager
# and phase produced it; KEEP=10 retains a useful rollback depth without adding
# to the auto/sanoid sprawl (each prefix is pruned independently).
apt-pre | dnf-pre | pacman-pre | apt-post | dnf-post | pacman-post)
    DS="${ROOT_DS}"
    PREFIX="${CONTEXT}"
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
    die "Unknown context: '$CONTEXT'. Valid: {apt,dnf,pacman}-{pre,post}, srv, manual"
    ;;
esac

# Only proceed if the dataset exists
if ! zfs list -H "$DS" >/dev/null 2>&1; then
    log "Dataset $DS not found — skipping snapshot (context: $CONTEXT)"
    exit 0
fi

SNAP="${DS}@${PREFIX}-$(date +%Y%m%d-%H%M%S)"
log "Creating snapshot: $SNAP"
# A failed safety snapshot must NEVER block the package transaction that
# triggered it. This script runs as apt DPkg::Pre-Invoke (which aborts
# apt on any non-zero hook exit) — an unguarded failure here (pool full,
# quota, same-second name collision) made Debian/Ubuntu unpatchable via
# apt, exactly when the operator is trying to patch. The dnf plugin and
# pacman hook already swallow failures by design; apt gets the same
# contract: log loud, exit 0.
if zfs snapshot "$SNAP" 2>&1 | tee -a "$LOG" >&2; then
    log "Snapshot created: $SNAP"
else
    log "ERROR: could not create $SNAP — proceeding WITHOUT a rollback point (pool full? name collision?)"
    exit 0
fi

# Prune old snapshots beyond the keep limit. Best-effort for the same
# reason: pruning noise must not abort an apt/dnf/pacman transaction.
/usr/local/sbin/snapshot-prune.sh "$DS" "$PREFIX" "$KEEP" ||
    log "WARNING: snapshot-prune failed for ${DS}@${PREFIX}-* (keep=${KEEP})"
