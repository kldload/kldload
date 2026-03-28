# Appliance Recipe: Automated Seedbox on ZFS

A kldloadOS seedbox with rtorrent, ruTorrent web UI, Flexget RSS automation, FileBot media renaming, per-stage ZFS datasets, and automatic replication to a Plex host over WireGuard. Downloads land in a staging dataset, get processed and hardlinked into an organized library, and `syncoid` sends only changed blocks to the media server.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      kldloadOS Seedbox                                  │
│                                                                         │
│  RSS Feeds ──→ Flexget ──→ rtorrent ──→ Landing Zone ──→ Processing     │
│  (autodl-irssi)            (daemon)     (rpool/landing)   Pipeline      │
│                                                                         │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────────┐   │
│  │  rtorrent    │    │  ruTorrent   │    │  Processing              │   │
│  │  :6881-6889  │    │  :8080 (web) │    │  unpackarr → filebot    │   │
│  │  SCGI :5000  │    │  nginx proxy │    │  or Sonarr/Radarr       │   │
│  └──────┬───────┘    └──────────────┘    └──────────┬───────────────┘   │
│         │                                           │                   │
│         ▼                                           ▼                   │
│  rpool/landing/              rpool/media/                               │
│  ├── torrent-a/              ├── tv/                                    │
│  ├── torrent-b/              │   ├── Breaking Bad/                      │
│  └── torrent-c/              │   └── The Expanse/                       │
│  (hourly snaps,              ├── movies/                                │
│   short retention)           │   ├── Dune (2021)/                       │
│                              │   └── Alien (1979)/                      │
│                              └── music/                                 │
│                              (daily snaps, long retention)              │
│                                                                         │
│  wg0: 10.200.0.1/24 ── WireGuard to Plex host                          │
│  nftables: VPN kill switch (nothing leaks if WireGuard drops)           │
└─────────────────────────────────────────────────────────────────────────┘
          │
          │ syncoid (every 30 min)
          │ WireGuard tunnel
          ▼
┌──────────────────────────────┐
│  kldloadOS Plex Host         │
│  rpool/media (replica)       │
│  Plex Media Server (:32400)  │
└──────────────────────────────┘
```

---

## Step 1: Install kldloadOS

```bash
cat > /tmp/answers.env << 'EOF'
KLDLOAD_DISTRO=debian
KLDLOAD_DISK=/dev/sda
KLDLOAD_HOSTNAME=seedbox
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=changeme
KLDLOAD_PROFILE=server
KLDLOAD_NET_METHOD=dhcp
EOF
kldload-install-target --config /tmp/answers.env
```

---

## Step 2: ZFS dataset layout

```bash
# Landing zone -- where downloads complete before processing
zfs create -o mountpoint=/srv/landing -o compression=lz4 \
    -o recordsize=1M rpool/landing

# Normalized media library
zfs create -o canmount=off -o mountpoint=none rpool/media
zfs create -o canmount=off -o mountpoint=/srv/media/tv rpool/media/tv
zfs create -o canmount=off -o mountpoint=/srv/media/movies rpool/media/movies
zfs create -o mountpoint=/srv/media/music -o compression=lz4 rpool/media/music

# Application state
zfs create -o mountpoint=/opt/rtorrent -o compression=lz4 rpool/apps
zfs create -o mountpoint=/opt/rtorrent/session -o recordsize=16k rpool/apps/session
zfs create -o mountpoint=/opt/flexget -o compression=lz4 rpool/apps/flexget
```

---

## Step 3: rtorrent + ruTorrent

```bash
apt install -y rtorrent screen
useradd -r -s /bin/bash -d /opt/rtorrent rtorrent

cat > /opt/rtorrent/.rtorrent.rc << 'RTRC'
network.port_range.set = 6881-6889
network.port_random.set = no
protocol.encryption.set = allow_incoming,try_outgoing,enable_retry
directory.default.set = /srv/landing
session.path.set = /opt/rtorrent/session
throttle.global_down.max_rate.set_kb = 0
throttle.global_up.max_rate.set_kb = 0
throttle.max_uploads.set = 100
throttle.max_uploads.global.set = 250
network.max_open_files.set = 65536
network.max_open_sockets.set = 999
pieces.memory.max.set = 2048M
network.xmlrpc.size_limit.set = 4M
network.scgi.open_port = 127.0.0.1:5000

schedule2 = watch_directory, 5, 5, \
    ((load.start, (cat, "/srv/landing/watch/", "*.torrent")))
schedule2 = low_diskspace, 5, 60, \
    ((close_low_diskspace, 10G))

group.seeding.ratio.enable =
group2.seeding.ratio.min.set = 200
group2.seeding.ratio.max.set = 300
group2.seeding.ratio.upload.set = 20M
RTRC

mkdir -p /srv/landing/{watch,complete}
chown -R rtorrent: /opt/rtorrent /srv/landing

cat > /etc/systemd/system/rtorrent.service << 'EOF'
[Unit]
Description=rtorrent BitTorrent client
After=network.target
[Service]
User=rtorrent
Type=simple
ExecStart=/usr/bin/screen -DmS rtorrent /usr/bin/rtorrent
ExecStop=/usr/bin/killall -w -s 2 rtorrent
Restart=on-failure
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now rtorrent
```

### ruTorrent web UI

```bash
apt install -y nginx php-fpm php-cli php-curl php-xml git apache2-utils

