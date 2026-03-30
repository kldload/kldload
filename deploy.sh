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
KVM_VMS="${KVM_VMS:-1}"

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

cmd_build_alpine_darksite() {
    local runtime
    runtime="$(detect_runtime)"
    local darksite_dir="$ROOT/live-build/darksite-alpine-cache"
    mkdir -p "$darksite_dir"
    log "Building Alpine Linux darksite apk cache (runs in Alpine container)..."
    "$runtime" run --rm \
        -v "$ROOT/build/darksite-alpine:/darksite-build:z,ro" \
        -v "$darksite_dir:/output:z" \
        -e ARCH="x86_64" \
        --name "kldload-darksite-alpine-$$" \
        alpine:latest \
        sh /darksite-build/build-darksite-alpine.sh
    log "Alpine darksite ready: $(du -sh "$darksite_dir" | cut -f1)"
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

cmd_build_ai_docs() {
    local ai_dir="$ROOT/live-build/config/includes.chroot/usr/local/share/kldload-ai"
    local web_dir="${KLDLOAD_WEB_DIR:-/root/kldload-web}"
    mkdir -p "$ai_dir"

    log "Building AI knowledge base..."

    # Step 1: Scrape kldload-web HTML to text
    if [[ -d "$web_dir" ]]; then
        log "Scraping ${web_dir} HTML pages..."
        local _docs="$ai_dir/kldload-docs.txt"
        : > "$_docs"
        find "$web_dir" -name '*.html' -not -path '*node_modules*' -not -path '*.git*' -not -path '*assets*' | sort | while read -r _f; do
            local _rel="${_f#${web_dir}/}"
            echo "=== ${_rel} ===" >> "$_docs"
            perl -0777 -pe 's/<script[^>]*>.*?<\/script>//gsi; s/<style[^>]*>.*?<\/style>//gsi; s/<[^>]+>//g; s/&nbsp;/ /g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&mdash;/—/g; s/&ndash;/–/g; s/&rsquo;/'"'"'/g; s/&lsquo;/'"'"'/g; s/&rdquo;/"/g; s/&ldquo;/"/g; s/&rarr;/→/g; s/&bull;/•/g; s/&#\d+;//g; s/^\s*$//gm' "$_f" >> "$_docs" 2>/dev/null
            echo "" >> "$_docs"
        done
        local _pages _size
        _pages=$(grep -c '^===' "$_docs")
        _size=$(du -sh "$_docs" | cut -f1)
        log "Site scrape: ${_pages} pages, ${_size}"
    else
        log "WARNING: kldload-web not found at ${web_dir} — skipping site scrape"
    fi

    # Step 2: OCR the PDF manual if available
    local _pdf
    _pdf=$(ls "$web_dir"/kldloadOS-documentation-*.pdf 2>/dev/null | sort -V | tail -1)
    if [[ -n "$_pdf" ]] && command -v ocrmypdf >/dev/null 2>&1; then
        log "OCR'ing $(basename "$_pdf")..."
        ocrmypdf --force-ocr "$_pdf" /tmp/kldload-docs-ocr.pdf 2>&1 | tail -3
        pdftotext /tmp/kldload-docs-ocr.pdf "$ai_dir/kldload-manual.txt" 2>&1
        rm -f /tmp/kldload-docs-ocr.pdf
        local _lines
        _lines=$(wc -l < "$ai_dir/kldload-manual.txt")
        log "PDF OCR: ${_lines} lines -> kldload-manual.txt"
    elif [[ -n "$_pdf" ]]; then
        # Fallback: pdftotext without OCR
        log "No ocrmypdf — trying pdftotext directly on $(basename "$_pdf")..."
        pdftotext "$_pdf" "$ai_dir/kldload-manual.txt" 2>&1
        log "PDF text: $(wc -l < "$ai_dir/kldload-manual.txt") lines"
    else
        log "No PDF manual found — skipping"
    fi

    log "AI docs ready: $(du -sh "$ai_dir" | cut -f1)"
    ls -lh "$ai_dir/"
}

cmd_build_ai_appliance() {
    local answers_src="$ROOT/live-build/config/includes.chroot/etc/kldload/debz/answers/ai-appliance.env"
    local answers_dst="$ROOT/live-build/config/includes.chroot/etc/kldload/autoinstall.env"
    [[ -f "$answers_src" ]] || die "Answers file not found: $answers_src"
    cp "$answers_src" "$answers_dst"
    log "AI appliance mode: baked autoinstall.env into ISO"
    log "  On boot: auto-detects disk, wipes, installs CentOS + Ollama + Open WebUI"
    PROFILE=desktop cmd_build
    log "AI appliance ISO ready — boot it, walk away, come back to a working AI box"
    rm -f "$answers_dst"  # clean up so normal builds aren't affected
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

        # Arch darksite disabled — Arch rolling release causes version drift.
        # Arch installs require internet (pulls from live mirrors + archzfs).
        log "Arch darksite: not available (internet required for Arch installs)"

        local alpine_darksite="$ROOT/live-build/darksite-alpine-cache"
        if [[ ! -d "$alpine_darksite/apk" ]] || [[ "$(find "$alpine_darksite/apk" -name '*.apk' -not -name 'APKINDEX*' 2>/dev/null | wc -l)" -eq 0 ]]; then
            cmd_build_alpine_darksite
        else
            log "Alpine darksite cached: $(du -sh "$alpine_darksite" | cut -f1)"
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

    # Shut down any existing kldload-test VMs first
    for _i in $(seq 1 10); do
        local _existing="kldload-test-${_i}"
        if virsh domstate "$_existing" 2>/dev/null | grep -q running; then
            log "Shutting down ${_existing}..."
            virsh destroy "$_existing" 2>/dev/null || true
        fi
    done

    for _i in $(seq 1 "$KVM_VMS"); do
        local _name="kldload-test-${_i}"
        local _disk="/var/lib/libvirt/images/${_name}.qcow2"

        log "Deploying ${_name}..."
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

cmd_kvm_deploy_bob() {
    local iso
    iso="$(latest_iso)"
    [[ -n "$iso" ]] || die "No ISO found — run build-ai-appliance first"

    cp "$iso" /var/lib/libvirt/images/kldload-bob.iso
    chown qemu:qemu /var/lib/libvirt/images/kldload-bob.iso

    local _name="bob-1"
    local _disk="/var/lib/libvirt/images/${_name}.qcow2"

    if virsh domstate "$_name" 2>/dev/null | grep -q running; then
        log "Shutting down ${_name}..."
        virsh destroy "$_name" 2>/dev/null || true
    fi

    log "Deploying ${_name}..."
    virsh undefine "$_name" --nvram --remove-all-storage 2>/dev/null || true
    rm -f "$_disk" 2>/dev/null || true

    qemu-img create -f qcow2 "$_disk" "${VM_DISK_GB}G"
    chown qemu:qemu "$_disk"

    virt-install --name "$_name" --ram "$VM_MEMORY" --vcpus "$VM_CORES" \
        --disk "path=${_disk},format=qcow2,bus=virtio" \
        --cdrom /var/lib/libvirt/images/kldload-bob.iso \
        --os-variant centos-stream9 --network network=default,model=virtio \
        --graphics vnc,listen=0.0.0.0 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --noautoconsole --noreboot

    log "${_name} ready (off) — VNC $(virsh vncdisplay "$_name" 2>/dev/null || echo '?')"
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
    build-ai-appliance) cmd_build_ai_appliance ;;
    build-debian-darksite) cmd_build_debian_darksite ;;
    build-bsd-darksite)    bash build/darksite-bsd/build-darksite-bsd.sh "$ROOT/live-build/darksite-bsd-cache" ;;
    build-ubuntu-darksite) cmd_build_ubuntu_darksite ;;
    build-arch-darksite) cmd_build_arch_darksite ;;
    build-alpine-darksite) cmd_build_alpine_darksite ;;
    build-fedora-darksite) cmd_build_fedora_darksite ;;
    build-ai-docs)      cmd_build_ai_docs ;;
    builder-image)      cmd_builder_image ;;
    clean)              cmd_clean ;;
    burn)               cmd_burn ;;
    full)               cmd_full ;;
    kvm-deploy)         cmd_kvm_deploy ;;
    kvm-deploy-bob)     cmd_kvm_deploy_bob ;;
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
        echo "  build-ai-appliance    Build unattended AI appliance ISO (Ollama + Open WebUI)"
        echo "  build-ai-docs         Scrape site + OCR PDF for AI knowledge base"
        echo "  build-alpine-darksite Rebuild Alpine apk darksite cache"
        echo "  build-debian-darksite Rebuild Debian APT darksite cache"
        echo "  builder-image         Rebuild the container builder image"
        echo "  clean                 Remove build artifacts"
        echo "  burn                  Write ISO to USB (USB_DEVICE=/dev/sda)"
        echo "  kvm-deploy            Deploy ISO to local KVM (virsh)"
        echo "  kvm-deploy-bob        Deploy Bob AI appliance to KVM (off)"
        echo "  proxmox-deploy        Deploy ISO to Proxmox (VMID=$VMID)"
        echo "  deploy-all            Deploy to KVM + Proxmox + print USB command"
        echo ""
        echo "Environment:"
        echo "  PROFILE         desktop | server (default: desktop)"
        echo "  RELEASE         CentOS release (default: 9)"
        echo "  USB_DEVICE      USB block device for burn (default: /dev/sda)"
        ;;
esac
