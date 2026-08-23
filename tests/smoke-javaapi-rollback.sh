#!/bin/bash
# smoke-javaapi-rollback.sh — the kldload full-stack acceptance gate.
#
# Runs the whole demo workflow on an installed kldload host:
#
#   1.  deploy    — kube-demo javaapi (helm installs the local chart)
#   2.  verify    — every tier Ready, and the VIP serves real rows
#   3.  write     — place an order through the API; assert it landed in the DB
#   4.  bluegreen — health-gated cutover, then assert the data survived it
#   5.  baseline  — row count before the disaster
#   6.  disaster  — drop the orders table (or fs-corrupt, or delete the PVC)
#   7.  break     — confirm the API visibly fails
#   8.  recover   — kube-demo javaapi_recover (zfs rollback + restart)
#   9.  measure   — time-to-recover; assert < 60s
#   10. verify    — rows back, API serving again
#   11. cleanup   — kube-demo javaapi_destroy
#
# Pass criteria:
#   * TTR < 60s
#   * Data integrity: orders.count() before == after
#   * A cutover moves the serving track and loses no data
#   * Runs cleanly with KEEP_DEMO=1 (leaves the demo up for inspection)
#
# HISTORY: until 2026-08-22 this asserted "8 pods Ready and the ingress VIP
# serves /api/customer" against a VIP constant of 10.100.10.30. None of it
# could pass: build #46 had cut the chart down to Postgres plus a contentless
# nginx, /api/customer did not exist, and MetalLB assigns the VIP from its own
# pool rather than from a constant. A gate that cannot pass is not a gate, so
# it is rewritten here against what the stack actually serves.
#
# Invocation:
#   sudo bash smoke-javaapi-rollback.sh                  # full cycle, cleanup
#   sudo KEEP_DEMO=1 bash smoke-javaapi-rollback.sh      # leave it deployed
#   sudo DISASTER_MODE=fs bash smoke-javaapi-rollback.sh # fs corruption variant
#
# Distro coverage: invoked by smoke-kvm.sh and smoke-server.sh (any kldload
# profile with a K8s cluster). Not invoked by smoke-core.sh (no cluster).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-test.sh
source "${SCRIPT_DIR}/lib-test.sh"

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
KEEP_DEMO="${KEEP_DEMO:-0}"
NS=demo

