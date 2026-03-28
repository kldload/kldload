# Appliance Recipe: Build Your Own Cloud

A complete self-hosted cloud stack on kldloadOS replacing Google Drive, Google Photos, 1Password, Slack, Zoom, GitHub, and S3 with open-source alternatives. Per-service ZFS datasets with tuned recordsize and quotas, Caddy reverse proxy, Docker Compose for the full stack, sanoid snapshots, and syncoid offsite replication.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     kldloadOS Home Lab Cloud                                │
│                                                                             │
│  WireGuard mesh (encrypted overlay -- access from anywhere)                 │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  Caddy (reverse proxy -- automatic HTTPS for all services)            │  │
│  │  :80 / :443 → routes to each service by hostname                      │  │
│  └──┬──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┬────────────┘  │
│     │      │      │      │      │      │      │      │      │               │
│     ▼      ▼      ▼      ▼      ▼      ▼      ▼      ▼      ▼               │
│  nextcloud immich vault  gitea matrix jitsi  minio grafana collabora        │
│  :8080    :2283  :8222  :3000 :8008  :8443  :9000 :3001   :9980            │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  ZFS Pool (rpool)                                                     │  │
│  │  ├── rpool/services/nextcloud     recordsize=1M    compression=lz4    │  │
│  │  ├── rpool/services/immich        recordsize=1M    compression=off    │  │
│  │  ├── rpool/services/vaultwarden   recordsize=8K    compression=lz4    │  │
│  │  ├── rpool/services/gitea         recordsize=8K    compression=lz4    │  │
│  │  ├── rpool/services/matrix        recordsize=8K    compression=lz4    │  │
│  │  ├── rpool/services/minio         recordsize=1M    compression=off    │  │
│  │  ├── rpool/services/grafana       recordsize=8K    compression=lz4    │  │
│  │  └── rpool/services/caddy         recordsize=16K   compression=lz4    │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  Sanoid snapshots → hourly/daily/monthly retention                          │
│  Syncoid replication → backup host over WireGuard                           │
│  nftables firewall → only 80/443/51820 exposed                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Service mapping

| Cloud Service | Self-hosted Alternative |
|---------------|------------------------|
| Google Drive / Dropbox | Nextcloud |
| Google Docs / Office 365 | Collabora Online |
| Google Photos | Immich |
| 1Password / LastPass | Vaultwarden (Bitwarden-compatible) |
| Slack / Teams | Matrix (Synapse + Element) |
| Zoom | Jitsi Meet |
| GitHub (private repos) | Gitea |
| Backblaze / S3 | MinIO on ZFS |
| Monitoring (Datadog) | Grafana + Prometheus |

---

## Step 1: Install kldloadOS

```bash
cat > /tmp/answers.env << 'EOF'
KLDLOAD_DISTRO=debian
KLDLOAD_DISK=/dev/sda
KLDLOAD_HOSTNAME=cloud
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=changeme
KLDLOAD_PROFILE=server
KLDLOAD_NET_METHOD=dhcp
EOF
kldload-install-target --config /tmp/answers.env
```

---

## Step 2: ZFS dataset layout

Every service gets its own dataset -- independent snapshots, quotas, and tuned recordsize. PostgreSQL gets 8K blocks (matching its page size), Nextcloud gets 1M (optimized for large files), photos skip compression (JPEGs are already compressed).

