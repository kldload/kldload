#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bootenv.sh — ZFSBootMenu integration library (sourced)
# Requires: common.sh
# ---------------------------------------------------------------------------

[[ "${_KLDLOAD_BOOTENV_LOADED:-0}" == "1" ]] && return 0
_KLDLOAD_BOOTENV_LOADED=1

# ---------------------------------------------------------------------------
# _bootenv_active_dataset — resolve the active root dataset
# Reads /etc/kldload/boot-environment written by the installer.
# Falls back to rpool/ROOT/default for backwards compatibility.
# ---------------------------------------------------------------------------
_bootenv_active_dataset() {
    local marker="/etc/kldload/boot-environment"
    if [[ -f "$marker" ]]; then
        local ds
        ds="$(cat "$marker")"
        [[ -n "$ds" ]] && { echo "$ds"; return 0; }
    fi
    echo "rpool/ROOT/default"
}

# ---------------------------------------------------------------------------
# _find_zbm_efi — locate ZFSBootMenu EFI binary
# ---------------------------------------------------------------------------

_find_zbm_efi() {
    local candidates=(
        "/usr/share/zfsbootmenu/zbm.EFI"
        "/usr/share/zfsbootmenu/zbm.efi"
        "/usr/lib/zfsbootmenu/zbm.EFI"
        "/usr/lib/zfsbootmenu/zbm.efi"
        "/usr/lib/zfsbootmenu/zfsbootmenu.EFI"
        "/usr/lib/zfsbootmenu/zfsbootmenu.efi"
    )

    for p in "${candidates[@]}"; do
        [[ -f "$p" ]] && { echo "$p"; return 0; }
    done

    # Fallback: search installed package files
    find /usr/share/zfsbootmenu /usr/lib/zfsbootmenu \
        \( -name "*.EFI" -o -name "*.efi" \) \
        -print 2>/dev/null | head -n1 || true
}

# ---------------------------------------------------------------------------
# bootenv_install — install ZFSBootMenu into target EFI and register with efibootmgr
# Args: target (e.g. /target), efi_part (e.g. /dev/sda1), disk (e.g. /dev/sda)
# ---------------------------------------------------------------------------

bootenv_install() {
    local target="$1"
    local efi_part="$2"
    local disk="${3:-}"

    log_section "ZFSBootMenu Installation"
    log "Target:    $target"
    log "EFI part:  $efi_part"
    log "Disk:      ${disk:-auto-detect}"

    # Find ZBM EFI binary
    local zbm_src
    zbm_src="$(_find_zbm_efi)"
    [[ -n "$zbm_src" && -f "$zbm_src" ]] \
        || die "ZFSBootMenu EFI binary not found. Is zfsbootmenu installed?"

    log "ZBM EFI source: $zbm_src"

    # Create EFI directory structure
    local efi_dir="${target}/boot/efi/EFI/kldload"
    local zbm_dest="${efi_dir}/zfsbootmenu.efi"

    run mkdir -p "$efi_dir"
    run cp "$zbm_src" "$zbm_dest"

    [[ -f "$zbm_dest" ]] \
        || die "ZBM EFI copy failed: $zbm_dest not found after copy."

    log "ZBM EFI installed: $zbm_dest"

    # Auto-detect disk from efi_part if not provided
    if [[ -z "$disk" ]]; then
        disk="$(lsblk -no PKNAME "$efi_part" 2>/dev/null | head -n1 || true)"
        [[ -n "$disk" ]] && disk="/dev/$disk"
    fi

    # Register with efibootmgr
    if [[ -n "$disk" && -b "$disk" ]]; then
        # Determine partition number from efi_part
        local part_num
        part_num="$(lsblk -no PARTN "$efi_part" 2>/dev/null | head -n1 || true)"
        part_num="${part_num:-1}"

        log "Registering with efibootmgr: disk=$disk part=$part_num"
        run efibootmgr \
            -c \
            -d "$disk" \
            -p "$part_num" \
            -L "KLDload ZBM" \
            -l '\EFI\kldload\zfsbootmenu.efi' \
            2>&1 || log "WARNING: efibootmgr registration failed — may need manual EFI entry"
    else
        log "WARNING: Could not determine disk for efibootmgr — skipping EFI registration"
    fi

    # Set ZFSBootMenu kernel command line property on root dataset
    local active_ds
    active_ds="$(_bootenv_active_dataset)"
    log "Setting ZBM commandline on ${active_ds}..."
    run zfs set org.zfsbootmenu:commandline="ro console=tty1 console=ttyS0,115200" "${active_ds}"

    # Write ZFSBootMenu config in target
    local zbm_conf_dir="${target}/etc/zfsbootmenu"
    run mkdir -p "$zbm_conf_dir"
    cat > "${zbm_conf_dir}/config.yaml" <<'EOF'
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d

Components:
  Enabled: true
  Versions: 1
  ResetRootPassword: false

EFI:
  ImageDir: /boot/efi/EFI/kldload
  Versions: false
  Signed: false

Kernel:
  CommandLine: "ro"
  Path: /vmlinuz
  Prefix: vmlinuz

Pool: rpool
Mountpoint: none
EOF

    log "ZFSBootMenu config written: ${zbm_conf_dir}/config.yaml"
    log "ZFSBootMenu installation complete."
}

# ---------------------------------------------------------------------------
# bootenv_list — list all boot environments (datasets under rpool/ROOT)
# ---------------------------------------------------------------------------

bootenv_list() {
    zfs list -H -r -t filesystem rpool/ROOT 2>/dev/null | \
        awk 'NR>0 {print $1}' || true
}

# ---------------------------------------------------------------------------
# bootenv_create — create a new boot environment snapshot
# Args: name (snapshot name without @)
# ---------------------------------------------------------------------------

bootenv_create() {
    local name="$1"
    [[ -n "$name" ]] || die "bootenv_create: snapshot name required"

    local ds snap
    ds="$(_bootenv_active_dataset)"
    snap="${ds}@${name}"
    log "Creating boot environment: $snap"
    run zfs snapshot "$snap"
    log "Boot environment created: $snap"
}

# ---------------------------------------------------------------------------
# bootenv_activate — set pool bootfs to a dataset
# Args: snapshot or dataset name (e.g. rpool/ROOT/default@name)
# ---------------------------------------------------------------------------

bootenv_activate() {
    local snapshot="$1"
    [[ -n "$snapshot" ]] || die "bootenv_activate: snapshot required"

    # Extract the dataset portion (before @)
    local dataset="${snapshot%%@*}"
    log "Activating boot environment: dataset=$dataset (from $snapshot)"
    run zpool set "bootfs=${dataset}" rpool
    log "Boot environment activated: $dataset"
}

# ---------------------------------------------------------------------------
# bootenv_rollback — roll back a dataset to a snapshot
# Args: snapshot (e.g. rpool/ROOT/default@name)
# ---------------------------------------------------------------------------

bootenv_rollback() {
    local snapshot="$1"
    [[ -n "$snapshot" ]] || die "bootenv_rollback: snapshot required"

    # If caller passed just a name (no @), expand to full snapshot path
    if [[ "$snapshot" != *"@"* ]]; then
        local ds
        ds="$(_bootenv_active_dataset)"
        snapshot="${ds}@${snapshot}"
    fi

    log "Rolling back to boot environment: $snapshot"
    run zfs rollback -r "$snapshot"
    log "Rollback complete: $snapshot"
}
