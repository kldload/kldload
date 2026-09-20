#!/bin/bash
# smoke-all.sh — comprehensive kldloadOS test report
# Detects profile, runs all applicable tests, generates a summary report
# Run on an installed system: sudo bash smoke-all.sh

set -Eeuo pipefail

# This file's own options line is `set -uo pipefail`, and that is the author's
# intent. The 2026-09-15 strict sweep put `set -Eeuo pipefail` above it, which
# additionally forced errexit here; a LATER set line cannot clear an
# option an earlier one set, so the file ran that way regardless. That is the
# mechanic that killed build 21 on onyx through dracut. The drop has to be
# explicit. See project_strict-sweep-overrode-soft-set-lines.
set +e +E

# --help answers before the root re-exec: asking what a tool does must never
# need a password, and this one takes no options at all, so the answer is
# short and cannot drift with a flag change.
case "${1:-}" in
-h | --help)
    cat <<'USAGE'
Usage: smoke-all.sh

Run every smoke suite that applies to THIS machine and print one summary
report. Meant to be run on an installed system, not on the live ISO.

Takes no options. Needs root.

It detects the installed profile itself and runs only the suites that match,
so a core install does not fail for having no KVM. Each suite's result is
folded into a single PASS / FAIL / WARN table at the end.

See also: tests/lifecycle.sh (installs into a throwaway VM and then runs this),
tests/smoke-build.sh (checks the built ISO instead, and needs no VM).
USAGE
    exit 0
    ;;
esac

if [[ $EUID -ne 0 ]]; then exec sudo "$0" "$@"; fi

# Resolve the SYMLINK CHAIN, not the invocation path. kldload-test is
# /usr/local/sbin/kldload-test -> /usr/local/bin/kldload-test ->
# /usr/local/share/kldload/tests/smoke-all.sh, and sudo's secure_path puts sbin
# first, so BASH_SOURCE[0] was /usr/local/sbin/kldload-test and every sibling
# suite was looked for in /usr/local/sbin. On fiend, debian/server, 2026-09-19:
# all three suites SKIPPED, 0 passes, and the run still printed "ALL TESTS
# PASSED — this system is verified and ready for production use".
_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPORT="/tmp/kldload-smoke-report-$(date -u +%Y%m%d-%H%M%S).txt"
# _count_results — how many result lines of one kind a suite emitted.
#
# Args:    $1 the captured suite output, $2 one of PASS / FAIL / WARN.
# Returns: the count on stdout; always exits 0, so a suite with none of a
#          given kind does not have to be special-cased by the caller.
#
# WHY NOT `grep -c WORD`: see the note at the call site. Also, grep -c exits 1
# when the count is zero, so the old `$(grep -c … || echo 0)` appended a SECOND
# "0" to a substitution that had already captured one — yielding "0\n0" and an
# arithmetic error the first time a suite passed everything.
_count_results() {
    local out=$1 kind=$2 n
    # Strip SGR sequences first: both emitters colour the marker, so the word
    # is never at the start of the raw line.
    n=$(printf '%s\n' "$out" |
        sed 's/\x1b\[[0-9;]*m//g' |
        grep -cE "^[[:space:]]*(✓|✗|⚠)?[[:space:]]*${kind}[[:space:]]") || n=0
    printf '%s\n' "$n"
}

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_WARN=0

# Colors
C="\033[1;36m"
G="\033[1;32m"
R="\033[1;31m"
Y="\033[1;33m"
W="\033[1;37m"
D="\033[0;37m"
N="\033[0m"

# ── Detect environment ───────────────────────────────────────────────────────
BUILD_ID="$(cat /etc/kldload-build-id 2>/dev/null || echo 'unknown')"
BUILD_SHA="$(cat /etc/kldload-build-sha 2>/dev/null || echo 'unknown')"
PROFILE="$(cat /etc/kldload/profile 2>/dev/null || echo 'unknown')"
EDITION="$(cat /etc/kldload/edition 2>/dev/null || echo 'unknown')"
DISTRO_ID="$(. /etc/os-release 2>/dev/null && echo "$ID" || echo 'unknown')"
KERNEL="$(uname -r)"
HOSTNAME="$(hostname 2>/dev/null || hostnamectl hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo 'unknown')"
UPTIME="$(uptime -p 2>/dev/null || uptime)"

