#!/usr/bin/env bash
# Sourced by kldload-install-target — sets KLDLOAD_*_LOG paths and k_log_section
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# shellcheck disable=SC2034
KLDLOAD_STORAGE_LOG="${KLDLOAD_LOG_DIR}/storage.log"
# shellcheck disable=SC2034
KLDLOAD_ZFS_LOG="${KLDLOAD_LOG_DIR}/zfs.log"
# shellcheck disable=SC2034
KLDLOAD_SECURITY_LOG="${KLDLOAD_LOG_DIR}/security.log"
# shellcheck disable=SC2034
KLDLOAD_NETWORK_LOG="${KLDLOAD_LOG_DIR}/network.log"
# shellcheck disable=SC2034
KLDLOAD_BOOTSTRAP_LOG="${KLDLOAD_LOG_DIR}/bootstrap.log"

k_log_section() {
    local title="$1"
    k_log "========== ${title} =========="
}

k_log_to() {
    local logfile="$1"
    shift
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$logfile" >&2
}
