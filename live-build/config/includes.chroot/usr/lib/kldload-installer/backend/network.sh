#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# network.sh — network configuration library (sourced)
# Requires: common.sh
# ---------------------------------------------------------------------------

[[ "${_KLDLOAD_NETWORK_LOADED:-0}" == "1" ]] && return 0
_KLDLOAD_NETWORK_LOADED=1

# ---------------------------------------------------------------------------
# network_write_hostname — write hostname and /etc/hosts
# Args: target, hostname
# ---------------------------------------------------------------------------

network_write_hostname() {
    local target="$1"
    local hostname="$2"

    [[ -n "$target" ]] || die "network_write_hostname: target required"
    [[ -n "$hostname" ]] || die "network_write_hostname: hostname required"

    log "Writing hostname: $hostname"

    echo "$hostname" >"${target}/etc/hostname"

    cat >"${target}/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   ${hostname}

# The following lines are desirable for IPv6 capable hosts
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

    log "Hostname written: $hostname"
    log "/etc/hosts written: ${target}/etc/hosts"
}

# ---------------------------------------------------------------------------
# network_enable_nm — enable NetworkManager in the target
# Args: target
# ---------------------------------------------------------------------------

network_enable_nm() {
    local target="$1"
    [[ -n "$target" ]] || die "network_enable_nm: target required"

    log "Enabling NetworkManager in $target..."
    in_chroot "$target" "systemctl enable NetworkManager 2>/dev/null || true"
    log "NetworkManager enabled."
}

# ---------------------------------------------------------------------------
# network_write_resolv — write a basic /etc/resolv.conf with fallback DNS
# Args: target
# ---------------------------------------------------------------------------

network_write_resolv() {
    local target="$1"
    [[ -n "$target" ]] || die "network_write_resolv: target required"

    log "Writing /etc/resolv.conf in $target..."

    cat >"${target}/etc/resolv.conf" <<'EOF'
# KLDload default resolv.conf — replaced by NetworkManager/systemd-resolved at runtime
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:3
EOF

    log "/etc/resolv.conf written."
}
