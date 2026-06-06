#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# security.sh — security configuration library (sourced)
# Requires: common.sh, detect.sh
# ---------------------------------------------------------------------------

[[ "${_KLDLOAD_SECURITY_LOADED:-0}" == "1" ]] && return 0
_KLDLOAD_SECURITY_LOADED=1

# ---------------------------------------------------------------------------
# security_apply_holds — pin critical platform packages in APT
# Prevents unintended upgrades of kernel, ZFS, bootloader
# Args: target
# ---------------------------------------------------------------------------

security_apply_holds() {
    local target="$1"
    [[ -n "$target" ]] || die "security_apply_holds: target required"

    log "Writing APT package hold preferences to $target..."

    local pref_dir="${target}/etc/apt/preferences.d"
    run mkdir -p "$pref_dir"

    cat >"${pref_dir}/kldload-platform.pref" <<'EOF'
# KLDload platform hold — managed by installer
# These packages are pinned at priority 1001 to prevent automatic upgrades.
# Use kldload-upgrade to perform controlled system upgrades.

Package: linux-image-amd64
Pin: release *
Pin-Priority: 1001

Package: grub-efi-amd64-signed
Pin: release *
Pin-Priority: 1001

Package: shim-signed
Pin: release *
Pin-Priority: 1001

Package: zfsutils-linux
Pin: release *
Pin-Priority: 1001

Package: zfs-dkms
Pin: release *
Pin-Priority: 1001

Package: zfs-initramfs
Pin: release *
Pin-Priority: 1001

Package: zfs-zed
Pin: release *
Pin-Priority: 1001

Package: zfsbootmenu
Pin: release *
Pin-Priority: 1001
EOF

    log "APT platform holds written: ${pref_dir}/kldload-platform.pref"
}

# ---------------------------------------------------------------------------
# security_configure_ssh — write hardened sshd configuration drop-in
# Args: target
# ---------------------------------------------------------------------------

security_configure_ssh() {
    local target="$1"
    [[ -n "$target" ]] || die "security_configure_ssh: target required"

    log "Writing sshd hardening config to $target..."

    local sshd_dir="${target}/etc/ssh/sshd_config.d"
    run mkdir -p "$sshd_dir"

    cat >"${sshd_dir}/99-kldload.conf" <<'EOF'
# KLDload SSH hardening — managed by installer
# Drop-in for /etc/ssh/sshd_config

PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
ChallengeResponseAuthentication no
KerberosAuthentication no
GSSAPIAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
EOF

    log "sshd config written: ${sshd_dir}/99-kldload.conf"
}

# ---------------------------------------------------------------------------
# security_log_secureboot_status — log Secure Boot state as info or warning
# ---------------------------------------------------------------------------

security_log_secureboot_status() {
    if detect_secure_boot; then
        log "Secure Boot: ENABLED — MOK enrollment required for DKMS ZFS modules."
        log "  After first boot, enroll the MOK key: sudo mokutil --import /var/lib/shim-signed/mok/MOK.der"
    else
        log "WARNING: Secure Boot is DISABLED. System will boot without firmware integrity checking."
        log "  To enable Secure Boot after install, enroll MOK and re-enable in BIOS/UEFI."
    fi
}
