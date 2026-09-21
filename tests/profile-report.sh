#!/usr/bin/env bash
# =============================================================================
# profile-report.sh — everything true about THIS installed machine, as markdown
# =============================================================================
#
# WHAT IT DOES, IN ORDER
#   1. Identity      — distro, profile, ISO build commit, kernel, ZFS, uptime.
#   2. Asked vs got  — every feature the answers file requested, against what is
#                      actually on the disk. This is the section that catches a
#                      silent install: requested and absent is a FAIL, not a note.
#   3. Boot posture  — Secure Boot, encryption, module signer, bootfs.
#   4. Services      — failed units, degraded state, and the units kldload owns.
#   5. Estate        — goldens, VMs, inventory, mesh, Prometheus targets.
#   6. Test suites   — the shipped smoke suite, tallied.
#   7. Doctor        — kldload-doctor, tallied by severity.
#   8. Logs          — first-boot warnings and journal errors, counted and sampled.
#   9. Verdict       — one line, and the reason.
#
# WHY IT EXISTS: a profile install has been "verified" by someone reading a
# terminal and seeing no red. That has passed a desktop with no desktop, a klab
# with no goldens, and a cluster with no exporters behind its Metrics menu.
# A run that produces the same manifest every time can be diffed, filed, and
# compared across distros — which is the only way seven profiles times three
# distros stays honest (operator, 2026-09-19).
#
# OUTPUT: markdown on stdout. Diagnostics on stderr. Nothing else on stdout, so
# the driver can redirect it straight into a results file.
# EXIT: 0 the report was produced (its VERDICT says whether the machine is
#       good) · 2 this is not a kldload machine.
# =============================================================================
set -Eeuo pipefail
trap 'echo "profile-report.sh: line $LINENO: $BASH_COMMAND" >&2' ERR
# Every probe below is wrapped (S, cap, _count, or an explicit fallback), so
# -e reports a BUG in this script rather than a machine that answered "no".

export PATH="/usr/local/bin:/usr/local/sbin:$PATH"

# --help answers before the re-exec and before any side effect (tool rule 9).
case "${1:-}" in
-h | --help | help)
    sed -n '2,${/^#/!q; s/^# \{0,1\}//; p}' "$0"
    exit 0
    ;;
esac

# Most of what this reads is root-only: the manifest is 0640 root:root, the
# journal is restricted, and kldload-test wants root. Re-exec rather than
# degrade -- the first run of this script asked `[[ -r ]]` as admin, got
# "not a kldload install" on a perfectly good machine, and reported nothing.
# A wrong probe returns empty, and empty reads as "not there" (2026-09-19).
if ((EUID != 0)); then
    exec sudo -n bash "$0" "$@"
fi

