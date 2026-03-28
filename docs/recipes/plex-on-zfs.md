# Appliance Recipe: Plex Media Server on ZFS

A kldloadOS media server where every movie gets its own ZFS dataset. Clone libraries instantly. Replicate content to a second server with `zfs send`. Compress, snapshot, and manage petabytes of media the way Netflix's Open Connect CDN does it — individual content datasets replicated to edge nodes.

**Why per-movie datasets matter:**

- `zfs send` one movie to a friend's server in seconds
- Clone a dataset for transcoding without touching the original
- Different compression per content type
- Quota per library
- Snapshot before bulk operations (metadata edits, re-encodes)
- Replicate your entire library to a backup server incrementally

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                     kldloadOS Plex Server                             │
│                                                                      │
│  rpool/media                          ← master media dataset         │
│  ├── movies/                          ← container (canmount=off)     │
│  │   ├── the-matrix-1999             ← one dataset per movie         │
│  │   ├── blade-runner-2049                                           │
│  │   ├── dune-2021                                                   │
│  │   └── ...                                                         │
│  ├── tv/                                                             │
│  │   ├── breaking-bad                ← one dataset per series        │
│  │   ├── the-expanse                                                 │
│  │   └── ...                                                         │
│  ├── music/                          ← lz4 compression (lossless)    │
│  └── photos/                         ← compression off (JPEG/RAW)   │
│                                                                      │
│  rpool/plex                          ← Plex metadata + database      │
│  ├── config                          ← recordsize=8k (SQLite)        │
│  └── transcode                       ← temporary, no snapshots       │
│                                                                      │
│  Plex Media Server (:32400)                                          │
│  wg0: WireGuard to backup server                                     │
└──────────────────────────────────────────────────────────────────────┘
        │
        │ syncoid (hourly)
        │ WireGuard tunnel
        ▼
┌──────────────────────────┐
│  kldloadOS Backup/Edge   │
│  rpool/media-replica     │
│  Plex Media Server       │
│  (read-only mirror)      │
└──────────────────────────┘
```

---

## Step 1: Install kldloadOS

```bash
cat > /tmp/answers.env << 'EOF'
KLDLOAD_DISTRO=debian
KLDLOAD_DISK=/dev/sda
KLDLOAD_HOSTNAME=plex-server
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=changeme
KLDLOAD_PROFILE=server
KLDLOAD_NET_METHOD=dhcp
EOF
kldload-install-target --config /tmp/answers.env
```

---

## Step 2: Create the ZFS dataset hierarchy

```bash
# Master media container (no mountpoint — children mount individually)
zfs create -o canmount=off -o mountpoint=none rpool/media

# Movie library — each movie gets its own dataset (created per-movie below)
zfs create -o canmount=off -o mountpoint=/srv/media/movies rpool/media/movies

# TV library — each series gets its own dataset
zfs create -o canmount=off -o mountpoint=/srv/media/tv rpool/media/tv

# Music — lz4 compression (FLAC benefits, MP3 doesn't hurt)
zfs create -o mountpoint=/srv/media/music -o compression=lz4 rpool/media/music

# Photos — compression off (JPEG/HEIF/RAW are already compressed)
zfs create -o mountpoint=/srv/media/photos -o compression=off rpool/media/photos

# Plex application data
zfs create -o mountpoint=/var/lib/plexmediaserver rpool/plex
zfs create -o mountpoint=/var/lib/plexmediaserver/Library -o recordsize=8k rpool/plex/config
zfs create -o mountpoint=/tmp/plex-transcode -o compression=off -o com.sun:auto-snapshot=false rpool/plex/transcode
```

---

## Step 3: Script to create per-movie datasets

```bash
#!/bin/bash
# /usr/local/bin/add-movie
# Usage: add-movie "The Matrix" 1999

TITLE="$1"
YEAR="$2"

if [[ -z "$TITLE" || -z "$YEAR" ]]; then
  echo "Usage: add-movie \"Movie Title\" YEAR"
  exit 1
fi

