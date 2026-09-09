#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# dr-drill.sh — prove the backup is real by round-tripping a canary file.
#
# What it does, in order:
#   1. Writes a canary on the CLIENT with a unique token, and fsyncs it. A
#      restore that comes back without this file restored an older snapshot,
#      which is the failure a "it booted!" test cannot see.
#   2. Makes the client snapshot NOW rather than waiting for sanoid's timer,
#      so the canary is inside a snapshot rather than only in the live
#      filesystem, which replication never sees.
#   3. Replicates to the archive host and verifies by OUTCOME.
#   4. Reads the canary back OUT of the archive, by cloning the received
#      snapshot — the archive itself is readonly and stays untouched.
#
# Why a canary at all: a restore can succeed, boot, and still be a week old.
# The token ties a specific write to a specific recovered filesystem.
#
# Exit: 0 the canary survived the round trip · 1 it did not · 2 setup problem.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
trap 'echo "FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

CLIENT_HOST="${CLIENT_HOST:-10.100.10.146}"
CLIENT_USER="${CLIENT_USER:-root}"
SSH_IDENTITY="${SSH_IDENTITY:-/root/.ssh/id_ed25519}"
CANARY_DATASET="${CANARY_DATASET:-rpool/srv}" # a dataset sanoid covers
CANARY_PATH="${CANARY_PATH:-/srv/.dr-canary}"
ARCHIVE="${ARCHIVE:-rpool/backup/fiend}"
SYNC_JOB="${SYNC_JOB:-fiend-nightly}"
ZXPLORE="${ZXPLORE:-/usr/local/bin/zxplore}"

ssh_c=(ssh -i "$SSH_IDENTITY" -o BatchMode=yes -o ConnectTimeout=10 "${CLIENT_USER}@${CLIENT_HOST}")
token="dr-$(date +%Y%m%d-%H%M%S)-$RANDOM"

say() { printf '%s\n' "$*" >&2; }

# ─── 1. canary ───────────────────────────────────────────────────────────────
"${ssh_c[@]}" true 2>/dev/null || {
    say "FATAL: cannot reach ${CLIENT_USER}@${CLIENT_HOST}"
    exit 2
}
say "token: $token"
# sync(1) so the write is on disk before the snapshot is taken; a snapshot of a
# dirty page cache is not the thing being tested.
"${ssh_c[@]}" "printf '%s\n' '$token' > '$CANARY_PATH' && sync" ||
    {
        say "FATAL: could not write the canary at $CANARY_PATH"
        exit 2
    }
say "canary written: ${CLIENT_HOST}:${CANARY_PATH}"

# ─── 2. snapshot NOW ─────────────────────────────────────────────────────────
snap="drill-$(date +%Y%m%d-%H%M%S)"
"${ssh_c[@]}" "zfs snapshot '${CANARY_DATASET}@${snap}'" ||
    {
        say "FATAL: snapshot failed"
        exit 2
    }
say "snapshot: ${CANARY_DATASET}@${snap}"

# ─── 3. replicate, judged by outcome ─────────────────────────────────────────
if ! "$ZXPLORE" --sync-run "$SYNC_JOB" >/dev/null 2>&1; then
    say "FATAL: replication failed — run '$ZXPLORE --sync-run $SYNC_JOB' to see why"
    exit 1
fi
leaf="${CANARY_DATASET#*/}"
archived="${ARCHIVE}/${leaf}@${snap}"
zfs list -H -t snapshot -o name "$archived" >/dev/null 2>&1 ||
    {
        say "FATAL: ${archived} is not in the archive"
        exit 1
    }
say "replicated: $archived"

# ─── 4. read the canary back OUT of the archive ──────────────────────────────
# A clone, not a mount of the archive: the archive is readonly and must stay
# untouched, and a clone of its snapshot is writable and free until written.
scratch="${ARCHIVE%/*}/drill-verify-$$"
mnt="/mnt/dr-drill-$$"
cleanup() {
    zfs unmount "$scratch" 2>/dev/null || true
    zfs destroy -r "$scratch" 2>/dev/null || true
    rmdir "$mnt" 2>/dev/null || true
}
trap cleanup EXIT
zfs clone -o mountpoint="$mnt" "$archived" "$scratch" ||
    {
        say "FATAL: could not clone $archived"
        exit 1
    }
got="$(cat "${mnt}/$(basename "$CANARY_PATH")" 2>/dev/null || true)"

if [[ "$got" == "$token" ]]; then
    say "OK: the canary written on ${CLIENT_HOST} is readable from the archive on $(hostname)."
    say "    token in archive: $got"
    exit 0
fi
say "FATAL: canary mismatch — wrote '$token', archive has '${got:-<nothing>}'"
exit 1
