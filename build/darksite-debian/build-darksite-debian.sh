#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# build-darksite-debian.sh — runs inside a Debian container.
# Downloads all required Debian packages and builds a local APT repository
# that is baked into the kldload CentOS live ISO at /root/darksite/debian/.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_SETS_DIR="${PKG_SETS_DIR:-${SCRIPT_DIR}/config/package-sets}"

PROFILE="${PROFILE:-desktop}"
ARCH="${ARCH:-amd64}"
SUITE="${SUITE:-trixie}"

# Output: mounted from host into this container
DARKSITE_OUT="${DARKSITE_OUT:-/output}"
APT_ROOT="${DARKSITE_OUT}/apt"
APT_POOL="${APT_ROOT}/pool/main"
APT_DISTS="${APT_ROOT}/dists/${SUITE}/main/binary-${ARCH}"

log() { printf '[%s] [darksite-deb] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
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
        line="${line//\$\{ARCH\}/$ARCH}"
        PACKAGES+=("$line")
    done < "$file"
    log "Loaded package set: $name ($(wc -l < "$file") entries)"
}

read_package_set "live-base"
read_package_set "target-base"
read_package_set "target-zfs"
read_package_set "target-desktop"
read_package_set "target-server"

# Enable contrib + non-free-firmware (ZFS is in contrib)
log "Enabling contrib and non-free-firmware components..."
sed -i 's/Components: main/Components: main contrib non-free-firmware/' /etc/apt/sources.list.d/*.sources 2>/dev/null || true
# Fallback for traditional sources.list format
if [[ -f /etc/apt/sources.list ]]; then
    sed -i 's/main$/main contrib non-free-firmware/' /etc/apt/sources.list 2>/dev/null || true
fi

# Update APT cache
log "Updating APT package lists..."
apt-get update -q 2>&1 | grep -v '^Get\|^Hit\|^Ign' || true

# Add required+important priority packages for debootstrap
log "Adding required+important Debian base packages..."
mapfile -t PRIORITY_PKGS < <(
    apt-cache dumpavail 2>/dev/null \
        | awk '/^Package:/ { pkg=$2 }
               /^Priority: (required|important)/ { print pkg }' \
        | sort -u
)
log "Priority packages found: ${#PRIORITY_PKGS[@]}"
PACKAGES+=("${PRIORITY_PKGS[@]}")

# Hardcoded debootstrap essentials
PACKAGES+=(
    gzip zstd xz-utils bzip2 tar
    dash bash coreutils diffutils findutils grep sed gawk
    mount util-linux apt dpkg base-files base-passwd
)

# Deduplicate
declare -A _seen=()
declare -a PKGS_FINAL=()
for p in "${PACKAGES[@]}"; do
    [[ -z "${_seen[$p]:-}" ]] || continue
    _seen["$p"]=1
    PKGS_FINAL+=("$p")
done

log "Packages to download: ${#PKGS_FINAL[@]}"

mkdir -p "$APT_POOL" "$APT_DISTS"

# Resolve full dependency closure
log "Resolving full dependency closure..."
mapfile -t CLOSURE < <(
    apt-cache depends --recurse --no-recommends --no-suggests \
        --no-conflicts --no-breaks --no-replaces --no-enhances \
        "${PKGS_FINAL[@]}" 2>/dev/null \
        | grep '^[[:alpha:]]' \
        | sort -u
)
log "Dependency closure: ${#CLOSURE[@]} packages"

if [[ "${#CLOSURE[@]}" -eq 0 ]]; then
    log "apt-cache depends returned empty — falling back to direct package list."
    CLOSURE=("${PKGS_FINAL[@]}")
fi

# Blacklist
DARKSITE_BLACKLIST=(
    musescore-general-soundfont musescore-general-soundfont-lossless
    musescore-general-soundfont-small fluid-soundfont-gm
    fluidr3mono-gm-soundfont opl3-soundfont timgm6mb-soundfont
    enlightenment-data libelementary-data mate-backgrounds
    breeze-wallpaper lxqt-themes lomiri-sounds lomiri-wallpapers-16.04
    chromium chromium-common snapd
)

if [[ "${#DARKSITE_BLACKLIST[@]}" -gt 0 ]]; then
    declare -A _bl
    for _b in "${DARKSITE_BLACKLIST[@]}"; do _bl["$_b"]=1; done
    _filtered=()
    for _p in "${CLOSURE[@]}"; do
        [[ -z "${_bl[$_p]:-}" ]] && _filtered+=("$_p")
    done
    log "Removed $(( ${#CLOSURE[@]} - ${#_filtered[@]} )) blacklisted packages"
    CLOSURE=("${_filtered[@]}")
fi

# Download packages
log "Downloading ${#CLOSURE[@]} packages..."
_dl_new=0 _dl_skip=0 _dl_fail=0 _dl_idx=0 _dl_total="${#CLOSURE[@]}"
for _pkg in "${CLOSURE[@]}"; do
    (( _dl_idx++ )) || true
    (( _dl_idx % 100 == 0 )) && log "Progress: ${_dl_idx}/${_dl_total} — ${_dl_new} new, ${_dl_skip} cached, ${_dl_fail} skipped"
    if compgen -G "${APT_POOL}/${_pkg}_*.deb" > /dev/null 2>&1; then
        (( _dl_skip++ )) || true
        continue
    fi
    (cd "$APT_POOL" && apt-get download "$_pkg" 2>/dev/null) && {
        (( _dl_new++ )) || true
    } || {
        (( _dl_fail++ )) || true
    }
done
log "Download complete: ${_dl_new} new, ${_dl_skip} cached, ${_dl_fail} skipped"

# Normalise epoch filenames
log "Normalising epoch filenames..."
while IFS= read -r -d '' f; do
    mv "$f" "${f//%3a/:}"
done < <(find "$APT_POOL" -maxdepth 1 -name '*%3a*' -print0)

DEB_COUNT=0
while IFS= read -r -d '' _; do
    (( DEB_COUNT++ )) || true
done < <(find "$APT_POOL" -maxdepth 1 -name "*.deb" -print0)

log "Darksite pool: ${DEB_COUNT} packages"
[[ "$DEB_COUNT" -gt 0 ]] || die "No packages downloaded"

# Generate APT index
log "Generating Packages index..."
(
    cd "$APT_ROOT"
    dpkg-scanpackages --multiversion pool/main 2>/dev/null \
        > "dists/${SUITE}/main/binary-${ARCH}/Packages" \
        || dpkg-scanpackages pool/main \
        > "dists/${SUITE}/main/binary-${ARCH}/Packages"
)
gzip -9c "${APT_DISTS}/Packages" > "${APT_DISTS}/Packages.gz"

# Generate Release file
log "Generating Release file..."
_size() { stat -c%s "$1"; }
_md5()  { md5sum "$1" | awk '{print $1}'; }
_sha256() { sha256sum "$1" | awk '{print $1}'; }

PKG_PATH="dists/${SUITE}/main/binary-${ARCH}/Packages"
PKG_GZ_PATH="dists/${SUITE}/main/binary-${ARCH}/Packages.gz"

cat > "${APT_ROOT}/dists/${SUITE}/Release" <<EOF
Origin: kldload Darksite
Label: kldload
Suite: ${SUITE}
Codename: ${SUITE}
Architectures: ${ARCH}
Components: main
Description: kldload offline Debian APT repository
Date: $(date -u '+%a, %d %b %Y %H:%M:%S UTC')
MD5Sum:
 $(_md5 "${APT_ROOT}/${PKG_PATH}") $(_size "${APT_ROOT}/${PKG_PATH}") main/binary-${ARCH}/Packages
 $(_md5 "${APT_ROOT}/${PKG_GZ_PATH}") $(_size "${APT_ROOT}/${PKG_GZ_PATH}") main/binary-${ARCH}/Packages.gz
SHA256:
 $(_sha256 "${APT_ROOT}/${PKG_PATH}") $(_size "${APT_ROOT}/${PKG_PATH}") main/binary-${ARCH}/Packages
 $(_sha256 "${APT_ROOT}/${PKG_GZ_PATH}") $(_size "${APT_ROOT}/${PKG_GZ_PATH}") main/binary-${ARCH}/Packages.gz
EOF

log "====================================================="
log "Debian darksite build complete"
log "  APT packages: ${DEB_COUNT}"
log "  Repo:         ${APT_ROOT}"
log "====================================================="
