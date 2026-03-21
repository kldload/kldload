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

k_bool() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
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
