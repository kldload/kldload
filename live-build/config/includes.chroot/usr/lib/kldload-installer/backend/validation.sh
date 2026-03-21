#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# validation.sh — installer input validation library (sourced)
# Requires: common.sh, detect.sh
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# validate_disk — die if dev is not a suitable installation target
# ---------------------------------------------------------------------------

validate_disk() {
    local dev="$1"
    [[ -n "$dev" ]] \
        || die "validate_disk: no device specified"

    [[ -b "$dev" ]] \
        || die "Not a block device: $dev"

    # Refuse to use partitions — must be a whole disk
    local type
    type="$(lsblk -dn -o TYPE "$dev" 2>/dev/null || true)"
    [[ "$type" == "disk" ]] \
        || die "Device is not a whole disk (type=$type): $dev"

    # Refuse to target the disk that holds the current root filesystem
    local root_src parent
    root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    if [[ -n "$root_src" && "$root_src" == /dev/* ]]; then
        parent="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1 || true)"
        local root_disk="/dev/${parent:-$(basename "$root_src")}"
        if [[ "$dev" == "$root_disk" ]]; then
            die "Refusing to install to current root/system disk: $dev"
        fi
    fi

    log "Disk validated: $dev ($(disk_size_gb "$dev") GB)"
}

# ---------------------------------------------------------------------------
# validate_profile — die unless profile is "server" or "desktop"
# ---------------------------------------------------------------------------

validate_profile() {
    local p="$1"
    case "$p" in
        server|desktop) ;;
        *) die "Invalid profile '$p'. Must be 'server' or 'desktop'." ;;
    esac
}

# ---------------------------------------------------------------------------
# validate_hostname — die if hostname is invalid
# ---------------------------------------------------------------------------

validate_hostname() {
    local h="$1"
    [[ -n "$h" ]] \
        || die "Hostname cannot be empty."

    # RFC 1123: labels 1-63 chars, alphanumeric + hyphens, no leading/trailing hyphens
    if ! echo "$h" | grep -qE '^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$'; then
        die "Invalid hostname '$h'. Must be valid RFC 1123 hostname."
    fi

    [[ "${#h}" -le 253 ]] \
        || die "Hostname too long (${#h} chars, max 253): $h"
}

# ---------------------------------------------------------------------------
# validate_username — die if username is invalid
# ---------------------------------------------------------------------------

validate_username() {
    local u="$1"
    [[ -n "$u" ]] \
        || die "Username cannot be empty."

    # POSIX: lowercase letters, digits, hyphens, underscores; start with letter
    if ! echo "$u" | grep -qE '^[a-z][a-z0-9_-]{0,31}$'; then
        die "Invalid username '$u'. Must start with a letter, use only lowercase letters/digits/-/_, max 32 chars."
    fi

    # Refuse reserved system usernames
    case "$u" in
        root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy| \
        www-data|backup|list|irc|gnats|nobody|systemd-*|_*)
            die "Reserved username not allowed: $u"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# validate_password — die if password is empty
# ---------------------------------------------------------------------------

validate_password() {
    local p="$1"
    [[ -n "$p" ]] \
        || die "Password cannot be empty."
}

# ---------------------------------------------------------------------------
# validate_storage_mode — die unless mode is a supported storage layout
# ---------------------------------------------------------------------------

validate_storage_mode() {
    local m="$1"
    case "$m" in
        single|mirror|encrypted-single|encrypted-mirror) ;;
        *) die "Invalid storage mode '$m'. Must be: single, mirror, encrypted-single, encrypted-mirror." ;;
    esac
}

# ---------------------------------------------------------------------------
# preflight_check — validate system requirements before installation
# ---------------------------------------------------------------------------

preflight_check() {
    log_section "Preflight checks"

    # Must boot in EFI mode
    detect_efi \
        || die "EFI firmware not detected. KLDload requires UEFI boot mode."
    log "EFI firmware: OK"

    # Required commands
    local required_cmds=(
        zpool
        zfs
        debootstrap
        rsync
        wipefs
        sgdisk
        mkfs.fat
        efibootmgr
        zgenhostid
        depmod
        update-initramfs
    )

    for cmd in "${required_cmds[@]}"; do
        need_cmd "$cmd"
        log "Command available: $cmd"
    done

    log "Preflight checks passed."
}
