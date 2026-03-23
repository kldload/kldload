#!/usr/bin/env bash
# install.sh — build & install 'ral' on Debian/Ubuntu
set -euo pipefail

APP=ral
SRC=ral.c
PREFIX=/usr/local
BIN_DIR="${PREFIX}/bin"

# Use sudo if not root
SUDO=""
if [[ $EUID -ne 0 ]]; then
  SUDO="sudo"
fi

echo "==> Ensuring build tools are present…"
if command -v apt-get >/dev/null 2>&1; then
  ${SUDO} apt-get update -y
  ${SUDO} apt-get install -y --no-install-recommends build-essential
else
  echo "apt-get not found. This script is for Debian/Ubuntu."
  exit 1
fi

echo "==> Compiling ${APP}…"
gcc -std=c11 -O2 -Wall -Wextra -Wpedantic "${SRC}" -o "${APP}"

# Optional: strip for smaller binary if available
if command -v strip >/dev/null 2>&1; then
  strip "${APP}" || true
fi

echo "==> Installing to ${BIN_DIR}/${APP}…"
${SUDO} install -d -m 0755 "${BIN_DIR}"
${SUDO} install -m 0755 "./${APP}" "${BIN_DIR}/${APP}"

echo "==> Done."
echo "    Try: ${APP} -h"
