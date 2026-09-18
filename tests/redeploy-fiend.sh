#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# redeploy-fiend.sh — arm fiend for an unattended netboot reinstall, verify it,
# and say what it will do. Built for running MANY times while testing.
#
# WHAT IT DOES, IN ORDER:
#   1. checks the netboot server on this host is running and serving;
#   2. writes an answers file from the flags given (defaults below);
#   3. arms fiend's MAC with it;
#   4. FETCHES the snippet and the seed back over HTTP, the way fiend will,
#      because arm-install exiting 0 is not evidence a target can read them;
#   5. prints the install fiend is about to do.
#
# WHY: every redeploy was four hand-typed steps with a MAC and a by-id disk
# path in them, and a typo in either is silent -- an unarmed machine just
# boots locally and an install "does not happen" with nothing to read.
#
# Inputs : flags (see --help); the netboot server must already be serving.
# Outputs: live-build/pxe/answers/<mac>.env, plus the armed token on the server.
# Exit   : 0 armed and verified · 1 a step failed · 2 usage.
#
# Notes:
#   - Arming copies the answers file AT THAT MOMENT. Editing the file later
#     changes nothing until you re-arm.
#   - The seed carries passwords in clear and is served unauthenticated to the
#     LAN until disarmed. --disarm when the install finishes.
#   - Secure Boot must be OFF in fiend's firmware to netboot at all: ipxe.efi
#     is unsigned. --secure-boot prepares the INSTALLED system; you turn it on
#     in firmware afterwards.
# ─────────────────────────────────────────────────────────────────────────────
set -Eeuo pipefail
trap 'echo "FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# fiend's identity. The MAC is the onboard Realtek; the disk is the by-id path,
# never /dev/nvme0n1 -- a kernel name is a ticking time bomb when a card moves.
MAC="${FIEND_MAC:-f0:2f:74:cd:27:50}"
# The NIC that carries the download: the X540 10G. Its card has only a
# legacy-BIOS PXE ROM, so under UEFI the Realtek above must start the boot and
# this one takes over in the initrd (arm-install --netdev; 2026-09-18, card
# refitted). --netdev none lets the initrd use whichever NIC routes first.
NETDEV="${FIEND_NETDEV:-a0:36:9f:9f:10:1c}"
DISK="${FIEND_DISK:-/dev/disk/by-id/nvme-WD_BLACK_SN850X_HS_2000GB_22303U801021}"
ANSWERS="${ROOT}/live-build/pxe/answers/$(tr 'A-Z:' 'a-z-' <<<"$MAC").env"

DISTRO=fedora
PROFILE=desktop
TEMPLATE=""
WORKERS="3"
CONTROL_PLANES="3"
ENCRYPT=0
PASSPHRASE=""
SECURE_BOOT=0
BUILD_IMAGES=1
PASSWORD="${FIEND_PASSWORD:-Passw0rd}"
DRY_RUN=0

usage() {
    cat >&2 <<'EOF'
usage: redeploy-fiend.sh [options]

  --distro NAME          fedora (default), debian, rocky, centos, ubuntu, arch
  --profile NAME         desktop (default), server, kvm, core
  --template NAME        klab, k8s, zfslab, devops, ai, kvm   (unset = zfslab
                         defaults apply, which means ZERO k8s workers)
  --control-planes N     default: the installer's own default of 3
  --workers N            default: whatever the template implies
  --encrypt              encrypt the pool (requires --passphrase)
  --passphrase TEXT      ZFS passphrase; stored in clear in the seed AND on
                         the installed system at /etc/kldload/zfs-passphrase
  --secure-boot          prepare shim/MOK on the target (see Notes in header)
  --build-images         build every golden, klab image and appliance
  --no-build-images      do NOT build them (the default in this copy is ON)
  --password TEXT        admin password (default Passw0rd)
  --netdev MAC|none      NIC that downloads the root image (default: the X540
                         10G, a0:36:9f:9f:10:1c); none = no pin
  --dry-run              print the answers file and stop, arming nothing
  --status               show what is armed, then exit
  --disarm               remove fiend's token, then exit
  -h, --help             this

examples:
  redeploy-fiend.sh --template klab --workers 3
  redeploy-fiend.sh --encrypt --passphrase hunter2 --secure-boot --build-images
  redeploy-fiend.sh --disarm
EOF
}

