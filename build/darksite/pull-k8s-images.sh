#!/usr/bin/env bash
# =============================================================================
# pull-k8s-images.sh — bake every image the locked Kubernetes stack will run
# =============================================================================
#
# WHAT IT DOES, IN ORDER
#   1. Reads the image list out of k8s-stack.lock — the set that
#      resolve-k8s-stack.sh derived from the charts and kubeadm this build
#      actually resolved.
#   2. Pulls each one and saves it as a tarball under the darksite, which
#      kube-load-images imports into containerd on the target.
#   3. Counts what landed against what it was given, and FAILS if any image is
#      missing.
#
# WHY IT CHANGED (2026-09-20)
#   It used to read k8s-images.txt, a list maintained by hand, so the mirror
#   was rebuilt faithfully from stale tags on every build. It also logged
#   "WARNING: Failed to pull $img — will need internet on first kube-init" and
#   carried on: an ISO that believes it is air-gapped, is not, and says so only
#   in a build log nobody reads afterwards. Both are fixed here — the list is
#   derived, and a missing image is fatal.
#
# DIGESTS: Cilium's chart pins images as repo@sha256:..., which is a better
#   reference than a tag and survives a tag being moved. They are pulled and
#   saved the same way; only the tarball filename needs flattening.
#
# INPUT:  $1 output directory · K8S_LOCK for the lock file path
# EXIT:   0 every image in the lock is on disk · 1 one or more are missing ·
#         2 the lock is missing (nothing to do, and that is a build error)
# =============================================================================
set -Eeuo pipefail
trap 'echo "pull-k8s-images.sh: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="${K8S_LOCK:-${SCRIPT_DIR}/k8s-stack.lock}"
OUTPUT_DIR="${1:-/build/live-build/config/includes.chroot/root/darksite/k8s-images}"

log() { printf '[%s] [k8s-images] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

[[ -s "$LOCK" ]] || {
    log "ERROR: ${LOCK} is missing or empty — run resolve-k8s-stack.sh first"
    exit 2
}

mapfile -t IMAGES < <(sed -n 's/^IMAGE=//p' "$LOCK")
((${#IMAGES[@]})) || {
    log "ERROR: ${LOCK} lists no images"
    exit 2
}

mkdir -p "$OUTPUT_DIR"
log "Baking ${#IMAGES[@]} image(s) from $(basename "$LOCK") ($(sed -n 's/^K8S_VERSION=//p' "$LOCK"))"

_engine=""
for _e in podman docker; do
    command -v "$_e" >/dev/null 2>&1 && {
        _engine="$_e"
        break
    }
done
[[ -n "$_engine" ]] || {
    log "ERROR: neither podman nor docker is available"
    exit 1
}

_ok=0
_missing=()
for img in "${IMAGES[@]}"; do
    # A digest reference carries @ and : — flatten everything that is not safe
    # in a filename, and keep it deterministic so a re-run finds its cache.
    local_name="$(printf '%s' "$img" | tr '/:@' '___')"
    tarball="${OUTPUT_DIR}/${local_name}.tar"
    if [[ -s "$tarball" ]]; then
        log "CACHED: $img"
        _ok=$((_ok + 1))
        continue
    fi
    log "PULL: $img"
    if "$_engine" pull "$img" >/dev/null 2>&1 && "$_engine" save -o "$tarball" "$img" >/dev/null 2>&1; then
        log "SAVED: $(basename "$tarball") ($(du -h "$tarball" | cut -f1))"
        _ok=$((_ok + 1))
    else
        # Named, not swallowed: an image that did not land is an offline
        # install that silently needs the internet.
        log "FAILED: $img"
        _missing+=("$img")
        rm -f "$tarball"
    fi
done

# A count is not a result: compare what landed against what was asked for.
log "Done. ${_ok}/${#IMAGES[@]} image(s) in ${OUTPUT_DIR} ($(du -sh "$OUTPUT_DIR" 2>/dev/null | cut -f1))"
if ((${#_missing[@]})); then
    log "ERROR: ${#_missing[@]} image(s) did NOT bake — this ISO would need the internet to bring up a cluster:"
    printf '  %s\n' "${_missing[@]}" >&2
    exit 1
fi
