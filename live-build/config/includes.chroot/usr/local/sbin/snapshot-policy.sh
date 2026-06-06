#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# snapshot-policy.sh — print current ZFS snapshot policy report
# Shows all rpool snapshots grouped by prefix, with counts vs limits.
# ---------------------------------------------------------------------------

# Policy limits (must match snapshot-create.sh)
declare -A POLICY_LIMITS=(
    ["apt-pre"]=10
    ["apt-post"]=10
    ["srv"]=4
    ["manual"]=10
    ["pre-upgrade"]=10
)

log() {
    echo "$*"
}

hr() {
    echo "================================================================"
}

# ---------------------------------------------------------------------------
# Collect all snapshots from rpool
# ---------------------------------------------------------------------------

hr
log "KLDload Snapshot Policy Report"
log "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
hr

# Check if zpool/rpool exists
if ! zpool list rpool >/dev/null 2>&1; then
    log "WARNING: rpool not imported or does not exist."
    log "No snapshots to report."
    exit 0
fi

# Group snapshots by dataset and prefix
declare -A GROUP_COUNTS
declare -A GROUP_SNAPS

while IFS= read -r snap; do
    [[ -z "$snap" ]] && continue

    # Parse: dataset@prefix-timestamp
    dataset="${snap%%@*}"
    snap_name="${snap##*@}"
    # Extract prefix (everything before the last -YYYYMMDD-HHMMSS)
    prefix="$(echo "$snap_name" | sed 's/-[0-9]\{8\}-[0-9]\{6\}$//')"

    key="${dataset}|${prefix}"
    GROUP_COUNTS["$key"]=$((${GROUP_COUNTS["$key"]:-0} + 1))
    GROUP_SNAPS["$key"]+="${snap}"$'\n'
done < <(zfs list -H -t snapshot -o name -r rpool 2>/dev/null | sort || true)

if [[ "${#GROUP_COUNTS[@]}" -eq 0 ]]; then
    log "No snapshots found on rpool."
    hr
    exit 0
fi

# ---------------------------------------------------------------------------
# Print grouped report
# ---------------------------------------------------------------------------

OVER_LIMIT=0

for key in $(echo "${!GROUP_COUNTS[@]}" | tr ' ' '\n' | sort); do
    dataset="${key%%|*}"
    prefix="${key##*|}"
    count="${GROUP_COUNTS[$key]}"

    # Look up limit
    limit="${POLICY_LIMITS[$prefix]:-unknown}"

    if [[ "$limit" == "unknown" ]]; then
        status="UNMANAGED"
    elif [[ "$count" -gt "$limit" ]]; then
        status="OVER LIMIT"
        ((OVER_LIMIT++)) || true
    else
        status="OK"
    fi

    printf "  %-35s  prefix=%-12s  count=%2d  limit=%s  [%s]\n" \
        "$dataset" "$prefix" "$count" "${limit}" "$status"

    # Print individual snapshot names (oldest to newest)
    while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        printf "    - %s\n" "$s"
    done < <(echo "${GROUP_SNAPS[$key]}" | sort)

    echo ""
done

hr
if [[ "$OVER_LIMIT" -gt 0 ]]; then
    log "WARNING: $OVER_LIMIT group(s) are OVER LIMIT."
    log "Run snapshot-prune.sh to clean up, or check APT hook configuration."
else
    log "All snapshot groups are within policy limits."
fi
hr
