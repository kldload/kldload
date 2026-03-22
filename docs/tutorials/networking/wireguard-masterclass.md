# WireGuard Masterclass

## The elephant in the room

WireGuard is a kernel module. On kldloadOS, it ships with every install — CentOS and Debian — as part of the stock kernel. No DKMS, no patches, no extra packages. It's just there.

This matters more than most people realize.

When you create a WireGuard interface, the kernel creates a network device that looks and behaves exactly like a physical NIC. Applications don't know they're running on a tunnel. `ping`, `ssh`, `curl`, `nginx`, `postgres` — they all see a normal network interface with an IP address. The encryption happens below them, in the kernel, before any packet hits the physical wire.

From the outside — from the perspective of anyone scanning your network, your ISP, or anything sitting between your nodes — all they see is UDP traffic on a single port. They can't see what's inside. They can't see how many services are running. They can't fingerprint what you're doing. They can't even tell it's WireGuard without deep packet inspection, and even then, WireGuard's packets look like random noise because they don't respond to unauthenticated traffic at all.

**A WireGuard interface that has no peers configured is completely silent. It doesn't respond to anything. It doesn't even acknowledge that it exists.**

This means you can build entire private networks — backplanes, control planes, data planes — that run silently underneath whatever your "visible" OS is doing. The applications running on top don't know. The outside world doesn't know. It's an invisible encrypted layer between your machines.

kldloadOS has this built in to every install. Here's how to use it.

---

## What makes WireGuard different

### It's in the kernel

OpenVPN runs in userspace. IPSec has a complex kernel/userspace split. WireGuard runs entirely in the kernel as a network device. This means:

- **No context switches** between kernel and userspace for packet processing
- **No TUN/TAP overhead** — packets go directly through the kernel network stack
- **Kernel-level routing** — WireGuard interfaces participate in the routing table like any physical NIC
- **Applications are oblivious** — they bind to addresses and send packets. The kernel handles encryption transparently.

### It's silent by default

WireGuard implements a concept called **cryptokey routing**. A peer is identified by its public key and a list of allowed IP ranges. If a packet arrives that doesn't match any peer's public key, WireGuard doesn't respond. At all. No RST, no ICMP unreachable, no "port closed" message. Nothing.

This means:
- Port scanners see nothing
- Unauthenticated packets are silently dropped
- The UDP port appears "filtered" or non-existent to outsiders
- There is no handshake until both sides have the correct keys

### It's stateless on disk

A WireGuard configuration is just a key pair and a peer list. There's no certificate authority, no PKI infrastructure, no certificate renewal, no CRL checking. Two machines that know each other's public keys can communicate. Period.

### It roams automatically

If a peer's IP address changes (laptop moves from WiFi to cellular, VM migrates, dynamic IP renews), WireGuard detects it from the next authenticated packet and updates the endpoint automatically. No reconnection, no renegotiation.

---

## Building a silent backplane

A backplane is a private network that runs underneath your production services. Your services bind to the backplane addresses. The outside world only sees the physical interface.

### The concept

```
┌─────────────────────────────────────────────────────────────┐
│                    The visible world                         │
│                                                             │
│  eth0: 203.0.113.10          eth0: 203.0.113.20            │
│  (public, scannable,         (public, scannable,            │
│   only UDP 51820 open)        only UDP 51820 open)          │
│         │                            │                      │
│         └────── UDP 51820 ───────────┘                      │
│                (encrypted noise)                            │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│                    The invisible backplane                   │
│                                                             │
│  wg0: 10.200.0.1            wg0: 10.200.0.2               │
│  ├── SSH (port 22)           ├── SSH (port 22)              │
│  ├── Postgres (5432)         ├── nginx (80, 443)            │
│  ├── Prometheus (9090)       ├── node_exporter (9100)       │
│  └── Grafana (3000)          └── app server (8080)          │
│                                                             │
│  These services ONLY listen on wg0.                         │
│  They are invisible from eth0.                              │
│  They don't exist to the outside world.                     │
└─────────────────────────────────────────────────────────────┘
```

### Step 1: Generate keys on every node

