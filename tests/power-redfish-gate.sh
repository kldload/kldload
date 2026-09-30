#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# power-redfish-gate.sh — drive kldload-power's Redfish driver and `selftest`
# against tests/power-fakeredfish.py, every verb and every failure path.
#
#   1. makes two self-signed certificates and starts the double on one;
#   2. `set` pins the certificate; status/on/force-off/cycle/off work and read
#      back; pxe-once sets Pxe+Once, and the next power-on spends it;
#   3. selftest (reads, pxe-once round trip) and selftest --cycle (puts the
#      machine back as it found it);
#   4. a BMC that rejects BootSourceOverrideMode (pxe-once retries without it),
#      one that wants a license (exit 3), a wrong password (5), the certificate
#      swapped under the pin (1, and says so), nothing listening (4);
#   5. a status-only record: selftest reads and sends the BMC no change at all;
#   6. no curl argv carries the password (PATH shim), including a password
#      holding " and \, which the curl config quoting has to survive.
#
# WHY: Redfish is what newer data-center BMCs speak (IPMI-over-LAN is off by
# default on current Dell/HPE); the operator's next rack is one of those. sushy
# (the OpenStack emulator) covers power against libvirt but ignores "Once", so
# the one-time boot is proven here. The real-hardware word is
# `kldload-power <machine> selftest --cycle` on the rack's first box.
#
# Needs python3, curl, jq, openssl. No root. Exit 0 all passed, 1 otherwise.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
trap 'echo "power-redfish-gate: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

HERE="$(cd "$(dirname "$0")" && pwd)"
T="${KLDLOAD_POWER_BIN:-${HERE}/../live-build/config/includes.chroot/usr/local/sbin/kldload-power}"
FAKE="${HERE}/power-fakeredfish.py"
for c in python3 curl jq openssl; do command -v "$c" >/dev/null || {
    echo "power-redfish-gate: DID NOT RUN — $c is missing" >&2
    exit 1
}; done
WORK="$(mktemp -d -p "${XDG_CACHE_HOME:-$HOME/.cache}" power-rf-gate.XXXXXX)"
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
for c in a b; do
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$c.key" -out "$c.crt" -days 1 -subj "/CN=bmc-$c" 2>/dev/null
done

export KLDLOAD_POWER_DIR="$WORK/rec" KLDLOAD_POWER_LOG="$WORK/power.log" KLDLOAD_POWER_WAIT=10
PW='rf"pa\ss $x`y'
PORT=$((20000 + RANDOM % 20000))
MAC=02:00:00:00:44:01
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
expect() { # expect <exit> <label> <cmd...>
    local want="$1" label="$2" rc=0
    shift 2
    OUT="$("$@" 2>err)" || rc=$?
    if [[ "$rc" == "$want" ]]; then ok "${label} (exit ${rc})"; else
        bad "${label}: exit ${rc}, wanted ${want}; $(tail -n 2 err | tr '\n' ' ' | cut -c1-200)"
    fi
}
start() { # start <cert> [ENV=1 ...]
    local cert="$1"
    shift
    ((FP)) && { kill "$FP" 2>/dev/null || true; } # already gone is the same end state
    wait "$FP" 2>/dev/null || true
    : >requests.log
    env FAKERF_PASSWORD="$PW" "$@" python3 "$FAKE" "$PORT" "$cert.crt" "$cert.key" &
    FP=$!
    local _
    for _ in $(seq 50); do
        curl -sk -o /dev/null "https://127.0.0.1:${PORT}/redfish/v1/" && return 0
        sleep 0.1
    done
    echo "power-redfish-gate: DID NOT RUN — the double never answered" >&2
    exit 1
}
boot() { # the double's Boot object, straight from it (not through the tool)
    curl -sk -K <(printf 'user = "admin:%s"\n' "$(sed 's/\\/\\\\/g; s/"/\\"/g' <<<"$PW")") \
        "https://127.0.0.1:${PORT}/redfish/v1/Systems/1" | jq -r '.Boot | "\(.BootSourceOverrideTarget)/\(.BootSourceOverrideEnabled)"'
}
setrec() { # setrec <password> [extra set args]
    local pw="$1"
    shift
    printf '%s\n' "$pw" | "$T" "$MAC" set --controller redfish --address "127.0.0.1:${PORT}" --user admin \
        --name bmc --cycle-off 1 "$@" --password-stdin 2>/dev/null
}

