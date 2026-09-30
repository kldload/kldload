#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# power-gate.sh — exercise kldload-power against a fake smart plug, every verb
# and every failure path, for each plug API it speaks.
#
#   1. starts tests/power-fakeplug.py as shelly1, shelly2 and tasmota in turn,
#      each with a login (Basic, SHA-256 digest, password-in-URL);
#   2. writes a record with `set --password-stdin`, then drives status, on,
#      force-off, cycle, and the refusals (off and pxe-once on a plug: exit 3);
#   3. wrong password -> exit 5, a plug that is gone -> exit 4;
#   4. records every argv curl was given through a PATH shim and fails if the
#      password is in any of them; checks power.log never holds it;
#   5. a status-only record (--allow status) refuses every other verb with
#      exit 6 and sends the plug nothing that changes state;
#   6. usage errors exit 2, and cutting power to THIS host is refused.
#
# WHY: a power tool that reports "done" while the plug did nothing, or leaks
# the password into ps, is worse than none. Two of this gate's own first
# probes were wrong (2026-09-29): `ps | grep PW` matched the grep, and
# sampling /proc every 0.1 s missed a planted leak entirely because curl lives
# milliseconds. The shim records every call; the gate was shown to fail on a
# copy of the tool that put the password on curl's command line.
#
# Needs: bash, python3, curl, jq. No root, no network beyond 127.0.0.1: the
# tool runs as the user against KLDLOAD_POWER_DIR (its test hook).
# Exit: 0 all passed, 1 any failed. Run: bash tests/power-gate.sh
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
trap 'echo "power-gate: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

HERE="$(cd "$(dirname "$0")" && pwd)"
T="${KLDLOAD_POWER_BIN:-${HERE}/../live-build/config/includes.chroot/usr/local/sbin/kldload-power}"
FAKE="${HERE}/power-fakeplug.py"
for c in python3 curl jq; do command -v "$c" >/dev/null || {
    echo "power-gate: DID NOT RUN — $c is missing" >&2
    exit 1
}; done

