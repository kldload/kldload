#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# users.sh — user account management library (sourced)
# Requires: common.sh
# ---------------------------------------------------------------------------

[[ "${_KLDLOAD_USERS_LOADED:-0}" == "1" ]] && return 0
_KLDLOAD_USERS_LOADED=1

# ---------------------------------------------------------------------------
# users_create — create a non-root user account in the target
# Args: target, username, password
# ---------------------------------------------------------------------------

users_create() {
    local target="$1"
    local username="$2"
    local password="$3"

    [[ -n "$target"   ]] || die "users_create: target required"
    [[ -n "$username" ]] || die "users_create: username required"
    [[ -n "$password" ]] || die "users_create: password required"

    log "Creating user '$username' in $target..."

    in_chroot "$target" \
        "useradd -m -s /bin/bash -G sudo ${username}"

    in_chroot "$target" \
        "echo '${username}:${password}' | chpasswd"

    log "User '$username' created with sudo group membership."
}

# ---------------------------------------------------------------------------
# users_set_root_password — set root account password in target
# Args: target, password
# ---------------------------------------------------------------------------

users_set_root_password() {
    local target="$1"
    local password="$2"

    [[ -n "$target"   ]] || die "users_set_root_password: target required"
    [[ -n "$password" ]] || die "users_set_root_password: password required"

    log "Setting root password in $target..."
    in_chroot "$target" "echo 'root:${password}' | chpasswd"
    log "Root password set."
}
