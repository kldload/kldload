#!/bin/bash
# smoke-javaapi-rollback.sh — the kldload 1.0 acceptance gate.
#
# Runs the full PetClinic demo workflow on an installed kldload host:
#
#   1.  deploy   — kube-demo javaapi   (Argo Application syncs the chart)
#   2.  verify   — confirm 8 pods Ready + ingress VIP serves /api/customer
#   3.  baseline — seed rows present in owners table
#   4.  disaster — drop the owners table (or fs-corrupt, or delete PVC)
#   5.  break    — confirm /api/customer now 500s
#   6.  recover  — kube-demo javaapi_recover    (zfs rollback + restart)
#   7.  measure  — time-to-recover; assert <60 seconds
#   8.  verify   — owners table back, /api/customer 200 again
#   9.  cleanup  — kube-demo javaapi_destroy
#
# Pass criteria for 1.0 release:
#   * TTR < 60s
#   * Data integrity: owners.count() before == owners.count() after
#   * Run cleanly with KEEP_DEMO=1 (leaves demo deployed for manual inspection)
#
# Invocation:
#   sudo bash smoke-javaapi-rollback.sh                  # full cycle, cleanup
#   sudo KEEP_DEMO=1 bash smoke-javaapi-rollback.sh      # full cycle, leave deployed
#   sudo DISASTER_MODE=fs bash smoke-javaapi-rollback.sh # fs corruption variant
#
# Distro coverage: invoked by smoke-kvm.sh and smoke-server.sh (any
# kldload profile that has a K8s cluster). Not invoked by smoke-core.sh
# (core profile has no cluster).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-test.sh
source "${SCRIPT_DIR}/lib-test.sh"

# Bail early if not on a cluster host. _find_cluster is defined in
# lib-test.sh; if missing, just check for kubectl.
if ! command -v kubectl >/dev/null 2>&1; then
    _warn "smoke-javaapi" "kubectl not installed — skipping (probably core profile)"
    exit 0
fi

if ! kubectl --request-timeout=5s get nodes >/dev/null 2>&1; then
    _warn "smoke-javaapi" "no reachable K8s cluster — skipping"
    exit 0
fi

DISASTER_MODE="${DISASTER_MODE:-app}"
TTR_LIMIT_SECONDS="${TTR_LIMIT_SECONDS:-60}"
VIP="${VIP:-10.100.10.30}"
KEEP_DEMO="${KEEP_DEMO:-0}"

# ── 1: Deploy ────────────────────────────────────────────────────────
_section "PetClinic deploy via kube-demo"
if ! kube-demo --list 2>/dev/null | grep -qx javaapi; then
    _fail "kube-demo javaapi subcommand missing — old build?"
    exit 1
fi
if ! kube-demo javaapi >/tmp/javaapi-deploy.log 2>&1; then
    _fail "kube-demo javaapi exited non-zero"
    tail -20 /tmp/javaapi-deploy.log
    exit 1
fi
_pass "kube-demo javaapi completed"

# ── 2: Verify pods + ingress ─────────────────────────────────────────
_section "PetClinic pod readiness"
READY=$(kubectl -n demo get pods --no-headers 2>/dev/null | grep -c "Running")
test_eq "$READY" 8 "8 pods in demo ns Running" || _warn "smoke-javaapi" "only $READY of 8 pods Running"

_section "Ingress VIP reachable"
if curl -sf --max-time 10 "http://$VIP/" >/dev/null 2>&1; then
    _pass "http://$VIP/ serves homepage"
else
    _fail "http://$VIP/ unreachable — MetalLB pool / VIP config issue?"
fi
if curl -sf --max-time 10 "http://$VIP/api/customer" >/dev/null 2>&1; then
    _pass "http://$VIP/api/customer returns 2xx"
else
    _fail "/api/customer not reachable — API gateway or services down"
fi

# ── 3: Baseline data ──────────────────────────────────────────────────
_section "Baseline owners.count()"
BASELINE=$(kubectl -n demo exec postgres-0 -- env PGPASSWORD=petclinic-demo-2026 \
    psql -U petclinic -d petclinic -tAc "SELECT count(*) FROM owners;" 2>/dev/null | tr -d '[:space:]')
if [[ -n "$BASELINE" && "$BASELINE" -gt 0 ]]; then
    _pass "owners table has $BASELINE rows (baseline)"
else
    _fail "owners table empty or unreachable (baseline=${BASELINE:-error})"
    exit 1
fi

# ── 4: Disaster ──────────────────────────────────────────────────────
_section "Trigger disaster: $DISASTER_MODE"
if ! kube-demo javaapi_disaster "$DISASTER_MODE" >/tmp/javaapi-disaster.log 2>&1; then
    _fail "disaster fired but kube-demo exited non-zero"
    tail -10 /tmp/javaapi-disaster.log
fi
_pass "disaster $DISASTER_MODE fired"
sleep 3

# ── 5: Confirm break ─────────────────────────────────────────────────
_section "Workload visibly broken"
if [[ "$DISASTER_MODE" == "app" ]]; then
    # owners table dropped → /api/customer should error
    if curl -sf --max-time 5 "http://$VIP/api/customer" >/dev/null 2>&1; then
        _warn "smoke-javaapi" "/api/customer still 2xx after table drop — caching?"
    else
        _pass "/api/customer no longer 2xx (as expected)"
    fi
fi

# ── 6+7: Recover, measure TTR ────────────────────────────────────────
_section "Recover via kube-demo javaapi_recover"
TTR_START=$(date +%s)
if kube-demo javaapi_recover >/tmp/javaapi-recover.log 2>&1; then
    TTR_END=$(date +%s)
    TTR=$((TTR_END - TTR_START))
    if [[ "$TTR" -lt "$TTR_LIMIT_SECONDS" ]]; then
        _pass "recovered in ${TTR}s (under ${TTR_LIMIT_SECONDS}s gate)"
    else
        _fail "TTR=${TTR}s exceeds ${TTR_LIMIT_SECONDS}s gate — regression"
    fi
else
    _fail "kube-demo javaapi_recover exited non-zero"
    tail -20 /tmp/javaapi-recover.log
    exit 1
fi

# ── 8: Verify data + service ─────────────────────────────────────────
_section "Post-recover verification"
# Service back?
if curl -sf --retry 5 --retry-delay 2 --max-time 10 "http://$VIP/api/customer" >/dev/null 2>&1; then
    _pass "/api/customer 2xx after recover"
else
    _fail "/api/customer still broken after recover"
fi
# Data intact?
POST=$(kubectl -n demo exec postgres-0 -- env PGPASSWORD=petclinic-demo-2026 \
    psql -U petclinic -d petclinic -tAc "SELECT count(*) FROM owners;" 2>/dev/null | tr -d '[:space:]')
test_eq "$POST" "$BASELINE" "owners.count() after recover ($POST) == baseline ($BASELINE)"

# ── 9: Cleanup ───────────────────────────────────────────────────────
if [[ "$KEEP_DEMO" != "1" ]]; then
    _section "Cleanup — destroy demo Application"
    echo "y" | kube-demo javaapi_destroy >/tmp/javaapi-destroy.log 2>&1 &&
        _pass "demo destroyed" ||
        _warn "smoke-javaapi" "destroy returned non-zero — check /tmp/javaapi-destroy.log"
fi

_summary
