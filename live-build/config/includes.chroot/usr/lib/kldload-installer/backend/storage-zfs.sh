#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# storage-zfs.sh — ZFS storage backend for KLDload installer (sourced)
# Requires: common.sh, detect.sh
# Dataset layout is DETERMINISTIC — never deviate from this schema.
# ---------------------------------------------------------------------------

# Guard against double-sourcing
[[ "${_KLDLOAD_STORAGE_ZFS_LOADED:-0}" == "1" ]] && return 0
_KLDLOAD_STORAGE_ZFS_LOADED=1

# ---------------------------------------------------------------------------
# disk_part_suffix — return "p" for nvme/mmcblk/loop devices, else ""
# ---------------------------------------------------------------------------

disk_part_suffix() {
    local dev="$1"
    local base
    base="$(basename "$dev")"
    case "$base" in
    nvme* | mmcblk* | loop*) echo "p" ;;
    *) echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# wipe_disk — securely wipe partition table and filesystem signatures
# ---------------------------------------------------------------------------

wipe_disk() {
    local dev="$1"
    log "Wiping disk: $dev"

    run wipefs -a "$dev"
    run sgdisk --zap-all "$dev"
    run sgdisk --clear "$dev"

    # Flush kernel partition table
    run partprobe "$dev" 2>/dev/null || run blockdev --rereadpt "$dev" 2>/dev/null || true
    sleep 1

    log "Disk wiped: $dev"
}

# ---------------------------------------------------------------------------
# partition_disk_single — create 2-partition layout on a single disk
# Partition 1: 2G EFI System (EF00) — see lib/storage-zfs.sh for why 2G and
#              not 512M: the portable (hostonly=no) initramfs is ~233MB and a
#              `rollback` needs backups plus an incoming pair on the same ESP.
# Partition 2: remainder ZFS (BF01)
# ---------------------------------------------------------------------------

partition_disk_single() {
    local dev="$1"
    log "Partitioning disk (single): $dev"

    run sgdisk \
        -n "1:0:+${KLDLOAD_ESP_SIZE:-2G}" -t "1:EF00" -c "1:EFI" \
        -n "2:0:0" -t "2:BF01" -c "2:ZFS" \
        "$dev"

    run partprobe "$dev" 2>/dev/null || run blockdev --rereadpt "$dev" 2>/dev/null || true
    sleep 2

    local suffix
    suffix="$(disk_part_suffix "$dev")"
    local efi_part="${dev}${suffix}1"
    local zfs_part="${dev}${suffix}2"

    [[ -b "$efi_part" ]] || die "EFI partition not found after partitioning: $efi_part"
    [[ -b "$zfs_part" ]] || die "ZFS partition not found after partitioning: $zfs_part"

    log "Partitions created: EFI=$efi_part ZFS=$zfs_part"
}

# ---------------------------------------------------------------------------
# partition_disk_mirror — create 2-partition layout on two disks for mirror
# ---------------------------------------------------------------------------

partition_disk_mirror() {
    local dev1="$1"
    local dev2="$2"
    log "Partitioning disks (mirror): $dev1 $dev2"

    partition_disk_single "$dev1"
    partition_disk_single "$dev2"

    log "Mirror disk partitioning complete."
}

# ---------------------------------------------------------------------------
# create_rpool_single — create single-disk ZFS pool
# ---------------------------------------------------------------------------

create_rpool_single() {
    local zfs_part="$1"
    local encrypt="${2:-false}"
    local passphrase="${3:-}"

    log "Creating rpool (single) on $zfs_part (encrypt=$encrypt)"

    local enc_opts=()
    if bool "$encrypt"; then
        [[ -n "$passphrase" ]] || die "Passphrase required for encrypted pool."
        enc_opts=(
            -O encryption=aes-256-gcm
            -O keylocation=prompt
            -O keyformat=passphrase
        )
    fi

    if bool "$encrypt"; then
        echo "$passphrase" | run zpool create \
            -o ashift=12 \
            -o autotrim=on \
            -O acltype=posixacl \
            -O compression=lz4 \
            -O dnodesize=auto \
            -O normalization=formD \
            -O relatime=on \
            -O xattr=sa \
            -O mountpoint=none \
            "${enc_opts[@]}" \
            -R "$KLDLOAD_TARGET" \
            rpool "$zfs_part"
    else
        run zpool create \
            -o ashift=12 \
            -o autotrim=on \
            -O acltype=posixacl \
            -O compression=lz4 \
            -O dnodesize=auto \
            -O normalization=formD \
            -O relatime=on \
            -O xattr=sa \
            -O mountpoint=none \
            -R "$KLDLOAD_TARGET" \
            rpool "$zfs_part"
    fi

    log "rpool created successfully."
}

