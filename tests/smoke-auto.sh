#!/bin/bash
# smoke-auto.sh — auto-detect profile and run the appropriate smoke test
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect profile based on what's installed
if command -v gnome-shell >/dev/null 2>&1; then
  PROFILE="desktop"
elif command -v kst >/dev/null 2>&1; then
  PROFILE="server"
else
  PROFILE="core"
fi

echo "Detected profile: $PROFILE"
echo ""

exec bash "${SCRIPT_DIR}/smoke-${PROFILE}.sh"
