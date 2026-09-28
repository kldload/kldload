#!/usr/bin/env bash
# =============================================================================
# k8s-offline-rebuild.sh — tear the cluster down and build it again with every
# VM cut off from the internet, and prove the rest of the estate survived it
# =============================================================================
#
# WHAT IT DOES, IN ORDER
#   1. Reads the shape of the cluster that exists (control planes, workers)
#      and the WireGuard keys of every enrolled machine that is NOT a cluster
#      node, so it can tell afterwards whether they were left alone.
#   2. offline-proof.sh start: VMs behind virbr* can no longer leave the host,
#      and every attempt is logged.
#   3. kube-cluster destroy --all --yes, then checks the golden and the nodes
#      are really gone.
#   4. kube-cluster bootstrap with the same shape. That rebuilds the golden
#      from the host's darksite over the ssh -R tunnel, clones the nodes,
#      joins them and runs kube-smoke-test. Exit 0 is required; 3 means it
#      came up with problems and said so.
#   5. Every node Ready, the count equal to the shape asked for, and every
#      kubelet at the K8S_VERSION the image's k8s-stack.lock pins.
#   6. The host mesh: wg-mgmt and wg-k8s up, every wg-k8s peer handshaking,
#      and every non-cluster machine's key still a wg-mgmt peer.
#   7. offline-proof.sh drops: every packet a VM tried to send off the host.
#      Any drop is a FAIL, listed by destination.
#
# WHY: 1.5.0 fetched containerd, kubeadm, helm and every image for the cluster
# from the internet while it was described as offline (fiend, 2026-09-27). The
# fix moved all of it onto the host's darksite; this is the proof, run on
# every install that has a cluster instead of once by hand. It also runs the
# destroy/re-bootstrap path, which wiped the host's wg-mgmt shared with every
# enrolled VM on build 152 and left wg-k8s down on build 153 while logging
# "joined".
#
# SAFETY: it destroys and rebuilds the kldload cluster -- the one kube-cluster
# owns, and nothing else. Run it on a test bench, never on a machine whose
# cluster holds work. The nft table is removed on every exit path.
#
# USAGE: k8s-offline-rebuild.sh [--timeout <seconds>]   (runs as root)
# EXIT:  0 all proved · 1 a check failed · 2 could not run (no cluster here)
# =============================================================================
set -Eeuo pipefail
trap 'echo "k8s-offline-rebuild.sh: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_MAX=5400 # 90 min: a golden build plus six clones and a join, measured ~40 on fiend

case "${1:-}" in
-h | --help)
    sed -n '2,${/^#/!q; s/^# \{0,1\}//; p}' "$0"
    exit 0
    ;;
--timeout)
    BOOT_MAX="${2:?--timeout needs seconds}"
    ;;
"") ;;
*)
    echo "k8s-offline-rebuild.sh: unknown argument: $1" >&2
    exit 2
    ;;
esac
((EUID == 0)) || exec sudo -n -- "$0" "$@"

# shellcheck source=lib-test.sh
source "${SCRIPT_DIR}/lib-test.sh"
OFFLINE="${SCRIPT_DIR}/offline-proof.sh"
LOCK=/root/darksite/k8s-stack.lock
BOOTLOG=/var/log/kldload/k8s-offline-rebuild.log
export KUBECONFIG=/root/.kube/config

have() { command -v "$1" >/dev/null 2>&1; }
didnotrun() {
    _warn "k8s offline rebuild" "DID NOT RUN — $1"
    printf '\n  k8s offline rebuild: %d passed, %d failed, %d warned (DID NOT RUN)\n' "$PASS" "$FAIL" "$WARN"
    exit 2
}
cleanup() {
    [[ "${BASHPID}" == "$$" ]] || return 0
    "$OFFLINE" stop >/dev/null 2>&1 || echo "  cleanup: offline-proof stop failed — run: nft delete table inet kldoffline" >&2
}

