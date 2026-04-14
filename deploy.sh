#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — kldloadOS build + deploy pipeline
#
# This is the single entry point for building kldloadOS ISOs and deploying
# them to KVM, Proxmox, or USB. It auto-detects podman or docker and runs
# all heavy work inside containers.
#
# The build pipeline has 5 stages (all containerized):
#   1. Builder image   — CentOS 9 container with lorax, squashfs, xorriso
#   2. Debian darksite — APT mirror for offline Debian installs (cached)
#   3. Ubuntu darksite — APT mirror for offline Ubuntu installs (cached)
#   4. RPM darksite    — built inside the builder container (CentOS/Rocky/RHEL)
#   5. ISO assembly    — rootfs via dnf, ZFS DKMS, darksites, squashfs, EFI, xorriso
#
# Quick reference:
#   ./deploy.sh build                  # incremental build (skips cached darksites)
#   ./deploy.sh clean && ./deploy.sh build   # full rebuild
#   PROFILE=server ./deploy.sh build   # build with a different profile
#
# See "Environment" section in help output for all configurable variables.
# ─────────────────────────────────────────────────────────────────────────────

ROOT="$(dirname "$(realpath "$0")")"

# Source project-level overrides (PROFILE, EDITION, PROXMOX_HOST, etc.)
[[ -f "$ROOT/kldload.env" ]] && source "$ROOT/kldload.env"

# ── Build configuration ──────────────────────────────────────────────────────
# These control what gets built. Override via environment or kldload.env.
PROFILE="${PROFILE:-desktop}"       # Install profile: desktop, server, kvm, ai, core
EDITION="${EDITION:-free}"          # Edition: free (full) or core (ZFS-only, no tools)
ARCH="${ARCH:-x86_64}"             # Target architecture
RELEASE="${RELEASE:-9}"            # CentOS Stream release version
BUILDER_IMAGE="${BUILDER_IMAGE:-kldload-live-builder:latest}"   # Builder container image tag
BUILDER_CONTAINER="${BUILDER_CONTAINER:-kldload-free-build-$$}" # Builder container name (unique per run)
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/live-build/output}"              # Where the ISO lands
LOG_DIR="${LOG_DIR:-$ROOT/live-build/logs}"                      # Build logs

# ── Proxmox deployment ───────────────────────────────────────────────────────
# Used by proxmox-deploy. Set in kldload.env or environment.
PROXMOX_HOST="${PROXMOX_HOST:-10.100.10.225}"     # Proxmox host IP
PROXMOX_NODE="${PROXMOX_NODE:-fiend}"             # Proxmox node name
PROXMOX_TOKEN_ID="${PROXMOX_TOKEN_ID:-}"          # API token (optional — uses SSH if empty)
PROXMOX_TOKEN_SECRET="${PROXMOX_TOKEN_SECRET:-}"

# ── VM configuration ─────────────────────────────────────────────────────────
# Shared defaults for KVM and Proxmox VMs.
VMID="${VMID:-902}"                # Proxmox VM ID
VM_NAME="${VM_NAME:-kldload-free}" # VM display name
VM_MEMORY="${VM_MEMORY:-16384}"    # RAM in MB
VM_CORES="${VM_CORES:-4}"          # CPU cores
VM_DISK_GB="${VM_DISK_GB:-80}"     # Disk size in GB
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"    # Network bridge
KVM_VMS="${KVM_VMS:-1}"            # Number of KVM test VMs to create

# ── USB burn ─────────────────────────────────────────────────────────────────
USB_DEVICE="${USB_DEVICE:-/dev/sda}"       # Target USB block device
USB_BURN_ON_DEPLOY="${USB_BURN_ON_DEPLOY:-no}"  # Auto-burn after full build (yes/no)

# ── Helpers ──────────────────────────────────────────────────────────────────

