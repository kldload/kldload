#!/usr/bin/env bash
# pull-k8s-images.sh — pre-pull Kubernetes + Cilium container images for offline deployment
# Run during ISO build to bake images into the darksite
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_FILE="${SCRIPT_DIR}/k8s-images.txt"
OUTPUT_DIR="${1:-/build/live-build/config/includes.chroot/root/darksite/k8s-images}"

log() { printf '[%s] [k8s-images] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

if [[ ! -f "$IMAGES_FILE" ]]; then
  log "ERROR: $IMAGES_FILE not found"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Read image list
declare -a IMAGES=()
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line//[[:space:]]/}" ]] && continue
  IMAGES+=("$line")
done < "$IMAGES_FILE"

log "Pulling ${#IMAGES[@]} container images for offline K8s deployment..."

# Pull each image and save as a tarball
for img in "${IMAGES[@]}"; do
  local_name="$(echo "$img" | tr '/:' '_')"
  tarball="${OUTPUT_DIR}/${local_name}.tar"

  if [[ -f "$tarball" ]]; then
    log "CACHED: $img"
    continue
  fi

  log "PULL: $img"
  if podman pull "$img" 2>/dev/null || docker pull "$img" 2>/dev/null; then
    if command -v podman >/dev/null 2>&1; then
      podman save -o "$tarball" "$img" 2>/dev/null
    else
      docker save -o "$tarball" "$img" 2>/dev/null
    fi
    log "SAVED: $tarball ($(du -h "$tarball" | cut -f1))"
  else
    log "WARNING: Failed to pull $img — will need internet on first kube-init"
  fi
done

total_size="$(du -sh "$OUTPUT_DIR" 2>/dev/null | cut -f1)"
log "Done. ${#IMAGES[@]} images saved to $OUTPUT_DIR ($total_size)"
