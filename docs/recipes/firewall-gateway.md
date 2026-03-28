# Appliance Recipe: Advanced Firewall and Gateway

A kldloadOS firewall with nftables, zone-based network segmentation, Unbound recursive DNS with sinkhole, Kea DHCP, WireGuard site-to-site VPN, and ZFS-backed configuration snapshots. Snapshot before every rule change. Rollback bad configs in seconds. Replicate firewall state to a standby node with `zfs send`.

---

## Architecture

```
                          ┌─────────────────────────────────────────────────────┐
         ISP              │           kldloadOS Firewall / Gateway               │
          │               │                                                     │
          ▼               │  WAN (enp1s0) ─── 203.0.113.1/24                    │
    ┌───────────┐         │       │                                             │
    │  Modem /  │─────────│───────┘                                             │
    │  ONT      │         │       │                                             │
    └───────────┘         │       ▼                                             │
                          │  ┌──────────────────────────────────────────────┐    │
                          │  │              nftables engine                 │    │
                          │  │                                              │    │
                          │  │  ┌─────────┐ ┌──────────┐ ┌─────────────┐   │    │
                          │  │  │ FORWARD │ │ NAT/PAT  │ │ Rate Limit  │   │    │
                          │  │  │ filter  │ │ masq     │ │ conntrack   │   │    │
                          │  │  └─────────┘ └──────────┘ └─────────────┘   │    │
                          │  └──────────────────────────────────────────────┘    │
                          │       │           │           │          │           │
                          │       ▼           ▼           ▼          ▼           │
                          │  ┌────────┐ ┌─────────┐ ┌────────┐ ┌────────┐      │
                          │  │  DMZ   │ │ Trusted │ │  IoT   │ │ Guest  │      │
                          │  │ enp2s0 │ │ enp3s0  │ │ enp4s0 │ │ enp5s0 │      │
                          │  │.1/24   │ │.1/24    │ │.1/24   │ │.1/24   │      │
                          │  └────────┘ └─────────┘ └────────┘ └────────┘      │
                          │  10.10.1.0   10.10.10.0  10.10.20.0  10.10.30.0    │
                          │                                                     │
                          │  wg0: 10.200.0.1/24  ── WireGuard site-to-site     │
                          │  Unbound: recursive DNS + sinkhole (:53)            │
                          │  Kea DHCP4: all zones (:67)                         │
                          │                                                     │
                          │  rpool/firewall         ← config snapshots          │
                          │  rpool/firewall/logs    ← compressed log storage    │
                          └─────────────────────────────────────────────────────┘
                                    │
                                    │ ZFS replication (syncoid)
                                    │ VRRP (keepalived)
                                    ▼
                          ┌─────────────────────────┐
                          │  kldloadOS Standby FW    │
                          │  rpool/firewall-replica  │
                          │  VRRP backup priority    │
                          └─────────────────────────┘
```

---

## Step 1: Install kldloadOS

```bash
cat > /tmp/answers.env << 'EOF'
KLDLOAD_DISTRO=debian
KLDLOAD_DISK=/dev/sda
KLDLOAD_HOSTNAME=fw-primary
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=changeme
KLDLOAD_PROFILE=server
KLDLOAD_NET_METHOD=static
KLDLOAD_NET_IP=203.0.113.1
KLDLOAD_NET_MASK=255.255.255.0
KLDLOAD_NET_GW=203.0.113.254
KLDLOAD_NET_DNS=1.1.1.1
EOF
kldload-install-target --config /tmp/answers.env
```

---

## Step 2: ZFS dataset layout

```bash
# Configuration datasets -- small, frequent snapshots
zfs create -o mountpoint=/etc/nftables -o compression=lz4 rpool/firewall
zfs create -o mountpoint=/etc/wireguard -o compression=lz4 rpool/firewall/wireguard
zfs create -o mountpoint=/etc/unbound -o compression=lz4 rpool/firewall/dns
zfs create -o mountpoint=/etc/kea -o compression=lz4 rpool/firewall/dhcp

# Logs -- verbose firewall logs compress extremely well
zfs create -o mountpoint=/var/log/firewall -o compression=zstd -o recordsize=128k rpool/firewall/logs

# Sinkhole blocklists
zfs create -o mountpoint=/etc/unbound/blocklists -o compression=lz4 rpool/firewall/blocklists
```

---

## Step 3: Configure network interfaces

