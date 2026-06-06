#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# common.sh — core installer library (sourced, not executed directly)
# Provides: log, log_section, die, need_cmd, require_root, run, in_chroot, bool
# ---------------------------------------------------------------------------

# Defaults — can be overridden by caller before sourcing
KLDLOAD_TARGET="${KLDLOAD_TARGET:-/target}"
KLDLOAD_LOG_DIR="${KLDLOAD_LOG_DIR:-/var/log/installer}"
KLDLOAD_LOG="${KLDLOAD_LOG:-}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
    local msg
    msg="[$(date '+%Y-%m-%dT%H:%M:%S')] $*"
    echo "$msg" >&2
    if [[ -n "${KLDLOAD_LOG:-}" ]]; then
        echo "$msg" >>"$KLDLOAD_LOG"
    fi
}

log_section() {
    local title="$1"
    local sep="================================================================"
    log "$sep"
    log "  $title"
    log "$sep"
}

die() {
    log "FATAL: $*"
    exit 1
}

# ---------------------------------------------------------------------------
# Command validation
# ---------------------------------------------------------------------------

need_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 ||
        die "Required command not found: $cmd"
}

# ---------------------------------------------------------------------------
# Privilege check
# ---------------------------------------------------------------------------

require_root() {
    [[ "$(id -u)" -eq 0 ]] ||
        die "This operation requires root privileges. Run as root or with sudo."
}

# ---------------------------------------------------------------------------
# Command execution with logging
# ---------------------------------------------------------------------------

run() {
    log "RUN: $*"
    "$@"
}

# ---------------------------------------------------------------------------
# Chroot execution
# ---------------------------------------------------------------------------

in_chroot() {
    local target="$1"
    shift
    local cmd="$*"
    log "CHROOT[$target]: $cmd"
    chroot "$target" /bin/bash -c "$cmd"
}

# ---------------------------------------------------------------------------
# Boolean helper
# Returns 0 (true) if val is 1/true/yes/on (case-insensitive), else 1 (false)
# ---------------------------------------------------------------------------

bool() {
    local val="${1:-}"
    case "${val,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
    esac
}