```bash
# On each machine
umask 077
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
```

### Step 2: Create the backplane config

**Node A (10.200.0.1)** — `/etc/wireguard/wg-backplane.conf`:

```ini
[Interface]
Address = 10.200.0.1/24
ListenPort = 51820
PrivateKey = <node-A-private-key>

# Lock the interface to a specific routing table (optional, advanced)
# Table = 200
# PostUp = ip rule add from 10.200.0.1 table 200

[Peer]
# Node B
PublicKey = <node-B-public-key>
AllowedIPs = 10.200.0.2/32
Endpoint = 203.0.113.20:51820
PersistentKeepalive = 25

[Peer]
# Node C
PublicKey = <node-C-public-key>
AllowedIPs = 10.200.0.3/32
Endpoint = 203.0.113.30:51820
PersistentKeepalive = 25
```

**Node B (10.200.0.2)** — `/etc/wireguard/wg-backplane.conf`:

```ini
[Interface]
Address = 10.200.0.2/24
ListenPort = 51820
PrivateKey = <node-B-private-key>

[Peer]
# Node A
PublicKey = <node-A-public-key>
AllowedIPs = 10.200.0.1/32
Endpoint = 203.0.113.10:51820
PersistentKeepalive = 25

[Peer]
# Node C
PublicKey = <node-C-public-key>
AllowedIPs = 10.200.0.3/32
Endpoint = 203.0.113.30:51820
PersistentKeepalive = 25
```

### Step 3: Bring it up

```bash
systemctl enable --now wg-quick@wg-backplane
```

### Step 4: Bind services to the backplane only

The key step — services only listen on the backplane address, not on eth0:

```bash
# SSH — only accessible over the backplane
cat >> /etc/ssh/sshd_config << 'EOF'
ListenAddress 10.200.0.1
EOF
systemctl restart sshd

# PostgreSQL — only accessible over the backplane
# In postgresql.conf:
# listen_addresses = '10.200.0.1'

# Prometheus — only on backplane
# --web.listen-address=10.200.0.1:9090

# nginx — only on backplane (or split: 443 on eth0, management on backplane)
# listen 10.200.0.1:8080;
```

### Step 5: Firewall the physical interface

Now lock down eth0 so only WireGuard UDP passes through:

```bash
# CentOS/RHEL (firewalld)
firewall-cmd --permanent --zone=public --remove-service=ssh
firewall-cmd --permanent --zone=public --add-port=51820/udp
firewall-cmd --permanent --zone=trusted --add-interface=wg-backplane
firewall-cmd --reload

# Debian (nftables)
cat > /etc/nftables.d/backplane.nft << 'EOF'
table inet filter {
  chain input {
    # Allow WireGuard UDP on physical interface
    iifname "eth0" udp dport 51820 accept

    # Allow everything on the backplane
    iifname "wg-backplane" accept

    # Drop everything else on eth0
    iifname "eth0" drop
  }
}
EOF
systemctl reload nftables
```

**Result:** From the outside, port scans show nothing. Not even SSH. The only thing visible is UDP 51820, which doesn't respond to unauthenticated traffic. All your services are running, fully functional, accessible only through the encrypted backplane.

---

## Multiple backplanes (traffic isolation)

One backplane is good. Multiple backplanes separate concerns:

```
wg-mgmt:     10.200.0.0/24  port 51820  — SSH, Salt, management
wg-data:     10.201.0.0/24  port 51821  — database replication, NFS, storage
wg-monitor:  10.202.0.0/24  port 51822  — Prometheus, Grafana, metrics
wg-app:      10.203.0.0/24  port 51823  — application traffic, API calls
```

Each plane has its own key pair, its own subnet, its own port. Traffic on one plane can't leak to another. If the monitoring plane is compromised, the attacker can see metrics but can't reach the database on the data plane — different keys, different network, different everything.

### Generate keys for each plane

```bash
for plane in mgmt data monitor app; do
  wg genkey | tee /etc/wireguard/${plane}.key | wg pubkey > /etc/wireguard/${plane}.pub
done
chmod 600 /etc/wireguard/*.key
```

### Create configs for each plane