```bash
cat > /etc/systemd/network/10-wan.network << 'EOF'
[Match]
Name=enp1s0
[Network]
Address=203.0.113.1/24
Gateway=203.0.113.254
DNS=127.0.0.1
EOF

# Zone interfaces
for zone in "enp2s0:10.10.1.1/24:dmz" "enp3s0:10.10.10.1/24:trusted" \
            "enp4s0:10.10.20.1/24:iot" "enp5s0:10.10.30.1/24:guest"; do
  IFS=':' read -r iface addr name <<< "$zone"
  cat > "/etc/systemd/network/20-${name}.network" << EOF
[Match]
Name=${iface}
[Network]
Address=${addr}
EOF
done

# Enable IP forwarding
cat > /etc/sysctl.d/99-firewall.conf << 'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv6.conf.all.forwarding = 1
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
EOF
sysctl --system
```

---

## Step 4: nftables stateful firewall

```bash
# Snapshot before writing rules
ksnap "before nftables initial config"

cat > /etc/nftables/firewall.nft << 'NFTEOF'
#!/usr/sbin/nft -f
flush ruleset

define WAN    = enp1s0
define DMZ    = enp2s0
define TRUST  = enp3s0
define IOT    = enp4s0
define GUEST  = enp5s0
define TRUSTED_NET = 10.10.10.0/24
define DMZ_NET     = 10.10.1.0/24
define IOT_NET     = 10.10.20.0/24
define GUEST_NET   = 10.10.30.0/24
define VPN_NET     = 10.200.0.0/24

table inet filter {
    chain ct_state {
        type filter hook prerouting priority -150; policy accept;
        ct state invalid drop
    }

    chain input {
        type filter hook input priority 0; policy drop;
        iif lo accept
        ct state established,related accept
        ip protocol icmp limit rate 10/second accept
        ip6 nexthdr icmpv6 limit rate 10/second accept

        # SSH from trusted only
        iifname $TRUST tcp dport 22 accept

        # DNS from all internal zones
        iifname { $TRUST, $DMZ, $IOT, $GUEST } udp dport 53 accept
        iifname { $TRUST, $DMZ, $IOT, $GUEST } tcp dport 53 accept

        # DHCP from all internal zones
        iifname { $TRUST, $DMZ, $IOT, $GUEST } udp dport 67 accept

        # WireGuard on WAN
        iifname $WAN udp dport 51820 accept

        log prefix "nft-input-drop: " limit rate 5/minute
        drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept

        # Trusted -> everywhere
        iifname $TRUST accept
        # DMZ -> WAN only
        iifname $DMZ oifname $WAN accept
        # IoT -> WAN only
        iifname $IOT oifname $WAN accept
        # Guest -> WAN only, rate limited
        iifname $GUEST oifname $WAN limit rate 100 mbytes/second accept
        # VPN -> trusted + DMZ
        iifname "wg0" oifname { $TRUST, $DMZ } accept
        # Trusted -> IoT (management)
        iifname $TRUST oifname $IOT accept

        log prefix "nft-forward-drop: " limit rate 5/minute
        drop
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table inet nat {
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
        iifname $WAN tcp dport 443 dnat to 10.10.1.10:443
    }

    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname $WAN masquerade
    }
}

table inet ratelimit {
    set ssh_meter { type ipv4_addr; flags dynamic; timeout 5m; }
    chain input {
        type filter hook input priority -10; policy accept;
        tcp dport 22 ct state new \
            add @ssh_meter { ip saddr limit rate 3/minute } accept
        tcp dport 22 ct state new drop
    }
}
NFTEOF

nft -f /etc/nftables/firewall.nft
systemctl enable nftables
ksnap "nftables initial config applied"
```

---

## Step 5: WireGuard site-to-site VPN

```bash
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.200.0.1/24
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/private.key)

[Peer]
PublicKey = <SITE_B_PUBLIC_KEY>
AllowedIPs = 10.200.0.2/32, 192.168.1.0/24
Endpoint = 198.51.100.1:51820
PersistentKeepalive = 25

[Peer]
PublicKey = <LAPTOP_PUBLIC_KEY>
AllowedIPs = 10.200.0.10/32
EOF

systemctl enable --now wg-quick@wg0
```

---

## Step 6: Unbound DNS with sinkhole