# ── Header ───────────────────────────────────────────────────────────────────
header() {
    local msg="$1"
    echo -e "${C}══════════════════════════════════════════════════════════════${N}"
    echo -e "${W}  $msg${N}"
    echo -e "${C}══════════════════════════════════════════════════════════════${N}"
}

tee_report() {
    # Write to both terminal and report file
    tee -a "$REPORT"
}

# ── Start report ─────────────────────────────────────────────────────────────
{
    header "kldloadOS Comprehensive Test Report"
    echo ""
    echo "  Date:      $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "  Build:     $BUILD_ID ($BUILD_SHA)"
    echo "  Profile:   $PROFILE"
    echo "  Edition:   $EDITION"
    echo "  Distro:    $DISTRO_ID"
    echo "  Kernel:    $KERNEL"
    echo "  Hostname:  $HOSTNAME"
    echo "  Uptime:    $UPTIME"
    echo ""
} | tee_report

# ── Run test suites based on profile ─────────────────────────────────────────
# SUITES_MISSING — suites this run could not find. A missing suite is not a
# skip: skipping is what this script does on purpose for a profile that has no
# desktop, while a suite whose FILE is absent means the run tested nothing it
# thought it was testing. Counted here and made fatal in the final report.
SUITES_MISSING=0

run_suite() {
    local name="$1" script="$2"
    if [[ ! -f "$script" ]]; then
        echo -e "  ${R}MISSING${N}  $name — script not found: $script" | tee_report
        SUITES_MISSING=$((SUITES_MISSING + 1))
        return
    fi

    echo "" | tee_report
    header "$name" | tee_report

    # Run the test and capture output + exit code
    local output
    output=$(bash "$script" 2>&1) || true
    echo "$output" | tee_report

    # Parse results from output.
    #
    # Count RESULT LINES, not every line containing the word. A bare substring
    # match also counts each suite's own summary block — "PASS: 41", "FAIL: 1",
    # "WARN: 3" and the "N FAILURES — review report above" trailer — so a suite
    # reporting one failure contributed two to the total. On fiend
    # (2026-08-19) a single cilium-scrape failure was reported as "FAIL: 2" and
    # the unit exited 2, which sent the operator looking for a second fault
    # that never existed.
    #
    # Two emitters have to match: tests/lib-test.sh prints "✗ FAIL <name> — …"
    # and kldload-doctor prints "FAIL  <name>: …". Both are anchored to the
    # start of the line and followed by whitespace, which is what separates a
    # result from the "FAIL:" of a summary.
    local p f w
    p=$(_count_results "$output" 'PASS') || p=0
    f=$(_count_results "$output" 'FAIL') || f=0
    w=$(_count_results "$output" 'WARN') || w=0

    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
    TOTAL_WARN=$((TOTAL_WARN + w))
}

# Always run core
run_suite "Core Tests (ZFS, SSH, Network)" "$SCRIPT_DIR/smoke-core.sh"

# The feature ledger runs on EVERY profile, deliberately. The other suites are
# organised by subsystem and each one is skipped on the profiles it does not
# apply to; this one is organised by SHIPPED FEATURE, and a feature that failed
# to reach the target is exactly the case no subsystem suite is looking for.
# Its checks degrade to a warning where a subsystem is genuinely absent, so it
# is safe to run everywhere. See the header of smoke-features.sh for the rule
# on adding to it: every feature gets a check here in the change that ships it.
run_suite "Feature Ledger (apps, rollback, estate, goldens, audio, mesh)" "$SCRIPT_DIR/smoke-features.sh"

# The estate suite runs everywhere too, for the same reason: the machines that
# BUILD goldens are not the only ones that end up with VMs, and a host with
# none reports DID NOT RUN rather than a pass. Where the feature ledger asks
# "is this VM in the inventory", this one asks "does Ansible reach it, does a
# play run, is it up in Prometheus, has it handshaken" -- the questions a
# listing cannot answer (operator, 2026-09-19).
run_suite "Estate (ansible reach, playbook, monitoring, mesh)" "$SCRIPT_DIR/smoke-estate.sh"

