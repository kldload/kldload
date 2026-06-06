#!/bin/bash
# smoke-auto.sh — auto-detect profile and dispatch to smoke-<profile>.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prefer the canonical profile marker the installer writes
# (profiles.sh:706: `echo "${_profile}" > "${target}/etc/kldload/profile"`).
# Fall back to binary detection when the file is missing — earlier
# revisions of the installer didn't always write it, and a manual
# install of a single component on top of an existing system might
# leave the file stale.
PROFILE=""
if [[ -r /etc/kldload/profile ]]; then
    PROFILE="$(tr -d '[:space:]' </etc/kldload/profile)"
fi
if [[ -z "$PROFILE" ]]; then
    if command -v gnome-shell >/dev/null 2>&1; then
        PROFILE="desktop"
    elif command -v virsh >/dev/null 2>&1 &&
        systemctl is-enabled libvirtd >/dev/null 2>&1; then
        # KVM profile — libvirtd enabled. Earlier this script collapsed kvm
        # into "server" and silently skipped the libvirtd / virbr0 / kube-*
        # checks, hiding regressions in those layers.
        PROFILE="kvm"
    elif command -v kst >/dev/null 2>&1; then
        PROFILE="server"
    else
        PROFILE="core"
    fi
fi

echo "Detected profile: $PROFILE"
echo ""

if [[ ! -x "${SCRIPT_DIR}/smoke-${PROFILE}.sh" ]]; then
    echo "no smoke-${PROFILE}.sh present — falling back to smoke-core.sh" >&2
    PROFILE="core"
fi

exec bash "${SCRIPT_DIR}/smoke-${PROFILE}.sh"