# ─── Preconditions ──────────────────────────────────────────────────────────
_section "k8s offline rebuild — preconditions"
for _t in kube-cluster virsh kubectl nft wg; do
    have "$_t" || didnotrun "${_t} is not installed"
done
[[ -x "$OFFLINE" ]] || didnotrun "${OFFLINE} is missing"
[[ -r "$LOCK" ]] || didnotrun "${LOCK} is missing — the host has no darksite to build from"

# The shape is what EXISTS, not what the answers file asked: the RAM preflight
# may have clamped it, and the report already judges that against the answers.
# swallow: grep -c exits 1 at zero, which is the "no cluster" case named next
want_cp="$(virsh list --all --name | grep -cE '^kldload-cp(-[0-9]+)?$' || true)"
want_w="$(virsh list --all --name | grep -cE '^kldload-w-[0-9]+$' || true)"
((want_cp > 0)) || didnotrun "no kldload-cp domain — this machine has no cluster to rebuild"
want_ver="$(sed -n 's/^K8S_VERSION=//p' "$LOCK" | head -n 1)"
_pass "cluster shape to rebuild: ${want_cp} control plane(s), ${want_w} worker(s); lock pins ${want_ver:-?}"

# Non-cluster members, by key: kvm-delete and kldload-enroll both key on
# /var/lib/kldload/mesh/enrolled/<vm>. A cluster node's record may go with it.
declare -A KEEP_KEYS=()
for _rec in /var/lib/kldload/mesh/enrolled/*; do
    [[ -f "$_rec" ]] || continue
    _n="$(basename "$_rec")"
    [[ "$_n" =~ ^(kldload-cp|kldload-w-|k8s-golden) ]] && continue
    _k="$(sed -n 's/^guest_pub=//p' "$_rec")"
    [[ -n "$_k" ]] && wg show wg-mgmt peers 2>/dev/null | grep -qxF "$_k" && KEEP_KEYS["$_n"]="$_k"
done
_pass "non-cluster machines on wg-mgmt before: ${#KEEP_KEYS[@]}"

# ─── Block, destroy, rebuild ────────────────────────────────────────────────
_section "Destroy and rebuild with the VMs offline"
trap cleanup EXIT
"$OFFLINE" start || didnotrun "offline-proof start failed"
_pass "offline-proof: VMs behind virbr* cannot leave this host"

: >"$BOOTLOG"
if timeout 1800 kube-cluster destroy --all --yes </dev/null >>"$BOOTLOG" 2>&1; then
    _pass "kube-cluster destroy --all"
else
    _fail "kube-cluster destroy" "exit non-zero — tail ${BOOTLOG}"
fi
# swallow: grep -c exits 1 at zero, which is the passing case
_left="$(virsh list --all --name | grep -cE '^(kldload-cp|kldload-w-|k8s-golden)' || true)"
((_left == 0)) && _pass "no cluster or golden domain left" || _fail "destroy" "${_left} cluster domain(s) survived"

_t0=$SECONDS
_brc=0
timeout "$BOOT_MAX" kube-cluster bootstrap --control-planes "$want_cp" --workers "$want_w" \
    </dev/null >>"$BOOTLOG" 2>&1 || _brc=$?
_secs=$((SECONDS - _t0))
case "$_brc" in
0) _pass "kube-cluster bootstrap exit 0 in ${_secs}s (golden rebuilt from the darksite, smoke run)" ;;
3)
    # swallow: grep exits 1 when the log names no problem; the tail is then the evidence
    _why="$({ grep -iE 'problem|fail' "$BOOTLOG" || tail -n 3 "$BOOTLOG"; } | tail -n 3 | tr '\n' ' ' | cut -c1-240)"
    _fail "kube-cluster bootstrap" "exit 3 after ${_secs}s: up with problems — ${_why}"
    ;;
124) _fail "kube-cluster bootstrap" "did not finish in ${BOOT_MAX}s" ;;
*) _fail "kube-cluster bootstrap" "exit ${_brc} after ${_secs}s — tail ${BOOTLOG}" ;;
esac
# The golden's own count of images it loaded from the darksite, as it logged it.
_img="$(grep -oiE '[0-9]+/[0-9]+ images?[^.]*' "$BOOTLOG" | tail -n 1 || true)"
[[ -n "$_img" ]] && _pass "golden images: ${_img}" || _warn "golden images" "no image count in ${BOOTLOG}"

# ─── The cluster that came back ─────────────────────────────────────────────
_section "Cluster"
_nodes="$(timeout 60 kubectl get nodes --no-headers 2>/dev/null || true)"
_n_all="$(printf '%s\n' "$_nodes" | grep -c . || true)"
_n_ready="$(printf '%s\n' "$_nodes" | awk '$2 == "Ready"' | grep -c . || true)"
if ((_n_ready == want_cp + want_w && _n_all == _n_ready)); then
    _pass "nodes Ready: ${_n_ready} of $((want_cp + want_w))"
else
    _fail "nodes Ready" "${_n_ready} Ready of ${_n_all} listed, $((want_cp + want_w)) asked"
fi
if [[ -n "$want_ver" ]]; then
    _bad="$(printf '%s\n' "$_nodes" | awk -v v="$want_ver" 'NF && $5 != v {print $1 "=" $5}' | tr '\n' ' ')"
    [[ -z "$_bad" ]] && _pass "every kubelet at ${want_ver} (the lock)" || _fail "kubelet version" "not ${want_ver}: ${_bad}"
fi

# ─── The host's mesh ────────────────────────────────────────────────────────
_section "Mesh after the rebuild"
for _if in wg-mgmt wg-k8s; do
    if ip link show "$_if" up >/dev/null 2>&1; then
        _pass "${_if} is up"
    else
        _fail "${_if}" "down or missing after the re-bootstrap"
    fi
done
# Handshakes are driven by keepalives; give a fresh cluster three minutes.
_stale=""
for _w in $(seq 1 18); do
    # swallow: wg exits 1 when wg-k8s does not exist; the peer count below FAILs that
    _stale="$(wg show wg-k8s latest-handshakes 2>/dev/null | awk -v now="$(date +%s)" '$2 == 0 || now - $2 > 180 {print $1}' | tr '\n' ' ' || true)"
    [[ -z "${_stale// /}" ]] && break
    sleep 10
done
_peers="$(wg show wg-k8s peers 2>/dev/null | grep -c . || true)"
if ((_peers == 0)); then
    _fail "wg-k8s peers" "none"
elif [[ -z "${_stale// /}" ]]; then
    _pass "wg-k8s: all ${_peers} peers handshaking"
else
    _fail "wg-k8s handshakes" "$(wc -w <<<"$_stale") of ${_peers} peers silent"
fi
_lost=""
for _n in "${!KEEP_KEYS[@]}"; do
    wg show wg-mgmt peers 2>/dev/null | grep -qxF "${KEEP_KEYS[$_n]}" || _lost+=" ${_n}"
done
[[ -z "$_lost" ]] && _pass "all ${#KEEP_KEYS[@]} non-cluster machines still on wg-mgmt" ||
    _fail "estate mesh" "dropped from wg-mgmt by the rebuild:${_lost}"

# ─── What tried to leave ────────────────────────────────────────────────────
_section "Traffic that tried to leave the host"
_drops="$("$OFFLINE" drops 2>&1)" && _drc=0 || _drc=$?
if ((_drc == 0)); then
    _pass "offline: 0 packets from the VMs tried to leave the host"
else
    printf '%s\n' "$_drops" | sed -n '/── by destination ──/,$p' | sed 's/^/    /'
    _fail "offline" "$(printf '%s\n' "$_drops" | tail -n 1) — the cluster reached for the internet"
fi

printf '\n  k8s offline rebuild: %d passed, %d failed, %d warned\n' "$PASS" "$FAIL" "$WARN"
((FAIL == 0)) && exit 0
exit 1