S() { "$@" 2>/dev/null || return 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# _count <extended regex> — matching lines of stdin, 0 when none.
#
# grep exits 1 on no matches and zero is an ANSWER here ("no failures", "no
# errors in the journal"), not a failure. One explained swallow instead of six.
_count() { grep -cE "$1" || true; }

# KLDLOAD_MANIFEST overrides the path, so this script can be exercised against
# a fixture instead of only on a freshly installed machine.
MANIFEST="${KLDLOAD_MANIFEST:-/etc/kldload/install-manifest.env}"
[[ -r "$MANIFEST" ]] || {
    echo "profile-report.sh: ${MANIFEST} is not readable as root — not a kldload install?" >&2
    exit 2
}

# mval <KEY> — a value from the install manifest, unquoted.
mval() { S grep -hE "^${1}=" "$MANIFEST" | tail -1 | cut -d= -f2- | tr -d '"' || true; }

DISTRO="$(mval KLDLOAD_DISTRO)"
PROFILE="$(mval KLDLOAD_PROFILE)"
FAILS=0
WARNS=0
note_fail() {
    FAILS=$((FAILS + 1))
    echo "- **FAIL** $*"
}
note_warn() {
    WARNS=$((WARNS + 1))
    echo "- WARN $*"
}

echo "# ${DISTRO:-unknown}/${PROFILE:-unknown} — $(hostname) — $(date -Is)"
echo

# ─── 1. Identity ────────────────────────────────────────────────────────────
echo "## Identity"
echo
echo '```'
printf '%-18s %s\n' \
    "distro" "$(. /etc/os-release && echo "${PRETTY_NAME:-?}")" \
    "profile" "${PROFILE:-?}" \
    "kernel" "$(uname -r)" \
    "zfs module" "$(S modinfo -F version zfs || echo '?')" \
    "zfs userland" "$(zfs --version 2>/dev/null | head -1 || echo '?')" \
    "ISO build" "$(S grep -hE '^KLDLOAD_(ISO_COMMIT|BUILD_COMMIT|ISO_VERSION)=' "$MANIFEST" | tr '\n' ' ' | tr -d '"' || echo '?')" \
    "installed at" "$(S stat -c %y "$MANIFEST" | cut -d. -f1 || echo '?')" \
    "uptime" "$(uptime -p)"
echo '```'
echo

# ─── 2. Asked vs got ────────────────────────────────────────────────────────
#
# Each row is a feature the answers file can request, the probe that proves it
# landed, and the artefact the probe looks at. The probe is deliberately the
# ARTEFACT (a binary, a unit, a dataset) rather than the package database:
# package databases record intent, files record fact.
echo "## Asked for, versus what is on the disk"
echo
echo '| feature | asked | present | probe |'
echo '|---|---|---|---|'
check_feature() { # check_feature <label> <manifest key> <probe cmd...>
    local label="$1" key="$2" asked got probe
    shift 2
    asked="$(mval "$key")"
    [[ -z "$asked" ]] && asked="unset"
    probe="$*"
    if "$@" >/dev/null 2>&1; then got="yes"; else got="no"; fi
    printf '| %s | %s | %s | `%s` |\n' "$label" "$asked" "$got" "${probe:0:52}"
    # Only a REQUESTED feature that is absent is a defect. An unrequested one
    # that is present is normal (profiles imply features).
    if [[ "$asked" == 1 && "$got" == no ]]; then
        echo "$label" >>/tmp/.pr_missing.$$
    fi
}
: >/tmp/.pr_missing.$$
check_feature "KVM / libvirt" KLDLOAD_ENABLE_KVM command -v virsh
check_feature "Kubernetes" KLDLOAD_ENABLE_K8S command -v kubectl
# NOT `test -d /etc/kubernetes` on the host: kldload builds the cluster INSIDE
# VMs, so the host never has that directory and the probe reported "absent" on
# a machine running six healthy cluster nodes (4-k8s, 2026-09-20). Ask the
# cluster: kubeconfig on the host, and the API answering.
check_feature "K8s bootstrap" KLDLOAD_K8S_BOOTSTRAP \
    bash -c 'test -r /root/.kube/config && timeout 20 kubectl --kubeconfig /root/.kube/config get nodes >/dev/null 2>&1'
check_feature "AI (ollama)" KLDLOAD_ENABLE_AI command -v ollama
check_feature "WireGuard" KLDLOAD_WIREGUARD command -v wg
check_feature "eBPF tools" KLDLOAD_ENABLE_EBPF command -v bpftrace
check_feature "Metrics (devops)" KLDLOAD_ENABLE_DEVOPS test -d /etc/prometheus
check_feature "Web console" KLDLOAD_ENABLE_WEBUI test -x /usr/local/bin/kldload-webui
check_feature "ZFS dev lab" KLDLOAD_KLAB_ZFS_DEV command -v klab
# NOT `test -d /rpool/vms`: that dataset is created with mountpoint=none, so
# the directory never exists and the probe reported "absent" on a machine that
# had five sealed goldens (deb-3-kvm, 2026-09-20). Ask ZFS, and ask about the
# thing that matters — a golden is only built once it carries its @golden snap.
check_feature "Build images" KLDLOAD_BUILD_IMAGES \
    bash -c 'zfs list -H -t snapshot -o name -r rpool/vms 2>/dev/null | grep -q "@golden"'
echo
if [[ -s /tmp/.pr_missing.$$ ]]; then
    while read -r _m; do note_fail "requested but ABSENT: ${_m}"; done </tmp/.pr_missing.$$
    echo
fi
rm -f /tmp/.pr_missing.$$

# ─── 3. Boot posture ────────────────────────────────────────────────────────
echo "## Boot posture"
echo
_sb="$(mokutil --sb-state 2>/dev/null | head -1 || echo 'unknown')"
_enc="$(S zfs get -H -o value encryption rpool || echo '?')"
_signer="$(S modinfo -F signer zfs | head -1 || echo 'unsigned')"
echo '```'
printf '%-18s %s\n' \
    "secure boot" "${_sb}" \
    "asked for SB" "$(mval KLDLOAD_ENABLE_SECURE_BOOT)" \
    "rpool encryption" "${_enc}" \
    "asked for enc" "$(mval KLDLOAD_ZFS_ENCRYPT)" \
    "zfs signed by" "${_signer:-unsigned}" \
    "bootfs" "$(S zpool get -H -o value bootfs rpool || echo '?')" \
    "root dataset" "$(findmnt -no SOURCE / 2>/dev/null)"
echo '```'
echo
# The two that matter: asked for and not got.
[[ "$(mval KLDLOAD_ZFS_ENCRYPT)" == 1 && "$_enc" == off ]] &&
    note_fail "encryption was requested and rpool is NOT encrypted"
[[ "$(mval KLDLOAD_ENABLE_SECURE_BOOT)" == 1 && "$_sb" != *enabled* ]] &&
    note_warn "Secure Boot was requested and firmware reports: ${_sb}"
[[ "$_signer" == "" || "$_signer" == unsigned ]] &&
    note_warn "the ZFS module is not signed — Secure Boot cannot be turned on later"
echo

# ─── 4. Services ────────────────────────────────────────────────────────────
echo "## Services"
echo
# `is-system-running` exits non-zero for "degraded", which is precisely the
# answer worth printing here.
_state="$(systemctl is-system-running 2>/dev/null || true)"
_failed="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
echo '```'
printf '%-18s %s\n' "systemd" "${_state}" "failed units" "${_failed:-none}"
echo '```'
echo
if [[ -n "${_failed// /}" ]]; then
    for _u in $_failed; do
        # kldload-smoke-firstboot runs the smoke suite at first boot, so it
        # fails exactly when the suite found failures. Counting it as its own
        # defect double-counts the same news and sends the reader hunting for a
        # second problem that does not exist (fedora/storage, 2026-09-20).
        if [[ "$_u" == kldload-smoke-firstboot.service ]]; then
            note_warn "kldload-smoke-firstboot failed — it runs the smoke suite, so this reflects the suite failures below, not a separate fault"
            continue
        fi
        note_fail "failed unit: ${_u} — $(S systemctl show -p Result --value "$_u" || echo '?')"
    done
    echo
fi

# ─── 5. Estate ──────────────────────────────────────────────────────────────
# `grep -c X || echo 0` prints TWO lines when there are no matches — grep's own
# "0" and then the echo — which shifted every printf argument after it and put
# stray zeroes through the middle of this table (3-kvm, 2026-09-20). It is the
# same shape the engineering rules already record. _count says it once.
echo "## Estate"
echo
echo '```'
if have virsh; then
    printf '%-18s %s\n' \
        "VMs defined" "$(S virsh list --all --name | _count .)" \
        "VMs running" "$(S virsh list --name | _count .)" \
        "goldens sealed" "$(S zfs list -H -t snapshot -o name -r rpool/vms 2>/dev/null | _count '@golden')" \
        "inventory hosts" "$(kldload-inventory --list 2>/dev/null | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("_meta",{}).get("hostvars",{})))
except Exception: print("?")' || echo '?')" \
        "prom targets" "$(S bash -c 'cat /etc/prometheus/targets/*.json 2>/dev/null' | grep -o '"vm"' | _count .)" \
        "wg peers" "$(S wg show all peers 2>/dev/null | _count .)"
else
    echo "no hypervisor on this machine (virsh absent)"
fi
echo '```'
echo

# ─── 6. Shipped test suite ──────────────────────────────────────────────────
#
# kldload-test IS smoke-all. Driving the shipped verb rather than a copy is the
# rule: a harness that re-implements what it tests has reproduced a fixed bug
# and blamed a healthy machine for it before.
echo "## Smoke suite"
echo
if have kldload-test; then
    # The suite exits 1 when the machine has failures, and that output is the
    # thing being tallied — so the status is discarded and the counts below
    # decide. (Since 2026-09-19 it also exits 1 when it ran nothing, which the
    # zero-pass check further down catches.)
    _smoke="$(S timeout 1800 kldload-test 2>&1 || true)"
    _sp="$(_count '✓ PASS' <<<"$_smoke")"
    _sf="$(_count '✗ FAIL' <<<"$_smoke")"
    _sw="$(_count '⚠ WARN' <<<"$_smoke")"
    echo '```'
    printf 'PASS %s   FAIL %s   WARN %s\n' "$_sp" "$_sf" "$_sw"
    echo '```'
    if ((_sf > 0)); then
        echo
        echo "Failures:"
        echo '```'
        grep -E '✗ FAIL' <<<"$_smoke" | sed 's/\x1b\[[0-9;]*m//g' | head -25
        echo '```'
        note_fail "smoke suite: ${_sf} failure(s)"
    fi
    # A suite that ran nothing is not a pass.
    ((_sp == 0)) && note_fail "smoke suite produced NO passes — it did not really run"
else
    note_warn "kldload-test is not installed — the smoke suite DID NOT RUN"
fi
echo

# ─── 7. Doctor ──────────────────────────────────────────────────────────────
echo "## Doctor"
echo
if have kldload-doctor; then
    # Same shape as the suite: the doctor's exit status reflects the machine,
    # and its output is what gets summarised.
    _doc="$(S timeout 600 kldload-doctor 2>&1 || true)"

    # READ THE DOCTOR'S OWN COUNT, not a line grep for the word "fail".
    #
    # This used to be `_count '(^|[^a-z])(error|fail)'` over the lowercased
    # output, reported as "doctor mentions error/fail on N line(s)". The
    # doctor emits JSON whose summary ALWAYS contains a "fail": key, so
    # `"fail": 0` on a perfectly healthy machine matched it too — the warning
    # fired identically whether the doctor found two problems or none, and the
    # number it printed was a line count, not a failure count. A warning that
    # cannot tell the two states apart is not a check.
    # HISTORY: fiend, 2026-09-21. 11-storage reported "fail": 2 and still came
    # out PASS, because two real doctor failures arrived as the same warning a
    # clean machine gets.
    #
    # The structured count is authoritative; the grep is only a fallback for a
    # doctor that is not emitting JSON, and it is reported as unparseable
    # rather than as a health verdict.
    _dfail="$(sed -n 's/.*"fail"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$_doc" | tail -1)"
    echo '```'
    sed 's/\x1b\[[0-9;]*m//g' <<<"$_doc" | tail -20
    echo '```'
    if [[ -n "$_dfail" ]]; then
        if ((_dfail > 0)); then
            note_fail "kldload-doctor reports ${_dfail} failing check(s)"
        fi
    else
        note_warn "kldload-doctor output carried no machine-readable summary — health NOT assessed"
    fi
else
    note_warn "kldload-doctor is not installed — DID NOT RUN"
fi
echo

# ─── 8. Logs ────────────────────────────────────────────────────────────────
echo "## Logs"
echo
_fb=/var/log/kldload/firstboot.log
_fbw="$(S grep -ciE 'warning|fatal|error' "$_fb" || echo 0)"
_jerr="$(S journalctl -p err -b --no-pager -q | grep -c . || echo 0)"
echo '```'
printf '%-24s %s\n' \
    "firstboot warn/error" "${_fbw}" \
    "journal priority<=err" "${_jerr}"
echo '```'
if ((_jerr > 0)); then
    echo
    echo "Journal errors (most recent 12):"
    echo '```'
    S journalctl -p err -b --no-pager -q | tail -12 | cut -c1-160
    echo '```'
fi
if ((_fbw > 0)); then
    echo
    echo "First-boot warnings (most recent 10):"
    echo '```'
    S grep -iE 'warning|fatal|error' "$_fb" | tail -10 | cut -c1-160
    echo '```'
fi
echo

# ─── 9. Verdict ─────────────────────────────────────────────────────────────
echo "## Verdict"
echo
if ((FAILS == 0 && WARNS == 0)); then
    echo "**PASS** — ${DISTRO}/${PROFILE}: everything requested is present, no failed units, no suite failures."
elif ((FAILS == 0)); then
    echo "**PASS (with ${WARNS} warning(s))** — ${DISTRO}/${PROFILE}. Nothing requested is missing; see the warnings above."
else
    echo "**FAIL** — ${DISTRO}/${PROFILE}: ${FAILS} defect(s), ${WARNS} warning(s). Every one is listed above."
fi
echo
echo "_Generated by tests/profile-report.sh on $(hostname) at $(date -Is)._"
# Explicit, so the ERR trap does not fire on the script's own verdict: a
# machine with defects is a RESULT of this report, not a bug in it.
if ((FAILS == 0)); then
    exit 0
fi
exit 1