# ---------------------------------------------------------------------------
# create_rpool_mirror — create mirrored ZFS pool across two partitions
# ---------------------------------------------------------------------------

create_rpool_mirror() {
    local part1="$1"
    local part2="$2"
    local encrypt="${3:-false}"
    local passphrase="${4:-}"

    log "Creating rpool (mirror) on $part1 + $part2 (encrypt=$encrypt)"

    local enc_opts=()
    if bool "$encrypt"; then
        [[ -n "$passphrase" ]] || die "Passphrase required for encrypted pool."
        enc_opts=(
            -O encryption=aes-256-gcm
            -O keylocation=prompt
            -O keyformat=passphrase
        )
    fi

    if bool "$encrypt"; then
        echo "$passphrase" | run zpool create \
            -o ashift=12 \
            -o autotrim=on \
            -O acltype=posixacl \
            -O compression=lz4 \
            -O dnodesize=auto \
            -O normalization=formD \
            -O relatime=on \
            -O xattr=sa \
            -O mountpoint=none \
            "${enc_opts[@]}" \
            -R "$KLDLOAD_TARGET" \
            rpool mirror "$part1" "$part2"
    else
        run zpool create \
            -o ashift=12 \
            -o autotrim=on \
            -O acltype=posixacl \
            -O compression=lz4 \
            -O dnodesize=auto \
            -O normalization=formD \
            -O relatime=on \
            -O xattr=sa \
            -O mountpoint=none \
            -R "$KLDLOAD_TARGET" \
            rpool mirror "$part1" "$part2"
    fi

    log "rpool mirror created successfully."
}

# ---------------------------------------------------------------------------
# create_datasets — create all KLDload datasets with DETERMINISTIC layout
# Mounts datasets to KLDLOAD_TARGET
# ---------------------------------------------------------------------------

create_datasets() {
    local hostname="$1"
    log_section "Creating ZFS datasets"

    # ROOT container
    run zfs create \
        -o canmount=off \
        -o mountpoint=none \
        rpool/ROOT

    # Root filesystem dataset
    run zfs create \
        -o canmount=noauto \
        -o mountpoint=/ \
        rpool/ROOT/default

    run zfs mount rpool/ROOT/default

    # Home directories
    run zfs create \
        -o mountpoint=/home \
        rpool/home

    # Root home
    run zfs create \
        -o mountpoint=/root \
        rpool/root

    # Service/workload data
    run zfs create \
        -o mountpoint=/srv \
        rpool/srv

    # /var container (canmount=off so /var itself comes from root)
    run zfs create \
        -o mountpoint=/var \
        -o canmount=off \
        rpool/var

    # /var/log — persistent logs
    run zfs create \
        -o mountpoint=/var/log \
        rpool/var/log

    # /var/cache — no auto-snapshots
    run zfs create \
        -o mountpoint=/var/cache \
        -o "com.sun:auto-snapshot=false" \
        rpool/var/cache

    # /var/tmp — no auto-snapshots
    run zfs create \
        -o mountpoint=/var/tmp \
        -o "com.sun:auto-snapshot=false" \
        rpool/var/tmp

    # Set bootfs property
    run zpool set bootfs=rpool/ROOT/default rpool

    log "All datasets created and mounted under $KLDLOAD_TARGET"
}

# ---------------------------------------------------------------------------
# mount_efi — format and mount EFI partition
# ---------------------------------------------------------------------------

mount_efi() {
    local efi_part="$1"
    log "Formatting EFI partition: $efi_part"

    run mkfs.fat -F32 -n EFI "$efi_part"
    run mkdir -p "${KLDLOAD_TARGET}/boot/efi"
    run mount "$efi_part" "${KLDLOAD_TARGET}/boot/efi"

    log "EFI partition mounted: $efi_part -> ${KLDLOAD_TARGET}/boot/efi"
}

