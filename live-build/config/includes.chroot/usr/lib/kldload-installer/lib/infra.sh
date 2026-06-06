#!/usr/bin/env bash
# infra.sh — control-plane infrastructure mode for the kldload guided installer
# Sourced by kldload-install-target.
# Provides: guided_infra_prompt, k_infra_calc_subnets, k_infra_node_table
set -Eeuo pipefail

# k_infra_calc_subnets — parse a /20 CIDR and derive 16 x /24 subnets.
# Sets: KLDLOAD_SUBNET_BASE, KLDLOAD_SUBNET_LIST, KLDLOAD_SUBNET_BLUE,
#       KLDLOAD_SUBNET_GREEN, KLDLOAD_HUB_IP
k_infra_calc_subnets() {
    local cidr="${1:?missing CIDR}"
    local base="${cidr%/*}"

    local o1 o2 o3
    IFS='.' read -r o1 o2 o3 _ <<<"$base"

    KLDLOAD_SUBNET_BASE="${o1}.${o2}.${o3}.0"
    KLDLOAD_SUBNET_LIST=""
    KLDLOAD_SUBNET_BLUE=""
    KLDLOAD_SUBNET_GREEN=""

    local i
    for ((i = 0; i < 16; i++)); do
        local sub="${o1}.${o2}.$((o3 + i)).0/24"
        KLDLOAD_SUBNET_LIST+="${sub} "
        if ((i < 8)); then
            KLDLOAD_SUBNET_BLUE+="${sub} "
        else
            KLDLOAD_SUBNET_GREEN+="${sub} "
        fi
    done

    # Hub always takes .1 in the first subnet
    KLDLOAD_HUB_IP="${o1}.${o2}.${o3}.1"

    export KLDLOAD_SUBNET_BASE KLDLOAD_SUBNET_LIST \
        KLDLOAD_SUBNET_BLUE KLDLOAD_SUBNET_GREEN KLDLOAD_HUB_IP
}

# k_infra_node_table — pretty-print the current node role table.
# Reads KLDLOAD_CLUSTER_CIDR and KLDLOAD_NODE_ROLE_<n> env vars.
k_infra_node_table() {
    local cidr="${KLDLOAD_CLUSTER_CIDR:-10.78.0.0/20}"
    local size="${KLDLOAD_CLUSTER_SIZE:-16}"
    local base="${cidr%/*}"
    local o1 o2 o3
    IFS='.' read -r o1 o2 o3 _ <<<"$base"

    printf '\n\e[1;37m  %-4s %-20s %-16s %-10s %s\e[0m\n' \
        "NODE" "SUBNET" "WG0 IP" "CLUSTER" "ROLE"
    printf '\e[1;34m  %-4s %-20s %-16s %-10s %s\e[0m\n' \
        "────" "──────────────────" "──────────────" "────────" "──────────────────"

    local i
    for ((i = 0; i < size; i++)); do
        local subnet="${o1}.${o2}.$((o3 + i)).0/24"
        local wg_ip="10.77.0.$((i + 1))"
        local cluster role color reset='\e[0m'

        if ((i < 8)); then
            cluster="blue"
            color='\e[1;34m'
        else
            cluster="green"
            color='\e[1;32m'
        fi

        local rvar="KLDLOAD_NODE_ROLE_${i}"
        role="${!rvar:-minion}"
        [[ $i -eq 0 ]] && role="master/hub"

        local role_color='\e[0;37m'
        [[ $i -eq 0 ]] && role_color='\e[1;33m'

        printf "${color}  %-4s %-20s %-16s %-10s ${role_color}%s${reset}\n" \
            "$i" "$subnet" "$wg_ip" "$cluster" "$role"
    done
    echo
}

# _infra_role_menu — list available roles
_infra_role_menu() {
    _info "  minion        — generic ZFS node (Salt minion, receives config)"
    _info "  k8s-control   — Kubernetes control plane (etcd + API server)"
    _info "  k8s-worker    — Kubernetes worker node"
    _info "  k8s-lb        — Load balancer (HAProxy)"
    _info "  storage       — Dedicated storage node (ZFS, NFS/iSCSI)"
    _info "  prometheus    — Metrics collection (Prometheus + node_exporter)"
    _info "  grafana       — Dashboard (Grafana)"
    _info "  custom        — Custom role (you define the Salt state)"
}

# _detect_cm_on_lan — probe the default gateway for a running Cluster Manager.
# Returns the LAN IP on stdout if found, empty otherwise.
_detect_cm_on_lan() {
    local gw
    gw="$(ip route show default 2>/dev/null | awk '/default/{print $3; exit}')"
    [[ -n "$gw" ]] || return 0
    local tmp
    tmp="$(mktemp)"
    if curl -fsS --max-time 3 "http://${gw}/hub.env" -o "$tmp" 2>/dev/null &&
        grep -q 'WG1_PUB=' "$tmp" 2>/dev/null; then
        echo "$gw"
    fi
    rm -f "$tmp"
}

