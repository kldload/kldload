#!/usr/bin/env bash
set -Eeuo pipefail

# build-darksite-ubuntu.sh — runs inside an Ubuntu container.
# Downloads all required Ubuntu packages for offline installation.
# Reuses the same Debian darksite builder logic with Ubuntu mirrors.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use our own package sets but the Debian builder script
DEBIAN_BUILDER="/darksite-build/build-darksite-debian.sh"

export SUITE="noble"
export PKG_SETS_DIR="${SCRIPT_DIR}/config/package-sets"
export DARKSITE_OUT="/output"

# The Debian builder works for Ubuntu — same deb format, same apt tools
exec bash "${DEBIAN_BUILDER}"