```bash
# Template — repeat for each plane with different addresses/ports
for plane in mgmt:10.200.0:51820 data:10.201.0:51821 monitor:10.202.0:51822 app:10.203.0:51823; do
  IFS=: read name subnet port <<< "$plane"
  cat > /etc/wireguard/wg-${name}.conf << EOF
[Interface]
Address = ${subnet}.1/24
ListenPort = ${port}
PrivateKey = $(cat /etc/wireguard/${name}.key)

# Add peers below
EOF
done
```

Then add `[Peer]` blocks for each node on each plane. Each peer needs a unique key pair per plane — don't reuse keys across planes.

### Bring all planes up

```bash
for plane in mgmt data monitor app; do
  systemctl enable --now wg-quick@wg-${plane}
done
```

### Bind services to specific planes

```bash
# SSH only on management plane
ListenAddress 10.200.0.1        # sshd_config

# PostgreSQL only on data plane
listen_addresses = '10.201.0.1'  # postgresql.conf

# Prometheus only on monitor plane
--web.listen-address=10.202.0.1:9090

# Your app only on app plane
APP_BIND=10.203.0.1:8080
```

Now each service is only reachable on its designated plane. An attacker who somehow gets access to the monitoring network can't reach the database, can't SSH to anything, can't touch the application.

---

## Full mesh vs hub-and-spoke

### Hub-and-spoke

