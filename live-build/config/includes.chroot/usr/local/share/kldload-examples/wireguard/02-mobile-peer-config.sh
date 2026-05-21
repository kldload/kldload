#!/usr/bin/env bash
# 02-mobile-peer-config.sh — generate a WireGuard peer config for a
# phone/laptop. The peer terminates on this kldload box at WG_VIP and
# gets routed access to the LAN behind it.
#
# Usage:  ./02-mobile-peer-config.sh "peer-name"
# Output: ./<peer-name>.conf  (paste into the WireGuard mobile app)
#         ./<peer-name>.png   (QR code for the mobile app to scan)
#
# Side effect: appends a [Peer] block to /etc/wireguard/wg0.conf and
# reloads it. Idempotent: re-running for the same peer name regenerates
# keys + replaces the block.
set -euo pipefail

PEER_NAME="${1:?usage: $0 <peer-name>}"
WG_IF=wg0
WG_NET=10.250.1                       # peer network — /24
WG_PORT=51820
LAN_BEHIND_HOST="192.168.1.0/24"      # what the peer can reach via you
DNS_SERVER="10.250.1.1"               # this box acts as DNS for peers
HOST_PUBLIC_IP="${PUBLIC_IP:-$(curl -s https://api.ipify.org)}"
HOST_PUBKEY="${HOST_PUBKEY:-$(sudo wg show $WG_IF public-key 2>/dev/null)}"

if [[ -z "$HOST_PUBKEY" ]]; then
  echo "ERROR: $WG_IF not configured on this host. Set up the WG endpoint first:"
  echo "       sudo bash -c 'umask 077; wg genkey | tee /etc/wireguard/wg0.key | wg pubkey > /etc/wireguard/wg0.pub'"
  echo "       sudo cp /etc/wireguard/wg0.tpl /etc/wireguard/wg0.conf"
  echo "       sudo systemctl enable --now wg-quick@wg0"
  exit 1
fi

# Find next free /32 in the peer subnet
USED=$(sudo wg show $WG_IF allowed-ips 2>/dev/null | grep -oE "${WG_NET//./\\.}\.[0-9]+" | sort -u)
NEXT=2
while echo "$USED" | grep -qx "${WG_NET}.${NEXT}"; do
  NEXT=$((NEXT + 1))
done
PEER_IP="${WG_NET}.${NEXT}"

# Generate peer keys
PEER_PRIV=$(wg genkey)
PEER_PUB=$(echo "$PEER_PRIV" | wg pubkey)
PEER_PSK=$(wg genpsk)

# Write peer config (the file the user pastes into their WG app)
cat > "${PEER_NAME}.conf" <<EOF
[Interface]
PrivateKey = $PEER_PRIV
Address    = ${PEER_IP}/24
DNS        = $DNS_SERVER

[Peer]
PublicKey    = $HOST_PUBKEY
PresharedKey = $PEER_PSK
Endpoint     = ${HOST_PUBLIC_IP}:${WG_PORT}
AllowedIPs   = ${LAN_BEHIND_HOST}, ${WG_NET}.0/24
PersistentKeepalive = 25
EOF
chmod 600 "${PEER_NAME}.conf"

# Add the peer to this host's running config
sudo wg set $WG_IF peer "$PEER_PUB" \
    preshared-key <(echo "$PEER_PSK") \
    allowed-ips "${PEER_IP}/32" \
    persistent-keepalive 25
# Persist to /etc/wireguard/wg0.conf
sudo wg-quick save $WG_IF

# Generate QR code for easy mobile import
if command -v qrencode >/dev/null 2>&1; then
  qrencode -t png -o "${PEER_NAME}.png" < "${PEER_NAME}.conf"
  echo "QR code: ${PEER_NAME}.png"
fi

echo
echo "Peer '$PEER_NAME' configured."
echo "  Internal IP: $PEER_IP"
echo "  Config file: ${PEER_NAME}.conf"
echo "  Import on phone: WireGuard app → ＋ → Scan from QR code → use ${PEER_NAME}.png"
echo "  Import on laptop: wg-quick up ./${PEER_NAME}.conf"
