#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# kfire-wall.sh — feed the microVM wall overlay with LIVE state, and serve it.
#
# WHAT IT DOES, IN ORDER:
#   1. writes `kfire list --json` to <dir>/feed.json every INTERVAL seconds,
#      atomically, so the page never reads a half-written file;
#   2. serves that directory over HTTP on PORT, bound to localhost;
#   3. cleans both up on exit.
#
# WHY: the wall is an OBS browser source composited over a screen capture. It
# has to show what is ACTUALLY running, not an animation timed to look right.
# Everything on screen is therefore derived from kfire's own output: one tile
# per instance, coloured by its golden, lit when it has an address. If a clone
# does not come up, the tile does not light, and the video shows that.
#
# NOT the demoscene kit. That runtime is deterministic by design -- compose(T)
# reads nothing but score time, no wall clock in any render path -- which is
# what makes an offline 4K60 render reproducible, and is precisely wrong for a
# live overlay. The rendered intro uses the kit; this does not.
#
# Inputs : kfire on PATH (reads /var/lib/kfire), jq
# Outputs: <dir>/feed.json, refreshed; an HTTP server on 127.0.0.1:PORT
# Exit   : 0 stopped cleanly · 1 a prerequisite is missing · 2 usage
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
trap 'echo "kfire-wall: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

usage() { sed -n '2,${/^#/!q; s/^# \{0,1\}//; p}' "$0"; }
case "${1:-}" in -h | --help)
    usage
    exit 0
    ;;
esac

PORT="${KFIRE_WALL_PORT:-8099}"
INTERVAL="${KFIRE_WALL_INTERVAL:-1}"
DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"

while (($#)); do
    case "$1" in
    --port)
        PORT="${2:?--port needs a number}"
        shift
        ;;
    --interval)
        INTERVAL="${2:?--interval needs seconds}"
        shift
        ;;
    *)
        echo "unknown option: $1 (try --help)" >&2
        exit 2
        ;;
    esac
    shift
done

command -v kfire >/dev/null || {
    echo "kfire is not on PATH" >&2
    exit 1
}
command -v jq >/dev/null || {
    echo "jq is not installed" >&2
    exit 1
}
[[ -r "${DIR}/kfire-wall.html" ]] || {
    echo "kfire-wall.html is not beside this script" >&2
    exit 1
}

_tmp="$(mktemp -d)"
_pids=()
cleanup() {
    for _p in "${_pids[@]:-}"; do [[ -n "${_p:-}" ]] && kill "$_p" 2>/dev/null; done
    rm -rf "$_tmp"
}
trap cleanup EXIT

# The feed. mv, not >: a browser polling this must never see a partial write.
(
    while :; do
        if kfire list --json >"${_tmp}/f" 2>/dev/null && jq -e . "${_tmp}/f" >/dev/null 2>&1; then
            mv "${_tmp}/f" "${DIR}/feed.json"
        else
            # swallow: kfire exits non-zero when no instance exists yet, which is
            # the normal state before the first clone. An empty wall is correct.
            printf '[]' >"${_tmp}/f" && mv "${_tmp}/f" "${DIR}/feed.json"
        fi
        sleep "$INTERVAL"
    done
) &
_pids+=($!)

(cd "$DIR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
_pids+=($!)

echo "wall:  http://127.0.0.1:${PORT}/kfire-wall.html"
echo "feed:  ${DIR}/feed.json (every ${INTERVAL}s)"
echo "OBS:   add a Browser source at that URL, 1920x1080, transparent background."
echo "Ctrl-C to stop."
wait
