#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bootstrap.sh — debootstrap and chroot setup library (sourced)
# Requires: common.sh
# ---------------------------------------------------------------------------

[[ "${_KLDLOAD_BOOTSTRAP_LOADED:-0}" == "1" ]] && return 0
_KLDLOAD_BOOTSTRAP_LOADED=1

KLDLOAD_DEBIAN_MIRROR="${KLDLOAD_DEBIAN_MIRROR:-https://mirror.it.ubc.ca/debian}"
KLDLOAD_DEBIAN_RELEASE="${KLDLOAD_DEBIAN_RELEASE:-trixie}"

# ---------------------------------------------------------------------------
# bootstrap_debootstrap — install base Debian system into target
# Args: target, hostname
# ---------------------------------------------------------------------------

bootstrap_debootstrap() {
    local target="$1"
    local hostname="${2:-kldload}"

    [[ -n "$target" ]] || die "bootstrap_debootstrap: target required"

    log_section "Debootstrap: $KLDLOAD_DEBIAN_RELEASE -> $target"

    run mkdir -p "$target"

    run debootstrap \
        --arch=amd64 \
        --include=ca-certificates,locales,systemd,systemd-sysv \
        "$KLDLOAD_DEBIAN_RELEASE" \
        "$target" \
        "$KLDLOAD_DEBIAN_MIRROR"

    log "Debootstrap complete: $target"
}

# ---------------------------------------------------------------------------
# bootstrap_bind_mounts — bind-mount virtual filesystems into target
# Args: target
# ---------------------------------------------------------------------------

bootstrap_bind_mounts() {
    local target="$1"
    [[ -n "$target" ]] || die "bootstrap_bind_mounts: target required"

    log "Binding virtual filesystems into $target..."

    run mount --bind /dev        "${target}/dev"
    run mount --bind /dev/pts    "${target}/dev/pts"
    run mount -t proc  proc      "${target}/proc"
    run mount -t sysfs sysfs     "${target}/sys"
    run mount -t tmpfs tmpfs     "${target}/run"

    log "Bind mounts complete."
}

# ---------------------------------------------------------------------------
# bootstrap_unbind_mounts — unmount virtual filesystems from target
# Args: target
# Continues on errors (cleanup context)
# ---------------------------------------------------------------------------

bootstrap_unbind_mounts() {
    local target="$1"
    [[ -n "$target" ]] || return 0

    log "Unmounting virtual filesystems from $target..."

    # Reverse order of mounting
    for mnt in run sys proc dev/pts dev; do
        umount "${target}/${mnt}" 2>/dev/null || \
        umount -l "${target}/${mnt}" 2>/dev/null || true
    done

    log "Unmount complete."
}

# ---------------------------------------------------------------------------
# bootstrap_write_sources — write /etc/apt/sources.list in target
# Args: target
# ---------------------------------------------------------------------------

bootstrap_write_sources() {
    local target="$1"
    [[ -n "$target" ]] || die "bootstrap_write_sources: target required"

    log "Writing /etc/apt/sources.list in $target..."

    cat > "${target}/etc/apt/sources.list" <<EOF
# KLDload APT sources — Debian ${KLDLOAD_DEBIAN_RELEASE}
deb ${KLDLOAD_DEBIAN_MIRROR} ${KLDLOAD_DEBIAN_RELEASE} main contrib non-free non-free-firmware
deb ${KLDLOAD_DEBIAN_MIRROR} ${KLDLOAD_DEBIAN_RELEASE}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${KLDLOAD_DEBIAN_RELEASE}-security main contrib non-free non-free-firmware
EOF

    log "sources.list written."
}

# ---------------------------------------------------------------------------
# bootstrap_install_packages — install profile packages into target chroot
# Args: target, profile
# ---------------------------------------------------------------------------

