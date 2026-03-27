#!/usr/bin/env bash
set -euo pipefail

# kldload Fedora darksite builder — downloads RPMs for offline install, creates local DNF repo
# Runs INSIDE a fedora:41 container via deploy.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_SETS_DIR="${PKG_SETS_DIR:-${SCRIPT_DIR}/config/package-sets}"
ARCH="${ARCH:-x86_64}"
FEDORA_RELEASE="${FEDORA_RELEASE:-41}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"

log() { printf '[%s] [darksite-fedora] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

REPO_DIR="${OUTPUT_DIR}/rpm"
mkdir -p "${REPO_DIR}"

# Install createrepo_c (needed to build repo metadata)
log "Installing createrepo_c..."
dnf install -y createrepo_c >/dev/null 2>&1

# Add ZFS on Linux repo for Fedora
log "Adding ZFS on Linux repo for Fedora ${FEDORA_RELEASE}..."
dnf install -y "https://zfsonlinux.org/fedora/zfs-release-2-5$(rpm --eval "%{dist}").noarch.rpm" 2>/dev/null || \
dnf install -y "https://zfsonlinux.org/fedora/zfs-release-2-4$(rpm --eval "%{dist}").noarch.rpm" 2>/dev/null || \
dnf install -y "https://zfsonlinux.org/fedora/zfs-release-2-3$(rpm --eval "%{dist}").noarch.rpm" 2>/dev/null || \
    log "WARNING: could not add ZFS repo — ZFS packages may be missing"

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
read_package_set "target-zfs"

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
    --releasever "${FEDORA_RELEASE}" --arch "${ARCH},noarch" \
    --skip-broken \
    "${PKGS_FINAL[@]}" 2>&1 | tail -10 || log "WARNING: some packages could not be downloaded"

log "Creating repo metadata..."
createrepo_c "${REPO_DIR}"

log "Fedora darksite repo ready: ${REPO_DIR}"
log "RPM count: $(find "${REPO_DIR}" -name '*.rpm' | wc -l)"
