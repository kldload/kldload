#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# logging.sh — installer logging setup (sourced after common.sh)
# Sets up per-subsystem log files and redirects output to master log.
# ---------------------------------------------------------------------------

# Requires: KLDLOAD_LOG_DIR (set in common.sh)

# Create log directory
mkdir -p "${KLDLOAD_LOG_DIR}"

# Master installer log
KLDLOAD_LOG="${KLDLOAD_LOG_DIR}/kldload-installer.log"

# Subsystem logs
STORAGE_LOG="${KLDLOAD_LOG_DIR}/storage.log"
ZFS_LOG="${KLDLOAD_LOG_DIR}/zfs.log"
SECURITY_LOG="${KLDLOAD_LOG_DIR}/security.log"
NETWORK_LOG="${KLDLOAD_LOG_DIR}/network.log"
BOOTSTRAP_LOG="${KLDLOAD_LOG_DIR}/bootstrap.log"

export KLDLOAD_LOG STORAGE_LOG ZFS_LOG SECURITY_LOG NETWORK_LOG BOOTSTRAP_LOG

# Touch all log files so they exist from the start
touch \
    "$KLDLOAD_LOG" \
    "$STORAGE_LOG" \
    "$ZFS_LOG" \
    "$SECURITY_LOG" \
    "$NETWORK_LOG" \
    "$BOOTSTRAP_LOG"

# Redirect stdout and stderr to tee into KLDLOAD_LOG while still showing
# output to the terminal/console. Only redirect if not already done.
if [[ "${_KLDLOAD_LOGGING_INIT:-0}" != "1" ]]; then
    _KLDLOAD_LOGGING_INIT=1
    export _KLDLOAD_LOGGING_INIT
    exec > >(tee -a "$KLDLOAD_LOG") 2>&1
fi

log "Logging initialized. Master log: $KLDLOAD_LOG"
log "Subsystem logs: storage=$STORAGE_LOG zfs=$ZFS_LOG security=$SECURITY_LOG network=$NETWORK_LOG bootstrap=$BOOTSTRAP_LOG"
