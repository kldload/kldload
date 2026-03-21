#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# detect.sh — hardware and system detection library (sourced)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# detect_disks — list block devices suitable for installation
# Excludes: loop devices, optical drives (sr*), zram, partitions
# Outputs one /dev/sdX or /dev/nvmeXnX path per line
# ---------------------------------------------------------------------------

detect_disks() {
    local dev type
    while IFS= read -r dev; do
        # lsblk -d: whole disks only (no partitions)
        type="$(lsblk -dn -o TYPE "/dev/$dev" 2>/dev/null || true)"
        [[ "$type" == "disk" ]] || continue

        # Exclude loop, zram, sr (optical)
        case "$dev" in
            loop*|zram*|sr*) continue ;;
        esac

        echo "/dev/$dev"
    done < <(ls /sys/block/ 2>/dev/null)
}

# ---------------------------------------------------------------------------
# detect_secure_boot — returns 0 if Secure Boot is enabled
# ---------------------------------------------------------------------------

detect_secure_boot() {
    command -v mokutil >/dev/null 2>&1 || return 1
    mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"
}

# ---------------------------------------------------------------------------
# detect_tpm — returns 0 if TPM device is present
# ---------------------------------------------------------------------------

detect_tpm() {
    [[ -e /sys/class/tpm/tpm0 ]]
}

# ---------------------------------------------------------------------------
# detect_efi — returns 0 if booted in EFI mode
# ---------------------------------------------------------------------------

detect_efi() {
    [[ -d /sys/firmware/efi ]]
}

# ---------------------------------------------------------------------------
# detect_zfs_pools — list names of currently imported ZFS pools
# ---------------------------------------------------------------------------

detect_zfs_pools() {
    command -v zpool >/dev/null 2>&1 || return 0
    zpool list -H -o name 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# disk_size_gb — return disk size in GB (integer, rounded down)
# Usage: disk_size_gb /dev/sda
# ---------------------------------------------------------------------------

disk_size_gb() {
    local dev="$1"
    [[ -b "$dev" ]] || { echo 0; return; }
    local bytes
    bytes="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
    echo $(( bytes / 1024 / 1024 / 1024 ))
}