```bash
zfs create -o canmount=off -o mountpoint=none rpool/services

# Nextcloud -- large files
zfs create -o mountpoint=/srv/nextcloud -o recordsize=1M \
    -o compression=lz4 -o atime=off rpool/services/nextcloud
zfs create -o mountpoint=/srv/nextcloud-db -o recordsize=8K \
    -o compression=lz4 -o logbias=throughput rpool/services/nextcloud-db

# Immich -- photos and video (already compressed)
zfs create -o mountpoint=/srv/immich -o recordsize=1M \
    -o compression=off -o atime=off rpool/services/immich
zfs create -o mountpoint=/srv/immich-db -o recordsize=8K \
    -o compression=lz4 -o logbias=throughput rpool/services/immich-db

# Vaultwarden -- small SQLite database
zfs create -o mountpoint=/srv/vaultwarden -o recordsize=8K \
    -o compression=lz4 rpool/services/vaultwarden

# Gitea
zfs create -o mountpoint=/srv/gitea -o recordsize=8K \
    -o compression=lz4 rpool/services/gitea

# Matrix Synapse
zfs create -o mountpoint=/srv/matrix -o recordsize=8K \
    -o compression=lz4 rpool/services/matrix

# MinIO -- S3-compatible object storage
zfs create -o mountpoint=/srv/minio -o recordsize=1M \
    -o compression=off -o atime=off rpool/services/minio

# Grafana + Prometheus
zfs create -o mountpoint=/srv/grafana -o recordsize=8K \
    -o compression=lz4 rpool/services/grafana

# Caddy -- TLS certs and config
zfs create -o mountpoint=/srv/caddy -o recordsize=16K \
    -o compression=lz4 rpool/services/caddy

zfs list -r rpool/services -o name,mountpoint,recordsize,compression
```

---

## Step 3: Caddy reverse proxy

```bash
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
    gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
    tee /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install -y caddy
```

```
# /srv/caddy/Caddyfile
{
    local_certs
    auto_https disable_redirects
}

nextcloud.home.lab {
    reverse_proxy localhost:8080
    header { Strict-Transport-Security "max-age=31536000" }
    request_body { max_size 10G }
}

immich.home.lab {
    reverse_proxy localhost:2283
    request_body { max_size 50G }
}

vaultwarden.home.lab {
    reverse_proxy localhost:8222
    reverse_proxy /notifications/hub localhost:3012
}

gitea.home.lab { reverse_proxy localhost:3000 }

matrix.home.lab {
    reverse_proxy /_matrix/* localhost:8008
    reverse_proxy /_synapse/* localhost:8008
}

jitsi.home.lab { reverse_proxy localhost:8443 }
minio.home.lab { reverse_proxy localhost:9001 }
s3.home.lab    { reverse_proxy localhost:9000 }
grafana.home.lab { reverse_proxy localhost:3001 }
```

```bash
ln -sf /srv/caddy/Caddyfile /etc/caddy/Caddyfile
systemctl enable --now caddy
```

For public access, replace `.home.lab` with your real domain and remove the `local_certs` block -- Caddy fetches Let's Encrypt certificates automatically.

---

## Step 4: Docker Compose stack

```bash
apt install -y docker.io docker-compose-v2

cat > /etc/docker/daemon.json << 'EOF'
{
  "storage-driver": "overlay2",
  "log-driver": "journald",
  "default-address-pools": [
    {"base": "172.20.0.0/14", "size": 24}
  ]
}
EOF
systemctl enable --now docker

# Generate secrets
mkdir -p /srv/homelab
cat > /srv/homelab/.env << EOF
NC_DB_PASS=$(openssl rand -base64 32)
NC_REDIS_PASS=$(openssl rand -base64 32)
NC_ADMIN_PASS=$(openssl rand -base64 32)
IMMICH_DB_PASS=$(openssl rand -base64 32)
VW_ADMIN_TOKEN=$(openssl rand -base64 32)
GITEA_DB_PASS=$(openssl rand -base64 32)
MATRIX_DB_PASS=$(openssl rand -base64 32)
MINIO_ROOT_PASSWORD=$(openssl rand -base64 32)
GRAFANA_ADMIN_PASS=$(openssl rand -base64 32)
EOF
chmod 600 /srv/homelab/.env
```

