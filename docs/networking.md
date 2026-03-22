# Networking on kldload

kldload systems use NetworkManager for network configuration on both CentOS/RHEL and Debian. This guide covers common networking tasks: static IPs, bridges, VLANs, bonds, and firewall rules.

---

## Check current state

```bash
# Show all connections
nmcli connection show

# Show device status
nmcli device status

# Detailed info on a connection
nmcli connection show "Wired connection 1"

# IP addresses
ip addr show
```

---

## Static IP

### Using nmcli

```bash
# Set static IP on the primary interface
nmcli connection modify "Wired connection 1" \
  ipv4.method manual \
  ipv4.addresses 10.100.10.50/24 \
  ipv4.gateway 10.100.10.1 \
  ipv4.dns "1.1.1.1 8.8.8.8"

# Apply
nmcli connection up "Wired connection 1"
```

### Verify

```bash
ip addr show
ip route show
cat /etc/resolv.conf
```

### Switch back to DHCP

```bash
nmcli connection modify "Wired connection 1" \
  ipv4.method auto \
  ipv4.addresses "" \
  ipv4.gateway "" \
  ipv4.dns ""
nmcli connection up "Wired connection 1"
```

---

## Network bridge (for KVM VMs)

VMs need a bridge interface to connect to the physical LAN:

```bash
# Create a bridge
nmcli connection add type bridge ifname br0 con-name br0 \
  ipv4.method manual \
  ipv4.addresses 10.100.10.50/24 \
  ipv4.gateway 10.100.10.1 \
  ipv4.dns "1.1.1.1"

# Attach the physical interface to the bridge
nmcli connection add type bridge-slave ifname eth0 master br0

# Bring down the old connection and bring up the bridge
nmcli connection down "Wired connection 1"
nmcli connection up br0
```

> After this, your host gets its IP from `br0` and VMs can bridge through `eth0` to the LAN.

### Verify

```bash
nmcli connection show
bridge link show
ip addr show br0
```

---

## VLAN tagging

```bash
# Create a VLAN interface (VLAN 100 on eth0)
nmcli connection add type vlan ifname eth0.100 dev eth0 id 100 \
  ipv4.method manual \
  ipv4.addresses 10.100.100.10/24

nmcli connection up vlan-eth0.100
```

### VLAN on a bridge (for VMs on a specific VLAN)

```bash
# Create VLAN interface
nmcli connection add type vlan ifname eth0.200 dev eth0 id 200

# Create bridge on that VLAN
nmcli connection add type bridge ifname br-vlan200 con-name br-vlan200 \
  ipv4.method manual \
  ipv4.addresses 10.100.200.1/24

# Attach VLAN to bridge
nmcli connection add type bridge-slave ifname eth0.200 master br-vlan200

nmcli connection up br-vlan200
```

---

## Link aggregation (bonding)

Combine multiple NICs for redundancy or throughput:

```bash
# Create a bond (active-backup mode for redundancy)
nmcli connection add type bond ifname bond0 con-name bond0 \
  bond.options "mode=active-backup,miimon=100" \
  ipv4.method manual \
  ipv4.addresses 10.100.10.50/24 \
  ipv4.gateway 10.100.10.1

# Add slave interfaces
nmcli connection add type bond-slave ifname eth0 master bond0
nmcli connection add type bond-slave ifname eth1 master bond0

nmcli connection up bond0
```

Bond modes:
- `active-backup` — one active NIC, failover to the other (no switch config needed)
- `802.3ad` (LACP) — aggregated throughput (requires switch support)
- `balance-rr` — round-robin (basic load balancing)

---

## Firewall

### CentOS/RHEL (firewalld)

```bash
# Check status
firewall-cmd --state

# List open ports
firewall-cmd --list-all

# Open a port
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --reload

# Open a service
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --reload

# Allow traffic on a WireGuard interface
firewall-cmd --permanent --zone=trusted --add-interface=wg0
firewall-cmd --reload

# Remove a rule
firewall-cmd --permanent --remove-port=8080/tcp
firewall-cmd --reload
```

### Debian (nftables)

```bash
# Check status
nft list ruleset

# Open port 8080
nft add rule inet filter input tcp dport 8080 accept

# Make persistent
cat > /etc/nftables.d/kldload-custom.nft << 'EOF'
table inet filter {
  chain input {
    tcp dport 8080 accept
    tcp dport { 80, 443 } accept
    udp dport { 51820, 51821, 51822, 51823 } accept  # WireGuard
  }
}
EOF
systemctl reload nftables
```

### Cross-distro shortcut

```bash
# Both distros: allow SSH, HTTP, HTTPS, WireGuard
for port in 22/tcp 80/tcp 443/tcp 51820/udp; do
  if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port="$port"
  fi
done
firewall-cmd --reload 2>/dev/null || true
```

---

## DNS configuration

```bash
# Set DNS servers via NetworkManager
nmcli connection modify "Wired connection 1" ipv4.dns "1.1.1.1 8.8.8.8"
nmcli connection up "Wired connection 1"

# Set search domain
nmcli connection modify "Wired connection 1" ipv4.dns-search "infra.local"
nmcli connection up "Wired connection 1"

# Verify
resolvectl status
```

---

## IP forwarding (for routing/NAT)

Enable if this node acts as a router, VPN gateway, or container host:

```bash
# Enable immediately
sysctl -w net.ipv4.ip_forward=1

# Make persistent
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-forwarding.conf
sysctl --system
```

### NAT masquerade (share internet from one interface to another)

```bash
# CentOS/RHEL
firewall-cmd --permanent --add-masquerade
firewall-cmd --reload

# Debian (nftables)
nft add table nat
nft add chain nat postrouting { type nat hook postrouting priority 100 \; }
nft add rule nat postrouting oifname "eth0" masquerade
```

---

## Troubleshooting

```bash
# Can't reach the network
ip link show          # is the interface UP?
ip addr show          # does it have an IP?
ip route show         # is the gateway set?
ping 1.1.1.1          # can you reach the internet?
ping google.com       # DNS working?

# NetworkManager logs
journalctl -u NetworkManager --since "10 minutes ago"

# Reset a broken connection
nmcli connection delete "Wired connection 1"
nmcli device wifi connect SSID password PASS   # WiFi
# or let NM auto-configure:
nmcli device connect eth0
```
