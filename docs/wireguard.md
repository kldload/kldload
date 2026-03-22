# WireGuard on kldload

`wireguard-tools` is pre-installed on every kldload system (CentOS and Debian). The kernel module ships with the default kernel — no DKMS needed.

---

## Standalone point-to-point tunnel

The simplest case: connect two kldload nodes over the internet.

### Generate keys (on both nodes)

```bash
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key
```

### Node A config — `/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = <node-A-private-key>

[Peer]
PublicKey = <node-B-public-key>
AllowedIPs = 10.0.0.2/32
Endpoint = <node-B-public-ip>:51820
PersistentKeepalive = 25
```

### Node B config — `/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.2/24
ListenPort = 51820
PrivateKey = <node-B-private-key>

[Peer]
PublicKey = <node-A-public-key>
AllowedIPs = 10.0.0.1/32
Endpoint = <node-A-public-ip>:51820
PersistentKeepalive = 25
```

### Bring it up

```bash
# Start
systemctl enable --now wg-quick@wg0

# Verify
wg show
ping 10.0.0.2   # from node A
```

### Open the firewall (if firewalld is active)

```bash
firewall-cmd --permanent --add-port=51820/udp
firewall-cmd --permanent --zone=trusted --add-interface=wg0
firewall-cmd --reload
```

---

## Hub-and-spoke (road warrior)

One server, multiple clients. Useful for remote access to a home lab or office.

### Hub — `/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = <hub-private-key>

# Enable IP forwarding so clients can reach each other and the LAN
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# Client 1
PublicKey = <client-1-pubkey>
AllowedIPs = 10.0.0.2/32

[Peer]
# Client 2
PublicKey = <client-2-pubkey>
AllowedIPs = 10.0.0.3/32
```

### Client — `/etc/wireguard/wg0.conf`

```ini
[Interface]
Address = 10.0.0.2/24
PrivateKey = <client-private-key>
# Route all traffic through the hub (full tunnel):
# DNS = 1.1.1.1

[Peer]
PublicKey = <hub-pubkey>
Endpoint = <hub-public-ip>:51820
AllowedIPs = 10.0.0.0/24
# Use 0.0.0.0/0 instead to route ALL traffic through the hub
PersistentKeepalive = 25
```

---

## kldload cluster mesh

kldload uses 4 isolated WireGuard planes to separate cluster traffic:

| Interface | Network | Port | Purpose |
|-----------|---------|------|---------|
| `wg0` | `10.77.0.0/16` | 51820 | Bootstrap / minion enrollment |
| `wg1` | `10.78.0.0/16` | 51821 | Control / SSH / Salt |
| `wg2` | `10.79.0.0/16` | 51822 | Metrics / monitoring |
| `wg3` | `10.80.0.0/16` | 51823 | Data / storage / Kubernetes overlay |

This is configured automatically during install when you select the `cluster-manager` or `join` deployment mode. See `ARCHITECTURE.md` for details on the cluster setup flow.

You can also set this up manually by creating four separate `wg0`–`wg3` configs with different subnets and ports, then enabling all four:

```bash
for iface in wg0 wg1 wg2 wg3; do
  systemctl enable --now wg-quick@${iface}
done
```

---

## Troubleshooting

```bash
# Check interface status and handshake times
wg show

# Watch for handshake — if "latest handshake" never appears, check:
#   1. Firewall on both ends (UDP port open?)
#   2. Endpoint IP/port correct?
#   3. Keys match? (pubkey on A == peer pubkey on B, and vice versa)

# Debug with kernel logs
journalctl -k | grep wireguard

# Check if the module is loaded
lsmod | grep wireguard

# Manual interface control
wg-quick up wg0
wg-quick down wg0
```

---

## ZFS snapshots and WireGuard

Since kldload uses ZFS on root, your WireGuard keys in `/etc/wireguard/` are captured in ZFS snapshots. If you roll back a boot environment, your keys roll back too. Keep a backup of your private keys outside ZFS if you rotate keys frequently.
