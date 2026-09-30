#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# netplan-gate.sh — kldload-netplan catches every overlap it claims to, and
# passes a clean plan.
#
#   1. the shipped defaults parse with no bad lines, and `check` reports the
#      one overlap they carry today (the master cluster CIDR inside wg1);
#   2. with that fixed, the plan is clean against a LAN route on br0;
#   3. the old 10.96.0.0/12 Services range fails against that LAN
#      (10.100.10.0/24) -- the mistake this tool exists for (2026-09-29);
#   4. a VIP inside the MetalLB pool, a pool off its node network, Services
#      on top of pods, and a value that is not a range all fail;
#   5. a route through a kldload interface (virbr0, wg-k8s) is not a conflict.
#
# Routes come from a fixture (NETPLAN_ROUTES), so the result is the same on
# any host. No root. Exit 0 all passed, 1 otherwise.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
trap 'echo "netplan-gate: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

HERE="$(cd "$(dirname "$0")" && pwd)"
LB="${HERE}/../live-build/config/includes.chroot"
T="${LB}/usr/local/sbin/kldload-netplan"
export NETPLAN_LIB="${LB}/usr/lib/kldload/netplan.sh"
export NETPLAN_DEFAULTS="${LB}/usr/lib/kldload/network-plan.defaults"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat >"$WORK/routes" <<'EOF'
default via 10.100.10.1 dev br0 proto dhcp src 10.100.10.121 metric 425
10.100.10.0/24 dev br0 proto kernel scope link src 10.100.10.121 metric 425
192.168.122.0/24 dev virbr0 proto kernel scope link src 192.168.122.1
10.251.0.0/24 dev wg-k8s proto kernel scope link src 10.251.0.254
EOF
export NETPLAN_ROUTES="$WORK/routes"

PASS=0 FAIL=0
# case <label> <want-exit> <must-print-or-empty> <override lines...>
case_() {
    local label="$1" want="$2" needle="$3" rc=0 out
    shift 3
    printf '%s\n' "$@" >"$WORK/over.env"
    out="$(NETPLAN_FILE="$WORK/over.env" "$T" check 2>&1)" || rc=$?
    if [[ "$rc" == "$want" && (-z "$needle" || "$out" == *"$needle"*) ]]; then
        echo "  PASS ${label} (exit ${rc})"
        PASS=$((PASS + 1))
    else
        echo "  FAIL ${label}: exit ${rc}, wanted ${want}${needle:+ and \"${needle}\"}"
        printf '%s\n' "$out" | sed 's/^/        /'
        FAIL=$((FAIL + 1))
    fi
}
FIX='MASTER_CLUSTER_CIDR=10.247.0.0/20'

case_ "shipped defaults: the wg1 overlap is reported" 1 "PLANE_WG1_NET 10.78.0.0/16 overlaps MASTER_CLUSTER_CIDR" ""
case_ "defaults with the overlap fixed are clean" 0 "0 problem(s)" "$FIX"
case_ "the old /12 Services range fails against the br0 LAN" 1 "overlaps 10.100.10.0/24, which this host reaches via br0" "$FIX" 'K8S_SVC_CIDR=10.96.0.0/12'
case_ "a VIP inside the MetalLB pool" 1 "is inside K8S_LB_POOL" "$FIX" 'K8S_VIP=192.168.122.210'
case_ "a pool off its node network" 1 "is not inside K8S_NODE_NET" "$FIX" 'K8S_LB_POOL=192.168.123.1-192.168.123.9'
case_ "Services on top of pods" 1 "overlaps K8S_SVC_CIDR" "$FIX" 'K8S_SVC_CIDR=10.244.0.0/16'
case_ "a value that is not a range" 1 "not a KEY=range line" "$FIX" 'WG_K8S_NET=banana'
case_ "a route through virbr0/wg-k8s is not a conflict" 0 "checked against 1 route(s)" "$FIX"
rc=0
out="$(NETPLAN_FILE=/nonexistent "$T" check 2>&1)" || rc=$?
[[ "$out" != *"not a KEY=range line"* ]] && echo "  PASS the shipped defaults have no bad lines" && PASS=$((PASS + 1)) ||
    { echo "  FAIL the shipped defaults have bad lines" && FAIL=$((FAIL + 1)); }

echo "netplan-gate: ${PASS} passed, ${FAIL} failed"
if ((FAIL)); then exit 1; fi
