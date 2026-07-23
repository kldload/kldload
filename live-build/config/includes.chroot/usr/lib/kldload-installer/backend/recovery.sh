#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# recovery.sh — recovery mode operations library (sourced)
# Requires: common.sh, bootenv.sh
# ---------------------------------------------------------------------------

[[ "${_KLDLOAD_RECOVERY_LOADED:-0}" == "1" ]] && return 0
_KLDLOAD_RECOVERY_LOADED=1

RECOVERY_MOUNT="${RECOVERY_MOUNT:-/mnt/recovery}"

# ---------------------------------------------------------------------------
# recovery_import_pool — force-import pool with recovery mountpoint
# Args: pool (default: rpool)
# ---------------------------------------------------------------------------

recovery_import_pool() {
    local pool="${1:-rpool}"
    log "Importing pool '$pool' for recovery (mountpoint: $RECOVERY_MOUNT)..."

    run mkdir -p "$RECOVERY_MOUNT"
    run zpool import -f -R "$RECOVERY_MOUNT" "$pool"

    log "Pool '$pool' imported at $RECOVERY_MOUNT"
}

# ---------------------------------------------------------------------------
# recovery_list_bootenvs — list available boot environments
# ---------------------------------------------------------------------------

recovery_list_bootenvs() {
    log "Listing boot environments..."
    zfs list -H -r -t filesystem rpool/ROOT 2>/dev/null |
        awk '{print $1}' |
        grep -v "^rpool/ROOT$" ||
        echo "(no boot environments found)"
}

# ---------------------------------------------------------------------------
# recovery_list_snapshots — list snapshots of a dataset
# Args: dataset
# ---------------------------------------------------------------------------

recovery_list_snapshots() {
    local dataset="$1"
    [[ -n "$dataset" ]] || die "recovery_list_snapshots: dataset required"

    log "Listing snapshots of $dataset..."
    zfs list -H -t snapshot "$dataset" 2>/dev/null |
        awk '{print $1}' ||
        echo "(no snapshots found for $dataset)"
}

# ---------------------------------------------------------------------------
# recovery_activate_bootenv — set pool bootfs to a boot environment
# Args: snapshot or dataset (e.g. rpool/ROOT/default@snap or rpool/ROOT/default)
# ---------------------------------------------------------------------------

recovery_activate_bootenv() {
    local target="$1"
    [[ -n "$target" ]] || die "recovery_activate_bootenv: target required"

    # Strip snapshot suffix to get the dataset
    local dataset="${target%%@*}"

    log "Setting bootfs: $dataset"
    run zpool set "bootfs=${dataset}" rpool
    log "Boot environment activated: $dataset"
}

# ---------------------------------------------------------------------------
# recovery_rollback — roll back a dataset to a snapshot
# Args: snapshot
# ---------------------------------------------------------------------------

recovery_rollback() {
    local snapshot="$1"
    [[ -n "$snapshot" ]] || die "recovery_rollback: snapshot required"

    log "Rolling back to: $snapshot"
    run zfs rollback -r "$snapshot"
    log "Rollback complete: $snapshot"
}

# ---------------------------------------------------------------------------
# recovery_mount_chroot — import pool and bind virtual filesystems for chroot
# Args: target (default: /mnt/recovery)
# ---------------------------------------------------------------------------

