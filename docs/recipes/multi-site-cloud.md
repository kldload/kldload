# Appliance Recipe: Multi-Site Cloud

Three or more bare-metal nodes across multiple regions, connected by a WireGuard mesh, replicated with ZFS. Site A is production, Site B is a hot standby with 15-minute replication lag, Site C is your home lab cold archive. Any site can become primary by promoting its latest snapshot.

---

## Architecture

```
┌─────────────────────┐     WireGuard      ┌─────────────────────┐
│  SITE A - Primary   │<==================>│  SITE B - Secondary │
│  OVH Montreal       │     encrypted       │  Hetzner Frankfurt  │
│  ┌───────────────┐  │     mesh            │  ┌───────────────┐  │
│  │ rpool/services│  │                     │  │ rpool/services│  │
│  │ rpool/vms     │  │                     │  │ rpool/vms     │  │
│  │ rpool/data    │  │                     │  │ rpool/data    │  │
│  └───────────────┘  │                     │  └───────────────┘  │
└─────────┬───────────┘                     └─────────┬───────────┘
          │              WireGuard                     │
          └──────────────────┬─────────────────────────┘
                             │
                    ┌────────┴────────────┐
                    │  SITE C - Home Lab  │
                    │  Your hardware      │
                    │  ┌───────────────┐  │
                    │  │ Cold replica  │  │
                    │  │ rpool/backup  │  │
                    │  └───────────────┘  │
                    └─────────────────────┘
```

### Replication topology

```
Site A (primary)
  │
  ├── every 15 min ──→ Site B (hot standby)
  ├── nightly ────────→ Site C (cold archive)
  │
Site B (secondary)
  │
  └── nightly ────────→ Site C (cold archive)
```

---

## Step 1: WireGuard mesh between sites

```bash
# On each node
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key
```

### Site A -- OVH Montreal (10.10.0.1)

```bash
cat > /etc/wireguard/wg0.conf << 'EOF'
[Interface]
Address = 10.10.0.1/24
ListenPort = 51820
PrivateKey = <SITE_A_PRIVATE_KEY>
PostUp = sysctl -w net.ipv4.ip_forward=1

[Peer]
PublicKey = <SITE_B_PUBLIC_KEY>
AllowedIPs = 10.10.0.2/32
Endpoint = site-b.example.com:51820
PersistentKeepalive = 25

[Peer]
PublicKey = <SITE_C_PUBLIC_KEY>
AllowedIPs = 10.10.0.3/32
Endpoint = site-c.example.com:51820
PersistentKeepalive = 25
EOF
systemctl enable --now wg-quick@wg0
```

Sites B and C follow the same pattern with swapped IPs/keys.

```bash
# Verify mesh
wg show wg0
ping -c 3 10.10.0.1 && ping -c 3 10.10.0.2 && ping -c 3 10.10.0.3
```

---

## Step 2: ZFS replication

### Dataset layout (all sites)

```bash
zfs create -o mountpoint=none rpool/services
zfs create -o mountpoint=/srv/services/web rpool/services/web
zfs create -o mountpoint=/srv/services/db rpool/services/db
zfs create -o mountpoint=/srv/services/app rpool/services/app
zfs create -o mountpoint=none rpool/vms
zfs create -o mountpoint=none rpool/data
zfs create -o mountpoint=/srv/data/shared rpool/data/shared

# Encrypted secrets
zfs create -o encryption=aes-256-gcm -o keyformat=passphrase \
    -o mountpoint=/srv/secrets rpool/secrets
```

### Sanoid snapshot schedule (Site A)

```ini
# /etc/sanoid/sanoid.conf
[rpool/services]
  use_template = production
  recursive = yes

[rpool/data]
  use_template = production
  recursive = yes

[rpool/vms]
  use_template = production
  recursive = yes

[template_production]
  frequently = 4
  hourly = 48
  daily = 30
  monthly = 6
  yearly = 0
  autosnap = yes
  autoprune = yes
```

### Site A to Site B -- every 15 minutes