die() {
    printf '\n  FATAL: %s\n\n' "$*" >&2
    exit 1
}

# A temp file for the answers, cleaned up whichever way this exits.
TMP_ANSWERS="$(mktemp)"
trap 'rm -f "$TMP_ANSWERS"' EXIT
say() { printf '  %s\n' "$*"; }

server() { sudo kldload-netboot-server "$@"; }

while (($#)); do
    case "$1" in
    --distro) DISTRO="${2:?--distro needs a value}" && shift 2 ;;
    --profile) PROFILE="${2:?--profile needs a value}" && shift 2 ;;
    --template) TEMPLATE="${2:?--template needs a value}" && shift 2 ;;
    --control-planes) CONTROL_PLANES="${2:?--control-planes needs a number}" && shift 2 ;;
    --workers) WORKERS="${2:?--workers needs a number}" && shift 2 ;;
    --passphrase) PASSPHRASE="${2:?--passphrase needs a value}" && shift 2 ;;
    --password) PASSWORD="${2:?--password needs a value}" && shift 2 ;;
    --encrypt) ENCRYPT=1 && shift ;;
    --secure-boot) SECURE_BOOT=1 && shift ;;
    --build-images) BUILD_IMAGES=1 && shift ;;
    # Needed because the DEFAULT is 1 in this copy: without an off switch
    # there is no way to ask for an install that does not spend its first
    # boot building five goldens and an appliance catalog.
    --no-build-images) BUILD_IMAGES=0 && shift ;;
    --netdev) NETDEV="${2:?--netdev needs a MAC or none}" && shift 2 ;;
    --dry-run) DRY_RUN=1 && shift ;;
    --status)
        server status
        exit 0
        ;;
    --disarm)
        server disarm "$MAC"
        server status | tail -2
        exit 0
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
    esac
done

# Encryption without a passphrase fails INSIDE the installer, minutes in, on a
# machine whose disk is already partitioned. Catch it here instead.
((ENCRYPT == 0)) || [[ -n "$PASSPHRASE" ]] ||
    die "--encrypt needs --passphrase; the installer aborts without it, after partitioning"

{
    printf '# fiend — generated by redeploy-fiend.sh on %s\n' "$(date -Is)"
    printf '# Regenerated on every run. Edit the script, not this file.\n'
    printf 'KLDLOAD_DISTRO=%s\n' "$DISTRO"
    printf 'KLDLOAD_PROFILE=%s\n' "$PROFILE"
    printf 'KLDLOAD_DISK=%s\n' "$DISK"
    printf 'KLDLOAD_HOSTNAME=fiend\n'
    printf 'KLDLOAD_USERNAME=admin\n'
    printf 'KLDLOAD_PASSWORD=%s\n' "$PASSWORD"
    printf 'KLDLOAD_TIMEZONE=America/Vancouver\n'
    printf 'KLDLOAD_LOCALE=en_US.UTF-8\n'
    printf 'KLDLOAD_ENABLE_ZFS=1\n'
    printf 'KLDLOAD_ZFS_ENCRYPT=%s\n' "$ENCRYPT"
    [[ -n "$PASSPHRASE" ]] && printf 'KLDLOAD_ZFS_PASSPHRASE=%s\n' "$PASSPHRASE"
    printf 'KLDLOAD_ENABLE_SECURE_BOOT=%s\n' "$SECURE_BOOT"
    printf 'KLDLOAD_BUILD_IMAGES=%s\n' "$BUILD_IMAGES"
    [[ -n "$TEMPLATE" ]] && printf 'KLDLOAD_TEMPLATE=%s\n' "$TEMPLATE"
    [[ -n "$CONTROL_PLANES" ]] && printf 'KLDLOAD_K8S_CONTROL_PLANES=%s\n' "$CONTROL_PLANES"
    [[ -n "$WORKERS" ]] && printf 'KLDLOAD_K8S_WORKERS=%s\n' "$WORKERS"
    printf 'KLDLOAD_KEEP_NETBOOT=1\n'
} >"$TMP_ANSWERS"

