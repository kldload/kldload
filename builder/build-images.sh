#!/usr/bin/env bash
# build-images.sh — builds VM disk images from a kldload ISO
#
# Runs on HOST (not in the builder container).
# Requires: qemu-system-x86_64, qemu-img, /dev/kvm, mkfs.fat
#
# Flow:
#   1. Find or accept the built ISO
#   2. For each template (server, desktop): call kldload-golden to do a
#      headless QEMU install (ISO boots, KLDLOAD-SEED disk triggers auto-install)
#   3. Convert qcow2 → vmdk (VMware/VBox), vdi (VirtualBox), vhd (Hyper-V), ova
#   4. Write sha256 manifest for all artifacts
#
# Usage:
#   builder/build-images.sh [options]
#   make images
#
# Options:
#   --iso PATH          Use this ISO (default: latest in live-build/output/)
#   --output-dir DIR    Output directory (default: live-build/output/images/)
#   --templates LIST    Comma-separated templates: server,desktop (default: server)
#   --size GB           Disk size per image in GB (default: 40)
#   --mem MB            RAM for QEMU install VM (default: 2048)
#   --cpus N            vCPUs for QEMU install VM (default: 2)
#   --formats LIST      Comma-separated: qcow2,vmdk,vdi,vhd,ova (default: all)
#   --keep-qcow2        Keep intermediate qcow2 even if not in --formats
#   --dry-run           Print what would be done without doing it
#   --help              Show this help

set -euo pipefail

ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
BUILD_DATE="$(date +%Y%m%d)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ISO=""
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/live-build/output/images}"
TEMPLATES="${TEMPLATES:-server}"
SIZE_GB="${GOLDEN_SIZE:-40}"
MEM_MB="${GOLDEN_MEM:-2048}"
CPUS="${GOLDEN_CPUS:-2}"
FORMATS="${IMAGE_FORMATS:-qcow2,vmdk,vdi,vhd,ova}"
KEEP_QCOW2=0
DRY_RUN=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { printf '[%s] [build-images] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() {
    log "FATAL: $*"
    exit 1
}
info() { printf '  %-16s %s\n' "$1" "$2"; }

usage() {
    grep '^#' "$0" | sed 's/^# \?//' | sed '1d'
    exit 0
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] $*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
    --iso)
        ISO="${2:?}"
        shift 2
        ;;
    --output-dir)
        OUTPUT_DIR="${2:?}"
        shift 2
        ;;
    --templates)
        TEMPLATES="${2:?}"
        shift 2
        ;;
    --size)
        SIZE_GB="${2:?}"
        shift 2
        ;;
    --mem)
        MEM_MB="${2:?}"
        shift 2
        ;;
    --cpus)
        CPUS="${2:?}"
        shift 2
        ;;
    --formats)
        FORMATS="${2:?}"
        shift 2
        ;;
    --keep-qcow2)
        KEEP_QCOW2=1
        shift
        ;;
    --dry-run)
        DRY_RUN=1
        shift
        ;;
    --help | -h) usage ;;
    *) die "Unknown option: $1" ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
log "Validating prerequisites..."

require_cmd qemu-system-x86_64
require_cmd qemu-img
require_cmd mkfs.fat

[[ -e /dev/kvm ]] || die "/dev/kvm not found — KVM must be available on the host"
[[ -r /dev/kvm ]] || die "/dev/kvm not readable — run as root or add user to kvm group"

# ---------------------------------------------------------------------------
# Locate ISO
# ---------------------------------------------------------------------------
if [[ -z "$ISO" ]]; then
    ISO="$(find "$ROOT/live-build/output" -maxdepth 1 -name '*.iso' \
        -not -name '*.sha256' | sort | tail -1 || true)"
    [[ -n "$ISO" && -f "$ISO" ]] ||
        die "No ISO found in $ROOT/live-build/output. Run 'make build' first or pass --iso."
fi

[[ -f "$ISO" ]] || die "ISO not found: $ISO"
log "Using ISO: $ISO"
log "ISO size:  $(du -sh "$ISO" | cut -f1)"

# ---------------------------------------------------------------------------
# Parse format list
# ---------------------------------------------------------------------------
has_format() {
    [[ ",$FORMATS," =~ ,$1, ]]
}

# Ensure we always produce qcow2 as the install target (it's the base)
NEED_QCOW2=1
if ! has_format qcow2 && [[ "$KEEP_QCOW2" -eq 0 ]]; then
    NEED_QCOW2=1 # still need it as intermediate; will delete after conversion
