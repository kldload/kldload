#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# build-darksite-arch.sh — runs inside an archlinux:latest container.
# Downloads all required Arch Linux packages and builds a local pacman cache
# that is baked into the kldload CentOS live ISO at /root/darksite/arch/.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_SETS_DIR="${PKG_SETS_DIR:-${SCRIPT_DIR}/config/package-sets}"

PROFILE="${PROFILE:-desktop}"
ARCH="${ARCH:-x86_64}"

# Output: mounted from host into this container
DARKSITE_OUT="${DARKSITE_OUT:-/output}"
PKG_CACHE="${DARKSITE_OUT}/pkg"
DB_DIR="${DARKSITE_OUT}/db"

log() { printf '[%s] [darksite-arch] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Read package sets
# ---------------------------------------------------------------------------

declare -a PACKAGES=()

read_package_set() {
    local name="$1"
    local file="${PKG_SETS_DIR}/${name}.txt"
    if [[ ! -f "$file" ]]; then
        log "Package set not found (skipping): $file"
        return 0
    fi
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        PACKAGES+=("$line")
    done < "$file"
    log "Loaded package set: $name ($(wc -l < "$file") entries)"
}

read_package_set "target-base"
read_package_set "target-zfs"
read_package_set "target-desktop"
read_package_set "target-server"

# Deduplicate
declare -A _seen=()
declare -a PKGS_FINAL=()
for p in "${PACKAGES[@]}"; do
    [[ -z "${_seen[$p]:-}" ]] || continue
    _seen["$p"]=1
    PKGS_FINAL+=("$p")
done

log "Packages to download: ${#PKGS_FINAL[@]}"

mkdir -p "$PKG_CACHE" "$DB_DIR"

# ---------------------------------------------------------------------------
# Initialize pacman and add archzfs repo for ZFS packages
# ---------------------------------------------------------------------------
log "Initializing pacman keyring..."
pacman-key --init
pacman-key --populate archlinux

# Add archzfs repo
log "Adding archzfs repository..."
cat >> /etc/pacman.conf <<'ARCHZFS'

[archzfs]
Server = https://archzfs.com/$repo/$arch
SigLevel = Optional TrustAll
ARCHZFS

# Update package databases
log "Syncing package databases..."
pacman -Sy --noconfirm

# ---------------------------------------------------------------------------
# Download packages with dependencies
# ---------------------------------------------------------------------------
log "Downloading ${#PKGS_FINAL[@]} packages with dependencies..."

_dl_ok=0 _dl_fail=0

# Download packages to cache — use pacman's own dependency resolution
# --cachedir points to our output directory so packages are saved there
# --noconfirm + --downloadonly = resolve deps and download without installing
pacman -Sw --noconfirm --cachedir "$PKG_CACHE" "${PKGS_FINAL[@]}" 2>&1 || {
    log "WARNING: Some packages failed to download — trying individually..."
    for _pkg in "${PKGS_FINAL[@]}"; do
        if pacman -Sw --noconfirm --cachedir "$PKG_CACHE" "$_pkg" 2>/dev/null; then
            (( _dl_ok++ )) || true
        else
            log "  SKIP: $_pkg (not found)"
            (( _dl_fail++ )) || true
        fi
    done
    log "Individual download: ${_dl_ok} ok, ${_dl_fail} failed"
}

# Copy sync databases so pacstrap can use them offline
log "Copying package databases..."
cp -r /var/lib/pacman/sync/*.db "$DB_DIR/" 2>/dev/null || true

# Count downloaded packages
PKG_COUNT=$(find "$PKG_CACHE" -name '*.pkg.tar.*' | wc -l)
log "Darksite cache: ${PKG_COUNT} packages"

TOTAL_SIZE=$(du -sh "$PKG_CACHE" 2>/dev/null | cut -f1)

log "====================================================="
log "Arch darksite build complete"
log "  Packages:  ${PKG_COUNT}"
log "  Size:      ${TOTAL_SIZE}"
log "  Cache:     ${PKG_CACHE}"
log "  DBs:       ${DB_DIR}"
log "====================================================="
