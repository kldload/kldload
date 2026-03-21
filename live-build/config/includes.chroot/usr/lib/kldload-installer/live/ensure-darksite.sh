#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p /var/log/installer
exec >>/var/log/installer/darksite.log 2>&1
echo "==== ensure-darksite $(date -Is) ===="
echo "phase-1 placeholder success"
exit 0
