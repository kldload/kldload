# Multi-Site Deployment

Multi-region infrastructure using WireGuard mesh networking and ZFS replication. Deploy kldloadOS across bare metal nodes in different locations with automated failover and offsite backup.

---

## Architecture

```
Site A (primary)          Site B (hot standby)       Site C (cold archive)
OVH / your DC             Hetzner / your DC          Home lab
┌──────────────┐          ┌──────────────┐          ┌──────────────┐
│ rpool/services│◄──15m──►│ rpool/services│          │ rpool/backup │
│ rpool/vms     │          │ rpool/vms     │──nightly─►│   site-a/    │
│ rpool/data    │──nightly────────────────────────────►│   site-b/    │
└──────┬───────┘          └──────┬───────┘          └──────────────┘
       │         WireGuard        │
       └──────── encrypted ──────┘
                  mesh
```

- **Site A → Site B:** syncoid every 15 minutes (hot standby, ≤15 min data loss)
- **Site A/B → Site C:** syncoid nightly (cold archive, ≤24h data loss)
- All inter-site traffic over WireGuard (UDP 51820 only port exposed)

---

## WireGuard mesh

Each site gets a WireGuard interface to every other site on `10.10.0.0/24`:

```bash
# Generate keys on each node
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
chmod 600 /etc/wireguard/private.key
```

Site A (`10.10.0.1`):

```ini
# /etc/wireguard/wg0.conf
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
```

Repeat for Site B (`10.10.0.2`) and Site C (`10.10.0.3`), swapping IPs and keys.

```bash
systemctl enable --now wg-quick@wg0
wg show wg0  # verify handshakes
```

---

## ZFS replication

### Sanoid snapshot policy

```ini
# /etc/sanoid/sanoid.conf (Site A)
[rpool/services]
  use_template = production
  recursive = yes

[rpool/data]
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

```bash
systemctl enable --now sanoid.timer
```

### Hot replication (A → B, every 15 min)

```bash
# /etc/cron.d/replicate-site-b
*/15 * * * * root syncoid --recursive --no-sync-snap --sendoptions="w" \
    rpool/services 10.10.0.2:rpool/services 2>&1 | logger -t zfs-replicate
*/15 * * * * root syncoid --recursive --no-sync-snap --sendoptions="w" \
    rpool/data 10.10.0.2:rpool/data 2>&1 | logger -t zfs-replicate
```

### Cold replication (A/B → C, nightly)

```bash
# /etc/cron.d/replicate-site-c (Site A, 02:00)
0 2 * * * root syncoid --recursive --no-sync-snap \
    rpool/services 10.10.0.3:rpool/backup/site-a/services 2>&1 | logger -t replicate-site-c

# /etc/cron.d/replicate-site-c (Site B, 03:00)
0 3 * * * root syncoid --recursive --no-sync-snap \
    rpool/services 10.10.0.3:rpool/backup/site-b/services 2>&1 | logger -t replicate-site-c
```

---

## Failover

### Automated (keepalived + floating IP)

Install `keepalived` on Sites A and B. Configure VRRP over the WireGuard interface with health checks against ZFS pool state and critical services. On failover, reassign the floating IP via provider API (OVH/Hetzner) and update DNS.

### Manual (< 5 min)

```bash
# On Site B:
# 1. Verify Site A is actually down
ping -c 5 10.10.0.1

# 2. Start services
systemctl start nginx postgresql app-server

# 3. Update DNS to Site B's IP
curl -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records/$RECORD" \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"type":"A","name":"app.example.com","content":"'$(curl -s ifconfig.me)'","ttl":60}'
```

---

## Disaster recovery

| Scenario | RTO | RPO | Procedure |
|----------|-----|-----|-----------|
| Site A fails | 5 min | 15 min | Promote Site B, reassign floating IP |
| Sites A+B fail | 15 min | 24h | Clone from Site C backup, start services |
| Full rebuild | 30 min | varies | Boot kldload ISO, `zfs receive` from backup |
| Ransomware | seconds | last snapshot | `zfs rollback` to clean snapshot |

---

## Hardware recommendations

| Site | Spec | Cost |
|------|------|------|
| OVH Advance-1 (Montreal) | Xeon E-2386G, 32GB ECC, 2x512GB NVMe | ~$90/mo |
| Hetzner AX41-NVMe (Frankfurt) | Ryzen 5 3600, 64GB ECC, 2x512GB NVMe | ~$45/mo |
| Home lab | Any x86_64 with 16GB+ RAM, 2+ disks | electricity |

Install kldloadOS on each node with `KLDLOAD_PROFILE=server` and `KLDLOAD_POOL_TYPE=mirror`.
