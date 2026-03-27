#!/usr/bin/env bash
set -euo pipefail

# kldload deploy.sh — build + deploy CentOS/Rocky ZFS live ISO

ROOT="$(dirname "$(realpath "$0")")"

[[ -f "$ROOT/kldload.env" ]] && source "$ROOT/kldload.env"

PROFILE="${PROFILE:-desktop}"
EDITION="${EDITION:-free}"
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
VM_MEMORY="${VM_MEMORY:-16384}"
VM_CORES="${VM_CORES:-4}"
VM_DISK_GB="${VM_DISK_GB:-80}"
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"

USB_DEVICE="${USB_DEVICE:-/dev/sda}"
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

cmd_build_debian_darksite() {
    local runtime
    runtime="$(detect_runtime)"
    local darksite_dir="$ROOT/live-build/darksite-debian-cache"
    mkdir -p "$darksite_dir"
    log "Building Debian darksite APT mirror (runs in Debian container)..."
    "$runtime" run --rm \
        -v "$ROOT/build/darksite-debian:/darksite-build:z,ro" \
        -v "$darksite_dir:/output:z" \
        -e PROFILE="$PROFILE" \
        -e ARCH="amd64" \
        -e SUITE="trixie" \
        --name "kldload-darksite-deb-$$" \
        debian:trixie-slim \
        bash -c "apt-get update -qq && apt-get install -y -qq dpkg-dev curl >/dev/null 2>&1 && bash /darksite-build/build-darksite-debian.sh"
    log "Debian darksite ready: $(du -sh "$darksite_dir" | cut -f1)"
}

cmd_build_ubuntu_darksite() {
    local runtime
    runtime="$(detect_runtime)"
    local darksite_dir="$ROOT/live-build/darksite-ubuntu-cache"
    mkdir -p "$darksite_dir"
    log "Building Ubuntu darksite APT mirror (runs in Ubuntu container)..."
    "$runtime" run --rm \
        -v "$ROOT/build/darksite-debian:/darksite-build:z,ro" \
        -v "$ROOT/build/darksite-ubuntu:/darksite-ubuntu:z,ro" \
        -v "$darksite_dir:/output:z" \
        -e PROFILE="$PROFILE" \
        -e ARCH="amd64" \
        -e SUITE="noble" \
        --name "kldload-darksite-ubuntu-$$" \
        ubuntu:noble \
        bash -c "apt-get update -qq && apt-get install -y -qq dpkg-dev curl >/dev/null 2>&1 && PKG_SETS_DIR=/darksite-ubuntu/config/package-sets bash /darksite-build/build-darksite-debian.sh"
    log "Ubuntu darksite ready: $(du -sh "$darksite_dir" | cut -f1)"
}

cmd_build_arch_darksite() {
    local runtime
    runtime="$(detect_runtime)"
    local darksite_dir="$ROOT/live-build/darksite-arch-cache"
    mkdir -p "$darksite_dir"
    log "Building Arch Linux darksite pacman cache (runs in Arch container)..."
    "$runtime" run --rm \
        -v "$ROOT/build/darksite-arch:/darksite-build:z,ro" \
        -v "$darksite_dir:/output:z" \
        -e PROFILE="$PROFILE" \
        -e ARCH="x86_64" \
        --name "kldload-darksite-arch-$$" \
        archlinux:latest \
        bash /darksite-build/build-darksite-arch.sh
    log "Arch darksite ready: $(du -sh "$darksite_dir" | cut -f1)"
}

cmd_build_fedora_darksite() {
    local runtime
    runtime="$(detect_runtime)"
    local darksite_dir="$ROOT/live-build/darksite-fedora-cache"
    mkdir -p "$darksite_dir"
    log "Building Fedora darksite RPM mirror (runs in Fedora container)..."
    "$runtime" run --rm \
        -v "$ROOT/build/darksite-fedora:/darksite-build:z,ro" \
        -v "$darksite_dir:/output:z" \
        -e PROFILE="$PROFILE" \
        -e ARCH="x86_64" \
        -e FEDORA_RELEASE="41" \
        --name "kldload-darksite-fedora-$$" \
        fedora:41 \
        bash /darksite-build/build-darksite-fedora.sh
    log "Fedora darksite ready: $(du -sh "$darksite_dir" | cut -f1)"
}

