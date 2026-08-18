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

# -r, NOT -x: we invoke via `bash` so the exec bit is irrelevant, and -x
# lies on noexec mounts — kldload's own /tmp ships exec=off, so lifecycle's
# upload-to-/tmp made every desktop run silently fall back to the core
# suite (found 2026-07-23: "Detected profile: desktop" followed by the
# core leanness assertions failing on desktop tools).
if [[ ! -r "${SCRIPT_DIR}/smoke-${PROFILE}.sh" ]]; then
    echo "no smoke-${PROFILE}.sh present — falling back to smoke-core.sh" >&2
    PROFILE="core"
fi

# ─── The offline mirror actually carried what the installer asked for ────────
#
# Runs for every profile, before dispatch, because it is not profile-specific.
#
# When the darksite is detected the target's sources.list is darksite-only and
# profile packages install BEFORE the internet repos are written, so anything
# the mirror lacks simply cannot be installed. The retry loop then records one
# line per package and the install still reports success — which is why
# chromium, git, gir1.2-webkit-6.0 and fonts-noto-color-emoji all shipped
# missing and nothing ever looked broken: firstboot healed the webview stack
# over the network, and no test read this log (2026-08-18).
#
# This is deliberately a HARD failure. A package silently absent from an
# offline install is the exact class of defect the darksite exists to prevent.
_boot_log="/var/log/kldload/bootstrap.log"
if [[ -r "$_boot_log" ]]; then
    _missed=()
    while IFS= read -r _line; do
        [[ -n "$_line" ]] && _missed+=("$_line")
    done < <(sed -n 's/.*package \(.*\) not available.*/\1/p' "$_boot_log")
    if [[ "${#_missed[@]}" -gt 0 ]]; then
        echo "FAIL: the install could not fetch ${#_missed[@]} package(s) — the offline mirror is incomplete:" >&2
        printf '  %s\n' "${_missed[@]}" >&2
        echo "  (add them to the darksite, or stop installing them in lib/profiles.sh)" >&2
        exit 1
    fi
    echo "Offline mirror: every profile package the installer asked for was installed"
else
    echo "WARNING: ${_boot_log} is absent — cannot verify the offline mirror was complete" >&2
fi
echo ""

exec bash "${SCRIPT_DIR}/smoke-${PROFILE}.sh"