fi

# ---------------------------------------------------------------------------
# Create output directory
# ---------------------------------------------------------------------------
mkdir -p "$OUTPUT_DIR"
log "Output directory: $OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Golden script
# ---------------------------------------------------------------------------
GOLDEN_SCRIPT="$ROOT/live-build/config/includes.chroot/usr/local/sbin/kldload-golden"
[[ -f "$GOLDEN_SCRIPT" ]] || die "kldload-golden not found at $GOLDEN_SCRIPT"

# ---------------------------------------------------------------------------
# Build each template
# ---------------------------------------------------------------------------
IFS=',' read -ra TEMPLATE_LIST <<<"$TEMPLATES"

MANIFEST_FILE="$OUTPUT_DIR/images-${BUILD_DATE}.sha256"
>"$MANIFEST_FILE"

for TEMPLATE in "${TEMPLATE_LIST[@]}"; do
    TEMPLATE="${TEMPLATE// /}" # trim spaces
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log "Building template: $TEMPLATE"

    BASENAME="kldload-${TEMPLATE}-amd64-${BUILD_DATE}"
    QCOW2_PATH="$OUTPUT_DIR/${BASENAME}.qcow2"

    # ── Step 1: headless QEMU install → qcow2 ────────────────────────────────
    log "Step 1/3: headless install (QEMU+KVM) → $QCOW2_PATH"
    log "  This takes ~10-20 minutes. Serial log: /tmp/kldload-golden-serial.log"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        bash "$GOLDEN_SCRIPT" \
            --template "$TEMPLATE" \
            --output "$QCOW2_PATH" \
            --iso "$ISO" \
            --format qcow2 \
            --size "$SIZE_GB" \
            --mem "$MEM_MB" \
            --cpus "$CPUS"
    else
        log "[dry-run] would call: kldload-golden --template $TEMPLATE --output $QCOW2_PATH ..."
        touch "$QCOW2_PATH" # placeholder for dry-run
    fi

    [[ -f "$QCOW2_PATH" ]] || die "kldload-golden did not produce $QCOW2_PATH"
    QCOW2_SIZE="$(du -sh "$QCOW2_PATH" | cut -f1)"
    log "qcow2 ready: $QCOW2_PATH ($QCOW2_SIZE)"

    # ── Step 2: convert to other formats ─────────────────────────────────────
    log "Step 2/3: format conversion"

    # Helper: convert + checksum
    convert_fmt() {
        local src_fmt="$1"
        local dst_fmt="$2"
        local dst_path="$3"
        shift 3
        local extra_args=("$@")

        log "  → $dst_fmt: $(basename "$dst_path")"
        if [[ "$DRY_RUN" -eq 0 ]]; then
            qemu-img convert \
                -f "$src_fmt" \
                -O "$dst_fmt" \
                "${extra_args[@]}" \
                "$QCOW2_PATH" \
                "$dst_path"
            (cd "$(dirname "$dst_path")" && sha256sum "$(basename "$dst_path")") >>"$MANIFEST_FILE"
        else
            log "[dry-run] qemu-img convert -f $src_fmt -O $dst_fmt ... $QCOW2_PATH $dst_path"
        fi
    }

    # VMware ESXi / VMware Workstation / VirtualBox
    if has_format vmdk; then
        VMDK_PATH="$OUTPUT_DIR/${BASENAME}.vmdk"
        # subformat=streamOptimized for VMware; monolithicSparse also works for VBox
        convert_fmt qcow2 vmdk "$VMDK_PATH" -o subformat=streamOptimized
    fi

    # VirtualBox native (VDI)
    if has_format vdi; then
        VDI_PATH="$OUTPUT_DIR/${BASENAME}.vdi"
        convert_fmt qcow2 vdi "$VDI_PATH"
    fi

    # Hyper-V / Azure (VHD using vpc format)
    if has_format vhd; then
        VHD_PATH="$OUTPUT_DIR/${BASENAME}.vhd"
        # vpc = VirtualPC/VHD; subformat=fixed required for Azure
        convert_fmt qcow2 vpc "$VHD_PATH" -o subformat=fixed
    fi

    # OVA (portable — VMDK wrapped in an OVF manifest, tarred)
    if has_format ova; then
        OVA_VMDK="$OUTPUT_DIR/${BASENAME}-ova.vmdk"
        OVA_PATH="$OUTPUT_DIR/${BASENAME}.ova"
        log "  → ova: $(basename "$OVA_PATH")"
        if [[ "$DRY_RUN" -eq 0 ]]; then
            # First convert to stream-optimized VMDK
            qemu-img convert -f qcow2 -O vmdk -o subformat=streamOptimized \
                "$QCOW2_PATH" "$OVA_VMDK"
            VMDK_BYTES="$(stat -c%s "$OVA_VMDK")"
            DISK_BYTES="$((SIZE_GB * 1024 * 1024 * 1024))"
            # Write OVF descriptor
            OVF_PATH="$OUTPUT_DIR/${BASENAME}.ovf"
            cat >"$OVF_PATH" <<OVF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1"
          xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
          xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData">
  <References>
    <File ovf:id="disk0" ovf:href="${BASENAME}-ova.vmdk" ovf:size="${VMDK_BYTES}"/>
  </References>
  <DiskSection>
    <Disk ovf:diskId="vmdisk0" ovf:fileRef="disk0"
          ovf:capacity="${DISK_BYTES}" ovf:capacityAllocationUnits="byte"
          ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"
          ovf:populatedSize="${VMDK_BYTES}"/>
  </DiskSection>
  <VirtualSystem ovf:id="kldload-${TEMPLATE}">
    <Info>kldload ${TEMPLATE} (Debian 13 trixie, ZFS-on-root)</Info>
    <Name>kldload-${TEMPLATE}</Name>
    <VirtualHardwareSection>
      <vssd:VirtualSystemType>vmx-19</vssd:VirtualSystemType>
      <Item>
        <rasd:ElementName>2 vCPUs</rasd:ElementName>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>2</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:ElementName>2048 MB RAM</rasd:ElementName>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>2048</rasd:VirtualQuantity>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
      </Item>
      <Item>
        <rasd:ElementName>disk0</rasd:ElementName>
        <rasd:ResourceType>17</rasd:ResourceType>
        <rasd:HostResource>ovf:/disk/vmdisk0</rasd:HostResource>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
