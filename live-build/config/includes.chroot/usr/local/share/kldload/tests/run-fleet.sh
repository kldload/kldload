#!/bin/bash
# run-fleet.sh — run smoke tests on multiple kldloadOS VMs
# Usage: ./run-fleet.sh user password ip1 ip2 ip3 ...
set -euo pipefail

USER="${1:?Usage: $0 user password ip1 ip2 ...}"
PASS="${2:?}"
shift 2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for IP in "$@"; do
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  TESTING: $IP"
  echo "════════════════════════════════════════════════════════════════"

  # Copy test files to the VM
  sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -q \
    "${SCRIPT_DIR}/lib-test.sh" \
    "${SCRIPT_DIR}/smoke-core.sh" \
    "${SCRIPT_DIR}/smoke-server.sh" \
    "${SCRIPT_DIR}/smoke-desktop.sh" \
    "${SCRIPT_DIR}/smoke-auto.sh" \
    "${USER}@${IP}:/tmp/" 2>/dev/null

  # Run auto-detect smoke test
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "${USER}@${IP}" \
    "echo '$PASS' | sudo -S bash /tmp/smoke-auto.sh" 2>&1 || echo "  FAILED to connect to $IP"
done