log() { printf '[%s] [deploy] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"

# Auto-detect container runtime (podman preferred, docker fallback)
detect_runtime() {
    if command -v podman &>/dev/null; then echo podman
    elif command -v docker &>/dev/null; then echo docker
    else die "No container runtime found (need docker or podman)"; fi
}

# Find the most recently built ISO in the output directory
latest_iso() {
    find "$OUTPUT_DIR" -maxdepth 1 -name '*.iso' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-
}

# ─────────────────────────────────────────────────────────────────────────────
# Build commands
# ─────────────────────────────────────────────────────────────────────────────

# Build the CentOS 9 builder container image.
# This container has all the tools needed to assemble the ISO: lorax,
# squashfs-tools, xorriso, dracut, mtools, dnf, etc.
# Only needs to be rebuilt when builder/Dockerfile changes.
cmd_builder_image() {
    local runtime
    runtime="$(detect_runtime)"
    log "Building kldload builder image: $BUILDER_IMAGE"
    "$runtime" build -t "$BUILDER_IMAGE" -f "$ROOT/builder/Dockerfile" "$ROOT/builder/"
    log "Builder image ready: $BUILDER_IMAGE"
}

# Build the Debian APT offline mirror (darksite).
# Runs inside a debian:trixie-slim container to resolve and download all
# packages needed for a Debian 13 install. Cached at live-build/darksite-debian-cache/.
# Slow on first run (~20 min), instant if cache exists.
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

# Build the Ubuntu APT offline mirror (darksite).
# Same approach as Debian but runs in ubuntu:noble. Uses the Debian builder
# script with Ubuntu-specific package sets. Needs universe component for ZFS.
# Cached at live-build/darksite-ubuntu-cache/.
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

# Build the AI knowledge base for the local assistant.
# Scrapes kldload-web HTML pages to text and OCRs the PDF manual.
# Output goes to the ISO at /usr/local/share/kldload-ai/.
cmd_build_ai_docs() {
    local ai_dir="$ROOT/live-build/config/includes.chroot/usr/local/share/kldload-ai"
    local web_dir="${KLDLOAD_WEB_DIR:-/root/kldload-web}"
    mkdir -p "$ai_dir"

    log "Building AI knowledge base..."

    # Scrape kldload-web HTML to plain text
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

    # OCR the PDF manual if available
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
        log "No ocrmypdf — trying pdftotext directly on $(basename "$_pdf")..."
        pdftotext "$_pdf" "$ai_dir/kldload-manual.txt" 2>&1
        log "PDF text: $(wc -l < "$ai_dir/kldload-manual.txt") lines"
    else
        log "No PDF manual found — skipping"
    fi

    log "AI docs ready: $(du -sh "$ai_dir" | cut -f1)"
    ls -lh "$ai_dir/"
}

# Build the Bob AI appliance ISO.
# Self-contained live USB: boots into Ollama + Open WebUI + local LLM.
# No install step — just boot and chat.
cmd_build_ai_appliance() {
    log "Bob live mode: AI assistant starts on boot"
    log "  Boot USB → Ollama + Bob + Open WebUI → Firefox opens → ready to chat"
    BOB_LIVE=1 ISO_NAME_OVERRIDE="bob-${KLDLOAD_VERSION:-1.0.2}-${ARCH}.iso" PROFILE=desktop cmd_build
    log "Bob ISO ready: $ROOT/live-build/output/bob-${KLDLOAD_VERSION:-1.0.2}-${ARCH}.iso"
}

# Build the kldloadOS ISO.
# This is the main build command. It:
#   1. Builds APT darksites if not cached (Debian + Ubuntu)
#   2. Pre-pulls Kubernetes container images for offline K8s deployment
#   3. Caches the Cilium Helm chart
#   4. Runs build-iso.sh inside the builder container (privileged, for loopback/squashfs)
#   5. Outputs the ISO to live-build/output/
#
# The builder container runs detached to avoid SIGPIPE when stdout fills.
# On completion, the ISO and its SHA256 checksum are written to OUTPUT_DIR.
cmd_build() {
    local runtime
    runtime="$(detect_runtime)"
    log "Building kldload ISO (PROFILE=$PROFILE EDITION=$EDITION ARCH=$ARCH RELEASE=$RELEASE)"

    # ── Stage 1: APT darksites (Debian + Ubuntu) ─────────────────────────
    # Skip for core edition (no darksites needed — stock distro only)
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

        # Arch, Alpine, Fedora have no darksites:
        #   Arch = rolling release (no point caching)
        #   Alpine = partial apk cache only
        #   Fedora = separate RPM darksite built inside the builder container
        log "Note: Arch, Alpine, Fedora installs require internet (no offline darksite)"
    else
        log "Core edition — skipping darksites."
    fi

    # ── Stage 2: Kubernetes container images (offline K8s deployment) ─────
    # Pre-pulls all images needed by kubeadm, Cilium, MetalLB, etc.
    # so kube-cluster bootstrap works without internet.
    local k8s_images_dir="$ROOT/live-build/config/includes.chroot/root/darksite/k8s-images"
    local k8s_images_list="$ROOT/build/darksite/k8s-images.txt"
    if [[ -f "$k8s_images_list" ]] && [[ "$EDITION" != "core" ]]; then
        if [[ ! -d "$k8s_images_dir" ]] || [[ "$(find "$k8s_images_dir" -name '*.tar' 2>/dev/null | wc -l)" -eq 0 ]]; then
            log "Pre-pulling Kubernetes + Cilium container images for offline deploy..."
            bash "$ROOT/build/darksite/pull-k8s-images.sh" "$k8s_images_dir"
        else
            log "K8s images cached: $(du -sh "$k8s_images_dir" | cut -f1) ($(ls "$k8s_images_dir"/*.tar 2>/dev/null | wc -l) images)"
        fi
    fi

    # ── Stage 3: Cilium Helm chart ───────────────────────────────────────
    # Cached so kube-init can install Cilium without internet.
    local helm_cache="$ROOT/live-build/config/includes.chroot/root/darksite/helm-charts"
    if [[ ! -f "$helm_cache/cilium.tgz" ]] && [[ "$EDITION" != "core" ]]; then
        log "Caching Cilium Helm chart..."
        mkdir -p "$helm_cache"
        if command -v helm >/dev/null 2>&1; then
            helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
            helm repo update >/dev/null 2>&1 || true
            helm pull cilium/cilium --version "${CILIUM_VERSION:-1.16.5}" -d "$helm_cache" 2>/dev/null && \
                mv "$helm_cache"/cilium-*.tgz "$helm_cache/cilium.tgz" 2>/dev/null || true
        elif command -v curl >/dev/null 2>&1; then
            curl -fsSL "https://helm.cilium.io/cilium-${CILIUM_VERSION:-1.16.5}.tgz" \
                -o "$helm_cache/cilium.tgz" 2>/dev/null || log "WARNING: Could not cache Cilium chart"
        fi
        [[ -f "$helm_cache/cilium.tgz" ]] && log "Cilium chart cached: $(du -h "$helm_cache/cilium.tgz" | cut -f1)" || true
    fi

    # ── Stage 4: ISO assembly (runs inside builder container) ────────────
    # The builder container runs build-iso.sh which:
    #   - Bootstraps a CentOS 9 rootfs via dnf --installroot
    #   - Builds ZFS kernel modules via DKMS
    #   - Embeds all darksites (RPM, APT, K8s images, Helm charts)
    #   - Creates squashfs, EFI boot image, and final ISO via xorriso
    #
    # Runs detached to avoid SIGPIPE when stdout pipe fills up.
    "$runtime" run -d --privileged \
        -v "$ROOT:/build:z" \
        -e PROFILE="$PROFILE" \
        -e EDITION="$EDITION" \
        -e ARCH="$ARCH" \
        -e RELEASE="$RELEASE" \
        -e ISO_NAME_OVERRIDE="${ISO_NAME_OVERRIDE:-}" \
        -e BOB_LIVE="${BOB_LIVE:-}" \
        --name "$BUILDER_CONTAINER" \
        "$BUILDER_IMAGE" \
        bash /build/builder/build-iso.sh

    log "Build container started — waiting for completion..."
    "$runtime" wait "$BUILDER_CONTAINER" || true
    local _rc
    _rc="$("$runtime" inspect "$BUILDER_CONTAINER" --format '{{.State.ExitCode}}' 2>/dev/null || echo 1)"
    "$runtime" rm "$BUILDER_CONTAINER" 2>/dev/null || true
    if [[ "$_rc" != "0" ]]; then
        log "WARNING: build container exited with code ${_rc} — checking for ISO"
    fi

    local iso
    iso="$(latest_iso)"
    if [[ -n "$iso" ]]; then
        log "ISO built: $iso ($(du -sh "$iso" | cut -f1))"
        sha256sum "$iso" > "${iso}.sha256"
    else
        die "No ISO found after build"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────

# Remove build artifacts (chroot, binary staging, ISOs).
# Does NOT remove darksite caches — those are expensive to rebuild.
# To force a full darksite rebuild: rm -rf live-build/darksite-*-cache/
cmd_clean() {
    log "Cleaning build artifacts..."
    rm -rf "$ROOT/live-build/chroot" "$ROOT/live-build/binary" "$ROOT/live-build/.build"
    rm -rf "$OUTPUT_DIR"
    log "Clean complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# Deploy commands
# ─────────────────────────────────────────────────────────────────────────────

# Write the latest ISO to a USB drive.
# If USB_DEVICE is not set, auto-detects removable drives.
# Refuses to auto-detect if multiple removable drives are found.
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

# Full rebuild: clean everything, rebuild the builder image, build ISO.
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

# Deploy ISO to local KVM via virt-install.
# Creates UEFI VMs with virtio disk/network on the default libvirt network.
# Secure Boot is disabled (ZFS modules need MOK enrollment first).
# VNC is enabled for console access.
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

# Deploy Bob AI appliance to KVM. Creates VM but doesn't start it (--noreboot).
cmd_kvm_deploy_bob() {
    local iso="$ROOT/live-build/output/bob-${KLDLOAD_VERSION:-1.0.2}-${ARCH}.iso"
    [[ -f "$iso" ]] || die "Bob ISO not found at $iso — run build-ai-appliance first"

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

# Deploy ISO to Proxmox via SSH + qm API.
# Uploads ISO, destroys any existing VM with the same VMID, creates a new one.
# VM config: q35 machine, host CPU, TPM 2.0, virtio-scsi, serial console,
# OVMF UEFI, IDE CDROM. Matches the hardware profile that kldloadOS expects.
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

# Deploy to all targets: KVM + Proxmox, then print USB burn command.
cmd_deploy_all() {
    cmd_kvm_deploy
    cmd_proxmox_deploy
    log ""
    log "Both VMs deployed. USB burn command:"
    local iso; iso="$(latest_iso)"
    log "  dd if=$iso of=/dev/sda bs=4M status=progress oflag=sync conv=fsync && sync"
}

# ─────────────────────────────────────────────────────────────────────────────
# Command dispatch
# ─────────────────────────────────────────────────────────────────────────────

case "${1:-help}" in
    build)              cmd_build ;;
    build-ai-appliance) cmd_build_ai_appliance ;;
    build-debian-darksite) cmd_build_debian_darksite ;;
    build-ubuntu-darksite) cmd_build_ubuntu_darksite ;;
    build-k8s-darksite)
        # Build Kubernetes + Cilium offline image cache separately.
        # Normally this runs as part of `build`, but can be triggered
        # independently to pre-cache images before a full build.
        log "Building Kubernetes + Cilium offline darksite..."
        bash "$ROOT/build/darksite/pull-k8s-images.sh" "$ROOT/live-build/config/includes.chroot/root/darksite/k8s-images"
        mkdir -p "$ROOT/live-build/config/includes.chroot/root/darksite/helm-charts"
        if command -v helm >/dev/null 2>&1; then
            helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
            helm repo update >/dev/null 2>&1 || true
            helm pull cilium/cilium --version "${CILIUM_VERSION:-1.16.5}" -d "/tmp/cilium-chart" 2>/dev/null
            mv /tmp/cilium-chart/cilium-*.tgz "$ROOT/live-build/config/includes.chroot/root/darksite/helm-charts/cilium.tgz" 2>/dev/null || true
            rm -rf /tmp/cilium-chart
        fi
        log "K8s darksite ready"
        ;;
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
        cat <<EOF