# Server tests for server, kvm, desktop, ai profiles
case "$PROFILE" in
server | kvm | desktop | ai | zfslab)
    run_suite "Server Tests (Tools, Sanoid, WireGuard, eBPF)" "$SCRIPT_DIR/smoke-server.sh"
    ;;
esac

# KVM tests wherever the machine is ACTUALLY a KVM host.
#
# This used to be `case $PROFILE in kvm|zfslab)`, which misses every desktop or
# server install that set KLDLOAD_ENABLE_KVM=1 -- and that is a full KVM host
# by every other measure. fiend (2026-09-16) was a desktop profile running 16
# VMs across 23 VM datasets and never ran one line of this suite; a broken
# hourly snapshot timer sat there unnoticed for the life of the install because
# the only test that would have caught it was gated on a profile NAME.
#
# Three signals, any one of which means there is something here to test: the
# profile, what the installer was asked for, and what is on the disk right now.
_is_kvm_host=0
case "$PROFILE" in
kvm | zfslab) _is_kvm_host=1 ;;
esac
grep -qs '^KLDLOAD_ENABLE_KVM="\?1' /etc/kldload/install-manifest.env && _is_kvm_host=1
zfs list rpool/vms >/dev/null 2>&1 && _is_kvm_host=1
if ((_is_kvm_host)); then
    run_suite "KVM Tests (Libvirt, virbr0, K8s Tools, Cluster)" "$SCRIPT_DIR/smoke-kvm.sh"
fi

# Desktop tests, wherever the machine ACTUALLY has a desktop.
#
# This used to be `case $PROFILE in desktop|ai)`, and the `ai` arm was simply
# wrong: that profile is "core + WireGuard + Python + tmux + modern CLI, Ollama
# on firstboot" and ships no GUI packages whatsoever. So every ai install ran
# the GNOME suite and failed seven checks it could never pass -- gnome-shell,
# gnome-session, gnome-terminal, nautilus, gdm, a chromium browser and
# PyGObject, none of which it is meant to have. Caught 2026-09-18 on the first
# ai install the matrix has ever done; the edition was reported FAILED while
# ollama was active and every other check passed.
#
# Same shape as the KVM suite being gated on a profile NAME rather than on
# whether the machine is a KVM host. Ask the machine instead: a display manager
# on disk is what "this is a desktop" means, and it is true for the desktop
# profile, for vdi, and for anything else that grows a GUI later without anyone
# remembering to edit this list.
_is_desktop=0
case "$PROFILE" in
desktop | vdi) _is_desktop=1 ;;
esac
[[ -e /etc/systemd/system/display-manager.service ]] && _is_desktop=1
if ((_is_desktop)); then
    run_suite "Desktop Tests (GNOME, GDM, Firefox)" "$SCRIPT_DIR/smoke-desktop.sh"
fi

# K8s cluster test if cluster is deployed
if virsh list --name 2>/dev/null | grep -q kldload-cp; then
    echo "" | tee_report
    header "Kubernetes Cluster Smoke Test" | tee_report

    CP_MAC=$(virsh domiflist kldload-cp 2>/dev/null | awk '/bridge/ {print $5}' | head -1)
    CP_IP=$(virsh net-dhcp-leases default 2>/dev/null | awk -v m="$CP_MAC" '$3 == m {print $5}' | cut -d/ -f1 | head -1)

    if [[ -n "$CP_IP" ]]; then
        echo "  Control plane: $CP_IP" | tee_report
        output=$(sshpass -p kldload ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "root@${CP_IP}" "kube-smoke-test" 2>&1) || true
        echo "$output" | tee_report

        p=$(_count_results "$output" 'PASS') || p=0
        f=$(_count_results "$output" 'FAIL') || f=0
        w=$(_count_results "$output" 'WARN') || w=0
        TOTAL_PASS=$((TOTAL_PASS + p))
        TOTAL_FAIL=$((TOTAL_FAIL + f))
        TOTAL_WARN=$((TOTAL_WARN + w))
    else
        echo -e "  ${Y}SKIP${N}  Cannot reach control plane" | tee_report
    fi
