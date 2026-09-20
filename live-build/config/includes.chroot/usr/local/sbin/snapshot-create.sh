#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# snapshot-create.sh — create a ZFS snapshot for the given context
# Usage: snapshot-create.sh <context> [dataset]
# Contexts: apt-pre, apt-post, dnf-pre, dnf-post, srv, manual
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
# The dnf contexts mirror the apt ones for the RPM substrates (Fedora, RHEL,
# Rocky, CentOS Stream). Same dataset, same retention — the only difference is
# the prefix, which is what lets `kldload-rollback list` say which package
# manager took a given snapshot. Added when the apt/dnf wrappers landed; an
# unknown context is fatal below, so omitting these would have made every
# dnf transaction on an RPM box warn and proceed with no rollback point.
dnf-pre)
    DS="${ROOT_DS}"
    PREFIX=dnf-pre
    KEEP=10
    ;;
dnf-post)
    DS="${ROOT_DS}"
    PREFIX=dnf-post
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
    die "Unknown context: '$CONTEXT'. Valid: apt-pre, apt-post, dnf-pre, dnf-post, srv, manual"
    ;;
esac

# Only proceed if the dataset exists
if ! zfs list -H "$DS" >/dev/null 2>&1; then
    log "Dataset $DS not found — skipping snapshot (context: $CONTEXT)"
    exit 0
fi

SNAP="${DS}@${PREFIX}-$(date +%Y%m%d-%H%M%S)"
log "Creating snapshot: $SNAP"
# An existing snapshot of this exact name is SUCCESS, not failure.
#
# apt registers this script on two hooks — APT::Update::Pre-Invoke and
# DPkg::Pre-Invoke — and the name is second-resolution, so an apt run that
# fires both inside one second asks for a name that already exists. `zfs
# snapshot` then exits non-zero, and because this runs as a Pre-Invoke hook
# apt aborts the ENTIRE transaction on it. The snapshot-before-install safety
# net was preventing installs.
#
# That is not theoretical: fiend 2026-09-20, first boot of deb-4-k8s. The
# prereqs phase could not install ansible-core, so kube-cluster had no
# ansible-playbook, so the k8s golden never provisioned, so a 3-control-plane
# cluster failed 29 seconds in — all from a duplicate snapshot name. It had
# been silent until now because the profiles that hit it did not need ansible.
#
# Same second means same filesystem state, so the existing snapshot IS the
# one this call wanted; taking it again would be a no-op even if ZFS allowed
# it. Any OTHER failure still propagates and still stops the transaction,
# which is the behaviour worth keeping.
if ! zfs snapshot "$SNAP" 2>/tmp/.snapshot-create.err; then
    if zfs list -H -t snapshot "$SNAP" >/dev/null 2>&1; then
        log "Snapshot $SNAP already exists (two apt hooks in one second) — reusing it"
        rm -f /tmp/.snapshot-create.err
    else
        log "FATAL: zfs snapshot $SNAP failed: $(cat /tmp/.snapshot-create.err 2>/dev/null)"
        cat /tmp/.snapshot-create.err >&2 2>/dev/null
        rm -f /tmp/.snapshot-create.err
        exit 1
    fi
else
    rm -f /tmp/.snapshot-create.err
    log "Snapshot created: $SNAP"
fi

# Prune old snapshots beyond the keep limit
/usr/local/sbin/snapshot-prune.sh "$DS" "$PREFIX" "$KEEP"