kldload deploy.sh — build + deploy pipeline for kldloadOS

Usage: ./deploy.sh <command>

Build:
  build                  Build ISO (incremental — uses cached darksites)
  full                   Clean + rebuild builder image + build ISO from scratch
  builder-image          Rebuild the CentOS 9 builder container image
  build-debian-darksite  Rebuild the Debian APT offline mirror cache
  build-ubuntu-darksite  Rebuild the Ubuntu APT offline mirror cache
  build-k8s-darksite     Pre-pull Kubernetes + Cilium container images
  build-ai-docs          Scrape website + OCR PDF for AI knowledge base
  build-ai-appliance     Build self-contained Bob AI appliance ISO
  clean                  Remove build artifacts (preserves darksite caches)

Deploy:
  kvm-deploy             Deploy ISO to local KVM (virt-install, UEFI, VNC)
  kvm-deploy-bob         Deploy Bob AI appliance to KVM (created off)
  proxmox-deploy         Deploy ISO to remote Proxmox (SSH + qm API)
  deploy-all             Deploy to KVM + Proxmox + print USB command
  burn                   Write ISO to USB drive

Environment (override via env vars or kldload.env):
  PROFILE         Install profile: desktop, server, kvm, ai, core (default: desktop)
  EDITION         Edition: free (full) or core (ZFS-only) (default: free)
  ARCH            Target architecture (default: x86_64)
  RELEASE         CentOS Stream release version (default: 9)
  VMID            Proxmox VM ID (default: 902)
  VM_MEMORY       VM RAM in MB (default: 16384)
  VM_CORES        VM CPU cores (default: 4)
  VM_DISK_GB      VM disk size in GB (default: 80)
  KVM_VMS         Number of KVM test VMs (default: 1)
  USB_DEVICE      USB block device for burn (default: /dev/sda)
  PROXMOX_HOST    Proxmox host IP (default: 10.100.10.225)
  CILIUM_VERSION  Cilium Helm chart version (default: 1.16.5)

Examples:
  ./deploy.sh build                          # Build with defaults
  PROFILE=server ./deploy.sh build           # Server profile
  PROFILE=kvm ./deploy.sh build              # KVM hypervisor + K8s
  ./deploy.sh clean && ./deploy.sh build     # Full rebuild
  ./deploy.sh kvm-deploy                     # Test in local KVM
  ./deploy.sh burn                           # Write to USB
EOF
        ;;
esac
