#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p /var/log/installer
echo "[$(date '+%F %T')] ensure-darksite placeholder" >> /var/log/installer/darksite.log
exit 0