# psql as the app user, with the password read from the Secret the chart made.
# A literal here would drift from values.yaml the first time it changed.
_psql() {
    local _pw
    _pw=$(kubectl -n "$NS" get secret postgres-credentials \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
    kubectl -n "$NS" exec postgres-0 -- env PGPASSWORD="$_pw" psql -U shop -d shop "$@"
}

# ── 1: Deploy ────────────────────────────────────────────────────────
_section "Full-stack deploy via kube-demo"
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

# ── 2: Verify every tier, then the VIP ───────────────────────────────
# Asserted per DEPLOYMENT rather than as one total pod count: "10 pods are
# Running" stays true when all three of a track's replicas are missing and
# something else scaled up, which is exactly when the gate must fail.
_section "Tier readiness"
for _d in app-blue app-green web; do
    _want=$(kubectl -n "$NS" get deploy "$_d" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    _got=$(kubectl -n "$NS" get deploy "$_d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    test_eq "${_got:-0}" "${_want:-0}" "$_d: ${_got:-0}/${_want:-0} replicas Ready"
done
_pg=$(kubectl -n "$NS" get statefulset postgres -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
test_eq "${_pg:-0}" 1 "postgres: ${_pg:-0}/1 Ready"

# The VIP is whatever MetalLB assigned. Never a constant.
_section "Public VIP serves the application"
VIP="${VIP:-$(kubectl -n "$NS" get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)}"
if [[ -z "$VIP" ]]; then
    _fail "the web Service has no LoadBalancer IP — MetalLB pool exhausted or speaker down"
    exit 1
fi
_pass "MetalLB assigned $VIP"

if curl -sf --max-time 10 "http://$VIP/" >/dev/null 2>&1; then
    _pass "http://$VIP/ serves the storefront page"
else
    _fail "http://$VIP/ unreachable"
fi

# Assert real ROWS, not merely a 2xx: an empty database behind a healthy API
# returns 200 and an empty list, which is the failure this gate exists to catch.
_products=$(curl -sf --max-time 10 "http://$VIP/api/products" 2>/dev/null | grep -o '"sku"' | grep -c .)
if [[ "${_products:-0}" -gt 0 ]]; then
    _pass "/api/products returns ${_products} rows from Postgres"
else
    _fail "/api/products returned no rows — schema not seeded?"
fi

# ── 3: The write path ────────────────────────────────────────────────
_section "Write path: place an order through the API"
_before=$(_psql -tAc "SELECT count(*) FROM shop.orders;" 2>/dev/null | tr -d '[:space:]')
_resp=$(curl -sf --max-time 15 -X POST "http://$VIP/api/orders" \
    -H 'Content-Type: application/json' \
    -d '{"customer_id":1,"product_id":5,"quantity":1}' 2>/dev/null)
_after=$(_psql -tAc "SELECT count(*) FROM shop.orders;" 2>/dev/null | tr -d '[:space:]')
if [[ -n "$_resp" && "${_after:-0}" -eq $((${_before:-0} + 1)) ]]; then
    _pass "order written and visible in Postgres (${_before} -> ${_after})"
else
    _fail "write path broken: response='${_resp:-none}' rows ${_before:-?} -> ${_after:-?}"
fi

# ── 4: Blue/green ────────────────────────────────────────────────────
# The cutover is the demo's headline claim, and nothing verified it before.
_section "Blue/green cutover"
if ! command -v kube-bluegreen >/dev/null 2>&1; then
    _warn "smoke-javaapi" "kube-bluegreen missing — skipping cutover checks"
else
    _live=$(kubectl -n "$NS" get svc shop -o jsonpath='{.spec.selector.track}' 2>/dev/null)
    _target=$([[ "$_live" == blue ]] && echo green || echo blue)
    _rows_pre=$(_psql -tAc "SELECT count(*) FROM shop.orders;" 2>/dev/null | tr -d '[:space:]')

    if kube-bluegreen cutover "$_target" >/tmp/javaapi-cutover.log 2>&1; then
        _now=$(kubectl -n "$NS" get svc shop -o jsonpath='{.spec.selector.track}' 2>/dev/null)
        test_eq "$_now" "$_target" "public selector moved $_live -> $_target"
        # Served-by must actually change, not just the manifest.
        _served=$(curl -s -D - -o /dev/null --max-time 10 "http://$VIP/" 2>/dev/null |
            awk 'tolower($1)=="x-kldload-track:"{print $2}' | tr -d '\r')
        test_eq "$_served" "$_target" "the VIP is served by $_target"
        _rows_post=$(_psql -tAc "SELECT count(*) FROM shop.orders;" 2>/dev/null | tr -d '[:space:]')
        test_eq "$_rows_post" "$_rows_pre" "data survived the cutover ($_rows_post rows)"
        kube-bluegreen cutover "$_live" >/dev/null 2>&1 &&
            _pass "rolled back to $_live" ||
            _warn "smoke-javaapi" "rollback to $_live failed"
    else
        _fail "kube-bluegreen cutover $_target failed"
        tail -10 /tmp/javaapi-cutover.log
    fi
fi

# ── 5: Baseline ──────────────────────────────────────────────────────
_section "Baseline orders.count()"
BASELINE=$(_psql -tAc "SELECT count(*) FROM shop.orders;" 2>/dev/null | tr -d '[:space:]')
if [[ -n "$BASELINE" && "$BASELINE" -gt 0 ]]; then
    _pass "orders table has $BASELINE rows (baseline)"
else
    _fail "orders table empty or unreachable (baseline=${BASELINE:-error})"
    exit 1
fi

# ── 6: Disaster ──────────────────────────────────────────────────────
# SAFETY: prove recovery is POSSIBLE before breaking anything. The recover step
# rolls back a ZFS dataset on this host, but the Postgres PV lives wherever its
# node put it -- and on a cluster whose nodes are VMs, that is inside a guest,
# where the host cannot snapshot it. Firing the disaster first and discovering
# this afterwards leaves the demo destroyed with no way back, which is a far
# worse outcome than a skipped test.
_section "Pre-flight: is recovery possible?"
_ds="${JAVAAPI_PVC_DATASET:-rpool/k8s/pvc-postgres-data}"
if ! zfs list "$_ds" >/dev/null 2>&1; then
    _warn "smoke-javaapi" "rollback dataset '$_ds' not present on this host — the Postgres PV is not host-local (node-local storage inside a VM does this). SKIPPING the destructive phase rather than breaking a demo that cannot be restored."
    if [[ "$KEEP_DEMO" != "1" ]]; then
        _section "Cleanup — destroy the demo"
        echo "y" | kube-demo javaapi_destroy >/tmp/javaapi-destroy.log 2>&1 &&
            _pass "demo destroyed" ||
            _warn "smoke-javaapi" "destroy returned non-zero"
    fi
    _summary
    exit 0
fi
_pass "rollback dataset $_ds present — recovery is possible"

_section "Trigger disaster: $DISASTER_MODE"
if ! kube-demo javaapi_disaster "$DISASTER_MODE" >/tmp/javaapi-disaster.log 2>&1; then
    _fail "disaster fired but kube-demo exited non-zero"
    tail -10 /tmp/javaapi-disaster.log
fi
_pass "disaster $DISASTER_MODE fired"
sleep 3

# ── 7: Confirm the break ─────────────────────────────────────────────
_section "Workload visibly broken"
if [[ "$DISASTER_MODE" == "app" ]]; then
    if curl -sf --max-time 5 "http://$VIP/api/orders" >/dev/null 2>&1; then
        _warn "smoke-javaapi" "/api/orders still 2xx after the table drop — caching?"
    else
        _pass "/api/orders no longer 2xx (as expected)"
    fi
fi

# ── 8+9: Recover, measure TTR ────────────────────────────────────────
_section "Recover via kube-demo javaapi_recover"
TTR_START=$(date +%s)
if kube-demo javaapi_recover >/tmp/javaapi-recover.log 2>&1; then
    TTR=$(($(date +%s) - TTR_START))
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

# ── 10: Verify data + service ────────────────────────────────────────
_section "Post-recover verification"
if curl -sf --retry 5 --retry-delay 2 --max-time 10 "http://$VIP/api/orders" >/dev/null 2>&1; then
    _pass "/api/orders 2xx after recover"
else
    _fail "/api/orders still broken after recover"
fi
POST=$(_psql -tAc "SELECT count(*) FROM shop.orders;" 2>/dev/null | tr -d '[:space:]')
test_eq "$POST" "$BASELINE" "orders.count() after recover ($POST) == baseline ($BASELINE)"

# ── 11: Cleanup ──────────────────────────────────────────────────────
if [[ "$KEEP_DEMO" != "1" ]]; then
    _section "Cleanup — destroy the demo"
    echo "y" | kube-demo javaapi_destroy >/tmp/javaapi-destroy.log 2>&1 &&
        _pass "demo destroyed" ||
        _warn "smoke-javaapi" "destroy returned non-zero — check /tmp/javaapi-destroy.log"
fi

_summary