fi

# ── Hardware inventory ───────────────────────────────────────────────────────
{
    echo ""
    header "Hardware Inventory"
    echo ""
    echo "  CPU:     $(nproc) cores — $(lscpu 2>/dev/null | grep 'Model name' | sed 's/.*: *//')"
    echo "  RAM:     $(free -h 2>/dev/null | awk '/Mem:/ {print $2}')"
    echo "  Disk:    $(lsblk -d -o NAME,SIZE,MODEL 2>/dev/null | grep -v "^NAME" | head -3 | sed 's/^/           /')"
    echo "  GPU:     $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo 'none')"
    echo "  ZFS:     $(zpool list -H -o name,size,health 2>/dev/null | head -3 | sed 's/^/           /')"
    echo ""

    # Network
    echo "  Network:"
    ip -4 addr show 2>/dev/null | grep 'inet ' | grep -v 127.0.0 | awk '{print "           " $NF ": " $2}'
    echo ""

    # VMs if KVM
    if command -v virsh >/dev/null 2>&1; then
        # grep -c prints its count even when it exits 1 (zero matches), so
        # only swallow the status — `|| echo 0` would yield "0\n0" here.
        vm_count=$(virsh list --all --name 2>/dev/null | grep -c -v '^$' || true)
        echo "  VMs:     $vm_count defined"
        virsh list --all 2>/dev/null | grep -v "^$" | sed 's/^/           /'
        echo ""
    fi
} | tee_report

# ── Final summary ────────────────────────────────────────────────────────────
{
    echo ""
    header "FINAL REPORT"
    echo ""
    echo "  Build:     $BUILD_ID ($BUILD_SHA)"
    echo "  Profile:   $PROFILE / $EDITION"
    echo "  Distro:    $DISTRO_ID ($KERNEL)"
    echo ""
    echo -e "  ${G}PASS: $TOTAL_PASS${N}"
    echo -e "  ${R}FAIL: $TOTAL_FAIL${N}"
    echo -e "  ${Y}WARN: $TOTAL_WARN${N}"
    echo ""

    if [[ $SUITES_MISSING -gt 0 ]]; then
        # A gate that cannot run is not a gate. This branch exists because the
        # old one printed "verified and ready for production use" over a run
        # where every suite file was missing and nothing had been checked.
        echo -e "  ${R}INCONCLUSIVE — $SUITES_MISSING suite(s) could not be found${N}"
        echo ""
        if [[ $TOTAL_PASS -eq 0 ]]; then
            echo "  This run tested NOTHING it believed it was testing. Do not read"
            echo "  the counts above as a verdict; fix the install and re-run."
        else
            echo "  The counts above cover only the suites that were found. The"
            echo "  missing ones are named above and were NOT run."
        fi
    elif [[ $TOTAL_PASS -eq 0 ]]; then
        echo -e "  ${R}INCONCLUSIVE — 0 checks passed${N}"
        echo ""
        echo "  No suite produced a single result. That is a broken run, not a"
        echo "  clean machine."
    elif [[ $TOTAL_FAIL -eq 0 ]]; then
        echo -e "  ${G}ALL TESTS PASSED${N}"
        echo ""
        echo "  This system is verified and ready for production use."
    else
        echo -e "  ${R}$TOTAL_FAIL FAILURES — review report above${N}"
    fi

    echo ""
    echo "  Report saved: $REPORT"
    echo ""
} | tee_report

echo -e "${C}══════════════════════════════════════════════════════════════${N}"

# Exit status is a boolean, not a count: `exit $TOTAL_FAIL` is taken mod 256 by
# the shell, so a run with exactly 256 failures would have reported success.
if ((TOTAL_FAIL > 0)); then
    exit 1
fi
# An inconclusive run must not exit 0 either, or the driver that greps for a
# clean status records "verified" for a machine nothing ran against.
if ((SUITES_MISSING > 0 || TOTAL_PASS == 0)); then
    exit 1
fi
exit 0