echo "== a Redfish BMC, pinned"
start a
setrec "$PW"
grep -q '^POWER_TLS_PIN=sha256//' "rec/${MAC}.env" && ok "set pinned the certificate" || bad "no pin in the record"
expect 0 "status" "$T" bmc status
[[ "$OUT" == off ]] || bad "a new BMC should read off, read '${OUT}'"
expect 0 "on" "$T" bmc on
expect 0 "status after on" "$T" bmc status
[[ "$OUT" == on ]] || bad "reads '${OUT}' after on"
expect 0 "force-off" "$T" bmc force-off
expect 0 "cycle" "$T" bmc cycle
expect 0 "off (graceful)" "$T" bmc off
expect 0 "pxe-once" "$T" bmc pxe-once
[[ "$(boot)" == Pxe/Once ]] && ok "the BMC holds Pxe/Once" || bad "the BMC holds $(boot)"
expect 0 "on spends the one-time override" "$T" bmc on
[[ "$(boot)" == None/Disabled ]] && ok "after the boot: None/Disabled" || bad "after the boot: $(boot)"

echo "== selftest"
expect 0 "selftest" "$T" bmc selftest
grep -q 'pxe-once set and read back' <<<"$OUT" && grep -q 'override cleared and read back' <<<"$OUT" &&
    ok "selftest did the round trip" || bad "selftest output: ${OUT}"
[[ "$(boot)" == None/Disabled ]] && ok "selftest left no override" || bad "selftest left $(boot)"
expect 0 "force-off before selftest --cycle" "$T" bmc force-off
expect 0 "selftest --cycle" "$T" bmc selftest --cycle
grep -q 'put back off, as it was' <<<"$OUT" && ok "selftest --cycle put it back off" || bad "selftest --cycle output: ${OUT}"
expect 0 "status after selftest --cycle" "$T" bmc status
[[ "$OUT" == off ]] || bad "selftest --cycle left it '${OUT}'"

echo "== awkward BMCs"
start a FAKERF_NO_MODE=1
expect 0 "pxe-once on a BMC that rejects the boot mode" "$T" bmc pxe-once
[[ "$(boot)" == Pxe/Once ]] && ok "retried without the mode" || bad "the BMC holds $(boot)"
start a FAKERF_LICENSE=1
expect 3 "a BMC that wants a license" "$T" bmc status
grep -q 'needs a license for Redfish (SUM DCMS OOB); use --controller ipmi' err && ok "the license is named" ||
    bad "license message: $(cat err)"
start a
setrec 'wrong-password'
expect 5 "wrong password" "$T" bmc status
setrec "$PW"
start b
expect 1 "the certificate swapped under the pin" "$T" bmc status
grep -q 'different certificate than the one pinned' err && ok "the swap is named" || bad "swap message: $(cat err)"
kill "$FP" 2>/dev/null || true # the next check is "nothing listening"
wait "$FP" 2>/dev/null || true
FP=0
expect 4 "nothing listening" "$T" bmc status

echo "== a status-only record"
start a
setrec "$PW" --allow status
expect 0 "selftest on a status-only record" "$T" bmc selftest
changes="$(grep -cE '^(POST|PATCH)' requests.log || true)" # grep -c exits 1 on zero, the good case
[[ "$changes" == 0 ]] && ok "the BMC received no change" || bad "the BMC received ${changes} changes"
expect 6 "cycle on a status-only record" "$T" bmc cycle

echo "== the password stays out of argv"
setrec "$PW"
: >argv.log
rc=0
PATH="$WORK/shim:$PATH" ARGV_LOG="$WORK/argv.log" "$T" bmc cycle >/dev/null 2>&1 || rc=$?
((rc == 0)) && ok "cycle through the shim (a password with quote and backslash)" || bad "cycle through the shim: exit ${rc}"
n="$(wc -l <argv.log)"
((n > 0)) && ok "the shim saw ${n} curl calls" || bad "the shim saw no curl call"
grep -F -q -- "rf\"pa" argv.log && bad "the password is in a curl argv" || ok "no curl argv carries the password"
grep -F -q -- "rf\"pa" power.log && bad "the password is in power.log" || ok "power.log does not hold the password"

echo "power-redfish-gate: ${PASS} passed, ${FAIL} failed"
if ((FAIL)); then exit 1; fi
