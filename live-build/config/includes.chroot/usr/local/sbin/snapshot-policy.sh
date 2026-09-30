#!/usr/bin/env bash
# snapshot-policy.sh — report the snapshots kldload's own retention manages:
# for the running boot environment and <pool>/srv, one line per kind of
# snapshot, with its count, its limit and the oldest and newest.
#
# Usage: snapshot-policy.sh [-v]     -v also lists every managed snapshot.
# Exit:  0 all within their limits, 1 a group is over its limit, 2 usage.
#
# The limits are the ones the takers prune to: snapshot-create.sh (apt-*,
# dnf-*, srv, manual), kpkg (kpkg-), kldload-snapshot (auto-). A kind no
# kldload tool prunes -- sanoid's autosnap, the install snapshot, anything
# made by hand -- is counted in one line and not judged.
#
# HISTORY: this listed every snapshot on the whole pool, one group per
# sanoid snapshot because their timestamps were not recognised: 6,200 lines
# on onyx, 2026-09-30, with the root environment's 35 auto and 10 dnf-pre
# snapshots buried and reported UNMANAGED. Its one verdict was that a
# BACKUP REPLICA (rpool/backup/fiend/srv) was over the srv limit, followed by
# advice to prune it. It judges only the local machine's datasets now.
set -Eeuo pipefail
trap 'echo "snapshot-policy.sh: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

verbose=0
case "${1:-}" in
-h | --help)
    sed -n '2,${/^#/!q; s/^# \{0,1\}//; p}' "$0"
    exit 0
    ;;
-v) verbose=1 ;;
"") ;;
*)
    echo "snapshot-policy.sh: unknown argument: $1 (try --help)" >&2
    exit 2
    ;;
esac

# Keep in step with the takers named in the header.
declare -A LIMIT=(
    ["apt-pre"]=10 ["apt-post"]=10 ["dnf-pre"]=10 ["dnf-post"]=10
    ["kpkg"]=10 ["auto"]=48 ["srv"]=4 ["manual"]=10
)

command -v zfs >/dev/null 2>&1 || {
    echo "snapshot-policy.sh: zfs is not installed" >&2
    exit 1
}

# The running root's pool, as kldload-rollback finds it.
root="$(findmnt -no SOURCE -t zfs / 2>/dev/null || true)"
if [[ -z "$root" ]]; then
    echo "snapshot-policy.sh: / is not on ZFS; nothing here is managed" >&2
    exit 0
fi
pool="${root%%/*}"
datasets=("$root")
zfs list -H -o name "${pool}/srv" >/dev/null 2>&1 && datasets+=("${pool}/srv")

# _kind NAME — the kind of a snapshot, from the part after '@': the taker's
# prefix without its -YYYYMMDD-HHMMSS, or sanoid's autosnap_<period>, or
# install; anything else is itself.
_kind() {
    local n="$1"
    if [[ "$n" =~ ^(.+)-[0-9]{8}-[0-9]{6}$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$n" =~ ^autosnap_[0-9-]+_[0-9:]+_([a-z]+)$ ]]; then
        printf 'autosnap_%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$n" =~ ^install-[0-9TZ]+$ ]]; then
        printf 'install\n'
    else
        printf '%s\n' "$n"
    fi
}

over=0
printf '%-28s %-18s %5s %5s  %-16s %-16s %s\n' DATASET KIND COUNT LIMIT OLDEST NEWEST STATE
for ds in "${datasets[@]}"; do
    declare -A count=() first=() last=() names=()
    other=0
    # Oldest first. name and creation in seconds, tab-separated.
    while IFS=$'\t' read -r name created; do
        [[ -n "$name" ]] || continue
        k="$(_kind "${name#*@}")"
        if [[ -z "${LIMIT[$k]:-}" ]]; then
            other=$((other + 1))
            continue
        fi
        count[$k]=$((${count[$k]:-0} + 1))
        [[ -n "${first[$k]:-}" ]] || first[$k]="$created"
        last[$k]="$created"
        names[$k]+="${name}"$'\n'
    done < <(zfs list -H -p -t snapshot -o name,creation -s creation -d 1 "$ds")
    for k in $(printf '%s\n' "${!count[@]}" | sort); do
        state=ok
        if ((count[$k] > LIMIT[$k])); then
            state="OVER LIMIT"
            over=$((over + 1))
        fi
        printf '%-28s %-18s %5d %5d  %-16s %-16s %s\n' "$ds" "$k" "${count[$k]}" "${LIMIT[$k]}" \
            "$(date -d "@${first[$k]}" '+%F %H:%M')" "$(date -d "@${last[$k]}" '+%F %H:%M')" "$state"
        ((verbose)) && printf '%s' "${names[$k]}" | sed 's/^/    /'
    done
    ((other == 0)) || printf '%-28s %-18s %5d %5s  %s\n' "$ds" "(not kldload's)" "$other" - \
        "sanoid, the install snapshot, or by hand -- not judged here"
    unset count first last names
done

if ((over)); then
    echo "${over} kind(s) over the limit. The next snapshot of that kind prunes it; to prune now:" >&2
    echo "  snapshot-prune.sh <dataset> <kind>- <limit>" >&2
    exit 1
fi
exit 0
