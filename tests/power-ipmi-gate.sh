#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# power-ipmi-gate.sh — drive kldload-power's IPMI driver against a real IPMI
# endpoint: virtualbmc in front of a throwaway libvirt domain.
#
#   1. defines power-probe-<pid>: 64 MiB, no disk, NO network interface (it can
#      never PXE into the netboot server this host may be running);
#   2. starts vbmcd and a virtual BMC for it on 127.0.0.1 (random port);
#   3. writes a record and drives status/on/force-off/cycle/pxe-once, checking
#      every outcome against `virsh domstate` / the domain XML -- the tool's
#      own read-back is not allowed to be the only witness;
#   4. a soft `off` with no OS to answer ACPI must FAIL (read-back honesty);
#   5. wrong password -> exit 5, nothing listening -> exit 4;
#   6. deletes the vBMC and the domain by exact name, stops the vbmcd it
#      started, and checks nothing is left.
#
# WHY: abyss is the only real BMC on the bench and must never be switched
# (operator's main pool, GELI unlocked by hand each boot), so every IPMI verb
# but `status` is proven here instead. What this cannot prove: UEFI network
# boot (vbmc ignores options=efiboot) and vendor quirks -- those need a real
# BMC that may be cycled.
#
# Needs root (qemu:///system), python3-virtualbmc (test-only, never shipped),
# ipmitool. Exit: 0 all passed, 1 any failed or the gate DID NOT RUN.
# Run: sudo bash tests/power-ipmi-gate.sh
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
trap 'echo "power-ipmi-gate: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

HERE="$(cd "$(dirname "$0")" && pwd)"
T="${KLDLOAD_POWER_BIN:-${HERE}/../live-build/config/includes.chroot/usr/local/sbin/kldload-power}"
didnotrun() {
    echo "power-ipmi-gate: DID NOT RUN — $*" >&2
    exit 1
}
((EUID == 0)) || didnotrun "needs root (libvirt qemu:///system)"
for c in vbmc vbmcd ipmitool virsh; do command -v "$c" >/dev/null || didnotrun "$c is missing (dnf install python3-virtualbmc ipmitool)"; done

P="power-probe-$$"
PORT=$((20000 + RANDOM % 20000))
WORK="$(mktemp -d)"
PW="$(head -c 12 /dev/urandom | base64 | tr -d '/+=')"
STARTED_VBMCD=0
cleanup() {
    vbmc stop "$P" >/dev/null 2>&1 || true           # not added yet is the same end state
    vbmc delete "$P" >/dev/null 2>&1 || true         # ditto
    virsh destroy "$P" >/dev/null 2>&1 || true       # already off is the wanted state
    virsh undefine "$P" >/dev/null 2>&1 || true      # never defined is the wanted state
    ((STARTED_VBMCD)) && { pkill -x vbmcd || true; } # already exited is fine
    rm -rf "$WORK"
    if virsh dominfo "$P" >/dev/null 2>&1; then echo "power-ipmi-gate: LEFT BEHIND: domain $P" >&2; fi
}
trap cleanup EXIT

cat >"$WORK/d.xml" <<EOF
<domain type='kvm'>
  <name>${P}</name>
  <memory unit='MiB'>64</memory>
  <vcpu>1</vcpu>
  <os><type arch='x86_64' machine='q35'>hvm</type><boot dev='hd'/></os>
  <features><acpi/></features>
  <devices><console type='pty'/></devices>
</domain>
EOF
virsh -q define "$WORK/d.xml"
if ! pgrep -x vbmcd >/dev/null; then
    vbmcd
    STARTED_VBMCD=1
    sleep 2
fi
# the emulator's own password is a throwaway; vbmc only takes it on argv
vbmc add "$P" --port "$PORT" --address 127.0.0.1 --username admin --password "$PW" --libvirt-uri qemu:///system >/dev/null
vbmc start "$P" >/dev/null
sleep 2

export KLDLOAD_POWER_DIR="$WORK/rec" KLDLOAD_POWER_LOG="$WORK/power.log" KLDLOAD_POWER_WAIT=20
MAC=02:00:00:00:99:01
printf '%s\n' "$PW" | "$T" "$MAC" set --controller ipmi --address "127.0.0.1:${PORT}" --user admin --name probe --cycle-off 3 --password-stdin 2>/dev/null

PASS=0 FAIL=0
ok() {
    echo "  PASS $*"
    PASS=$((PASS + 1))
}
bad() {
    echo "  FAIL $*"
    FAIL=$((FAIL + 1))
}
# check <exit> <domstate> <label> <verb> — the tool's exit AND libvirt's view
check() {
    local want_rc="$1" want_st="$2" label="$3" rc=0 st
    "$T" probe "$4" >/dev/null 2>&1 || rc=$?
    st="$(virsh domstate "$P" 2>/dev/null)"
    if [[ "$rc" == "$want_rc" && ("$want_st" == - || "$st" == "$want_st") ]]; then
        ok "${label}: exit ${rc}, libvirt says ${st}"
    else
        bad "${label}: exit ${rc} (want ${want_rc}), libvirt says ${st} (want ${want_st})"
    fi
}
st="$("$T" probe status 2>/dev/null || true)" # checked on the next line
[[ "$st" == off ]] && ok "status reads off on a defined, stopped domain" || bad "status read '${st}'"
check 0 running "on" on
check 0 running "on again is a no-op" on
check 0 "shut off" "force-off" force-off
check 0 running "cycle" cycle
# vbmc changes the boot device only while the domain is off; a real BMC takes
# it at any time and applies it at the next boot
check 0 "shut off" "force-off before pxe-once" force-off
check 0 "shut off" "pxe-once" pxe-once
grep -q "<boot dev='network'/>" <(virsh dumpxml "$P") && ok "the domain now boots from the network" ||
    bad "pxe-once returned but the domain still boots: $(virsh dumpxml "$P" | grep '<boot ')"
check 0 running "on" on
check 1 running "soft off with no OS to answer ACPI fails after its wait" off

printf 'wrong-password\n' | "$T" "$MAC" set --controller ipmi --address "127.0.0.1:${PORT}" --user admin --name probe --password-stdin 2>/dev/null
check 5 - "wrong password" status
printf '%s\n' "$PW" | "$T" "$MAC" set --controller ipmi --address "127.0.0.1:$((PORT + 1))" --user admin --name probe --password-stdin 2>/dev/null
check 4 - "nothing listening" status
grep -F -q -- "$PW" "$WORK/power.log" && bad "the password is in power.log" || ok "power.log does not hold the password"

echo "power-ipmi-gate: ${PASS} passed, ${FAIL} failed"
if ((FAIL)); then exit 1; fi
