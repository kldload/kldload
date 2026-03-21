#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# snapshots.sh — ZFS snapshot management library (sourced)
# Requires: common.sh
# ---------------------------------------------------------------------------

[[ "${_KLDLOAD_SNAPSHOTS_LOADED:-0}" == "1" ]] && return 0
_KLDLOAD_SNAPSHOTS_LOADED=1

_SNAP_LOG=/var/log/kldload/snapshots.log

_snap_log() {
    local msg
    msg="[$(date '+%Y-%m-%dT%H:%M:%S')] [snapshots] $*"
    echo "$msg" >&2
    mkdir -p /var/log/kldload
    echo "$msg" >> "$_SNAP_LOG"
}

# ---------------------------------------------------------------------------
# snapshot_create — create a timestamped snapshot
# Args: dataset, prefix
# ---------------------------------------------------------------------------

snapshot_create() {
    local dataset="$1"
    local prefix="$2"
    [[ -n "$dataset" ]] || die "snapshot_create: dataset required"
    [[ -n "$prefix"  ]] || die "snapshot_create: prefix required"

    if ! zfs list -H "$dataset" >/dev/null 2>&1; then
        _snap_log "Dataset not found, skipping: $dataset"
        return 0
    fi

    local snap
    snap="${dataset}@${prefix}-$(date +%Y%m%d-%H%M%S)"
    _snap_log "Creating: $snap"
    zfs snapshot "$snap"
    _snap_log "Created: $snap"
    echo "$snap"
}

# ---------------------------------------------------------------------------
# snapshot_prune — delete oldest snapshots beyond keep limit
# Args: dataset, prefix, keep
# ---------------------------------------------------------------------------

snapshot_prune() {
    local dataset="$1"
    local prefix="$2"
    local keep="$3"

    [[ -n "$dataset" ]] || die "snapshot_prune: dataset required"
    [[ -n "$prefix"  ]] || die "snapshot_prune: prefix required"
    [[ "$keep" =~ ^[0-9]+$ && "$keep" -ge 1 ]] \
        || die "snapshot_prune: keep must be a positive integer, got: $keep"

    mapfile -t snaps < <(
        zfs list -H -t snapshot -o name -s creation "$dataset" 2>/dev/null \
            | grep "@${prefix}" || true
    )

    local total="${#snaps[@]}"
    if [[ "$total" -le "$keep" ]]; then
        _snap_log "No pruning needed for $dataset @$prefix ($total <= $keep)"
        return 0
    fi

    local delete_count=$(( total - keep ))
    _snap_log "Pruning $delete_count snapshot(s) from $dataset (keep=$keep, total=$total)"

    for (( i=0; i<delete_count; i++ )); do
        local s="${snaps[$i]}"
        _snap_log "Deleting: $s"
        zfs destroy "$s" && _snap_log "Deleted: $s" || _snap_log "WARNING: failed to delete $s"
    done
}

# ---------------------------------------------------------------------------
# apt_pre_snapshot — snapshot root before APT transaction, keep 10
# ---------------------------------------------------------------------------

apt_pre_snapshot() {
    snapshot_create rpool/ROOT/default "apt-pre"
    snapshot_prune  rpool/ROOT/default "apt-pre" 10
}

# ---------------------------------------------------------------------------
# apt_post_snapshot — snapshot root after APT transaction, keep 10
# ---------------------------------------------------------------------------

apt_post_snapshot() {
    snapshot_create rpool/ROOT/default "apt-post"
    snapshot_prune  rpool/ROOT/default "apt-post" 10
}

# ---------------------------------------------------------------------------
# srv_snapshot — snapshot /srv workload data, keep 4
# ---------------------------------------------------------------------------

srv_snapshot() {
    snapshot_create rpool/srv "srv"
    snapshot_prune  rpool/srv "srv" 4
}