if ((DRY_RUN)); then
    echo
    grep -vE '^\s*#' "$TMP_ANSWERS" | sed 's/^/    /'
    echo
    say "dry run — nothing written, nothing armed"
    exit 0
fi

# Written as a temp file then installed with sudo: the answers file is
# root-owned (arm-install and earlier installs created it), so a plain
# redirect dies with "Permission denied" AFTER the heredoc has already run.
sudo install -m 0644 "$TMP_ANSWERS" "$ANSWERS" ||
    die "could not write $ANSWERS"
say "answers: $ANSWERS"

# The server has to be up BEFORE arming, or the token lands in a tree nobody
# serves and the machine boots locally with no clue why.
systemctl is-active --quiet kldload-netboot.service ||
    die "kldload-netboot.service is not running — start it before arming"

[[ "$NETDEV" == none ]] && NETDEV=""
server arm-install "$MAC" "$ANSWERS" ${NETDEV:+--netdev "$NETDEV"} >/dev/null ||
    die "arm-install failed"

# Outcome, not exit code: fetch what fiend will fetch. A token that exists on
# disk but 403s or 404s over HTTP is the failure that cost an afternoon
# (2026-09-12: initrd.img was mode 0600 and iPXE reported the 403 as
# "Operation not permitted", which reads exactly like a dead NIC).
BASE="$(sudo sed -n 's/^NETBOOT_PORT=/port=/p;s/^NETBOOT_IFACE=/iface=/p' /etc/kldload/netboot.env 2>/dev/null || true)"
PORT="$(sed -n 's/^port=//p' <<<"$BASE")"
PORT="${PORT:-8080}"
IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
M="$(tr 'A-Z:' 'a-z-' <<<"$MAC")"
for path in "armed/${M}.ipxe" "answers/${M}.env" kldload/vmlinuz kldload/initrd.img kldload/squashfs.img; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -r 0-0 "http://${IP}:${PORT}/${path}")"
    [[ "$code" == 206 || "$code" == 200 ]] ||
        die "http://${IP}:${PORT}/${path} returned ${code} — fiend would fail here"
done
say "verified: every file fiend needs answers over HTTP"
if [[ -n "$NETDEV" ]]; then
    ND="$(tr 'A-Z:' 'a-z-' <<<"$NETDEV")"
    curl -s --max-time 10 "http://${IP}:${PORT}/armed/${M}.ipxe" | grep -q "BOOTIF=01-${ND}\b" ||
        die "the armed boot line does not pin the download to ${NETDEV}"
    say "verified: the boot line pins the download to ${NETDEV}"
fi

echo
say "fiend will install: ${DISTRO}/${PROFILE}"
say "  disk       ${DISK}"
say "  boots on   ${MAC}, downloads over ${NETDEV:-<whichever NIC routes first>}"
say "  encrypted  $((ENCRYPT)) $([[ $ENCRYPT == 1 ]] && echo '(passphrase in the seed AND on the target)')"
say "  secureboot $((SECURE_BOOT)) $([[ $SECURE_BOOT == 1 ]] && echo '(turn it on in firmware AFTER; netboot needs it OFF)')"
say "  images     $((BUILD_IMAGES))"
say "  cluster    template=${TEMPLATE:-<none, zfslab defaults: 0 workers>} cp=${CONTROL_PLANES:-3} workers=${WORKERS:-<template default>}"
echo
say "now netboot fiend from its one-time boot menu."
say "when it finishes:  $0 --disarm"