```yaml
# /srv/homelab/docker-compose.yml
networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
    internal: true

services:
  # --- Nextcloud ---
  nextcloud-db:
    image: postgres:16-alpine
    restart: unless-stopped
    networks: [backend]
    volumes: [ "/srv/nextcloud-db:/var/lib/postgresql/data" ]
    environment:
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: ${NC_DB_PASS}

  nextcloud-redis:
    image: redis:7-alpine
    restart: unless-stopped
    networks: [backend]
    command: redis-server --requirepass ${NC_REDIS_PASS}

  nextcloud:
    image: nextcloud:29-apache
    restart: unless-stopped
    depends_on: [nextcloud-db, nextcloud-redis]
    networks: [frontend, backend]
    ports: ["8080:80"]
    volumes: ["/srv/nextcloud:/var/www/html"]
    environment:
      POSTGRES_HOST: nextcloud-db
      POSTGRES_DB: nextcloud
      POSTGRES_USER: nextcloud
      POSTGRES_PASSWORD: ${NC_DB_PASS}
      REDIS_HOST: nextcloud-redis
      REDIS_HOST_PASSWORD: ${NC_REDIS_PASS}
      NEXTCLOUD_ADMIN_USER: admin
      NEXTCLOUD_ADMIN_PASSWORD: ${NC_ADMIN_PASS}
      NEXTCLOUD_TRUSTED_DOMAINS: nextcloud.home.lab

  # --- Immich (photos) ---
  immich-db:
    image: tensorchord/pgvecto-rs:pg16-v0.2.1
    restart: unless-stopped
    networks: [backend]
    volumes: ["/srv/immich-db:/var/lib/postgresql/data"]
    environment:
      POSTGRES_DB: immich
      POSTGRES_USER: immich
      POSTGRES_PASSWORD: ${IMMICH_DB_PASS}

  immich-server:
    image: ghcr.io/immich-app/immich-server:release
    restart: unless-stopped
    depends_on: [immich-db]
    networks: [frontend, backend]
    ports: ["2283:2283"]
    volumes: ["/srv/immich:/usr/src/app/upload"]
    environment:
      DB_HOSTNAME: immich-db
      DB_DATABASE_NAME: immich
      DB_USERNAME: immich
      DB_PASSWORD: ${IMMICH_DB_PASS}

  # --- Vaultwarden ---
  vaultwarden:
    image: vaultwarden/server:latest
    restart: unless-stopped
    networks: [frontend]
    ports: ["8222:80", "3012:3012"]
    volumes: ["/srv/vaultwarden:/data"]
    environment:
      DOMAIN: https://vaultwarden.home.lab
      WEBSOCKET_ENABLED: "true"
      ADMIN_TOKEN: ${VW_ADMIN_TOKEN}

  # --- Gitea ---
  gitea:
    image: gitea/gitea:latest
    restart: unless-stopped
    networks: [frontend]
    ports: ["3000:3000", "2222:22"]
    volumes: ["/srv/gitea:/data"]
    environment:
      GITEA__database__DB_TYPE: sqlite3
      GITEA__server__DOMAIN: gitea.home.lab

  # --- MinIO (S3-compatible) ---
  minio:
    image: minio/minio:latest
    restart: unless-stopped
    networks: [frontend]
    ports: ["9000:9000", "9001:9001"]
    volumes: ["/srv/minio:/data"]
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: admin
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
```

```bash
cd /srv/homelab && docker compose up -d
```

---

## Step 5: Automated snapshots and replication

```ini
# /etc/sanoid/sanoid.conf
[rpool/services]
  use_template = production
  recursive = yes

[template_production]
  hourly = 48
  daily = 30
  monthly = 6
  yearly = 0
  autosnap = yes
  autoprune = yes
```

```bash
systemctl enable --now sanoid.timer

# Nightly replication to backup host over WireGuard
cat > /etc/cron.d/cloud-replicate << 'EOF'
0 3 * * * root syncoid -r --no-sync-snap rpool/services 10.200.0.2:rpool/services-replica 2>&1 | logger -t cloud-replicate
EOF
```

---

## Verify

```bash
docker compose -f /srv/homelab/docker-compose.yml ps
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080     # Nextcloud
curl -s -o /dev/null -w "%{http_code}" http://localhost:2283     # Immich
curl -s -o /dev/null -w "%{http_code}" http://localhost:8222     # Vaultwarden
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000     # Gitea
zfs list -r rpool/services -o name,used,compressratio
```

---

## Bill of materials

| Component | Cost |
|-----------|------|
| Mini PC (8+ cores, 32GB RAM) | $400-800 |
| Storage (2x 2TB NVMe mirror) | $150-300 |
| kldloadOS on USB | Free |
| **Total** | **~$550-1,100** |