cmd_build() {
    local runtime
    runtime="$(detect_runtime)"
    log "Building kldload ISO (PROFILE=$PROFILE EDITION=$EDITION ARCH=$ARCH RELEASE=$RELEASE)"

    # Build APT darksites if not already cached (free edition only)
    if [[ "$EDITION" != "core" ]]; then
        local debian_darksite="$ROOT/live-build/darksite-debian-cache"
        if [[ ! -f "$debian_darksite/apt/dists/trixie/Release" ]]; then
            cmd_build_debian_darksite
        else
            log "Debian darksite cached: $(du -sh "$debian_darksite" | cut -f1)"
        fi

        local ubuntu_darksite="$ROOT/live-build/darksite-ubuntu-cache"
        if [[ ! -f "$ubuntu_darksite/apt/dists/noble/Release" ]]; then
            cmd_build_ubuntu_darksite
        else
            log "Ubuntu darksite cached: $(du -sh "$ubuntu_darksite" | cut -f1)"
        fi

        local arch_darksite="$ROOT/live-build/darksite-arch-cache"
        if [[ ! -d "$arch_darksite/pkg" ]] || [[ "$(find "$arch_darksite/pkg" -name '*.pkg.tar.*' 2>/dev/null | wc -l)" -eq 0 ]]; then
            cmd_build_arch_darksite
        else
            log "Arch darksite cached: $(du -sh "$arch_darksite" | cut -f1)"
        fi

        local fedora_darksite="$ROOT/live-build/darksite-fedora-cache"
        if [[ ! -d "$fedora_darksite/rpm" ]] || [[ "$(find "$fedora_darksite/rpm" -name '*.rpm' 2>/dev/null | wc -l)" -eq 0 ]]; then
            cmd_build_fedora_darksite
        else
            log "Fedora darksite cached: $(du -sh "$fedora_darksite" | cut -f1)"
        fi
    else
        log "Core edition — skipping darksites."
    fi

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
    local iso
    iso="$(latest_iso)"
    if [[ -n "$iso" ]]; then
        log ""
        log "USB burn command:"
        log "  dd if=$iso of=/dev/sda bs=4M status=progress oflag=sync conv=fsync && sync"
    fi
    log "=== FULL complete ==="
}

cmd_kvm_deploy() {
    local iso
    iso="$(latest_iso)"
    [[ -n "$iso" ]] || die "No ISO found — run build first"

    cp "$iso" /var/lib/libvirt/images/kldload-free-latest.iso
    chown qemu:qemu /var/lib/libvirt/images/kldload-free-latest.iso

    for _name in kldload-test-1 kldload-test-2; do
        local _disk="/var/lib/libvirt/images/${_name}.qcow2"

        log "Deploying ${_name}..."
        virsh destroy "$_name" 2>/dev/null || true
        virsh undefine "$_name" --nvram --remove-all-storage 2>/dev/null || true
        rm -f "$_disk" 2>/dev/null || true

        qemu-img create -f qcow2 "$_disk" "${VM_DISK_GB}G"
        chown qemu:qemu "$_disk"

        virt-install --name "$_name" --ram "$VM_MEMORY" --vcpus "$VM_CORES" \
            --disk "path=${_disk},format=qcow2,bus=virtio" \
            --cdrom /var/lib/libvirt/images/kldload-free-latest.iso \
            --os-variant centos-stream9 --network network=default,model=virtio \
            --graphics vnc,listen=0.0.0.0 \
            --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
            --noautoconsole

        log "${_name} ready — VNC $(virsh vncdisplay "$_name" 2>/dev/null || echo '?') — DHCP"
    done
}