bootstrap_install_packages() {
    local target="$1"
    local profile="$2"

    [[ -n "$target"  ]] || die "bootstrap_install_packages: target required"
    [[ -n "$profile" ]] || die "bootstrap_install_packages: profile required"

    log_section "Installing packages (profile: $profile)"

    # Update package index
    in_chroot "$target" "apt-get update -qq"

    # Base packages — all profiles
    local base_pkgs=(
        linux-image-amd64
        linux-headers-amd64
        zfsutils-linux
        zfs-dkms
        zfs-initramfs
        zfs-zed
        zfsbootmenu
        sudo
        curl
        rsync
        openssh-server
        systemd-sysv
        dbus
        locales
        ca-certificates
        gnupg2
        wget
        less
        nano
        vim-tiny
        tmux
        git
        jq
        iproute2
        net-tools
        parted
        gdisk
        dosfstools
        efibootmgr
        mokutil
    )

    log "Installing base packages..."
    in_chroot "$target" \
        "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${base_pkgs[*]}"

    # Profile-specific packages
    case "$profile" in
        desktop)
            log "Installing desktop packages..."
            local desktop_pkgs=(
                task-gnome-desktop
                gdm3
                gnome-terminal
                network-manager
                network-manager-gnome
                calamares
            )
            in_chroot "$target" \
                "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${desktop_pkgs[*]}"
            ;;

        server)
            log "Installing server packages..."
            local server_pkgs=(
                chrony
                nftables
                htop
                ethtool
                tcpdump
            )
            in_chroot "$target" \
                "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${server_pkgs[*]}"
            ;;

        *)
            die "Unknown profile: $profile"
            ;;
    esac

    log "Package installation complete."
}

# ---------------------------------------------------------------------------
# bootstrap_write_locale — generate en_US.UTF-8 locale in target
# Args: target
# ---------------------------------------------------------------------------

bootstrap_write_locale() {
    local target="$1"
    [[ -n "$target" ]] || die "bootstrap_write_locale: target required"

    log "Configuring locale in $target..."

    echo "en_US.UTF-8 UTF-8" > "${target}/etc/locale.gen"

    cat > "${target}/etc/default/locale" <<'EOF'
LANG=en_US.UTF-8
LANGUAGE=en_US:en
LC_ALL=en_US.UTF-8
EOF

    in_chroot "$target" "locale-gen"

    log "Locale configured: en_US.UTF-8"
}

# ---------------------------------------------------------------------------
# bootstrap_write_manifest — write install metadata to target
# Args: target, disk, profile, mode
# ---------------------------------------------------------------------------

bootstrap_write_manifest() {
    local target="$1"
    local disk="$2"
    local profile="$3"
    local mode="$4"

    [[ -n "$target" ]] || die "bootstrap_write_manifest: target required"

    log "Writing install manifest..."

    local manifest_dir="${target}/etc/kldload"
    run mkdir -p "$manifest_dir"

    cat > "${manifest_dir}/install-manifest.env" <<EOF
# KLDload Install Manifest
# Generated by installer on $(date -u '+%Y-%m-%dT%H:%M:%SZ')

KLDLOAD_INSTALL_DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
KLDLOAD_INSTALL_DISK="${disk}"
KLDLOAD_INSTALL_PROFILE="${profile}"
KLDLOAD_INSTALL_MODE="${mode}"
KLDLOAD_DEBIAN_RELEASE="${KLDLOAD_DEBIAN_RELEASE}"
KLDLOAD_DEBIAN_MIRROR="${KLDLOAD_DEBIAN_MIRROR}"
KLDLOAD_INSTALLER_VERSION="1.0.0"
KLDLOAD_TARGET="${target}"
EOF

    log "Install manifest written: ${manifest_dir}/install-manifest.env"
}

# ---------------------------------------------------------------------------
# bootstrap_run — main entry point: full bootstrap sequence
# Args: target, profile, hostname, username, password, root_password
# ---------------------------------------------------------------------------

bootstrap_run() {
    local target="$1"
    local profile="$2"
    local hostname="$3"
    local username="$4"
    local password="$5"
    local root_password="$6"

    [[ -n "$target"        ]] || die "bootstrap_run: target required"
    [[ -n "$profile"       ]] || die "bootstrap_run: profile required"
    [[ -n "$hostname"      ]] || die "bootstrap_run: hostname required"
    [[ -n "$username"      ]] || die "bootstrap_run: username required"
    [[ -n "$password"      ]] || die "bootstrap_run: password required"
    [[ -n "$root_password" ]] || die "bootstrap_run: root_password required"

    log_section "Bootstrap Run: profile=$profile hostname=$hostname"

    bootstrap_debootstrap "$target" "$hostname"
    bootstrap_bind_mounts "$target"

    # Ensure unbind on exit
    # SC2064: single-quote the variable so it expands at trap time, not now
    # shellcheck disable=SC2064
    trap "bootstrap_unbind_mounts '$target'" EXIT

    bootstrap_write_sources "$target"
    bootstrap_install_packages "$target" "$profile"
    bootstrap_write_locale "$target"

    bootstrap_unbind_mounts "$target"
    trap - EXIT

    log "Bootstrap sequence complete."
}
