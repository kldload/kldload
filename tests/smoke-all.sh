#!/bin/bash
# smoke-all.sh — comprehensive kldloadOS test report
# Detects profile, runs all applicable tests, generates a summary report
# Run on an installed system: sudo bash smoke-all.sh
set -uo pipefail

if [[ $EUID -ne 0 ]]; then exec sudo "$0" "$@"; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
run_suite() {
    local name="$1" script="$2"
    if [[ ! -f "$script" ]]; then
        echo -e "  ${Y}SKIP${N}  $name — script not found: $script" | tee_report
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

# Server tests for server, kvm, desktop, ai profiles
case "$PROFILE" in
server | kvm | desktop | ai | zfslab)
    run_suite "Server Tests (Tools, Sanoid, WireGuard, eBPF)" "$SCRIPT_DIR/smoke-server.sh"
    ;;
esac

# KVM tests for kvm and zfslab profiles
case "$PROFILE" in
kvm | zfslab)
    run_suite "KVM Tests (Libvirt, virbr0, K8s Tools, Cluster)" "$SCRIPT_DIR/smoke-kvm.sh"
    ;;
esac

# Desktop tests
case "$PROFILE" in
desktop | ai)
    run_suite "Desktop Tests (GNOME, GDM, Firefox)" "$SCRIPT_DIR/smoke-desktop.sh"
    ;;
esac

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

    if [[ $TOTAL_FAIL -eq 0 ]]; then
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
exit 0