# The shim must be executable, and /tmp is noexec on some hosts (onyx), so the
# work directory lives under the user's cache.
WORK="$(mktemp -d -p "${XDG_CACHE_HOME:-$HOME/.cache}" power-gate.XXXXXX)"
FP=0
cleanup() {
    ((FP)) && kill "$FP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
cd "$WORK"
mkdir shim
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"${ARGV_LOG:?}"\nexec %q "$@"\n' "$(command -v curl)" >shim/curl
chmod +x shim/curl

export KLDLOAD_POWER_DIR="$WORK/rec" KLDLOAD_POWER_LOG="$WORK/power.log" KLDLOAD_POWER_WAIT=6
PW='s3cr€t $pw`x'
PASS=0 FAIL=0
ok() {
    echo "  PASS $*"
    PASS=$((PASS + 1))
}
bad() {
    echo "  FAIL $*"
    FAIL=$((FAIL + 1))
}
OUT=""
# expect <exit> <label> <cmd...> — runs it, keeps stdout in OUT
expect() {
    local want="$1" label="$2" rc=0
    shift 2
    OUT="$("$@" 2>err)" || rc=$?
    if [[ "$rc" == "$want" ]]; then
        ok "${label} (exit ${rc}${OUT:+, ${OUT%%$'\n'*}})"
    else
        bad "${label}: exit ${rc}, wanted ${want}; $(head -c 200 err)"
    fi
}
start_plug() { # start_plug <kind> <port>
    : >requests.log
    FAKEPLUG_PASSWORD="$PW" python3 "$FAKE" "$1" "$2" &
    FP=$!
    local _
    for _ in $(seq 50); do
        curl -s -o /dev/null "http://127.0.0.1:$2/" && return 0
        sleep 0.1
    done
    echo "power-gate: DID NOT RUN — the fake plug on :$2 never answered" >&2
    exit 1
}
stop_plug() {
    kill "$FP" 2>/dev/null || true # already gone is the same end state
    wait "$FP" 2>/dev/null || true # its exit status is the kill's, not a result
    FP=0
}

port=$((20000 + RANDOM % 20000))
for kind in shelly1 shelly2 tasmota; do
    port=$((port + 1))
    mac="02:00:00:00:$(printf '%02x:%02x' $((port / 256 % 256)) $((port % 256)))"
    echo "== ${kind} on :${port} (${mac})"
    start_plug "$kind" "$port"
    user=()
    [[ "$kind" == shelly2 ]] || user=(--user admin)
    printf '%s\n' "$PW" | "$T" "$mac" set --controller outlet --kind "$kind" \
        --address "127.0.0.1:${port}" "${user[@]}" --name "plug-${kind}" --cycle-off 1 --password-stdin 2>/dev/null
    [[ "$(stat -c %a "rec/${mac}.env")" == 600 ]] && ok "record is 0600" || bad "record mode $(stat -c %a "rec/${mac}.env")"

    expect 0 "status by name" "$T" "plug-${kind}" status
    [[ "$OUT" == off ]] || bad "a new plug should read off, read '${OUT}'"
    expect 0 "on" "$T" "$mac" on
    expect 0 "status" "$T" "$mac" status
    [[ "$OUT" == on ]] || bad "after on it reads '${OUT}'"
    expect 0 "on again is a no-op" "$T" "$mac" on
    expect 3 "off: a plug cannot shut an OS down" "$T" "$mac" off
    expect 3 "pxe-once: a plug cannot pick a boot device" "$T" "$mac" pxe-once
    expect 0 "force-off" "$T" "$mac" force-off
    expect 0 "status" "$T" "$mac" status
    [[ "$OUT" == off ]] || bad "after force-off it reads '${OUT}'"

    # every argv curl receives during a full cycle
    : >argv.log
    rc=0
    PATH="$WORK/shim:$PATH" ARGV_LOG="$WORK/argv.log" "$T" "$mac" cycle >/dev/null 2>&1 || rc=$?
    ((rc == 0)) && ok "cycle (exit 0)" || bad "cycle exit ${rc}"
    n="$(wc -l <argv.log)"
    ((n > 0)) && ok "the shim saw ${n} curl calls" || bad "the shim saw no curl call: the leak check measured nothing"
    grep -F -q -- "${PW:0:4}" argv.log && bad "the password is in a curl argv" || ok "no curl argv carries the password"
    grep -F -q -- "${PW:0:4}" power.log && bad "the password is in power.log" || ok "power.log does not hold the password"
    expect 0 "status after cycle" "$T" "$mac" status
    [[ "$OUT" == on ]] || bad "after cycle it reads '${OUT}'"

    printf 'wrong\n' | "$T" "$mac" set --controller outlet --kind "$kind" --address "127.0.0.1:${port}" "${user[@]}" --password-stdin 2>/dev/null
    expect 5 "wrong password" "$T" "$mac" status
    stop_plug
    expect 4 "the plug is gone" "$T" "$mac" status
done

echo "== status-only record"
port=$((port + 1))
start_plug shelly2 "$port"
printf '%s\n' "$PW" | "$T" 02:00:00:00:ff:01 set --controller outlet --kind shelly2 --address "127.0.0.1:${port}" \
    --name keepout --allow status --password-stdin 2>/dev/null
expect 0 "status is allowed" "$T" keepout status
for v in on force-off cycle off pxe-once; do
    expect 6 "${v} is refused by the record" "$T" keepout "$v"
done
sets="$(grep -c 'Switch.Set' requests.log || true)" # grep -c exits 1 on zero, the good case
[[ "$sets" == 0 ]] && ok "the plug received no state change" || bad "the plug received ${sets} state changes"
stop_plug

echo "== usage and safety"
expect 2 "a verb is required" "$T" 02:00:00:00:00:01
expect 1 "an unknown machine" "$T" nosuchbox status
expect 2 "set: a bad kind" "$T" 02:00:00:00:00:09 set --controller outlet --kind x --address a
expect 2 "set: a bad address" "$T" 02:00:00:00:00:09 set --controller outlet --kind shelly1 --address 'a b'
expect 2 "set: a bad --allow" "$T" 02:00:00:00:00:09 set --controller outlet --kind shelly1 --address a --allow reboot
self_if="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
if [[ -n "$self_if" && -r "/sys/class/net/${self_if}/address" ]]; then
    self="$(cat "/sys/class/net/${self_if}/address")"
    printf '\n' | "$T" "$self" set --controller outlet --kind shelly2 --address 127.0.0.1:1 --password-stdin 2>/dev/null
    expect 2 "force-off of this very host is refused" "$T" "$self" force-off
else
    echo "  DID NOT RUN: self-refusal (no default route to find this host's MAC)"
fi
expect 0 "--help needs no root" env -u KLDLOAD_POWER_DIR "$T" --help

echo "power-gate: ${PASS} passed, ${FAIL} failed"
if ((FAIL)); then exit 1; fi