# _detect_preprovisioned — check for a pre-provisioned answer file on disk or USB.
# Returns the CM LAN IP if found.
_detect_preprovisioned() {
    local _f
    for _f in /etc/kldload/answers.env /run/kldload-answers.env /mnt/answers.env; do
        if [[ -f "$_f" ]] && grep -q 'KLDLOAD_HUB_LAN=' "$_f"; then
            grep 'KLDLOAD_HUB_LAN=' "$_f" | cut -d= -f2 | tr -d '"' | head -1
            return 0
        fi
    done
}

# guided_infra_prompt — infrastructure screens (7+) for the guided installer.
# Called from guided_prompt() before the summary.
guided_infra_prompt() {
    local v

    # Read edition from baked-in file (free or pro)
    local _edition
    _edition="$(cat /etc/kldload/edition 2>/dev/null || echo free)"

    # ── 7 · Deployment Intent ─────────────────────────────────────────────────
    if [[ "$_edition" == "free" ]]; then
        # Free edition — standalone only
        _hdr "7 of 7  ·  Deployment Mode"
        _info "This is kldload Free — install as a standalone system."
        echo
        _info "  ZFS on root, boot environments, dark GNOME desktop,"
        _info "  offline installer — all included."
        echo
        _info "  Upgrade to kldload Pro for cluster management, WireGuard mesh,"
        _info "  golden image pipeline, multi-node fleet, and the full web UI."
        echo
        export KLDLOAD_INFRA_MODE="standalone"
        _ok "Mode" "Standalone (kldload Free)"
        return 0
    fi

    # Pro edition — full three-way choice
    _hdr "7 of 9  ·  Deployment Intent"
    _info "Choose how this node will be used:"
    echo
    _info "  standalone       — independent node, no cluster"
    _info "                     install KVM, storage, or any role as a self-contained"
    _info "                     system. Works without a Cluster Manager."
    echo
    _info "  cluster-manager  — this node becomes the cluster control plane"
    _info "                     generates all cluster keys, WireGuard hub, Salt master,"
    _info "                     state database, and web management UI."
    _info "                     deploy this first, then add other nodes."
    echo
    _info "  join             — connect this node to an existing Cluster Manager"
    _info "                     fetches cluster config from the CM over LAN at first boot."
    _info "                     the CM must already be running on this network."
    echo

    # Auto-detect pre-provisioned answer file
    local _preprovisioned_ip=""
    _preprovisioned_ip="$(_detect_preprovisioned)"
    if [[ -n "$_preprovisioned_ip" ]]; then
        _info "  ★ Pre-provisioned answer file detected — CM at ${_preprovisioned_ip}"
        _info "    This node slot is already reserved in the cluster database."
        echo
    fi

    # Auto-detect running CM on LAN
    local _detected_cm_ip=""
    if [[ -z "$_preprovisioned_ip" ]]; then
        printf '  \e[0;37mScanning LAN for Cluster Manager…\e[0m\r' >&2
        _detected_cm_ip="$(_detect_cm_on_lan)"
        if [[ -n "$_detected_cm_ip" ]]; then
            printf '                                       \r' >&2
            _info "  ★ Cluster Manager found at ${_detected_cm_ip}"
            echo
        else
            printf '                                       \r' >&2
        fi
    fi

    local _default_intent="standalone"
    [[ -n "$_preprovisioned_ip" || -n "$_detected_cm_ip" ]] && _default_intent="join"

    v="$(_ask "Deployment intent [standalone|cluster-manager|join]" "$_default_intent")"

    case "${v}" in
    cluster-manager | cm | master | control-plane | control | cp | hub)
        export KLDLOAD_INFRA_MODE="cluster-manager"
        export KLDLOAD_PROFILE="master"
        _ok "Intent" "Cluster Manager — this node is the cluster control plane"
        ;;
    join | cluster | member)
        export KLDLOAD_INFRA_MODE="join"
        # Use pre-provisioned IP if present, else detected, else ask
        local _hub_ip="${_preprovisioned_ip:-${_detected_cm_ip}}"
        if [[ -z "$_hub_ip" ]]; then
            _info ""
            _info "Enter the Cluster Manager's LAN IP address."
            _info "The CM must be reachable over the network before this node boots."
            _eg "10.100.10.45  or  192.168.1.10"
            _hub_ip="$(_ask "Cluster Manager IP")"
        fi
        export KLDLOAD_HUB_LAN="${_hub_ip}"
        _ok "Intent" "Join cluster — CM at ${KLDLOAD_HUB_LAN}"
        _info ""
        _info "At first boot this node will:"
        _info "  1. Fetch cluster config from http://${KLDLOAD_HUB_LAN}/hub.env"
        _info "  2. Configure WireGuard and connect to the management plane"
        _info "  3. Register with Salt master — appears in cluster DB automatically"
        return 0
        ;;
    *)
        export KLDLOAD_INFRA_MODE="standalone"
        _ok "Intent" "Standalone — independent node, no cluster"
        return 0
        ;;
    esac

    # ── 8 · Cluster Network ───────────────────────────────────────────────────
    _hdr "8 of 9  ·  Cluster Network"
    _info "A /20 CIDR provides 16 x /24 subnets:"
    _info "  Blue  cluster — subnets 0–7   (first 8 nodes)"
    _info "  Green cluster — subnets 8–15  (second 8 nodes)"
    _info "Two independent parallel deployments in the same /20 enable"
    _info "zero-downtime blue/green upgrades."
    echo
    _eg "10.78.0.0/20"
    KLDLOAD_CLUSTER_CIDR="$(_ask "Cluster CIDR" "10.78.0.0/20")"
    export KLDLOAD_CLUSTER_CIDR
    k_infra_calc_subnets "${KLDLOAD_CLUSTER_CIDR}"

    _eg "infra.local  cluster.internal  nodes.home"
    KLDLOAD_CLUSTER_DOMAIN="$(_ask "Cluster domain" "infra.local")"
    export KLDLOAD_CLUSTER_DOMAIN

    _info ""
    _info "Number of nodes (2–64). 16 fills the /20 space."
    KLDLOAD_CLUSTER_SIZE="$(_ask "Cluster size" "16")"
    [[ "${KLDLOAD_CLUSTER_SIZE}" =~ ^[0-9]+$ ]] || KLDLOAD_CLUSTER_SIZE=16
    export KLDLOAD_CLUSTER_SIZE

    _ok "CIDR" "${KLDLOAD_CLUSTER_CIDR}  →  ${KLDLOAD_CLUSTER_SIZE} nodes"
    _ok "Hub IP" "${KLDLOAD_HUB_IP}  (this machine — node 0)"
    _ok "Domain" "${KLDLOAD_CLUSTER_DOMAIN}"
    _ok "Blue" "$(printf '%s' "${KLDLOAD_SUBNET_BLUE}" | awk '{print $1}') … (8 subnets)"
    _ok "Green" "$(printf '%s' "${KLDLOAD_SUBNET_GREEN}" | awk '{print $1}') … (8 subnets)"

    # ── 9 · WireGuard Planes ──────────────────────────────────────────────────
    _hdr "9 of 9  ·  WireGuard Mesh Planes"
    _info "4 isolated WireGuard planes separate traffic by function:"
    echo
    _info "  wg0  10.77.0.0/16  :51820  — bootstrap / minion enrollment"
    _info "  wg1  10.78.0.0/16  :51821  — control / SSH / Salt"
    _info "  wg2  10.79.0.0/16  :51822  — metrics / monitoring"
    _info "  wg3  10.80.0.0/16  :51823  — data / storage / Kubernetes overlay"
    echo
    v="$(_ask "Accept default WireGuard plane layout?" "yes")"
    if [[ "${v}" == "yes" || "${v}" == "y" ]]; then
        export KLDLOAD_WG0_NET="10.77.0.0/16" KLDLOAD_WG0_PORT="51820"
        export KLDLOAD_WG1_NET="10.78.0.0/16" KLDLOAD_WG1_PORT="51821"
        export KLDLOAD_WG2_NET="10.79.0.0/16" KLDLOAD_WG2_PORT="51822"
        export KLDLOAD_WG3_NET="10.80.0.0/16" KLDLOAD_WG3_PORT="51823"
    else
        _info "Enter network CIDR and port for each plane:"
        KLDLOAD_WG0_NET="$(_ask "wg0 network" "10.77.0.0/16")"
        export KLDLOAD_WG0_NET
        KLDLOAD_WG0_PORT="$(_ask "wg0 port" "51820")"
        export KLDLOAD_WG0_PORT
        KLDLOAD_WG1_NET="$(_ask "wg1 network" "10.78.0.0/16")"
        export KLDLOAD_WG1_NET
        KLDLOAD_WG1_PORT="$(_ask "wg1 port" "51821")"
        export KLDLOAD_WG1_PORT
        KLDLOAD_WG2_NET="$(_ask "wg2 network" "10.79.0.0/16")"
        export KLDLOAD_WG2_NET
        KLDLOAD_WG2_PORT="$(_ask "wg2 port" "51822")"
        export KLDLOAD_WG2_PORT
        KLDLOAD_WG3_NET="$(_ask "wg3 network" "10.80.0.0/16")"
        export KLDLOAD_WG3_NET
        KLDLOAD_WG3_PORT="$(_ask "wg3 port" "51823")"
        export KLDLOAD_WG3_PORT
    fi
    _ok "wg0" "${KLDLOAD_WG0_NET}  :${KLDLOAD_WG0_PORT}  (bootstrap)"
    _ok "wg1" "${KLDLOAD_WG1_NET}  :${KLDLOAD_WG1_PORT}  (control)"
    _ok "wg2" "${KLDLOAD_WG2_NET}  :${KLDLOAD_WG2_PORT}  (metrics)"
    _ok "wg3" "${KLDLOAD_WG3_NET}  :${KLDLOAD_WG3_PORT}  (data)"
    echo
    _info "All cluster configuration is stored in the state database (state.db)."
    _info "Keys, node roles, and WireGuard addresses are"
    _info "generated and managed through the web UI after first boot."
    _info "Additional nodes are added via the Cluster Manager web UI — no pre-config needed."
}
