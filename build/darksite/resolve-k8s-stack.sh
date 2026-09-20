#!/usr/bin/env bash
# =============================================================================
# resolve-k8s-stack.sh — decide, fresh, what Kubernetes stack this build carries
# =============================================================================
#
# WHAT IT DOES, IN ORDER
#   1. Asks each Helm repo for its newest chart version (cilium, tetragon,
#      metallb, argo-cd, zfs-localpv).
#   2. Asks dl.k8s.io for the newest stable Kubernetes release.
#   3. DERIVES the container images from those answers rather than from a list
#      somebody maintains by hand: `kubeadm config images list` for the control
#      plane, `helm template` for every chart.
#   4. Writes one lock file naming every chart version, every image and every
#      CLI version this build will carry.
#
# WHY IT EXISTS
#   The darksite rebuilt itself on every build and re-downloaded the SAME
#   frozen tags every time — Cilium 1.16.5 when 1.20.2 was current, a
#   hand-typed list of 29 images, and three different pinned helm versions in
#   one repository. Fresh transfer, stale content, and it looked current from
#   the outside right up until somebody checked (2026-09-20).
#
#   Pinning was not laziness: charts and images MUST agree, and resolving
#   "newest" independently in two places is how you get a 1.20 chart pulling
#   against a 1.16 image cache, which the build once did. The answer is to
#   resolve ONCE and lock, which is this file — and which is what the project's
#   own rule has always said: derive versions, lock the resolved set, and make
#   an unresolvable stack fatal.
#
# WHY FRESH IS SAFE HERE
#   kldload rolls back at every layer that matters: boot environments for the
#   host, `klab deploy blue|green` for the fleet, kube-bluegreen for workloads.
#   A stack that resolves badly is a promote away from undone, so the risk that
#   justified freezing is already handled somewhere better.
#
# OUTPUT: build/darksite/k8s-stack.lock — sourceable shell, and the record the
#         ISO carries so a node can say exactly what it was built from.
# EXIT:   0 resolved and locked · 1 something would not resolve (FATAL: a stack
#         that cannot be resolved must never be silently replaced by an old one)
# =============================================================================
set -Eeuo pipefail
trap 'echo "resolve-k8s-stack.sh: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="${LOCK:-${SCRIPT_DIR}/k8s-stack.lock}"
# The work directory must be EXECUTABLE: this script downloads kubeadm and runs
# it to derive the control-plane images. On onyx /tmp is a ZFS dataset mounted
# noexec, so `mktemp -d` gives a directory where the binary cannot run — and
# the first version of this script hid that behind 2>/dev/null and reported
# "0 images" (2026-09-20, the same noexec trap already recorded for PATH shims).
WORK=""
for _cand in "${TMPDIR:-}" /var/tmp /tmp; do
    [[ -n "$_cand" && -d "$_cand" ]] || continue
    _try="$(mktemp -d -p "$_cand" 2>/dev/null)" || continue
    printf '#!/bin/sh\nexit 0\n' >"$_try/.exectest"
    chmod +x "$_try/.exectest"
    if "$_try/.exectest" 2>/dev/null; then
        rm -f "$_try/.exectest"
        WORK="$_try"
        break
    fi
    rm -rf "$_try"
done
[[ -n "$WORK" ]] || {
    echo "resolve-k8s-stack.sh: no writable+executable temp directory (tried TMPDIR, /var/tmp, /tmp)" >&2
    exit 1
}
trap 'rm -rf "$WORK"' EXIT

case "${1:-}" in
-h | --help | help)
    sed -n '2,${/^#/!q; s/^# \{0,1\}//; p}' "$0"
    exit 0
    ;;
esac

say() { echo "[resolve] $*" >&2; }
die() {
    echo "[resolve] FATAL: $*" >&2
    exit 1
}

command -v helm >/dev/null || die "helm is required to resolve chart versions"
command -v curl >/dev/null || die "curl is required"

export HELM_CACHE_HOME="$WORK/cache" HELM_CONFIG_HOME="$WORK/config" HELM_DATA_HOME="$WORK/data"

# ── The stack, declared once ────────────────────────────────────────────────
# repo-name|repo-url|chart. NO versions: that is the entire point of this file.
# Adding a component to the offline stack means adding one line here, and the
# images follow automatically.
CHARTS=(
    "cilium|https://helm.cilium.io/|cilium"
    "cilium|https://helm.cilium.io/|tetragon"
    "metallb|https://metallb.github.io/metallb|metallb"
    "argo|https://argoproj.github.io/argo-helm|argo-cd"
    "openebs-zfslocalpv|https://openebs.github.io/zfs-localpv|zfs-localpv"
)

say "adding helm repos"
declare -A _added=()
for _entry in "${CHARTS[@]}"; do
    IFS='|' read -r _rname _rurl _cname <<<"$_entry"
    [[ -n "${_added[$_rname]:-}" ]] && continue
    helm repo add "$_rname" "$_rurl" >/dev/null 2>&1 || die "helm repo add ${_rname} (${_rurl}) failed"
    _added[$_rname]=1
done
helm repo update >/dev/null 2>&1 || die "helm repo update failed"

