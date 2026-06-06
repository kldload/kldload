#!/usr/bin/env bash
# Sourced by kldload-install-target — core helpers: k_log, k_die, k_bool, k_mount_bind, k_umount_if_mounted
set -Eeuo pipefail

KLDLOAD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
KLDLOAD_ROOT_DIR="$(cd "${KLDLOAD_LIB_DIR}/.." && pwd)"
KLDLOAD_LOG_DIR="${KLDLOAD_LOG_DIR:-/var/log/installer}"
KLDLOAD_STATE_DIR="${KLDLOAD_STATE_DIR:-/var/lib/kldload-installer}"
KLDLOAD_TARGET="${KLDLOAD_TARGET:-/target}"
KLDLOAD_DEBUG="${KLDLOAD_DEBUG:-0}"

mkdir -p "${KLDLOAD_LOG_DIR}" "${KLDLOAD_STATE_DIR}"

k_log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${KLDLOAD_LOG_DIR}/kldload-installer.log" >&2
}

k_log_section() {
    k_log "========== $* =========="
}

k_debug() {
    if [[ "${KLDLOAD_DEBUG}" == "1" ]]; then
        k_log "DEBUG: $*"
    fi
}

k_die() {
    k_log "ERROR: $*"
    exit 1
}

k_need_cmd() {
    command -v "$1" >/dev/null 2>&1 || k_die "required command missing: $1"
}

k_run() {
    k_debug "RUN: $*"
    "$@"
}

k_capture() {
    local outfile="$1"
    shift
    k_debug "CAPTURE(${outfile}): $*"
    "$@" >"${outfile}" 2>&1
}

k_require_root() {
    [[ "$(id -u)" -eq 0 ]] || k_die "must be run as root"
}

# ── Install-time copy helpers — fail loudly on shortfalls ────────────────────
# Adopted 2026-06-05 after the .135 incident: every `cp -r ... && k_log "N items"`
# call site silently dropped files (1/6 ansible playbooks, wallpapers, dock pin
# overlay, dock favorites file, dconf GDM overrides) without surfacing anything
# to the operator. "WARNING: feature will fail" buried in install logs is not
# a fail. Use these helpers instead of bare cp at install time. If a future
# helper call site shows up in the next post-install audit as missing, the
# install dies loudly. That's the only way to keep the pattern from coming back.
k_install_tree() {
    # Recursively copy DIR contents and verify file count didn't shrink.
    # Usage: k_install_tree <src-dir> <dst-dir> <label>
    local src="$1" dst="$2" label="$3"
    [[ -d "$src" ]] || k_die "${label}: source directory missing: $src"
    mkdir -p "$dst"
    cp -r "$src/." "$dst/" ||
        k_die "${label}: cp failed: $src → $dst"
    local src_n dst_n
    src_n=$(find "$src" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) | wc -l)
    dst_n=$(find "$dst" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) | wc -l)
    ((dst_n >= src_n)) ||
        k_die "${label}: short copy — ${dst_n}/${src_n} entries landed in $dst"
    k_log "${label}: ${dst_n} entries → $dst"
}

k_install_file() {
    # Copy a single file and verify it landed non-empty (or with the same size
    # as the source, whichever's tighter). Use for marker files / configs
    # whose 0-byte version means "broken feature" (see the empty .iso.sha256
    # we shipped in 1.3.0-b623).
    # Usage: k_install_file <src> <dst> <label>
    local src="$1" dst="$2" label="$3"
    [[ -f "$src" ]] || k_die "${label}: source file missing: $src"
    install -D -m "$(stat -c '%a' "$src")" "$src" "$dst" ||
        k_die "${label}: install failed: $src → $dst"
    [[ -s "$dst" || ! -s "$src" ]] ||
        k_die "${label}: dst is 0 bytes (src is $(stat -c %s "$src") bytes): $dst"
    k_log "${label}: → $dst"
}

k_assert_landed() {
    # Sanity-check that one or more paths exist on the target. Use at the end
    # of install phases to catch silent drops that slipped past per-step
    # helpers. Dies on first miss.
    # Usage: k_assert_landed <label> <path> [path ...]
    local label="$1"
    shift
    local p
    for p in "$@"; do
        [[ -e "$p" ]] || k_die "${label}: expected path missing — $p"
    done
    k_log "${label}: $# path(s) present"
}

k_bool() {
    case "${1:-}" in
    1 | true | TRUE | yes | YES | on | ON) return 0 ;;
    *) return 1 ;;
    esac
}

k_mount_bind() {
    local src="$1"
    local dst="$2"
    mkdir -p "${dst}"
    mountpoint -q "${dst}" || mount --bind "${src}" "${dst}"
}

k_umount_if_mounted() {
    local p="$1"
    if mountpoint -q "${p}" 2>/dev/null; then
        umount -lf "${p}" || true
    fi
}

k_mkdir() {
    mkdir -p "$@"
}

k_log_to() {
    local logfile="$1"
    shift
    mkdir -p "$(dirname "${logfile}")"
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${logfile}" >&2
}

k_in_chroot() {
    local target="$1"
    shift
    chroot "${target}" /usr/bin/env \
        DEBIAN_FRONTEND=noninteractive \
        LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        "$@"
}
