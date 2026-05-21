#!/usr/bin/env bash
# 03-site-to-site.sh — site-to-site WireGuard. Two kldload boxes
# bridge their LANs as if they were one network. After this is up,
# 192.168.10.0/24 (site A) and 192.168.20.0/24 (site B) reach each
# other transparently.
#
# Run once, follow the printed instructions to deploy to both sites.
set -euo pipefail

# Edit these for your topology
SITE_A_NAME=site-a
SITE_A_LAN=192.168.10.0/24
SITE_A_PUBLIC_IP=203.0.113.10
SITE_A_WG_IP=10.250.2.1

SITE_B_NAME=site-b
SITE_B_LAN=192.168.20.0/24
SITE_B_PUBLIC_IP=198.51.100.20
SITE_B_WG_IP=10.250.2.2

WG_PORT=51820
OUTDIR="./wg-s2s"
mkdir -p "$OUTDIR"

A_PRIV=$(wg genkey); A_PUB=$(echo "$A_PRIV" | wg pubkey)
B_PRIV=$(wg genkey); B_PUB=$(echo "$B_PRIV" | wg pubkey)
PSK=$(wg genpsk)

cat > "$OUTDIR/${SITE_A_NAME}-wg0.conf" <<EOF
# Site A — ${SITE_A_NAME} (LAN ${SITE_A_LAN})
[Interface]
Address    = ${SITE_A_WG_IP}/30
ListenPort = $WG_PORT
PrivateKey = $A_PRIV
# Forward LAN-to-WG packets
PostUp   = sysctl -w net.ipv4.ip_forward=1 ; iptables -A FORWARD -i wg0 -j ACCEPT ; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT ; iptables -D FORWARD -o wg0 -j ACCEPT

[Peer]
# Site B
PublicKey    = $B_PUB
PresharedKey = $PSK
Endpoint     = ${SITE_B_PUBLIC_IP}:${WG_PORT}
AllowedIPs   = ${SITE_B_LAN}, ${SITE_B_WG_IP}/32
PersistentKeepalive = 25
EOF

cat > "$OUTDIR/${SITE_B_NAME}-wg0.conf" <<EOF
# Site B — ${SITE_B_NAME} (LAN ${SITE_B_LAN})
[Interface]
Address    = ${SITE_B_WG_IP}/30
ListenPort = $WG_PORT
PrivateKey = $B_PRIV
PostUp   = sysctl -w net.ipv4.ip_forward=1 ; iptables -A FORWARD -i wg0 -j ACCEPT ; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT ; iptables -D FORWARD -o wg0 -j ACCEPT

[Peer]
# Site A
PublicKey    = $A_PUB
PresharedKey = $PSK
Endpoint     = ${SITE_A_PUBLIC_IP}:${WG_PORT}
AllowedIPs   = ${SITE_A_LAN}, ${SITE_A_WG_IP}/32
PersistentKeepalive = 25
EOF

chmod 600 "$OUTDIR"/*.conf

cat <<EOF

Configs generated in $OUTDIR:

Site A (${SITE_A_PUBLIC_IP}):
  scp $OUTDIR/${SITE_A_NAME}-wg0.conf root@${SITE_A_PUBLIC_IP}:/etc/wireguard/wg0.conf
  ssh root@${SITE_A_PUBLIC_IP} 'systemctl enable --now wg-quick@wg0'

Site B (${SITE_B_PUBLIC_IP}):
  scp $OUTDIR/${SITE_B_NAME}-wg0.conf root@${SITE_B_PUBLIC_IP}:/etc/wireguard/wg0.conf
  ssh root@${SITE_B_PUBLIC_IP} 'systemctl enable --now wg-quick@wg0'

After both are up, verify cross-LAN connectivity:
  # From a host on Site A's LAN
  ping 192.168.20.x   # any host on Site B
  # On the kldload box: wg show wg0  (peer status)

Static routes may be needed on hosts that DON'T use the kldload box
as default gateway — add a static route via the kldload box's LAN IP
for the remote subnet on each LAN host.
EOF
