#!/bin/bash
# build-darksite-bsd.sh — download FreeBSD, OpenBSD, and GhostBSD base sets
# for offline installation from the kldload ISO.
set -euo pipefail

CACHE_DIR="${1:-/build/live-build/darksite-bsd-cache}"
ARCH="amd64"

FREEBSD_VER="14.4"
OPENBSD_VER="7.8"

log() { printf '[%(%F %T)T] [darksite-bsd] %s\n' -1 "$*"; }

mkdir -p "${CACHE_DIR}/freebsd" "${CACHE_DIR}/openbsd" "${CACHE_DIR}/ghostbsd"

# ── FreeBSD ────────────────────────────────────────────────────────────────
FREEBSD_URL="https://download.freebsd.org/releases/amd64/amd64/${FREEBSD_VER}-RELEASE"
log "Downloading FreeBSD ${FREEBSD_VER} base sets..."
for f in base.txz kernel.txz; do
    if [[ ! -f "${CACHE_DIR}/freebsd/${f}" ]]; then
        curl -fSL -o "${CACHE_DIR}/freebsd/${f}" "${FREEBSD_URL}/${f}"
        log "  ${f} downloaded"
    else
        log "  ${f} cached"
    fi
done
echo "${FREEBSD_VER}" > "${CACHE_DIR}/freebsd/VERSION"
log "FreeBSD ${FREEBSD_VER}: $(du -sh "${CACHE_DIR}/freebsd" | cut -f1)"

# ── OpenBSD ────────────────────────────────────────────────────────────────
OPENBSD_SHORT="${OPENBSD_VER/./}"
OPENBSD_URL="https://cdn.openbsd.org/pub/OpenBSD/${OPENBSD_VER}/amd64"
log "Downloading OpenBSD ${OPENBSD_VER} install sets..."
for f in base${OPENBSD_SHORT}.tgz comp${OPENBSD_SHORT}.tgz man${OPENBSD_SHORT}.tgz bsd bsd.rd; do
    if [[ ! -f "${CACHE_DIR}/openbsd/${f}" ]]; then
        curl -fSL -o "${CACHE_DIR}/openbsd/${f}" "${OPENBSD_URL}/${f}" || \
            log "  WARNING: ${f} not found — skipping"
        log "  ${f} downloaded"
    else
        log "  ${f} cached"
    fi
done
echo "${OPENBSD_VER}" > "${CACHE_DIR}/openbsd/VERSION"
log "OpenBSD ${OPENBSD_VER}: $(du -sh "${CACHE_DIR}/openbsd" | cut -f1)"

# ── GhostBSD ──────────────────────────────────────────────────────────────
# GhostBSD is FreeBSD-based — uses the same base.txz plus desktop packages.
# We use FreeBSD base + GhostBSD pkg repo for the desktop layer.
# For offline, we cache the base (shared with FreeBSD) and a minimal pkg set.
log "GhostBSD uses FreeBSD ${FREEBSD_VER} base (shared)"
cp -l "${CACHE_DIR}/freebsd/base.txz" "${CACHE_DIR}/ghostbsd/base.txz" 2>/dev/null || \
    cp "${CACHE_DIR}/freebsd/base.txz" "${CACHE_DIR}/ghostbsd/base.txz"
cp -l "${CACHE_DIR}/freebsd/kernel.txz" "${CACHE_DIR}/ghostbsd/kernel.txz" 2>/dev/null || \
    cp "${CACHE_DIR}/freebsd/kernel.txz" "${CACHE_DIR}/ghostbsd/kernel.txz"
echo "${FREEBSD_VER}" > "${CACHE_DIR}/ghostbsd/VERSION"
log "GhostBSD: shared FreeBSD base (desktop packages installed online on firstboot)"

# ── illumos (OpenIndiana) ──────────────────────────────────────────────────
# OpenIndiana is the most accessible illumos distribution
ILLUMOS_URL="https://dlc.openindiana.org/isos/hipster/latest"
log "Downloading OpenIndiana (illumos) minimal install..."
if [[ ! -f "${CACHE_DIR}/illumos/oi-hipster-minimal.iso" ]]; then
    mkdir -p "${CACHE_DIR}/illumos"
    # Get the latest minimal ISO filename
    ILLUMOS_ISO="$(curl -sL "${ILLUMOS_URL}/" | grep -oP 'href="\KOI-hipster-minimal-[^"]+\.iso' | tail -1)"
    if [[ -n "$ILLUMOS_ISO" ]]; then
        curl -fSL -o "${CACHE_DIR}/illumos/oi-hipster-minimal.iso" "${ILLUMOS_URL}/${ILLUMOS_ISO}"
        log "  ${ILLUMOS_ISO} downloaded"
    else
        log "  WARNING: could not find OpenIndiana ISO — check URL"
    fi
else
    log "  OpenIndiana cached"
fi
log "illumos: $(du -sh "${CACHE_DIR}/illumos" 2>/dev/null | cut -f1 || echo '0')"

log "BSD/illumos darksite complete: $(du -sh "${CACHE_DIR}" | cut -f1)"