git clone https://github.com/Novik/ruTorrent.git /var/www/rutorrent
chown -R www-data: /var/www/rutorrent

cat > /etc/nginx/sites-available/rutorrent << 'EOF'
server {
    listen 8080;
    server_name _;
    root /var/www/rutorrent;
    index index.html index.php;
    auth_basic "Seedbox";
    auth_basic_user_file /etc/nginx/.htpasswd;
    location / { try_files $uri $uri/ =404; }
    location ~ \.php$ {
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
    location /RPC2 {
        scgi_pass 127.0.0.1:5000;
        include scgi_params;
    }
}
EOF

htpasswd -cb /etc/nginx/.htpasswd admin changeme
ln -sf /etc/nginx/sites-available/rutorrent /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl enable --now nginx php-fpm
```

---

## Step 4: RSS automation with Flexget

```bash
python3 -m venv /opt/flexget/venv
/opt/flexget/venv/bin/pip install flexget

cat > /opt/flexget/config.yml << 'FLEXGET'
schedules:
  - tasks: [tv-rss, movies-rss]
    interval:
      minutes: 15

tasks:
  tv-rss:
    rss:
      url: "https://example.com/tv-feed.rss"
      all_entries: no
    series:
      settings:
        quality: hdtv+ 720p-1080p
        propers: 12 hours
      identified_by: ep
      shows:
        - Breaking Bad
        - The Expanse
        - Severance
    rtorrent:
      uri: scgi://127.0.0.1:5000
      directory: /srv/landing
      custom1: tv

  movies-rss:
    rss:
      url: "https://example.com/movie-feed.rss"
      all_entries: no
    quality: 1080p bluray+
    rtorrent:
      uri: scgi://127.0.0.1:5000
      directory: /srv/landing
      custom1: movies
FLEXGET

cat > /etc/systemd/system/flexget.service << 'EOF'
[Unit]
Description=Flexget RSS automation
After=network.target rtorrent.service
[Service]
User=rtorrent
ExecStart=/opt/flexget/venv/bin/flexget daemon start
ExecStop=/opt/flexget/venv/bin/flexget daemon stop
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now flexget
```

---

## Step 5: Processing pipeline

```bash
apt install -y openjdk-17-jre mediainfo libchromaprint-tools
# Download FileBot (check https://www.filebot.net for latest)
curl -fsSL "https://get.filebot.net/filebot/FileBot_5.1/FileBot_5.1-portable.tar.xz" | \
    tar -xJf - -C /opt/filebot

cat > /usr/local/bin/process-download << 'SCRIPT'
#!/bin/bash
# Called by rtorrent on completion
# Args: $1 = torrent name, $2 = base path, $3 = custom1 (tv/movies)
NAME="$1"; PATH_BASE="$2"; TYPE="$3"
LOG="/var/log/seedbox-process.log"

zfs snapshot "rpool/landing@before-process-$(date +%s)"

case "$TYPE" in
    tv)
        /opt/filebot/filebot.sh -rename "$PATH_BASE/$NAME" \
            --db TheTVDB \
            --format "/srv/media/tv/{n}/Season {s}/{n} - {s00e00} - {t}.{ext}" \
            --action hardlink -non-strict >> "$LOG" 2>&1
        ;;
    movies)
        /opt/filebot/filebot.sh -rename "$PATH_BASE/$NAME" \
            --db TheMovieDB \
            --format "/srv/media/movies/{n} ({y})/{n} ({y}).{ext}" \
            --action hardlink -non-strict >> "$LOG" 2>&1
        ;;
esac
SCRIPT
chmod +x /usr/local/bin/process-download

# Add completion hook to rtorrent
cat >> /opt/rtorrent/.rtorrent.rc << 'EOF'
method.set_key = event.download.finished, process_complete, \
    "execute2={/usr/local/bin/process-download,$d.name=,$d.base_path=,$d.custom1=}"
EOF
systemctl restart rtorrent
```

Hardlinks mean the file exists in both the landing zone (for seeding) and the organized library (for Plex) without double disk usage.

---

## Step 6: Replication to Plex host

```bash
# WireGuard tunnel to Plex host
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.200.0.1/24
PrivateKey = $(cat /etc/wireguard/private.key)

[Peer]
PublicKey = <PLEX_HOST_PUBLIC_KEY>
AllowedIPs = 10.200.0.2/32
Endpoint = plex-host.example.com:51820
PersistentKeepalive = 25
EOF

systemctl enable --now wg-quick@wg0

# Replicate media every 30 minutes
cat > /etc/cron.d/media-replicate << 'EOF'
*/30 * * * * root syncoid -r --no-sync-snap rpool/media 10.200.0.2:rpool/media 2>&1 | logger -t media-replicate
EOF
```

---

## Verify

```bash
# Check rtorrent
systemctl status rtorrent

# Check ruTorrent
curl -s -u admin:changeme http://localhost:8080/ | head -5

# Check Flexget
/opt/flexget/venv/bin/flexget status

# Check WireGuard
wg show wg0

# Check disk usage per dataset
zfs list -r rpool/landing rpool/media -o name,used,avail,compressratio -S used
```