# ── Kubernetes ──────────────────────────────────────────────────────────────
# stable.txt is upstream's own answer to "what is current", and it is the same
# source kubeadm's documentation points at.
K8S_VERSION="$(curl -fsSL --max-time 30 https://dl.k8s.io/release/stable.txt 2>/dev/null || true)"
[[ "$K8S_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not resolve the current Kubernetes release (got '${K8S_VERSION}')"
say "kubernetes ${K8S_VERSION}"

# The control-plane image set is kubeadm's to decide, not ours to guess: etcd,
# coredns and pause carry versions that do not track the Kubernetes version.
# Asking the matching kubeadm binary is the only answer that cannot drift.
_arch="$(uname -m)"
case "$_arch" in
x86_64) _arch=amd64 ;;
aarch64) _arch=arm64 ;;
esac
say "fetching kubeadm ${K8S_VERSION} to derive the control-plane images"
curl -fsSL --max-time 120 -o "$WORK/kubeadm" \
    "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${_arch}/kubeadm" ||
    die "could not download kubeadm ${K8S_VERSION}"
chmod +x "$WORK/kubeadm"
# stderr is KEPT: when this returned nothing the reason was a noexec mount, and
# discarding it turned a one-line diagnosis into an afternoon.
_kubeadm_err="$WORK/kubeadm.err"
mapfile -t _k8s_images < <("$WORK/kubeadm" config images list --kubernetes-version "$K8S_VERSION" 2>"$_kubeadm_err" || true)
((${#_k8s_images[@]} >= 5)) ||
    die "kubeadm listed ${#_k8s_images[@]} images (expected >=5). kubeadm said: $(head -2 "$_kubeadm_err" 2>/dev/null | tr '\n' ' ')"

# ── Charts, and the images they actually reference ──────────────────────────
declare -a _chart_lines=() _all_images=()
_all_images+=("${_k8s_images[@]}")

for _entry in "${CHARTS[@]}"; do
    IFS='|' read -r _rname _rurl _cname <<<"$_entry"
    _ver="$(helm search repo "${_rname}/${_cname}" --versions -o json 2>/dev/null |
        python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
print(d[0]["version"] if d else "")' 2>/dev/null || true)"
    [[ -n "$_ver" ]] || die "could not resolve a version for ${_rname}/${_cname}"
    say "${_cname} ${_ver}"
    _chart_lines+=("${_rname}|${_rurl}|${_cname}|${_ver}")

    # helm template names every image the chart will run. Rendering with
    # default values can miss images behind feature flags, so the flags this
    # build actually enables are passed where they matter.
    _extra=()
    [[ "$_cname" == cilium ]] && _extra=(--set hubble.relay.enabled=true --set hubble.ui.enabled=true --set gatewayAPI.enabled=true)
    mapfile -t _imgs < <(helm template "$_cname" "${_rname}/${_cname}" --version "$_ver" "${_extra[@]}" 2>/dev/null |
        grep -oE '^[[:space:]]*image:[[:space:]]*"?[^"[:space:]]+' |
        sed -E 's/^[[:space:]]*image:[[:space:]]*"?//' | sort -u || true)
    ((${#_imgs[@]})) || die "helm template ${_cname} ${_ver} produced no images — the chart or its values changed shape"
    _all_images+=("${_imgs[@]}")
done

# ── CLI tooling, resolved the same way ──────────────────────────────────────
_gh_latest() { # _gh_latest <owner/repo> — newest tag, or empty
    curl -fsSL --max-time 20 "https://api.github.com/repos/${1}/releases/latest" 2>/dev/null |
        grep -oE '"tag_name": *"[^"]+"' | head -1 | cut -d'"' -f4 || true
}
HELM_CLI_VERSION="$(_gh_latest helm/helm)"
CILIUM_CLI_VERSION="$(_gh_latest cilium/cilium-cli)"
HUBBLE_CLI_VERSION="$(_gh_latest cilium/hubble)"
K9S_VERSION="$(_gh_latest derailed/k9s)"
for _v in HELM_CLI_VERSION CILIUM_CLI_VERSION HUBBLE_CLI_VERSION K9S_VERSION; do
    [[ -n "${!_v}" ]] || die "could not resolve ${_v} from GitHub"
done

# ── Write the lock ──────────────────────────────────────────────────────────
mapfile -t _uniq_images < <(printf '%s\n' "${_all_images[@]}" | grep -v '^$' | sort -u)
{
    echo "# k8s-stack.lock — GENERATED by build/darksite/resolve-k8s-stack.sh"
    echo "# Resolved $(date -Is) on $(hostname)."
    echo "#"
    echo "# Do not hand-edit: this is the record of what one build resolved, and"
    echo "# the chart staging, the image mirror and the installers all read it."
    echo "# To move the stack, re-run the resolver."
    echo
    echo "K8S_VERSION=${K8S_VERSION}"
    echo "HELM_CLI_VERSION=${HELM_CLI_VERSION}"
    echo "CILIUM_CLI_VERSION=${CILIUM_CLI_VERSION}"
    echo "HUBBLE_CLI_VERSION=${HUBBLE_CLI_VERSION}"
    echo "K9S_VERSION=${K9S_VERSION}"
    echo
    echo "# repo|url|chart|version"
    printf 'CHART=%s\n' "${_chart_lines[@]}"
    echo
    echo "# Every image the above will run, derived — never typed."
    printf 'IMAGE=%s\n' "${_uniq_images[@]}"
} >"${LOCK}.new"

mv -f "${LOCK}.new" "$LOCK"
say "locked ${#_chart_lines[@]} chart(s), ${#_uniq_images[@]} image(s) -> ${LOCK}"