cmd_proxmox_deploy() {
    local iso
    iso="$(latest_iso)"
    [[ -n "$iso" ]] || die "No ISO found — run build first"
    [[ -n "$PROXMOX_HOST" ]] || die "PROXMOX_HOST not set"
    log "Deploying to Proxmox ($PROXMOX_HOST VMID=$VMID)..."
    scp "$iso" "root@${PROXMOX_HOST}:/var/lib/vz/template/iso/kldload-free-latest.iso"
    ssh "root@${PROXMOX_HOST}" bash -s "$VMID" "$VM_MEMORY" "$VM_CORES" "$VM_DISK_GB" <<'PVESH'
        VMID="$1" VMEM="$2" VCORES="$3" VDISK="$4"
        qm stop "$VMID" 2>/dev/null; sleep 1
        qm destroy "$VMID" --purge 2>/dev/null; sleep 1
        qm create "$VMID" --name kldload-free --memory "$VMEM" --cores "$VCORES" \
            --sockets 1 --cpu host --machine q35 --ostype l26 --bios ovmf \
            --efidisk0 local-zfs:4,efitype=4m,pre-enrolled-keys=0 \
            --scsihw virtio-scsi-single --scsi0 "local-zfs:${VDISK}" \
            --net0 virtio,bridge=vmbr0 --serial0 socket --agent 1 --vga std \
            --ide2 local:iso/kldload-free-latest.iso,media=cdrom \
            --boot 'order=ide2;scsi0'
        qm set "$VMID" --tpmstate0 local-zfs:4,version=v2.0
        qm start "$VMID"
PVESH
    log "Proxmox VM $VMID started on $PROXMOX_HOST"
}

cmd_deploy_all() {
    cmd_kvm_deploy
    cmd_proxmox_deploy
    log ""
    log "Both VMs deployed. USB burn command:"
    local iso; iso="$(latest_iso)"
    log "  dd if=$iso of=/dev/sda bs=4M status=progress oflag=sync conv=fsync && sync"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${1:-help}" in
    build)              cmd_build ;;
    build-debian-darksite) cmd_build_debian_darksite ;;
    build-bsd-darksite)    bash build/darksite-bsd/build-darksite-bsd.sh "$ROOT/live-build/darksite-bsd-cache" ;;
    build-ubuntu-darksite) cmd_build_ubuntu_darksite ;;
    build-arch-darksite) cmd_build_arch_darksite ;;
    build-fedora-darksite) cmd_build_fedora_darksite ;;
    builder-image)      cmd_builder_image ;;
    clean)              cmd_clean ;;
    burn)               cmd_burn ;;
    full)               cmd_full ;;
    kvm-deploy)         cmd_kvm_deploy ;;
    proxmox-deploy)     cmd_proxmox_deploy ;;
    deploy-all)         cmd_deploy_all ;;
    help|*)
        echo "kldload deploy.sh — multi-distro ZFS live ISO builder"
        echo ""
        echo "Usage: ./deploy.sh <command>"
        echo ""
        echo "Commands:"
        echo "  full                  Clean + rebuild builder + build ISO"
        echo "  build                 Build ISO only (caches Debian darksite)"
        echo "  build-debian-darksite Rebuild Debian APT darksite cache"
        echo "  builder-image         Rebuild the container builder image"
        echo "  clean                 Remove build artifacts"
        echo "  burn                  Write ISO to USB (USB_DEVICE=/dev/sda)"
        echo "  kvm-deploy            Deploy ISO to local KVM (virsh)"
        echo "  proxmox-deploy        Deploy ISO to Proxmox (VMID=$VMID)"
        echo "  deploy-all            Deploy to KVM + Proxmox + print USB command"
        echo ""
        echo "Environment:"
        echo "  PROFILE         desktop | server (default: desktop)"
        echo "  RELEASE         CentOS release (default: 9)"
        echo "  USB_DEVICE      USB block device for burn (default: /dev/sda)"
        ;;
esac
