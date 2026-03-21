#!/usr/bin/env bash
set -euo pipefail

# kldload darksite builder — downloads RPMs for offline install, creates local DNF repo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_SETS_DIR="${SCRIPT_DIR}/config/package-sets"
ARCH="${ARCH:-x86_64}"
RELEASE="${RELEASE:-9}"
DARKSITE_ROOT="${DARKSITE_ROOT:-/build/live-build/config/includes.chroot/root/darksite}"
REPO_DIR="${DARKSITE_ROOT}/rpm"

log() { printf '[%s] [darksite] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

mkdir -p "${REPO_DIR}"

# Add ZFS on Linux repo
if [[ ! -f /etc/yum.repos.d/zfs.repo ]]; then
    log "Adding ZFS on Linux repo..."
    dnf install -y "https://zfsonlinux.org/epel/zfs-release-2-3.el${RELEASE}.noarch.rpm" 2>/dev/null || \
    dnf install -y "https://zfsonlinux.org/epel/zfs-release-2-2.el${RELEASE}.noarch.rpm" 2>/dev/null || \
        log "WARNING: could not add ZFS repo — ZFS packages may be missing"
fi

# Read package sets
declare -a PACKAGES=()
read_package_set() {
    local file="${PKG_SETS_DIR}/${1}.txt"
    [[ -f "$file" ]] || { log "Package set not found (skipping): $file"; return 0; }
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        PACKAGES+=("$line")
    done < "$file"
    log "Loaded package set: $1 ($(wc -l < "$file") entries)"
}

read_package_set "target-base"
read_package_set "target-server"
read_package_set "target-desktop"

# Deduplicate
declare -A _seen=()
declare -a PKGS_FINAL=()
for p in "${PACKAGES[@]}"; do
    [[ -z "${_seen[$p]:-}" ]] || continue
    _seen["$p"]=1
    PKGS_FINAL+=("$p")
done

log "Total unique packages: ${#PKGS_FINAL[@]}"
log "Downloading RPMs to ${REPO_DIR}..."

dnf download --resolve --alldeps --destdir "${REPO_DIR}" \
    --releasever "${RELEASE}" --arch "${ARCH},noarch" \
    --skip-broken \
    "${PKGS_FINAL[@]}" 2>&1 | tail -10 || log "WARNING: some packages could not be downloaded"

log "Creating repo metadata..."
createrepo_c "${REPO_DIR}"

log "Darksite repo ready: ${REPO_DIR}"
log "RPM count: $(find "${REPO_DIR}" -name '*.rpm' | wc -l)"