recovery_mount_chroot() {
    local target="${1:-$RECOVERY_MOUNT}"

    log "Preparing chroot environment at $target..."

    # Mount the ACTIVE root dataset, not a hardcoded rpool/ROOT/default —
    # the installer names the BE after the hostname, so the hardcoded mount
    # failed (silently) on every real install and chroot landed in an empty
    # dir. Detection + a loud failure are the whole point of this path: a
    # 3am operator must know the root didn't mount, not get a hollow shell.
    if ! mountpoint -q "$target" 2>/dev/null; then
        # bootenv.sh owns BE detection; source it if the caller hasn't
        if ! declare -F _bootenv_active_dataset >/dev/null; then
            # shellcheck source=bootenv.sh
            source "$(dirname "${BASH_SOURCE[0]:-$0}")/bootenv.sh"
        fi
        local _root_ds
        _root_ds="$(_bootenv_active_dataset)"
        log "Mounting root BE: $_root_ds"
        run zfs mount "$_root_ds" ||
            die "failed to mount $_root_ds — is the pool imported? (krecovery import). 'zfs list -r rpool/ROOT' shows the available BEs."
    fi

    # Sanity: this must look like a root filesystem before we bind into it
    [[ -d "${target}/etc" && -d "${target}/usr" ]] ||
        die "$target is mounted but does not look like a root filesystem (no /etc or /usr) — wrong dataset or empty BE"

    # Bind virtual filesystems — visible warning per failure (a missing
    # /dev or /proc makes most in-chroot tooling misbehave in confusing ways)
    run mount --bind /dev "${target}/dev" 2>/dev/null || log "WARNING: bind mount of /dev failed"
    run mount --bind /dev/pts "${target}/dev/pts" 2>/dev/null || log "WARNING: bind mount of /dev/pts failed"
    run mount -t proc proc "${target}/proc" 2>/dev/null || log "WARNING: mount of /proc failed"
    run mount -t sysfs sysfs "${target}/sys" 2>/dev/null || log "WARNING: mount of /sys failed"
    run mount -t tmpfs tmpfs "${target}/run" 2>/dev/null || log "WARNING: mount of /run failed"

    log "Chroot environment ready at $target"
}

# ---------------------------------------------------------------------------
# recovery_chroot — exec into recovery chroot
# Args: target (default: /mnt/recovery)
# ---------------------------------------------------------------------------

recovery_chroot() {
    local target="${1:-$RECOVERY_MOUNT}"

    [[ -x "${target}/bin/bash" || -x "${target}/usr/bin/bash" ]] ||
        die "no bash inside $target — root BE not mounted correctly (run krecovery import, then retry)"

    log "Entering chroot: $target"
    exec chroot "$target" /bin/bash
}

# ---------------------------------------------------------------------------
# recovery_reinstall_bootloader — reinstall ZFSBootMenu on a disk
# Args: target, disk
# ---------------------------------------------------------------------------

recovery_reinstall_bootloader() {
    local target="${1:-$RECOVERY_MOUNT}"
    local disk="$2"

    [[ -n "$disk" ]] || die "recovery_reinstall_bootloader: disk required"

    log "Reinstalling bootloader on $disk..."

    # Source bootenv.sh for bootenv_install
    local bootenv_lib="/usr/lib/kldload-installer/backend/bootenv.sh"
    if [[ ! -f "$bootenv_lib" ]]; then
        local script_dir
        script_dir="$(dirname "$(realpath "${BASH_SOURCE[0]:-$0}")")"
        bootenv_lib="${script_dir}/bootenv.sh"
    fi
    [[ -f "$bootenv_lib" ]] ||
        die "bootenv.sh not found at $bootenv_lib"
    # shellcheck source=bootenv.sh
    source "$bootenv_lib"

    local suffix
    suffix="$(disk_part_suffix "$disk" 2>/dev/null || true)"
    # Default: first partition is EFI
    local efi_part="${disk}${suffix}1"

    bootenv_install "$target" "$efi_part" "$disk"

    log "Bootloader reinstalled on $disk"
}

# ---------------------------------------------------------------------------
# recovery_export_logs — copy installer and kldload logs to a destination
# Args: dest (e.g. /mnt/usb/kldload-logs)
# ---------------------------------------------------------------------------

recovery_export_logs() {
    local dest="$1"
    [[ -n "$dest" ]] || die "recovery_export_logs: destination required"

    log "Exporting logs to $dest..."
    run mkdir -p "$dest"

    # Export installer logs
    if [[ -d /var/log/installer ]]; then
        run rsync -av /var/log/installer/ "${dest}/installer/" 2>/dev/null || true
    fi

    # Export kldload operational logs
    if [[ -d /var/log/kldload ]]; then
        run rsync -av /var/log/kldload/ "${dest}/kldload/" 2>/dev/null || true
    fi

    log "Logs exported to $dest"
}
