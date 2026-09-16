#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# smoke-show.sh — drive the first-boot show (part 2) through every scene,
# headless, and fail on any console error.
#
# What it does, in order:
#   1. Serves the canonical page directory (free/) on a loopback port, the way
#      the kiosk's nginx listener does, so fetch() and the URL parameters behave
#      as they do on the machine.
#   2. Asks the page how many scenes it has (the #pick options).
#   3. Runs each scene once in headless Chrome for a few seconds of virtual time
#      (?lab=1&scene=N&still=4) and greps the console for Uncaught / Reference /
#      Type / Syntax errors.
#   4. Counts the rendered slides against the arrays in the source.
#
# WHY: the page is 3,000 lines of hand-written JS with no bundler and no test.
# A scene that references the wrong array throws a ReferenceError on its first
# frame, and nothing catches it until the machine boots into a black stage
# (the pylon rebuild used `plats`, 2026-09-15). This gate found that class of
# defect in under two minutes and was proven to fire on a deliberately broken
# copy before it was trusted.
#
# Inputs : SHOW_DIR (default: the repo's free/), SHOW_PORT (default 8199),
#          google-chrome on PATH.
# Outputs: one line per scene on stdout; the usual _pass/_fail summary.
# Exit   : 0 every scene clean, 1 otherwise. A missing browser is a loud WARN
#          and exit 1: a gate that cannot run is not a gate (§3).
# ═══════════════════════════════════════════════════════════════════════════════
set -Eeuo pipefail
trap 'echo "smoke-show.sh: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib-test.sh
source "$ROOT/tests/lib-test.sh"

DIR="${SHOW_DIR:-$ROOT/live-build/config/includes.chroot/usr/local/share/kldload-webui/free}"
PORT="${SHOW_PORT:-8199}"
PAGE="$DIR/firstboot.html"

_section "first-boot show, part 2 (firstboot.html)"

[[ -f "$PAGE" ]] || {
    _fail "show page" "$PAGE is missing"
    exit 1
}
CHROME=""
for c in google-chrome google-chrome-stable chromium chromium-browser; do
    if command -v "$c" >/dev/null 2>&1; then
        CHROME="$c"
        break
    fi
done
[[ -n "$CHROME" ]] || {
    _warn "show gate" "no headless Chrome on this host — this check DID NOT RUN"
    exit 1
}

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$DIR" >/dev/null 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null || true' EXIT # the server is ours; a dead one is fine
sleep 0.5

chrome() { # url [budget-ms]  — the console goes to stderr
    timeout 60 "$CHROME" --headless=new --disable-gpu --no-sandbox --enable-logging=stderr --v=0 \
        --virtual-time-budget="${2:-6000}" --window-size=1600,900 "$1"
}
dom() { # url [budget-ms]  — the rendered DOM on stdout
    timeout 60 "$CHROME" --headless=new --disable-gpu --no-sandbox \
        --virtual-time-budget="${2:-3000}" --window-size=1600,900 --dump-dom "$1" 2>/dev/null
}

# 2. how many scenes: the picker has one <option> per scene
# -o | wc -l, not grep -c: the dumped DOM puts every <option> on one line
N=$(dom "http://127.0.0.1:$PORT/firstboot.html?lab=1&still=1" 2000 | grep -o '<option' | wc -l || true)
if ((N == 0)); then
    _fail "scene count" "could not count scenes from #pick — the page did not render at all"
    exit 1
fi

# 3. every scene, one run each
bad=0
for i in $(seq 1 "$N"); do
    log=$(chrome "http://127.0.0.1:$PORT/firstboot.html?lab=1&scene=$i&still=4" 2>&1 >/dev/null || true)
    errs=$(printf '%s\n' "$log" | grep -E 'Uncaught|ReferenceError|TypeError|SyntaxError|is not defined' || true) # no error lines is the pass
    if [[ -n "$errs" ]]; then
        _fail "scene $i" "$(printf '%s\n' "$errs" | head -1)"
        bad=$((bad + 1))
    else
        echo "  scene $i: ok"
    fi
done
((bad == 0)) && _pass "all $N scenes draw with no console errors"

# 4. the slides the page built against the slides the source declares
want=$(grep -cE '^    \["' "$PAGE" || true)
got=$(dom "http://127.0.0.1:$PORT/firstboot.html?lab=1&still=1" 3000 | grep -o 'class="slide' | wc -l || true) # grep 1 = zero slides, which is the failure reported below, not an abort
# MANUAL entries are also 4-space "[" lines; subtract them from the source count
manual=$(awk '/var MANUAL = \[/{m=1; next} m && /^  \];/{m=0} m && /^    \[/{n++} END{print n+0}' "$PAGE")
want=$((want - manual))
if ((got == want)); then
    _pass "$got slides rendered, matching the $want declared in the source"
else
    _fail "slide count" "page built $got slides, source declares $want — a bracket is wrong somewhere"
fi

echo
echo "  smoke-show: PASS=$PASS FAIL=$FAIL WARN=$WARN"
((FAIL == 0))
