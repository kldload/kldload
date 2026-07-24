#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bootenv.sh — ZFSBootMenu integration library (sourced)
# Requires: common.sh
# ---------------------------------------------------------------------------

[[ "${_KLDLOAD_BOOTENV_LOADED:-0}" == "1" ]] && return 0
_KLDLOAD_BOOTENV_LOADED=1

# ---------------------------------------------------------------------------
# _bootenv_active_dataset — resolve the active root dataset
# The installer creates rpool/ROOT/<hostname>, NOT rpool/ROOT/default, so a
# hardcoded fallback broke recovery on essentially every real install
# (found 2026-07-22 audit). Resolution order:
#   1. the zfs dataset mounted at /       (running installed system)
#   2. /etc/kldload/boot-environment      (installer marker, if present)
#   3. zpool bootfs                       (authoritative in recovery — the
#                                          live ISO has neither 1 nor 2)
#   4. first child of rpool/ROOT          (single-BE systems w/o bootfs)
#   5. rpool/ROOT/default                 (pre-1.0 legacy layouts only)
# Returns the dataset on stdout; logs which source won when not the marker.
# ---------------------------------------------------------------------------
_bootenv_active_dataset() {
    local ds=""

    # 1. Running system: dataset mounted at / (recovery's / is a live overlay,
    #    where findmnt reports a non-zfs source and this stays empty)
    ds="$(findmnt -no SOURCE -t zfs / 2>/dev/null || true)"
    if [[ -n "$ds" ]]; then
        echo "$ds"
        return 0
    fi

    # 2. Installer marker
    local marker="/etc/kldload/boot-environment"
    if [[ -f "$marker" ]]; then
        ds="$(cat "$marker")"
        if [[ -n "$ds" ]]; then
            echo "$ds"
            return 0
        fi
    fi

    # 3. Pool bootfs — what ZFSBootMenu itself boots by default
    ds="$(zpool get -H -o value bootfs rpool 2>/dev/null || true)"
    if [[ -n "$ds" && "$ds" != "-" ]]; then
        log "active BE resolved from zpool bootfs: $ds"
        echo "$ds"
        return 0
    fi

    # 4. First child of rpool/ROOT (NR==1 is rpool/ROOT itself)
    ds="$(zfs list -H -o name -r -t filesystem rpool/ROOT 2>/dev/null | awk 'NR==2' || true)"
    if [[ -n "$ds" ]]; then
        log "active BE resolved from rpool/ROOT children: $ds (no bootfs set)"
        echo "$ds"
        return 0
    fi

    # 5. Legacy
    log "WARNING: could not resolve active BE — falling back to rpool/ROOT/default"
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
        [[ -f "$p" ]] && {
            echo "$p"
            return 0
        }
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
    [[ -n "$zbm_src" && -f "$zbm_src" ]] ||
        die "ZFSBootMenu EFI binary not found. Is zfsbootmenu installed?"

    log "ZBM EFI source: $zbm_src"

    # Create EFI directory structure
    local efi_dir="${target}/boot/efi/EFI/kldload"
    local zbm_dest="${efi_dir}/zfsbootmenu.efi"

    run mkdir -p "$efi_dir"
    run cp "$zbm_src" "$zbm_dest"

    [[ -f "$zbm_dest" ]] ||
        die "ZBM EFI copy failed: $zbm_dest not found after copy."

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

        # Clean stale boot entries from prior installs — but ONLY entries that
        # are provably ours: label contains kldload/ZFSBootMenu, or the entry's
        # device path references THIS ESP's PARTUUID (efibootmgr -v prints it
        # inside HD(...,GPT,<uuid>,...)). The old sweep also matched generic
        # labels ("UEFI OS", any distro name) and the disk basename as a
        # substring, which deleted boot entries belonging to OTHER disks on
        # multi-boot/JBOD hosts (2026-07 audit). Anchored ^Boot + {4} so the
        # hex ID only ever comes from the entry line itself.
        log "Cleaning stale EFI boot entries (this disk + kldload/ZBM labels only)..."
        local _efi_uuid
        _efi_uuid=$(blkid -s PARTUUID -o value "$efi_part" 2>/dev/null || true)
        for _bnum in $(efibootmgr -v 2>/dev/null | grep -iE "kldload|ZFSBootMenu|${_efi_uuid:-NOMATCH}" | grep -oP '^Boot\K[0-9A-Fa-f]{4}' || true); do
            efibootmgr -b "$_bnum" -B 2>/dev/null && log "  Removed Boot${_bnum}" || true
        done

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

    # Set ZFSBootMenu kernel command line property on root dataset — but only
    # if none exists yet. ZBM builds the kernel cmdline EXCLUSIVELY from this
    # property, and the installer sets "rw ... psi=1" (plus e.g. the nouveau
    # blacklist on NVIDIA boxes) on rpool/ROOT at install time. Recovery
    # blindly overwriting it with a minimal "ro ..." line downgraded every
    # recovered system's boot (ro root, lost module blacklists). Preserve
    # what's there; only seed a default on pools that never had one.
    local active_ds _existing_cmdline
    active_ds="$(_bootenv_active_dataset)"
    _existing_cmdline="$(zfs get -H -o value org.zfsbootmenu:commandline "${active_ds}" 2>/dev/null || echo '-')"
    if [[ -z "$_existing_cmdline" || "$_existing_cmdline" == "-" ]]; then
        log "Setting ZBM commandline on ${active_ds} (none present)..."
        run zfs set org.zfsbootmenu:commandline="rw console=tty1 console=ttyS0,115200" "${active_ds}"
    else
        log "Preserving existing ZBM commandline on ${active_ds}: ${_existing_cmdline}"
    fi

    # Secure Boot reality check: the ZBM binary staged above is not signed
    # for shim (upstream ZBM ships no shim SBAT entry — see lib/bootloader.sh
    # SBAT notes), so SB-enabled firmware will refuse to boot it regardless
    # of MOK state. Recovery must say so instead of handing back a machine
    # that fails at the next boot with "Verification failed".
    if mokutil --sb-state 2>/dev/null | grep -qi enabled; then
        log "WARNING: Secure Boot is ENABLED on this firmware. The ZBM entry just installed will be REJECTED by shim (upstream SBAT gap)."
        log "WARNING: either disable Secure Boot in firmware, or boot via the distro's signed GRUB entry and run 'kldload-secure-boot enable' — then use the firmware boot menu."
    fi

    # Write ZFSBootMenu config in target
    local zbm_conf_dir="${target}/etc/zfsbootmenu"
    run mkdir -p "$zbm_conf_dir"
    cat >"${zbm_conf_dir}/config.yaml" <<'EOF'
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
# bootenv_list — list all boot environments under rpool/ROOT.
# Includes SNAPSHOTS, not just filesystems: bootenv_create makes a BE as a
# snapshot (rpool/ROOT/<host>@<name>), so a filesystem-only listing hid every
# created BE (kbe create/list mismatch, verified on hardware 2026-07-24).
# ---------------------------------------------------------------------------

bootenv_list() {
    zfs list -H -r -t filesystem,snapshot rpool/ROOT 2>/dev/null |
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
