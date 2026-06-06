#!/usr/bin/env bash
# 01-host-to-host-mesh.sh — generate WireGuard configs for an N-host
# mesh between kldload boxes. Each box gets a config that peers with
# every other box (full mesh).
#
# Run on ONE box; copy the resulting .conf files to the other hosts.
#
# Usage:
#   ./01-host-to-host-mesh.sh "alpha:192.168.1.10 beta:192.168.1.11 gamma:192.168.1.12"
#
# Output:
#   ./wg-mesh/alpha.conf  ./wg-mesh/beta.conf  ./wg-mesh/gamma.conf
#
# Deployment:
#   scp wg-mesh/<host>.conf root@<host>:/etc/wireguard/wg-mesh.conf
#   ssh root@<host> systemctl enable --now wg-quick@wg-mesh
#
# After it's up:
#   ping 10.250.0.<n>    (the mesh's internal address space)
#   wg show wg-mesh      (peer status)
set -euo pipefail

HOSTS_ARG="${1:?usage: $0 \"host1:lan_ip1 host2:lan_ip2 ...\"}"
WG_NET="10.250.0" # mesh network — /24
WG_PORT=51820
OUTDIR="./wg-mesh"

mkdir -p "$OUTDIR"

# Parse hosts into arrays
declare -a NAMES IPS WG_IPS PRIVKEYS PUBKEYS
i=1
for spec in $HOSTS_ARG; do
    NAMES+=("${spec%:*}")
    IPS+=("${spec#*:}")
    WG_IPS+=("${WG_NET}.${i}")
    pk=$(wg genkey)
    PRIVKEYS+=("$pk")
    PUBKEYS+=("$(echo "$pk" | wg pubkey)")
    i=$((i + 1))
done

N=${#NAMES[@]}
echo "Generating $N-host mesh on $WG_NET.0/24..."

# Write one config per host
for ((j = 0; j < N; j++)); do
    conf="$OUTDIR/${NAMES[$j]}.conf"
    cat >"$conf" <<EOF
# wg-mesh.conf — kldload host ${NAMES[$j]}
# Mesh peers: $(
        IFS=,
        echo "${NAMES[*]}" | sed "s/${NAMES[$j]},\?//;s/,$//"
    )
# Activate:  systemctl enable --now wg-quick@wg-mesh

[Interface]
Address    = ${WG_IPS[$j]}/24
ListenPort = $WG_PORT
PrivateKey = ${PRIVKEYS[$j]}
# Hooks fire on up/down. Useful for adding routes to /etc/hosts entries
# or kicking other services. Default: nothing.

EOF
    for ((k = 0; k < N; k++)); do
        [[ $j -eq $k ]] && continue
        cat >>"$conf" <<EOF
[Peer]
# ${NAMES[$k]}
PublicKey  = ${PUBKEYS[$k]}
Endpoint   = ${IPS[$k]}:$WG_PORT
AllowedIPs = ${WG_IPS[$k]}/32
PersistentKeepalive = 25
EOF
    done
    echo "  wrote $conf"
done

echo
echo "Done. Deploy each host's config + activate:"
for ((j = 0; j < N; j++)); do
    echo "  scp $OUTDIR/${NAMES[$j]}.conf root@${IPS[$j]}:/etc/wireguard/wg-mesh.conf && \\"
    echo "    ssh root@${IPS[$j]} 'chmod 600 /etc/wireguard/wg-mesh.conf && systemctl enable --now wg-quick@wg-mesh'"
done
echo
echo "Verify:  wg show wg-mesh   (run on any host)"
