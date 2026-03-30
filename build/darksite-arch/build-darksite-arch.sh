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

# Prevent dirmngr from hanging in containers — it tries to reach keyservers
# and spins at 100% CPU forever. Replace it with a no-op wrapper.
mkdir -p /root/.gnupg
echo "disable-ipv6" >> /etc/pacman.d/gnupg/dirmngr.conf 2>/dev/null || true
echo "keyserver-timeouts 5" >> /etc/pacman.d/gnupg/dirmngr.conf 2>/dev/null || true
# Move real dirmngr aside and replace with exit-0 stub
if [[ -x /usr/bin/dirmngr ]]; then
  mv /usr/bin/dirmngr /usr/bin/dirmngr.real 2>/dev/null || true
  printf '#!/bin/sh\nexit 0\n' > /usr/bin/dirmngr
  chmod +x /usr/bin/dirmngr
  log "Replaced dirmngr with stub to prevent container hangs"
fi
# Kill any dirmngr that spawns — pacman reinstalls gnupg which restores the real binary.
# Use pkill by exact name (not -f pattern which matches the shell loop itself).
# Also use dpkg-divert-style protection: make dirmngr non-executable.
chmod -x /usr/bin/dirmngr 2>/dev/null || true
( while true; do
    killall -9 dirmngr 2>/dev/null
    # Re-stub dirmngr in case pacman reinstalled gnupg and overwrote our stub
    if [[ -x /usr/bin/dirmngr ]] && ! grep -q 'exit 0' /usr/bin/dirmngr 2>/dev/null; then
      printf '#!/bin/sh\nexit 0\n' > /usr/bin/dirmngr
      chmod +x /usr/bin/dirmngr
    fi
    sleep 1
  done ) &
_dirmngr_killer=$!

# Add archzfs repo — use TrustAll and Never to avoid key lookup issues in containers
log "Adding archzfs repository..."
cat >> /etc/pacman.conf <<'ARCHZFS'

[archzfs]
Server = https://archzfs.com/$repo/$arch
SigLevel = Never
ARCHZFS

# Update package databases
log "Syncing package databases..."
pacman -Sy --noconfirm

# ---------------------------------------------------------------------------
# Download packages with dependencies
# ---------------------------------------------------------------------------
log "Downloading ${#PKGS_FINAL[@]} packages with ALL transitive dependencies..."

# Install into a throwaway root with --cachedir pointing to our output.
# This forces pacman to download EVERY dependency (nothing pre-installed).
# We use -S (install) not -Sw (download only) because -Sw skips deps
# that are already installed in the container.
_install_root="/tmp/darksite-install-root"
mkdir -p "${_install_root}/var/lib/pacman" "${_install_root}/etc"
cp /etc/pacman.conf "${_install_root}/etc/pacman.conf"
mkdir -p "${_install_root}/etc/pacman.d"
cp /etc/pacman.d/mirrorlist "${_install_root}/etc/pacman.d/mirrorlist"

log "Syncing databases in install root..."
pacman --root "${_install_root}" --cachedir "$PKG_CACHE" \
    -Sy --noconfirm 2>&1 || log "WARNING: DB sync had errors"

log "Installing all packages into throwaway root (this downloads everything)..."
pacman --root "${_install_root}" --cachedir "$PKG_CACHE" \
    --noconfirm --needed -S "${PKGS_FINAL[@]}" 2>&1 || {
    log "WARNING: Some packages failed — trying individually..."
    for _pkg in "${PKGS_FINAL[@]}"; do
        pacman --root "${_install_root}" --cachedir "$PKG_CACHE" \
            --noconfirm --needed -S "$_pkg" 2>/dev/null || \
            log "  SKIP: $_pkg"
    done
}

# Copy the install root's sync DBs (these match the downloaded packages exactly)
cp "${_install_root}/var/lib/pacman/sync/"*.db "$DB_DIR/" 2>/dev/null || true
cp "${_install_root}/var/lib/pacman/sync/"*.db "$PKG_CACHE/" 2>/dev/null || true

rm -rf "${_install_root}"