OVF
            # Bundle OVF + VMDK into a tar (= OVA)
            tar -C "$OUTPUT_DIR" -cf "$OVA_PATH" \
                "$(basename "$OVF_PATH")" "$(basename "$OVA_VMDK")"
            rm -f "$OVF_PATH" "$OVA_VMDK"
            (cd "$(dirname "$OVA_PATH")" && sha256sum "$(basename "$OVA_PATH")") >>"$MANIFEST_FILE"
        else
            log "[dry-run] would build OVA from $QCOW2_PATH"
        fi
    fi

    # qcow2 checksum (add after conversions so it's in the manifest regardless)
    if has_format qcow2; then
        if [[ "$DRY_RUN" -eq 0 ]]; then
            (cd "$(dirname "$QCOW2_PATH")" && sha256sum "$(basename "$QCOW2_PATH")") >>"$MANIFEST_FILE"
        fi
    elif [[ "$KEEP_QCOW2" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
        # qcow2 was only used as intermediate — delete it
        rm -f "$QCOW2_PATH"
        log "  (intermediate qcow2 removed — use --keep-qcow2 to retain)"
    fi

    # ── Step 3: summary ───────────────────────────────────────────────────────
    log "Step 3/3: artifacts for template '$TEMPLATE'"
    for f in "$OUTPUT_DIR/${BASENAME}".*; do
        [[ -f "$f" ]] || continue
        [[ "$f" == *.sha256 ]] && continue
        info "  $(basename "$f")" "$(du -sh "$f" | cut -f1)"
    done
done

# ---------------------------------------------------------------------------
# Final manifest
# ---------------------------------------------------------------------------
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Image build complete."
log "Manifest: $MANIFEST_FILE"
if [[ "$DRY_RUN" -eq 0 ]]; then
    cat "$MANIFEST_FILE"
fi
log ""
log "Import instructions:"
log "  KVM/QEMU:    virt-install --import --disk path=kldload-server-*.qcow2 --os-type linux"
log "  VirtualBox:  File → Import Appliance → select .ova (or File → Virtual Media Manager → .vdi)"
log "  VMware:      File → Open → select .vmdk or .ova"
log "  Hyper-V:     New VM → Use existing VHD → select .vhd"
log "  Azure:       az storage blob upload + az image create (use .vhd, fixed format)"
