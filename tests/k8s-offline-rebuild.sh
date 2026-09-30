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
# -o wide: the wg-k8s check below reads each node's INTERNAL-IP ($6), which the
# default output does not print (review 2026-09-28: without it every cluster
# edition failed "no node addresses"). VERSION stays column 5 either way.
_nodes="$(timeout 60 kubectl get nodes -o wide --no-headers 2>/dev/null || true)"
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
# A bootstrap that FAILED never reaches the step that joins the host to the
# cluster mesh, so wg-k8s down is its consequence, not a second fault.
# deb-4-k8s (build 155, 2026-09-28) reported one failed bootstrap as five
# failures this way. What must hold either way is below: the machines that
# are not cluster nodes keep their wg-mgmt membership. Exit 3 is a cluster
# that came UP with problems; it has joined the host, so it is judged.
if ((_brc == 0 || _brc == 3)); then
    for _if in wg-mgmt wg-k8s; do
        if ip link show "$_if" up >/dev/null 2>&1; then
            _pass "${_if} is up"
        else
            _fail "${_if}" "down or missing after the re-bootstrap"
        fi
    done
    # Judged on the CLUSTER'S peers only: wg-k8s also carries every enrolled
    # machine, and powered-off klab clones are on it by design -- 6-full
    # (build 155) failed "4 of 10 peers silent" on klab-blue-* that quiesce
    # had shut down. A node's peer is the one whose endpoint is its
    # INTERNAL-IP; every node must have one that handshook in the last three
    # minutes (keepalives drive it, so a fresh cluster gets that long).
    _node_ips="$(printf '%s\n' "$_nodes" | awk 'NF {print $6}' | sort -u)"
    _live=0 _dead=""
    for _w in $(seq 1 18); do
        _live=0 _dead=""
        for _ip in $_node_ips; do
            # dump: pubkey psk endpoint allowed-ips latest-handshake rx tx keepalive
            # swallow: no wg-k8s is an empty dump, reported as a dead node below
            # the node's address can be its endpoint (Fedora: kubelet reports
            # the libvirt address) OR its mesh address in allowed-ips (Debian:
            # kubelet reports 10.251.0.x) -- matching the endpoint alone called
            # a healthy Debian mesh "6 of 6 silent" (deb-4-k8s, build 159)
            _hs="$(wg show wg-k8s dump 2>/dev/null | awk -v ip="$_ip" 'NR > 1 {split($3, e, ":"); if (e[1] == ip || index("," $4 ",", "," ip "/32,")) print $5}' | sort -n | tail -n 1 || true)"
            if [[ -n "$_hs" ]] && ((_hs > 0 && $(date +%s) - _hs <= 180)); then
                _live=$((_live + 1))
            else
                _dead+=" ${_ip}"
            fi
        done
        [[ -z "$_dead" ]] && break
        sleep 10
    done
    if [[ -z "$_node_ips" ]]; then
        _fail "wg-k8s peers" "no node addresses to judge (kubectl listed no nodes)"
    elif [[ -z "$_dead" ]]; then
        _pass "wg-k8s: all ${_live} cluster nodes handshaking"
    else
        _fail "wg-k8s handshakes" "$(wc -w <<<"$_dead") of $(wc -w <<<"$_node_ips") nodes silent:${_dead}"
    fi
else
    _warn "cluster mesh (wg-k8s)" "not judged: the bootstrap failed before the host joins it"
    if ((${#KEEP_KEYS[@]} > 0)); then
        ip link show wg-mgmt up >/dev/null 2>&1 && _pass "wg-mgmt is up (non-cluster machines are on it)" ||
            _fail "wg-mgmt" "down after a failed bootstrap, with ${#KEEP_KEYS[@]} non-cluster machine(s) on it"
    fi
fi
_lost=""
for _n in "${!KEEP_KEYS[@]}"; do
    wg show wg-mgmt peers 2>/dev/null | grep -qxF "${KEEP_KEYS[$_n]}" || _lost+=" ${_n}"
done
[[ -z "$_lost" ]] && _pass "all ${#KEEP_KEYS[@]} non-cluster machines still on wg-mgmt" ||
    _fail "estate mesh" "dropped from wg-mgmt by the rebuild:${_lost}"

# in_cidr <ipv4> <a.b.c.d/n> — 0 when the address is inside the range.
in_cidr() {
    local ip="$1" net="${2%/*}" bits="${2#*/}" a b c d x y
    IFS=. read -r a b c d <<<"$ip" || return 1
    x=$(((a << 24) | (b << 16) | (c << 8) | d))
    IFS=. read -r a b c d <<<"$net" || return 1
    y=$(((a << 24) | (b << 16) | (c << 8) | d))
    ((bits == 0)) && return 0
    (((x >> (32 - bits)) == (y >> (32 - bits))))
}

# ─── What tried to leave ────────────────────────────────────────────────────
_section "Traffic that tried to leave the host"
_drops="$("$OFFLINE" drops 2>&1)" && _drc=0 || _drc=$?
if ((_drc == 0)); then
    _pass "offline: 0 packets from the VMs tried to leave the host"
else
    printf '%s\n' "$_drops" | sed -n '/── by destination ──/,$p' | sed 's/^/    /'
    # Which drops were the internet, and which were cluster traffic sent out
    # the default route? build 162 had 316, every one TCP 443 to a ClusterIP
    # (the aggregator dialling metrics-server) and not one outside address;
    # "reached for the internet" said otherwise (2026-09-29).
    _cfg="$(kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null || true)" # absent: the defaults below
    _svc="$(sed -n 's/^ *serviceSubnet: *//p' <<<"$_cfg" | head -n 1)"
    _pod="$(sed -n 's/^ *podSubnet: *//p' <<<"$_cfg" | head -n 1)"
    _svc="${_svc:-10.96.0.0/16}" _pod="${_pod:-10.244.0.0/16}"
    _n_svc=0 _n_pod=0 _n_net=0 _net_dst=""
    while read -r _cnt _src _arrow _dst _rest; do
        [[ "$_arrow" == "->" && "$_cnt" =~ ^[0-9]+$ ]] || continue
        if in_cidr "$_dst" "$_svc"; then
            _n_svc=$((_n_svc + _cnt))
        elif in_cidr "$_dst" "$_pod"; then
            _n_pod=$((_n_pod + _cnt))
        else
            _n_net=$((_n_net + _cnt))
            [[ " ${_net_dst} " == *" ${_dst} "* ]] || _net_dst+=" ${_dst}"
        fi
    done < <(printf '%s\n' "$_drops" | sed -n '/── by destination ──/,$p')
    _what="$(printf '%s\n' "$_drops" | tail -n 1 | sed 's/^ *//'): ${_n_net} to the internet${_net_dst:+ (${_net_dst# })}, ${_n_svc} to the service range ${_svc}, ${_n_pod} to the pod range ${_pod}"
    if ((_n_net > 0)); then
        _fail "offline" "${_what} — the cluster reached for the internet"
    else
        _fail "offline" "${_what} — cluster traffic left by the default route (no internet destination)"
    fi
fi

printf '\n  k8s offline rebuild: %d passed, %d failed, %d warned\n' "$PASS" "$FAIL" "$WARN"
((FAIL == 0)) && exit 0
exit 1