```bash
apt install -y unbound

cat > /etc/unbound/unbound.conf << 'EOF'
server:
    interface: 0.0.0.0
    port: 53
    access-control: 10.10.0.0/16 allow
    access-control: 10.200.0.0/24 allow
    access-control: 127.0.0.0/8 allow
    num-threads: 4
    msg-cache-size: 64m
    rrset-cache-size: 128m
    cache-min-ttl: 300
    cache-max-ttl: 86400
    prefetch: yes
    prefetch-key: yes
    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes
    aggressive-nsec: yes
    auto-trust-anchor-file: "/var/lib/unbound/root.key"
    include: /etc/unbound/blocklists/blocklist.conf
    verbosity: 1
    log-queries: yes
    logfile: /var/log/firewall/unbound.log

forward-zone:
    name: "."
    forward-tls-upstream: yes
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 1.0.0.1@853#cloudflare-dns.com
EOF

# Blocklist updater (Steven Black's unified hosts)
cat > /usr/local/bin/update-blocklist << 'SCRIPT'
#!/bin/bash
URL="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
curl -fsSL "$URL" | \
    grep '^0\.0\.0\.0' | \
    awk '{print "local-zone: \""$2"\" always_nxdomain"}' | \
    grep -v 'localhost' \
    > /etc/unbound/blocklists/blocklist.conf
echo "Blocked $(wc -l < /etc/unbound/blocklists/blocklist.conf) domains"
systemctl reload unbound
SCRIPT
chmod +x /usr/local/bin/update-blocklist
/usr/local/bin/update-blocklist

# Weekly update
echo '0 4 * * 1 root /usr/local/bin/update-blocklist 2>&1 | logger -t dns-sinkhole' \
    > /etc/cron.d/dns-sinkhole

systemctl enable --now unbound
```

---

## Step 7: Kea DHCP4

```bash
apt install -y kea-dhcp4-server

cat > /etc/kea/kea-dhcp4.conf << 'EOF'
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": [ "enp2s0", "enp3s0", "enp4s0", "enp5s0" ]
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "lfc-interval": 3600
    },
    "valid-lifetime": 28800,
    "subnet4": [
      {
        "subnet": "10.10.1.0/24",
        "pools": [ { "pool": "10.10.1.100-10.10.1.200" } ],
        "option-data": [
          { "name": "routers", "data": "10.10.1.1" },
          { "name": "domain-name-servers", "data": "10.10.1.1" }
        ]
      },
      {
        "subnet": "10.10.10.0/24",
        "pools": [ { "pool": "10.10.10.100-10.10.10.200" } ],
        "option-data": [
          { "name": "routers", "data": "10.10.10.1" },
          { "name": "domain-name-servers", "data": "10.10.10.1" }
        ]
      },
      {
        "subnet": "10.10.20.0/24",
        "pools": [ { "pool": "10.10.20.100-10.10.20.200" } ],
        "option-data": [
          { "name": "routers", "data": "10.10.20.1" },
          { "name": "domain-name-servers", "data": "10.10.20.1" }
        ]
      },
      {
        "subnet": "10.10.30.0/24",
        "pools": [ { "pool": "10.10.30.100-10.10.30.200" } ],
        "option-data": [
          { "name": "routers", "data": "10.10.30.1" },
          { "name": "domain-name-servers", "data": "10.10.30.1" }
        ],
        "valid-lifetime": 3600
      }
    ]
  }
}
EOF

systemctl enable --now kea-dhcp4-server
```

---

## Step 8: Monitoring

```bash
cat > /usr/local/bin/fw-stats << 'SCRIPT'
#!/bin/bash
echo "=== nftables counter summary ==="
nft list ruleset | grep -E "(packets|bytes)" | grep -v "0 packets"
echo ""
echo "=== Connection tracking ==="
conntrack -C
echo "Active connections: $(conntrack -L 2>/dev/null | wc -l)"
echo ""
echo "=== Top talkers (last hour) ==="
journalctl -u nftables --since "1 hour ago" --no-pager | \
    grep -oP 'SRC=\K[0-9.]+' | sort | uniq -c | sort -rn | head -10
echo ""
echo "=== DNS query stats ==="
unbound-control stats_noreset | grep -E "(total\.|num\.)"
echo ""
echo "=== Zone bandwidth ==="
for iface in enp2s0 enp3s0 enp4s0 enp5s0; do
    rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
    tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
    echo "$iface: RX=$(numfmt --to=iec $rx) TX=$(numfmt --to=iec $tx)"
done
SCRIPT
chmod +x /usr/local/bin/fw-stats
```

---

## Bill of materials

| Component | Cost |
|-----------|------|
| Quad-NIC mini PC (Protectli VP2420, Topton N5105) | $200-400 |
| USB stick (installer) | $5 |
| **Total** | **~$200-400** |
