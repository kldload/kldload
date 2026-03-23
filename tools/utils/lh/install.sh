#!/usr/bin/env bash
# install.sh — one-shot installer for LogHog (lh) on Debian 12
set -euo pipefail

APP_NAME="lh"
INSTALL_PATH="/usr/local/bin/${APP_NAME}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${REPO_ROOT}/src"

# Colors
c_green="\033[32m"; c_yellow="\033[33m"; c_red="\033[31m"; c_blue="\033[34m"; c_rst="\033[0m"

need_root() {
  if [[ $EUID -ne 0 ]]; then echo "sudo -n true" >/dev/null 2>&1 || {
    echo -e "${c_yellow}•${c_rst} Elevation needed — re-running with sudo..."
    exec sudo -E bash "$0" "${ARGS[@]:-}"
  }
fi
}

log()   { echo -e "${c_green}✓${c_rst} $*"; }
warn()  { echo -e "${c_yellow}!${c_rst} $*"; }
error() { echo -e "${c_red}✗${c_rst} $*" >&2; }

ensure_debian_bookworm() {
  if [[ -f /etc/debian_version ]]; then
    codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-}")"
    if [[ "${codename}" != "bookworm" ]]; then
      warn "Detected Debian codename '${codename:-unknown}'. Proceeding anyway."
    fi
  else
    warn "This script targets Debian. Proceeding anyway."
  fi
}

apt_install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq
  apt-get install -y -qq \
    build-essential pkg-config \
    libjson-c-dev libreadline-dev libncurses-dev \
    less
  log "Dependencies installed."
}

ensure_tools() {
  command -v make >/dev/null || { error "make not found after install."; exit 1; }
  command -v pkg-config >/dev/null || { error "pkg-config not found after install."; exit 1; }
}

build_app() {
  if [[ ! -d "${SRC_DIR}" ]]; then
    error "Could not find src directory at: ${SRC_DIR}"
    exit 1
  fi
  log "Building in ${SRC_DIR} ..."
  make -C "${SRC_DIR}" clean >/dev/null || true
  make -C "${SRC_DIR}" >/dev/null
  [[ -x "${SRC_DIR}/${APP_NAME}" ]] || { error "Build did not produce ${APP_NAME} binary."; exit 1; }
  log "Build complete."
}

install_app() {
  install -m 0755 "${SRC_DIR}/${APP_NAME}" "${INSTALL_PATH}"
  log "Installed ${APP_NAME} to ${INSTALL_PATH}"
}

ensure_path() {
  if ! command -v "${APP_NAME}" >/dev/null 2>&1; then
    # PATH might be missing /usr/local/bin in non-login shells
    if ! echo "$PATH" | tr ':' '\n' | grep -qx "/usr/local/bin"; then
      warn "/usr/local/bin not found in PATH. Adding for current user (~/.bashrc)."
      USER_HOME="${SUDO_USER:+/home/${SUDO_USER}}"
      [[ -z "${USER_HOME}" || ! -d "${USER_HOME}" ]] && USER_HOME="$HOME"
      if [[ -w "${USER_HOME}" ]]; then
        echo 'export PATH="/usr/local/bin:$PATH"' >> "${USER_HOME}/.bashrc"
        log "Appended PATH update to ${USER_HOME}/.bashrc. Open a new shell to pick it up."
      else
        warn "Could not write to ${USER_HOME}/.bashrc — please add /usr/local/bin to PATH manually."
      fi
    fi
  fi
}

show_summary() {
  echo -e "${c_blue}\n— Installation Summary —${c_rst}"
  echo "Binary: ${INSTALL_PATH}"
  echo "Run   : ${APP_NAME}"
  echo "Uninst: sudo bash $0 --uninstall"
  echo
}

uninstall_app() {
  need_root
  if [[ -e "${INSTALL_PATH}" ]]; then
    rm -f "${INSTALL_PATH}"
    log "Removed ${INSTALL_PATH}"
  else
    warn "Nothing to remove at ${INSTALL_PATH}"
  fi
  exit 0
}

usage() {
  cat <<EOF
Usage: $0 [--uninstall]

No flags: installs dependencies, builds, and installs ${APP_NAME} to ${INSTALL_PATH}.
--uninstall: removes the installed binary.
EOF
}

main() {
  ARGS=("$@")
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --uninstall) uninstall_app ;;
  esac

  need_root
  ensure_debian_bookworm
  apt_install_deps
  ensure_tools
  build_app
  install_app
  ensure_path
  show_summary
}

main "$@"