```bash
cat > /usr/local/bin/replicate-to-site-b << 'SCRIPT'
#!/bin/bash
set -euo pipefail
SITE_B="10.10.0.2"

if ! ping -c 1 -W 3 "$SITE_B" > /dev/null 2>&1; then
    logger -t replicate-site-b "ERROR: Site B unreachable"
    exit 1
fi

for ds in rpool/services rpool/data rpool/vms; do
    syncoid --recursive --no-sync-snap --sendoptions="w" \
        "$ds" "$SITE_B:$ds" 2>&1 | logger -t replicate-site-b
done
SCRIPT
chmod +x /usr/local/bin/replicate-to-site-b

cat > /etc/cron.d/replicate-site-b << 'CRON'
*/15 * * * * root /usr/local/bin/replicate-to-site-b 2>&1 | logger -t zfs-replicate
CRON
```

### Both sites to Site C -- nightly

```bash
# On Site A (02:00)
cat > /etc/cron.d/replicate-site-c << 'CRON'
0 2 * * * root syncoid --recursive --no-sync-snap rpool/services 10.10.0.3:rpool/backup/site-a/services 2>&1 | logger -t replicate-site-c
15 2 * * * root syncoid --recursive --no-sync-snap rpool/data 10.10.0.3:rpool/backup/site-a/data 2>&1 | logger -t replicate-site-c
CRON

# On Site B (03:00)
cat > /etc/cron.d/replicate-site-c << 'CRON'
0 3 * * * root syncoid --recursive --no-sync-snap rpool/services 10.10.0.3:rpool/backup/site-b/services 2>&1 | logger -t replicate-site-c
CRON
```

---

## Step 3: Failover

### Automated failover with keepalived

```bash
apt install -y keepalived

# Site A (MASTER)
cat > /etc/keepalived/keepalived.conf << 'EOF'
global_defs {
    router_id SITE_A
    script_user root
    enable_script_security
}

vrrp_script check_services {
    script "/usr/local/bin/check-site-health"
    interval 5
    weight -20
    fall 3
    rise 2
}

vrrp_instance MULTISITE {
    state MASTER
    interface wg0
    virtual_router_id 51
    priority 100
    advert_int 1
    unicast_src_ip 10.10.0.1
    unicast_peer { 10.10.0.2 }
    authentication {
        auth_type PASS
        auth_pass changeme_secret
    }
    track_script { check_services }
    notify_master "/usr/local/bin/failover-become-master"
    notify_backup "/usr/local/bin/failover-become-backup"
}
EOF
```

```bash
cat > /usr/local/bin/check-site-health << 'SCRIPT'
#!/bin/bash
zpool status rpool | grep -q "state: ONLINE" || exit 1
systemctl is-active --quiet nginx || exit 1
systemctl is-active --quiet postgresql || exit 1
AVAIL=$(zfs get -Hp -o value available rpool)
USED=$(zfs get -Hp -o value used rpool)
TOTAL=$((AVAIL + USED))
PCT=$((AVAIL * 100 / TOTAL))
[ "$PCT" -lt 10 ] && exit 1
exit 0
SCRIPT
chmod +x /usr/local/bin/check-site-health
```

### Manual failover

```bash
cat > /usr/local/bin/manual-failover << 'SCRIPT'
#!/bin/bash
set -euo pipefail
echo "=== Manual Failover to this site ==="
echo "Last snapshot received:"
zfs list -t snapshot -r rpool/services -o name,creation -s creation | tail -5
echo ""
echo "Starting services..."
systemctl start nginx postgresql app-server
echo "Update DNS to point to this site's IP: $(curl -s ifconfig.me)"
SCRIPT
chmod +x /usr/local/bin/manual-failover
```

---

## Step 4: BMaaS -- Bare Metal as a Service

Use ZFS snapshots to run different environments on the same hardware at different times. Snapshot the current environment, destroy it, build a new one. When done, rollback.

```bash
# Snapshot current environment
zfs snapshot -r rpool/services@before-ephemeral

# Build CI/CD environment for the day
# ... run workloads ...

# Tear down and restore
zfs rollback -r rpool/services@before-ephemeral
```

---

## Verify

```bash
# WireGuard mesh
wg show wg0

# Replication status
zfs list -t snapshot -r rpool/services -o name,creation -s creation | tail -5

# Keepalived
systemctl status keepalived

# Site health
/usr/local/bin/check-site-health && echo "healthy" || echo "unhealthy"
```
