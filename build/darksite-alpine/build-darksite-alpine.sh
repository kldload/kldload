#!/bin/sh
set -eu

# ---------------------------------------------------------------------------
# build-darksite-alpine.sh — runs inside an alpine:latest container.
# Downloads all required Alpine Linux packages and builds a local apk cache
# that is baked into the kldload CentOS live ISO at /root/darksite/alpine/.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_SETS_DIR="${PKG_SETS_DIR:-${SCRIPT_DIR}/config/package-sets}"

ARCH="${ARCH:-x86_64}"

# Output: mounted from host into this container
DARKSITE_OUT="${DARKSITE_OUT:-/output}"
APK_CACHE="${DARKSITE_OUT}/apk"

log() { printf '[%s] [darksite-alpine] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Read package sets
# ---------------------------------------------------------------------------

PACKAGES=""

read_package_set() {
    local name="$1"
    local file="${PKG_SETS_DIR}/${name}.txt"
    if [ ! -f "$file" ]; then
        log "Package set not found (skipping): $file"
        return 0
    fi
    while IFS= read -r line; do
        case "$line" in
            \#*|"") continue ;;
        esac
        # strip leading/trailing whitespace
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        PACKAGES="$PACKAGES $line"
    done < "$file"
    log "Loaded package set: $name ($(grep -cve '^[[:space:]]*$' -e '^[[:space:]]*#' "$file" || true) entries)"
}

read_package_set "target-base"
read_package_set "target-zfs"

# Deduplicate
PKGS_FINAL=""
for p in $PACKAGES; do
    case " $PKGS_FINAL " in
        *" $p "*) ;;
        *) PKGS_FINAL="$PKGS_FINAL $p" ;;
    esac
done
PKGS_FINAL="$(echo "$PKGS_FINAL" | sed 's/^ //')"

PKG_COUNT="$(echo "$PKGS_FINAL" | wc -w)"
log "Packages to download: $PKG_COUNT"

mkdir -p "$APK_CACHE"

# ---------------------------------------------------------------------------
# Enable community repo (needed for ZFS)
# ---------------------------------------------------------------------------
log "Configuring Alpine repositories..."

# Detect Alpine version from the container
ALPINE_VER="$(cat /etc/alpine-release | cut -d. -f1,2)"
log "Alpine version: $ALPINE_VER"

cat > /etc/apk/repositories <<EOF
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/main
https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community
EOF

log "Updating package index..."
apk update

# ---------------------------------------------------------------------------
# Download packages with dependencies
# ---------------------------------------------------------------------------
log "Downloading packages with dependencies..."

dl_ok=0
dl_fail=0

# apk fetch --recursive downloads the package and all its dependencies
# shellcheck disable=SC2086
if apk fetch --recursive --output "$APK_CACHE" $PKGS_FINAL 2>&1; then
    log "All packages downloaded successfully"
else
    log "WARNING: Batch download had errors — trying individually..."
    for pkg in $PKGS_FINAL; do
        if apk fetch --recursive --output "$APK_CACHE" "$pkg" 2>/dev/null; then
            dl_ok=$((dl_ok + 1))
        else
            log "  SKIP: $pkg (not found)"
            dl_fail=$((dl_fail + 1))
        fi
    done
    log "Individual download: ${dl_ok} ok, ${dl_fail} failed"
fi

# ---------------------------------------------------------------------------
# Build APKINDEX for offline repo
# ---------------------------------------------------------------------------
log "Building APKINDEX for offline repository..."
cd "$APK_CACHE"

# Create the APKINDEX.tar.gz so apk can use this as a local repo
# We need to sign it or use --allow-untrusted
apk index --output APKINDEX.tar.gz *.apk 2>&1 || \
    log "WARNING: apk index had errors"

# Copy the Alpine signing keys so the live system can verify packages
mkdir -p "${DARKSITE_OUT}/keys"
cp /etc/apk/keys/* "${DARKSITE_OUT}/keys/" 2>/dev/null || true

# Also save the repo version info
echo "$ALPINE_VER" > "${DARKSITE_OUT}/alpine-version"

# Count results
FINAL_COUNT="$(find "$APK_CACHE" -name '*.apk' -not -name 'APKINDEX*' | wc -l)"
TOTAL_SIZE="$(du -sh "$APK_CACHE" 2>/dev/null | cut -f1)"

log "====================================================="
log "Alpine darksite build complete"
log "  Packages:  ${FINAL_COUNT}"
log "  Size:      ${TOTAL_SIZE}"
log "  Cache:     ${APK_CACHE}"
log "  Version:   ${ALPINE_VER}"
log "====================================================="