All traffic goes through a central hub. Simpler to configure (peers only need the hub's endpoint), but the hub is a bottleneck and single point of failure.

```
     ┌─── Node B
     │
Hub ─┼─── Node C
     │
     └─── Node D
```

Good for: remote access, home labs, small deployments, road warriors.

### Full mesh

Every node connects directly to every other node. No bottleneck, no single point of failure, but O(n²) peer configurations.

```
Node A ─── Node B
  │  ╲      │
  │   ╲     │
  │    ╲    │
Node C ─── Node D
```

Good for: clusters, production infrastructure, low-latency requirements.

### Full mesh configuration

For a 4-node full mesh, each node needs 3 peer blocks:

```bash
#!/bin/bash
# generate-mesh.sh — generate full mesh WireGuard configs
# Usage: ./generate-mesh.sh

declare -A NODES=(
  [node-a]="203.0.113.10:10.200.0.1"
  [node-b]="203.0.113.20:10.200.0.2"
  [node-c]="203.0.113.30:10.200.0.3"
  [node-d]="203.0.113.40:10.200.0.4"
)

PORT=51820

# Generate keys
for name in "${!NODES[@]}"; do
  wg genkey | tee "keys/${name}.key" | wg pubkey > "keys/${name}.pub"
done

# Generate configs
for name in "${!NODES[@]}"; do
  IFS=: read pub_ip wg_ip <<< "${NODES[$name]}"

  cat > "configs/${name}.conf" << CONF
[Interface]
Address = ${wg_ip}/24
ListenPort = ${PORT}
PrivateKey = $(cat keys/${name}.key)
CONF

  for peer in "${!NODES[@]}"; do
    [[ "$peer" == "$name" ]] && continue
    IFS=: read peer_pub peer_wg <<< "${NODES[$peer]}"

    cat >> "configs/${name}.conf" << CONF

[Peer]
# ${peer}
PublicKey = $(cat keys/${peer}.pub)
AllowedIPs = ${peer_wg}/32
Endpoint = ${peer_pub}:${PORT}
PersistentKeepalive = 25
CONF
  done
done

echo "Configs generated in configs/"
echo "Distribute each .conf to its respective node at /etc/wireguard/wg0.conf"
```

```bash
mkdir -p keys configs
chmod 700 keys
./generate-mesh.sh
```

### Dynamic mesh with wg-quick and PostUp

For larger meshes, use a script to add peers dynamically:

```ini
[Interface]
Address = 10.200.0.1/24
ListenPort = 51820
PrivateKey = <key>
PostUp = /etc/wireguard/add-mesh-peers.sh %i
PostDown = /etc/wireguard/remove-mesh-peers.sh %i
```

---

## NAT traversal and peers behind firewalls

WireGuard handles NAT naturally with `PersistentKeepalive`. But there are edge cases:

### Both peers behind NAT

If neither peer has a public IP, neither can set an `Endpoint` for the other. Solutions:

1. **Use a relay node** — one node with a public IP acts as a hub. Both NAT'd peers connect to it, and it forwards traffic.

2. **Use a STUN/TURN approach** — not built into WireGuard, but you can use a coordination service to exchange endpoints.

3. **Use a cloud relay** — spin up a tiny VM (t2.micro, free tier) as a WireGuard hub. Both peers connect to it.

```bash
# Tiny relay VM config
[Interface]
Address = 10.200.0.1/24
ListenPort = 51820
PrivateKey = <relay-key>
PostUp = sysctl -w net.ipv4.ip_forward=1

[Peer]
# Home lab (behind NAT)
PublicKey = <home-pub>
AllowedIPs = 10.200.0.2/32
# No Endpoint — the home lab connects to us

[Peer]
# Office (behind NAT)
PublicKey = <office-pub>
AllowedIPs = 10.200.0.3/32
# No Endpoint — the office connects to us
```

Both NAT'd peers set the relay as their `Endpoint`. The relay forwards traffic between them. They can reach each other via 10.200.0.x addresses through the relay.

### Changing ports to avoid corporate firewalls

Some networks block non-standard UDP ports. Use 443 or 53 instead:

```ini
[Interface]
ListenPort = 443   # looks like HTTPS to basic firewalls
```

Or run WireGuard on port 53:

```ini
[Interface]
ListenPort = 53    # looks like DNS
```

---

## Site-to-site: connecting entire networks

Connect two LANs so all devices on both sides can talk to each other:

### Site A — LAN 192.168.1.0/24

```ini
[Interface]
Address = 10.200.0.1/24
ListenPort = 51820
PrivateKey = <site-a-key>
PostUp = sysctl -w net.ipv4.ip_forward=1

[Peer]
PublicKey = <site-b-key>
AllowedIPs = 10.200.0.2/32, 192.168.2.0/24
Endpoint = <site-b-public-ip>:51820
PersistentKeepalive = 25
```

### Site B — LAN 192.168.2.0/24

```ini
[Interface]
Address = 10.200.0.2/24
ListenPort = 51820
PrivateKey = <site-b-key>
PostUp = sysctl -w net.ipv4.ip_forward=1

[Peer]
PublicKey = <site-a-key>
AllowedIPs = 10.200.0.1/32, 192.168.1.0/24
Endpoint = <site-a-public-ip>:51820
PersistentKeepalive = 25
```

The `AllowedIPs` field includes the remote LAN subnet. WireGuard routes packets for those subnets through the tunnel. Devices on LAN A (192.168.1.x) can reach devices on LAN B (192.168.2.x) transparently — no VPN client needed on individual devices.

Add routes on each site's router pointing the remote subnet to the WireGuard gateway:

```bash
# On Site A's router (or the WireGuard host if it IS the router)
ip route add 192.168.2.0/24 via 10.200.0.1 dev wg0
```

---

## Split tunnel vs full tunnel

### Split tunnel (default)

Only traffic destined for the WireGuard subnet goes through the tunnel. Everything else goes out the normal internet connection.

```ini
[Peer]
AllowedIPs = 10.200.0.0/24    # only backplane traffic tunneled
```

### Full tunnel

ALL traffic goes through the tunnel. Your exit IP becomes the remote peer's IP. Useful for privacy, bypassing geo-restrictions, or routing all traffic through a trusted exit point.

```ini
[Peer]
AllowedIPs = 0.0.0.0/0, ::/0  # everything tunneled
```

When using full tunnel, set DNS on the interface:

```ini
[Interface]
Address = 10.200.0.2/24
PrivateKey = <key>
DNS = 1.1.1.1, 9.9.9.9
```

### Split tunnel with specific routes

Route only certain subnets through the tunnel:

```ini
[Peer]
AllowedIPs = 10.200.0.0/24, 10.0.0.0/8, 172.16.0.0/12
# Only RFC1918 private traffic goes through the tunnel
# Public internet traffic goes out normally
```

---

## Stealth configuration

Maximum invisibility. The goal: nothing about this machine reveals that it's part of a private network.

### 1. No listening port on the initiator

If a node only initiates connections (never receives them), it doesn't need a `ListenPort`:

```ini
[Interface]
Address = 10.200.0.5/24
PrivateKey = <key>
# No ListenPort — uses a random ephemeral port
# No UDP port visible in port scans

[Peer]
PublicKey = <hub-key>
Endpoint = <hub-ip>:51820
AllowedIPs = 10.200.0.0/24
PersistentKeepalive = 25
```

The node connects outbound to the hub. The hub can reach it back through the established tunnel. But no port is open on this machine — nothing to scan, nothing to find.

### 2. Non-standard port on the hub

```ini
ListenPort = 8172   # or any random high port
```

### 3. Firewall everything except WireGuard

```bash
# Only allow WireGuard UDP, drop everything else
# CentOS
firewall-cmd --permanent --zone=drop --change-interface=eth0
firewall-cmd --permanent --zone=drop --add-port=51820/udp
firewall-cmd --permanent --zone=trusted --add-interface=wg-backplane
firewall-cmd --reload
```

The machine now has exactly one open port on its public interface: WireGuard. And WireGuard doesn't respond to unauthenticated traffic. To the outside world, this machine appears to have no open ports at all.

### 4. No DNS, no hostname leaks

```bash
# Set hostname to something generic
hostnamectl set-hostname localhost

# Don't publish mDNS
systemctl disable --now avahi-daemon 2>/dev/null || true
```

### 5. Verify stealth

From another machine, scan the target:

```bash
nmap -sU -sT -p- 203.0.113.10
```

Expected result: all ports filtered or closed. No services detected. The machine appears to be off or non-existent, but it's fully operational on the backplane.

---

## Monitoring WireGuard

### Basic status

```bash
wg show
```

Shows: interfaces, public keys, endpoints, allowed IPs, latest handshake, transfer bytes.

### Watch for problems

```bash
# Continuous monitoring
watch -n5 wg show

# Check if a specific peer has a recent handshake (within 3 minutes)
wg show wg0 latest-handshakes | while read pub ts; do
  age=$(( $(date +%s) - ts ))
  if (( age > 180 )); then
    echo "STALE: peer ${pub:0:8}... last handshake ${age}s ago"
  fi
done
```

### Prometheus metrics

Use the `wireguard_exporter` or scrape `wg show` output:

```bash
cat > /usr/local/bin/wg-metrics.sh << 'SCRIPT'
#!/bin/bash
# Textfile exporter for node_exporter
echo "# HELP wireguard_peers Number of WireGuard peers"
echo "# TYPE wireguard_peers gauge"
for iface in $(wg show interfaces); do
  count=$(wg show "$iface" peers | wc -l)
  echo "wireguard_peers{interface=\"${iface}\"} ${count}"
done

echo "# HELP wireguard_transfer_bytes Bytes transferred per peer"
echo "# TYPE wireguard_transfer_bytes gauge"
wg show all transfer | while read iface pub rx tx; do
  short="${pub:0:8}"
  echo "wireguard_transfer_rx_bytes{interface=\"${iface}\",peer=\"${short}\"} ${rx}"
  echo "wireguard_transfer_tx_bytes{interface=\"${iface}\",peer=\"${short}\"} ${tx}"
done

echo "# HELP wireguard_latest_handshake_seconds Seconds since last handshake"
echo "# TYPE wireguard_latest_handshake_seconds gauge"
wg show all latest-handshakes | while read iface pub ts; do
  short="${pub:0:8}"
  age=$(( $(date +%s) - ts ))
  echo "wireguard_latest_handshake_seconds{interface=\"${iface}\",peer=\"${short}\"} ${age}"
done
SCRIPT
chmod +x /usr/local/bin/wg-metrics.sh

# Run every 30s via cron or systemd timer
mkdir -p /var/lib/node_exporter/textfile
echo '* * * * * root /usr/local/bin/wg-metrics.sh > /var/lib/node_exporter/textfile/wireguard.prom' >> /etc/crontab
```

### eBPF tracing of WireGuard

Use the kldloadOS eBPF tools to trace WireGuard at the kernel level:

```bash
# Count packets per WireGuard interface
bpftrace -e 'tracepoint:net:net_dev_xmit /str(args.name) == "wg0"/ { @packets = count(); }'

# Histogram of packet sizes on the backplane
bpftrace -e 'tracepoint:net:net_dev_xmit /str(args.name) == "wg-backplane"/ { @size = hist(args.len); }'

# Watch for WireGuard handshakes (new connections)
bpftrace -e 'kprobe:wg_packet_receive { printf("WG packet received: pid=%d comm=%s\n", pid, comm); }'
```

---

## Key management best practices

### Rotate keys periodically

```bash
# Generate new keys
wg genkey | tee /etc/wireguard/private.key.new | wg pubkey > /etc/wireguard/public.key.new

# Distribute the new public key to all peers
# Update the config
# Atomically swap:
wg-quick down wg-backplane
mv /etc/wireguard/private.key.new /etc/wireguard/private.key
wg-quick up wg-backplane
```

### Pre-shared keys (PSK) for post-quantum protection

WireGuard supports a pre-shared key per peer that adds a symmetric encryption layer on top of the Curve25519 key exchange. If quantum computers break Curve25519, the PSK still protects the traffic:

```bash
# Generate a PSK
wg genpsk > /etc/wireguard/psk-node-b.key

# Add to the peer block
[Peer]
PublicKey = <node-B-public-key>
PresharedKey = <contents of psk-node-b.key>
AllowedIPs = 10.200.0.2/32
Endpoint = 203.0.113.20:51820
```

Both sides must have the same PSK. Distribute it out-of-band (USB stick, in-person, encrypted email — never over the same WireGuard tunnel you're securing with it).

### ZFS and key backups

On kldloadOS, `/etc/wireguard/` is on ZFS. Your keys are included in ZFS snapshots. This is both good (rollback restores keys) and something to be aware of (snapshots contain your private keys). If you replicate snapshots offsite, those replicas contain your private keys.

```bash
# Back up keys separately (encrypted)
tar czf - /etc/wireguard/*.key | gpg -c > wireguard-keys-$(hostname)-$(date +%Y%m%d).tar.gz.gpg
```

---

## Quick reference

| I want to... | Command |
|---|---|
| Generate a key pair | `wg genkey \| tee priv.key \| wg pubkey > pub.key` |
| Generate a pre-shared key | `wg genpsk > psk.key` |
| Start an interface | `wg-quick up wg0` |
| Stop an interface | `wg-quick down wg0` |
| Enable at boot | `systemctl enable wg-quick@wg0` |
| Show all interfaces | `wg show` |
| Show specific interface | `wg show wg0` |
| Add a peer live (no restart) | `wg set wg0 peer <pubkey> allowed-ips 10.200.0.5/32 endpoint 1.2.3.4:51820` |
| Remove a peer live | `wg set wg0 peer <pubkey> remove` |
| Show latest handshakes | `wg show wg0 latest-handshakes` |
| Show transfer stats | `wg show wg0 transfer` |
| Dump current config | `wg showconf wg0` |
| Save running config to file | `wg showconf wg0 > /etc/wireguard/wg0.conf` |

---

## Topologies at a glance

| Topology | Peers per node | Use case |
|---|---|---|
| **Point-to-point** | 1 | Two servers, site-to-site |
| **Hub-and-spoke** | 1 (clients), N (hub) | Remote access, road warriors |
| **Full mesh** | N-1 | Clusters, low-latency |
| **Multi-plane** | N-1 per plane | Traffic isolation, defense in depth |
| **Relay** | 1 per NAT'd node | Peers behind NAT |

---

## See also

- [WireGuard basics](wireguard.md) — simple point-to-point and hub-and-spoke configs
- [16-Node Cluster Setup](cluster-setup.md) — full cluster with 4-plane WireGuard mesh
- [Networking](networking.md) — bridges, VLANs, firewall rules to complement WireGuard
