#!/usr/bin/env bash
set -euo pipefail

# kldload deploy.sh — build + deploy CentOS/Rocky ZFS live ISO

ROOT="$(dirname "$(realpath "$0")")"

[[ -f "$ROOT/kldload.env" ]] && source "$ROOT/kldload.env"

PROFILE="${PROFILE:-desktop}"
EDITION="free"
ARCH="${ARCH:-x86_64}"
RELEASE="${RELEASE:-9}"
BUILDER_IMAGE="${BUILDER_IMAGE:-kldload-live-builder:latest}"
BUILDER_CONTAINER="${BUILDER_CONTAINER:-kldload-free-build-$$}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/live-build/output}"
LOG_DIR="${LOG_DIR:-$ROOT/live-build/logs}"

PROXMOX_HOST="${PROXMOX_HOST:-10.100.10.225}"
PROXMOX_NODE="${PROXMOX_NODE:-fiend}"
PROXMOX_TOKEN_ID="${PROXMOX_TOKEN_ID:-}"
PROXMOX_TOKEN_SECRET="${PROXMOX_TOKEN_SECRET:-}"

VMID="${VMID:-902}"
VM_NAME="${VM_NAME:-kldload-free}"
VM_MEMORY="${VM_MEMORY:-4096}"
VM_CORES="${VM_CORES:-4}"
VM_DISK_GB="${VM_DISK_GB:-40}"
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"

USB_DEVICE="${USB_DEVICE:-}"
USB_BURN_ON_DEPLOY="${USB_BURN_ON_DEPLOY:-no}"

log() { printf '[%s] [deploy] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

detect_runtime() {
    if command -v podman &>/dev/null; then echo podman
    elif command -v docker &>/dev/null; then echo docker
    else die "No container runtime found (need docker or podman)"; fi
}

latest_iso() {
    find "$OUTPUT_DIR" -maxdepth 1 -name '*.iso' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-
}

# ── Subcommands ───────────────────────────────────────────────────────────────

cmd_builder_image() {
    local runtime
    runtime="$(detect_runtime)"
    log "Building kldload builder image: $BUILDER_IMAGE"
    "$runtime" build -t "$BUILDER_IMAGE" -f "$ROOT/builder/Dockerfile" "$ROOT/builder/"
    log "Builder image ready: $BUILDER_IMAGE"
}

cmd_build() {
    local runtime
    runtime="$(detect_runtime)"
    log "Building kldload ISO (PROFILE=$PROFILE ARCH=$ARCH RELEASE=$RELEASE)"

    "$runtime" run --rm --privileged \
        -v "$ROOT:/build:z" \
        -e PROFILE="$PROFILE" \
        -e EDITION="$EDITION" \
        -e ARCH="$ARCH" \
        -e RELEASE="$RELEASE" \
        --name "$BUILDER_CONTAINER" \
        "$BUILDER_IMAGE" \
        bash /build/builder/build-iso.sh

    local iso
    iso="$(latest_iso)"
    if [[ -n "$iso" ]]; then
        log "ISO built: $iso ($(du -sh "$iso" | cut -f1))"
        sha256sum "$iso" > "${iso}.sha256"
    else
        die "No ISO found after build"
    fi
}

cmd_clean() {
    log "Cleaning build artifacts..."
    rm -rf "$ROOT/live-build/chroot" "$ROOT/live-build/binary" "$ROOT/live-build/.build"
    rm -rf "$OUTPUT_DIR"
    log "Clean complete"
}

cmd_burn() {
    local iso
    iso="$(latest_iso)"
    [[ -n "$iso" ]] || die "No ISO found"

    if [[ -z "$USB_DEVICE" ]]; then
        local candidates=()
        while IFS= read -r dev; do
            local rm_flag
            rm_flag="$(cat "/sys/block/$(basename "$dev")/removable" 2>/dev/null || echo 0)"
            [[ "$rm_flag" == "1" ]] && candidates+=("$dev")
        done < <(find /dev -maxdepth 1 -name 'sd[a-z]' | sort)
        [[ "${#candidates[@]}" -eq 1 ]] || die "Set USB_DEVICE explicitly"
        USB_DEVICE="${candidates[0]}"
    fi

    log "Burning $iso to $USB_DEVICE..."
    dd if="$iso" of="$USB_DEVICE" bs=4M status=progress oflag=sync conv=fsync
    sync
    log "USB burn complete: $USB_DEVICE"
}

cmd_full() {
    local runtime
    runtime="$(detect_runtime)"
    log "=== FULL: clean + rebuild + build ISO ==="
    cmd_clean
    if "$runtime" image inspect "$BUILDER_IMAGE" &>/dev/null; then
        "$runtime" rmi "$BUILDER_IMAGE" || true
    fi
    cmd_builder_image
    cmd_build
    if [[ "$USB_BURN_ON_DEPLOY" == "yes" ]]; then
        cmd_burn
    fi
    log "=== FULL complete ==="
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${1:-help}" in
    build)          cmd_build ;;
    builder-image)  cmd_builder_image ;;
    clean)          cmd_clean ;;
    burn)           cmd_burn ;;
    full)           cmd_full ;;
    help|*)
        echo "kldload deploy.sh — CentOS/Rocky ZFS live ISO builder"
        echo ""
        echo "Usage: ./deploy.sh <command>"
        echo ""
        echo "Commands:"
        echo "  full            Clean + rebuild builder + build ISO + burn"
        echo "  build           Build ISO only"
        echo "  builder-image   Rebuild the container builder image"
        echo "  clean           Remove build artifacts"
        echo "  burn            Write ISO to USB (USB_DEVICE=/dev/sdX)"
        echo ""
        echo "Environment:"
        echo "  PROFILE         desktop | server (default: desktop)"
        echo "  RELEASE         CentOS release (default: 9)"
        echo "  USB_DEVICE      USB block device for burn"
        ;;
esac