# Normalize name: lowercase, replace spaces with hyphens
SLUG=$(echo "${TITLE}-${YEAR}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')

DATASET="rpool/media/movies/${SLUG}"
MOUNT="/srv/media/movies/${SLUG}"

if zfs list "$DATASET" >/dev/null 2>&1; then
  echo "Dataset already exists: $DATASET"
  exit 1
fi

# Video files are already compressed — disable ZFS compression
zfs create -o mountpoint="$MOUNT" -o compression=off -o recordsize=1M "$DATASET"

# Create Plex-expected directory structure
mkdir -p "${MOUNT}"

echo "Created: $DATASET → $MOUNT"
echo "Copy your movie file into: $MOUNT"
```

```bash
chmod +x /usr/local/bin/add-movie

# Add movies
add-movie "The Matrix" 1999
add-movie "Blade Runner 2049" 2017
add-movie "Dune" 2021
add-movie "Alien" 1979
```

Same for TV:
```bash
#!/bin/bash
# /usr/local/bin/add-series
# Usage: add-series "Breaking Bad"

TITLE="$1"
SLUG=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
DATASET="rpool/media/tv/${SLUG}"
MOUNT="/srv/media/tv/${SLUG}"

zfs create -o mountpoint="$MOUNT" -o compression=off -o recordsize=1M "$DATASET"
echo "Created: $DATASET → $MOUNT"
echo "Create season directories: mkdir ${MOUNT}/Season\\ {1..5}"
```

---

## Step 4: Install Plex Media Server

```bash
# Debian
curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.key | \
  gpg --dearmor -o /usr/share/keyrings/plex.gpg

echo "deb [signed-by=/usr/share/keyrings/plex.gpg] https://downloads.plex.tv/repo/deb public main" \
  > /etc/apt/sources.list.d/plexmediaserver.list

apt update
apt install -y plexmediaserver

systemctl enable --now plexmediaserver
```

Access Plex at: `http://plex-server:32400/web`

Add libraries:
- Movies: `/srv/media/movies`
- TV: `/srv/media/tv`
- Music: `/srv/media/music`
- Photos: `/srv/media/photos`

---

## Step 5: ZFS operations for media management

### Snapshot before bulk operations

```bash
# Before re-encoding a movie
zfs snapshot rpool/media/movies/the-matrix-1999@before-reencode

# Before editing metadata for entire library
zfs snapshot -r rpool/media/movies@before-metadata-edit

# Rollback if something goes wrong
zfs rollback rpool/media/movies/the-matrix-1999@before-reencode
```

### Clone for transcoding

```bash
# Clone a movie dataset for transcoding — zero copy cost
zfs snapshot rpool/media/movies/dune-2021@transcode-src
zfs clone rpool/media/movies/dune-2021@transcode-src rpool/media/movies/dune-2021-4k-to-1080p

# Transcode in the clone (original untouched)
ffmpeg -i /srv/media/movies/dune-2021-4k-to-1080p/Dune.2021.2160p.mkv \
  -c:v libx264 -preset slow -crf 18 -vf scale=1920:1080 \
  -c:a copy \
  /srv/media/movies/dune-2021-4k-to-1080p/Dune.2021.1080p.mkv

# Keep the clone or destroy it
zfs destroy rpool/media/movies/dune-2021-4k-to-1080p
```

### Send a movie to a friend

```bash
# Snapshot the movie
zfs snapshot rpool/media/movies/blade-runner-2049@share

# Send it (full)
zfs send rpool/media/movies/blade-runner-2049@share | \
  ssh friend@their-server zfs receive tank/media/movies/blade-runner-2049

# Or compressed over WireGuard
zfs send rpool/media/movies/blade-runner-2049@share | \
  zstd -3 | ssh 10.200.0.2 "zstd -d | zfs receive tank/media/movies/blade-runner-2049"
```

### Check library disk usage

```bash
# Per-movie usage
zfs list -r rpool/media/movies -o name,used,compressratio -S used | head -20

# Total library size
zfs list rpool/media -o name,used,avail,compressratio

# Compression savings (music library should show benefit)
zfs get compressratio rpool/media/music
```

---

## Step 6: Replicate entire library to a backup server

### Initial full replication

```bash
# Snapshot everything
zfs snapshot -r rpool/media@replicate-initial

# Send entire library to backup server over WireGuard
zfs send -R rpool/media@replicate-initial | \
  ssh 10.200.0.2 zfs receive -F rpool/media-replica
```

### Daily incremental replication

```bash
# Cron job — replicate changes every night
cat > /etc/cron.d/media-replicate << 'EOF'
0 3 * * * root syncoid -r rpool/media 10.200.0.2:rpool/media-replica 2>&1 | logger -t media-replicate
0 3 * * * root syncoid rpool/plex/config 10.200.0.2:rpool/plex-replica/config 2>&1 | logger -t plex-replicate
EOF
```

### The backup server runs Plex too

On the backup server (10.200.0.2):
```bash
# Point Plex at the replicated datasets
# Movies: /srv/media-replica/movies
# TV: /srv/media-replica/tv

# This gives you a hot standby — if the primary dies,
# the backup is already serving the same library
```

---

## Step 7: Quotas per library

```bash
# Limit movies to 10TB
zfs set quota=10T rpool/media/movies

# Limit TV to 5TB
zfs set quota=5T rpool/media/tv

# Reserve 2TB for music (guaranteed even if movies fill up)
zfs set reservation=2T rpool/media/music

# Check quotas
zfs get quota,reservation,used rpool/media/movies rpool/media/tv rpool/media/music
```

---

## Step 8: Automated cleanup

```bash
#!/bin/bash
# /usr/local/bin/media-cleanup
# Remove snapshots older than 30 days

zfs list -t snapshot -H -o name,creation -r rpool/media | while read snap creation; do
  snap_epoch=$(date -d "$creation" +%s 2>/dev/null || echo 0)
  cutoff_epoch=$(date -d "30 days ago" +%s)
  if (( snap_epoch < cutoff_epoch && snap_epoch > 0 )); then
    echo "Destroying: $snap ($creation)"
    zfs destroy "$snap"
  fi
done
```

```bash
chmod +x /usr/local/bin/media-cleanup
echo '0 4 * * 0 root /usr/local/bin/media-cleanup' >> /etc/crontab
```

---

## Netflix comparison

Netflix's Open Connect appliances use a remarkably similar architecture:

| Feature | Netflix Open Connect | kldloadOS Plex |
|---------|---------------------|----------------|
| Storage | ZFS on FreeBSD | ZFS on Linux |
| Content datasets | Per-title datasets | Per-movie datasets |
| Replication | `zfs send` to edge nodes | `syncoid` to backup/edge |
| Compression | Off (video is pre-compressed) | Off for video, lz4 for music |
| Snapshots | Before content updates | Before metadata/transcode ops |
| Edge distribution | HTTP from local cache | Plex from local replica |

The architecture is the same. The scale is different. The principle — individual datasets replicated to edge nodes — is identical.

---

## Bill of materials

| Component | Cost |
|-----------|------|
| Mini PC / server (8+ cores, 16GB RAM) | $400-800 |
| Storage (4x 8TB HDD, RAIDZ1) | $400-600 |
| GPU for transcoding (optional) | $150-300 |
| kldloadOS on USB | Free |
| Plex Pass (lifetime, optional) | $120 |
| **Total** | **~$1,000-1,800** |