# ---------------------------------------------------------------------------
# write_hostid — generate and install /etc/hostid
# ---------------------------------------------------------------------------

write_hostid() {
    log "Generating host ID..."
    run zgenhostid
    run cp /etc/hostid "${KLDLOAD_TARGET}/etc/hostid"
    log "Host ID written to ${KLDLOAD_TARGET}/etc/hostid"
}

# ---------------------------------------------------------------------------
# export_pool — cleanly unmount and export rpool
# ---------------------------------------------------------------------------

export_pool() {
    log "Exporting rpool..."

    # Unmount all datasets
    run zfs unmount -a 2>/dev/null || true
    run zpool export rpool

    log "rpool exported."
}

# ---------------------------------------------------------------------------
# storage_zfs_install — main entry point
# Args: disk, mode, hostname, encrypt, passphrase
# ---------------------------------------------------------------------------

storage_zfs_install() {
    local disk="$1"
    local mode="$2"
    local hostname="$3"
    local encrypt="${4:-false}"
    local passphrase="${5:-}"

    log_section "ZFS Storage Installation"
    log "Disk:     $disk"
    log "Mode:     $mode"
    log "Hostname: $hostname"
    log "Encrypt:  $encrypt"

    local suffix
    suffix="$(disk_part_suffix "$disk")"

    case "$mode" in
    single | encrypted-single)
        local is_enc="false"
        [[ "$mode" == encrypted-* ]] && is_enc="true"

        wipe_disk "$disk"
        partition_disk_single "$disk"

        local efi_part="${disk}${suffix}1"
        local zfs_part="${disk}${suffix}2"

        create_rpool_single "$zfs_part" "$is_enc" "$passphrase"
        create_datasets "$hostname"
        mount_efi "$efi_part"
        write_hostid
        # Stage passphrase for firstboot clevis sealing (encrypted pools only)
        if [[ "$is_enc" == "true" && -n "$passphrase" ]]; then
            mkdir -p "${KLDLOAD_TARGET}/etc/kldload"
            printf '%s' "$passphrase" >"${KLDLOAD_TARGET}/etc/kldload/zfs-passphrase"
            chmod 600 "${KLDLOAD_TARGET}/etc/kldload/zfs-passphrase"
            log "ZFS passphrase staged at ${KLDLOAD_TARGET}/etc/kldload/zfs-passphrase (firstboot will seal and shred)"
        fi
        ;;

    mirror | encrypted-mirror)
        local is_enc="false"
        [[ "$mode" == encrypted-* ]] && is_enc="true"

        # For mirror mode, disk should be "disk1,disk2"
        local disk1 disk2
        IFS=',' read -r disk1 disk2 <<<"$disk"
        [[ -n "$disk1" && -n "$disk2" ]] ||
            die "Mirror mode requires two disks specified as 'disk1,disk2'"

        local suffix1 suffix2
        suffix1="$(disk_part_suffix "$disk1")"
        suffix2="$(disk_part_suffix "$disk2")"

        wipe_disk "$disk1"
        wipe_disk "$disk2"
        partition_disk_mirror "$disk1" "$disk2"

        local efi_part1="${disk1}${suffix1}1"
        local zfs_part1="${disk1}${suffix1}2"
        local zfs_part2="${disk2}${suffix2}2"

        create_rpool_mirror "$zfs_part1" "$zfs_part2" "$is_enc" "$passphrase"
        create_datasets "$hostname"
        mount_efi "$efi_part1"
        write_hostid
        # Stage passphrase for firstboot clevis sealing (encrypted pools only)
        if [[ "$is_enc" == "true" && -n "$passphrase" ]]; then
            mkdir -p "${KLDLOAD_TARGET}/etc/kldload"
            printf '%s' "$passphrase" >"${KLDLOAD_TARGET}/etc/kldload/zfs-passphrase"
            chmod 600 "${KLDLOAD_TARGET}/etc/kldload/zfs-passphrase"
            log "ZFS passphrase staged at ${KLDLOAD_TARGET}/etc/kldload/zfs-passphrase (firstboot will seal and shred)"
        fi
        ;;

    *)
        die "Unknown storage mode: $mode"
        ;;
    esac

    log "ZFS storage installation complete."
}