# Copy sync databases so pacstrap can use them offline
log "Copying package databases..."
mkdir -p "$DB_DIR"
log "Sync DB dir contents: $(ls /var/lib/pacman/sync/ 2>&1)"
for _db in /var/lib/pacman/sync/*.db; do
    if [[ -f "$_db" ]]; then
        cp "$_db" "$DB_DIR/" && log "  Copied $(basename "$_db") to db/"
        cp "$_db" "$PKG_CACHE/" && log "  Copied $(basename "$_db") to pkg/"
    fi
done
log "Databases: $(ls "$DB_DIR/"*.db 2>/dev/null | wc -l) in db/, $(ls "$PKG_CACHE/"*.db 2>/dev/null | wc -l) in pkg/"

# ---------------------------------------------------------------------------
# Pre-build ZFS kernel module
# ---------------------------------------------------------------------------
# archzfs often lags behind the latest Arch kernel, so zfs-linux (prebuilt)
# may not exist. Rather than relying on DKMS at install time (which runs in
# a CentOS chroot and is fragile), we build zfs.ko right here in the native
# Arch container where kernel + headers + gcc all match perfectly.
#
# The resulting module tree is shipped in the darksite at /zfs-modules/<kver>/
# and bootstrap.sh copies it into the target before mkinitcpio runs.
# ---------------------------------------------------------------------------

ZFS_MOD_DIR="${DARKSITE_OUT}/zfs-modules"
mkdir -p "$ZFS_MOD_DIR"

log "Pre-building ZFS kernel module..."

# ── Step 1: Determine which kernel archzfs supports ──────────────────────
# Install zfs-dkms and build deps first (no kernel yet)
pacman --noconfirm --needed -S dkms gcc make autoconf automake libtool \
    zfs-dkms zfs-utils 2>&1 || {
  log "WARNING: Could not install ZFS build deps — skipping pre-build"
}

_zfs_dkms_ver=$(pacman -Q zfs-dkms 2>/dev/null | awk '{print $2}' | cut -d- -f1 || echo "")

# Check if archzfs has a prebuilt zfs-linux — if so, extract its kernel dep
_zfs_kernel_ver=""
_zfs_si=$(pacman -Si zfs-linux 2>/dev/null || echo "")
if [[ -n "$_zfs_si" ]]; then
  _zfs_kernel_ver=$(echo "$_zfs_si" | grep -oP 'linux=\K[0-9][^\s]*' | head -1 || echo "")
  log "archzfs zfs-linux requires linux=${_zfs_kernel_ver}"
fi

# ── Step 2: Install the matching kernel ──────────────────────────────────
if [[ -n "$_zfs_kernel_ver" ]]; then
  # Try installing the pinned kernel from Arch Linux Archive
  _archive_url="https://archive.archlinux.org/packages"
  _kpkg="${_archive_url}/l/linux/linux-${_zfs_kernel_ver}-x86_64.pkg.tar.zst"
  _hpkg="${_archive_url}/l/linux-headers/linux-headers-${_zfs_kernel_ver}-x86_64.pkg.tar.zst"
  log "Downloading pinned kernel ${_zfs_kernel_ver} from Arch Linux Archive..."

  curl -sfL "$_kpkg" -o "/tmp/linux-${_zfs_kernel_ver}.pkg.tar.zst" 2>&1 && \
  curl -sfL "$_hpkg" -o "/tmp/linux-headers-${_zfs_kernel_ver}.pkg.tar.zst" 2>&1 && {
    pacman --noconfirm -U "/tmp/linux-${_zfs_kernel_ver}.pkg.tar.zst" \
                          "/tmp/linux-headers-${_zfs_kernel_ver}.pkg.tar.zst" 2>&1 || true
    # Also copy these pinned kernel packages into the darksite cache
    cp "/tmp/linux-${_zfs_kernel_ver}.pkg.tar.zst" "$PKG_CACHE/"
    cp "/tmp/linux-headers-${_zfs_kernel_ver}.pkg.tar.zst" "$PKG_CACHE/"
    log "Pinned kernel ${_zfs_kernel_ver} installed and cached"

    # Try to install the prebuilt zfs-linux (replaces zfs-dkms — use --ask 4 to auto-resolve conflicts)
    pacman --noconfirm --ask 4 --needed -S zfs-linux 2>&1 && {
      log "Prebuilt zfs-linux installed — caching package"
      cp /var/cache/pacman/pkg/zfs-linux-*.pkg.tar.* "$PKG_CACHE/" 2>/dev/null || true
    } || log "zfs-linux prebuilt not available — will use DKMS"
  } || {
    log "Archive download failed — falling back to latest kernel"
    pacman --noconfirm --needed -S linux linux-headers 2>&1 || true
  }
else
  log "No pinned kernel version found — installing latest"
  pacman --noconfirm --needed -S linux linux-headers 2>&1 || true
fi

# ── Step 3: Try DKMS build if zfs-dkms is still installed ────────────────
_kver=$(ls /usr/lib/modules/ 2>/dev/null | grep -v '^$' | sort -V | tail -1)
log "Kernel version: ${_kver:-UNKNOWN}"

# If zfs-dkms is still present (zfs-linux didn't replace it), build via DKMS
if [[ -n "$_kver" ]] && pacman -Q zfs-dkms >/dev/null 2>&1; then
  _zfs_dkms_ver=$(pacman -Q zfs-dkms 2>/dev/null | awk '{print $2}' | cut -d- -f1)
  log "Building ZFS DKMS ${_zfs_dkms_ver} for kernel ${_kver}..."
  dkms build -m zfs -v "$_zfs_dkms_ver" -k "$_kver" 2>&1 && \
  dkms install -m zfs -v "$_zfs_dkms_ver" -k "$_kver" 2>&1 && \
    log "DKMS build succeeded" || \
    log "DKMS build failed (zfs-linux may have been installed instead)"
fi

# ── Step 4: Copy zfs.ko to darksite (regardless of install method) ───────
if [[ -n "$_kver" ]]; then
  _mod_src="/usr/lib/modules/${_kver}"
  if find "${_mod_src}" -name 'zfs.ko*' 2>/dev/null | grep -q .; then
    mkdir -p "${ZFS_MOD_DIR}/${_kver}"
    # Copy all module subdirs that contain .ko files
    for _subdir in extra updates extramodules kernel; do
      [[ -d "${_mod_src}/${_subdir}" ]] && cp -a "${_mod_src}/${_subdir}" "${ZFS_MOD_DIR}/${_kver}/"
    done
    depmod -a "$_kver" 2>/dev/null
    cp "${_mod_src}"/modules.* "${ZFS_MOD_DIR}/${_kver}/" 2>/dev/null || true
    log "Module dirs copied: $(ls "${ZFS_MOD_DIR}/${_kver}/" 2>/dev/null)"
    log "VERIFIED: zfs.ko pre-built for ${_kver}"
    log "  $(find "${ZFS_MOD_DIR}/${_kver}" -name 'zfs.ko*' 2>/dev/null)"
  else
    log "ERROR: zfs.ko not found in /usr/lib/modules/${_kver}/ — ZFS will not work offline!"
    log "  Installed ZFS packages: $(pacman -Q zfs-linux zfs-dkms zfs-utils 2>/dev/null)"
  fi
else
  log "ERROR: No kernel installed — cannot ship ZFS modules"
fi

# Count downloaded packages
PKG_COUNT=$(find "$PKG_CACHE" -name '*.pkg.tar.*' | wc -l)
log "Darksite cache: ${PKG_COUNT} packages"

TOTAL_SIZE=$(du -sh "$PKG_CACHE" 2>/dev/null | cut -f1)
ZFS_MOD_COUNT=$(find "$ZFS_MOD_DIR" -name '*.ko*' 2>/dev/null | wc -l)

log "====================================================="
log "Arch darksite build complete"
log "  Packages:    ${PKG_COUNT}"
log "  Size:        ${TOTAL_SIZE}"
log "  Cache:       ${PKG_CACHE}"
log "  DBs:         ${DB_DIR}"
log "  ZFS modules: ${ZFS_MOD_COUNT} .ko files in ${ZFS_MOD_DIR}"
log "====================================================="
