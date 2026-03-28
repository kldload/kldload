# Appliance Recipe: Internet Radio Station

A kldloadOS appliance running multiple internet radio stations from a single server using Icecast for streaming, Liquidsoap for playlist automation and crossfade mixing, and ZFS for media storage with per-station datasets, compression, quotas, and snapshots. Supports up to 30 stations on a 4-core box.

---

## Architecture

```
                      kldloadOS Internet Radio Server
  MEDIA STORAGE              AUTOMATION                   DELIVERY
  ─────────────              ──────────────               ────────
                          ┌─ liquidsoap@station1 ──┐
  /srv/music ────────────┤  (playlist, crossfade,  │
    (ZFS, zstd)           │   scheduled shows,     ├──► Icecast2 ──► Listeners
                          │   fallback/silence det) │    :8000       (web/apps)
  /srv/stations/station1 ─┤                         │
    (per-station media)   ├─ liquidsoap@station2 ──┤    /station1
                          │                         ├──► /station2
  /srv/stations/station2 ─┤                         │    /station3
                          ├─ liquidsoap@station3 ──┤    ...
  /srv/playlists ─────────┤                         │    /station30
    (auto-generated M3U)  └─ ...                   ┘
```

---

## Hardware

| Component | 10 stations | 30 stations |
|-----------|-------------|-------------|
| CPU | 2+ cores | 4+ cores |
| RAM | 4 GB | 8 GB |
| Storage | 1-4 TB (depends on library) | 1-4 TB |
| Network | 1 Gbps (~500 concurrent 128kbps listeners) | 1 Gbps |

No GPU required. Encoding 30 simultaneous 128kbps streams uses roughly one modern core.

---

## Step 1: Install kldloadOS

```bash
cat > /tmp/answers.env << 'EOF'
KLDLOAD_DISTRO=debian
KLDLOAD_DISK=/dev/sda
KLDLOAD_HOSTNAME=radio-server
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=changeme
KLDLOAD_PROFILE=server
KLDLOAD_NET_METHOD=dhcp
EOF
kldload-install-target --config /tmp/answers.env
```

---

## Step 2: Install the radio stack

```bash
apt install -y icecast2 liquidsoap
apt install -y ffmpeg vorbis-tools lame flac
apt install -y id3v2 python3-mutagen
apt install -y python3 python3-pip sox libsox-fmt-all
```

---

## Step 3: ZFS datasets

```bash
# Shared music library -- zstd saves 40-60% on FLAC/WAV
zfs create -o mountpoint=/srv/music \
           -o compression=zstd -o recordsize=128K \
           -o atime=off rpool/srv/music

# Auto-generated playlists
zfs create -o mountpoint=/srv/playlists \
           -o compression=zstd -o atime=off rpool/srv/playlists

# Recorded shows archive
zfs create -o mountpoint=/srv/archive \
           -o compression=zstd-3 -o recordsize=128K \
           -o atime=off rpool/srv/archive

# Per-station datasets with quotas
for i in $(seq 1 30); do
  zfs create -o mountpoint=/srv/stations/station${i} \
             -o compression=zstd -o recordsize=128K \
             -o atime=off -o quota=50G \
             rpool/srv/stations/station${i}
done

# Daily snapshots, keep 30
cat > /etc/cron.d/radio-snapshots << 'EOF'
0 4 * * * root for ds in music playlists archive; do zfs snapshot rpool/srv/${ds}@auto-$(date +\%Y\%m\%d); done
0 4 * * * root for i in $(seq 1 30); do zfs snapshot rpool/srv/stations/station${i}@auto-$(date +\%Y\%m\%d); done
15 4 * * * root for ds in music playlists archive; do zfs list -t snapshot -o name -H rpool/srv/${ds} | grep @auto- | head -n -30 | xargs -r -n1 zfs destroy; done
EOF
```

---

## Step 4: Configure Icecast

```xml
<!-- /etc/icecast2/icecast.xml -->
<icecast>
    <location>Radio Server</location>
    <admin>admin@radio-server.local</admin>
    <limits>
        <clients>1000</clients>
        <sources>60</sources>
        <queue-size>524288</queue-size>
        <client-timeout>30</client-timeout>
        <source-timeout>10</source-timeout>
        <burst-on-connect>1</burst-on-connect>
        <burst-size>65535</burst-size>
    </limits>
    <authentication>
        <source-password>changeme-source</source-password>
        <relay-password>changeme-relay</relay-password>
        <admin-user>admin</admin-user>
        <admin-password>changeme-admin</admin-password>
    </authentication>
    <hostname>radio-server.local</hostname>
    <listen-socket><port>8000</port></listen-socket>
    <mount>
        <mount-name>/station1</mount-name>
        <fallback-mount>/silence</fallback-mount>
        <fallback-override>1</fallback-override>
        <max-listeners>200</max-listeners>
    </mount>
    <mount>
        <mount-name>/station2</mount-name>
        <fallback-mount>/silence</fallback-mount>
        <fallback-override>1</fallback-override>
        <max-listeners>200</max-listeners>
    </mount>
    <!-- Generate more mounts programmatically -->
    <mount>
        <mount-name>/silence</mount-name>
        <max-listeners>10</max-listeners>
    </mount>
    <fileserve>1</fileserve>
    <paths>
        <logdir>/var/log/icecast2</logdir>
        <webroot>/usr/share/icecast2/web</webroot>
        <adminroot>/usr/share/icecast2/admin</adminroot>
    </paths>
    <logging>
        <accesslog>access.log</accesslog>
        <errorlog>error.log</errorlog>
        <loglevel>3</loglevel>
    </logging>
</icecast>
```

```bash
systemctl enable --now icecast2
# Status: http://radio-server:8000
# Admin: http://radio-server:8000/admin
```

---

## Step 5: Liquidsoap station config

```ruby
#!/usr/bin/liquidsoap
# /etc/liquidsoap/station1.liq -- Classic Rock

set("log.file.path", "/var/log/liquidsoap/station1.log")
set("server.telnet", true)
set("server.telnet.port", 1234)

# Main playlist
main_playlist = playlist(
  mode="randomize",
  reload=3600,
  reload_mode="rounds",
  "/srv/playlists/station1.m3u"
)

# Jingles -- station ID every 4 tracks
jingles = playlist(mode="randomize", "/srv/stations/station1/jingles")
radio = rotate(weights=[4, 1], [main_playlist, jingles])

# Scheduled shows -- Saturday night 8pm-midnight
saturday_night = playlist(mode="randomize", "/srv/playlists/station1-saturday.m3u")
radio = switch([
  ({ 6w and 20h-23h59m59s }, saturday_night),
  ({ true }, radio)
])

# Crossfade between tracks
radio = crossfade(duration=5.0, fade_in=3.0, fade_out=3.0, radio)

# Skip silence
radio = skip_blank(max_blank=5.0, threshold=-40.0, radio)

# Fallback chain
emergency = single("/srv/stations/station1/emergency.mp3")
safety = sine(440.0)
radio = fallback(track_sensitive=false, [radio, emergency, safety])
radio = normalize(radio)

# Output OGG Vorbis
output.icecast(
  %vorbis(quality=0.4),
  host="localhost", port=8000,
  password="changeme-source",
  mount="/station1",
  name="Station 1 - Classic Rock",
  genre="Rock",
  radio
)

# Also output MP3
output.icecast(
  %mp3(bitrate=128),
  host="localhost", port=8000,
  password="changeme-source",
  mount="/station1.mp3",
  name="Station 1 - Classic Rock (MP3)",
  radio
)
```

---

## Step 6: Playlist generator

```python
#!/usr/bin/env python3
# /usr/local/bin/playlist-generator.py
# Scans music library, generates shuffled M3U playlists per genre/station

import os, random, hashlib
from pathlib import Path
from datetime import datetime

MUSIC_ROOT = "/srv/music"
PLAYLIST_DIR = "/srv/playlists"
STATION_DIR = "/srv/stations"
AUDIO_EXT = {".mp3", ".ogg", ".flac", ".wav", ".m4a", ".opus"}
NO_REPEAT_WINDOW = 50

def scan_directory(path):
    tracks = []
    for root, dirs, files in os.walk(path):
        for f in files:
            if Path(f).suffix.lower() in AUDIO_EXT:
                tracks.append(os.path.join(root, f))
    return sorted(tracks)

def write_m3u(tracks, output_path):
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w") as f:
        f.write("#EXTM3U\n")
        for track in tracks:
            f.write(f"{track}\n")

if __name__ == "__main__":
    # Genre playlists
    for genre_dir in sorted(os.listdir(MUSIC_ROOT)):
        genre_path = os.path.join(MUSIC_ROOT, genre_dir)
        if not os.path.isdir(genre_path): continue
        tracks = scan_directory(genre_path)
        if tracks:
            random.shuffle(tracks)
            name = genre_dir.lower().replace(" ", "-")
            write_m3u(tracks, f"{PLAYLIST_DIR}/genre-{name}.m3u")

    # Station playlists
    if os.path.exists(STATION_DIR):
        for station_dir in sorted(os.listdir(STATION_DIR)):
            station_path = os.path.join(STATION_DIR, station_dir)
            if not os.path.isdir(station_path): continue
            tracks = scan_directory(station_path)
            if tracks:
                random.shuffle(tracks)
                write_m3u(tracks, f"{PLAYLIST_DIR}/{station_dir}.m3u")

    # Master playlist
    tracks = scan_directory(MUSIC_ROOT)
    if tracks:
        random.shuffle(tracks)
        write_m3u(tracks, f"{PLAYLIST_DIR}/all-music.m3u")
```

```bash
chmod +x /usr/local/bin/playlist-generator.py
/usr/local/bin/playlist-generator.py

# Regenerate hourly
echo '0 * * * * root /usr/local/bin/playlist-generator.py >> /var/log/playlist-generator.log 2>&1' \
    > /etc/cron.d/playlist-generator
```

---

## Step 7: Multi-station systemd template

```ini
# /etc/systemd/system/liquidsoap@.service
[Unit]
Description=Liquidsoap radio station %i
After=network.target icecast2.service

[Service]
Type=simple
ExecStart=/usr/bin/liquidsoap /etc/liquidsoap/%i.liq
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
# Enable stations
for i in station1 station2 station3; do
  systemctl enable --now liquidsoap@${i}
done
```

---

## Step 8: Show recording

```bash
# Record a show to the archive
cat > /usr/local/bin/record-show << 'SCRIPT'
#!/bin/bash
STATION="$1"; DURATION="$2"; SHOW_NAME="$3"
OUTPUT="/srv/archive/${STATION}/${SHOW_NAME}-$(date +%Y%m%d-%H%M).ogg"
mkdir -p "$(dirname "$OUTPUT")"
ffmpeg -i "http://localhost:8000/${STATION}" \
  -t "$DURATION" -c copy "$OUTPUT"
echo "Recorded: $OUTPUT"
SCRIPT
chmod +x /usr/local/bin/record-show

# Usage: record-show station1 3600 "saturday-night-special"
```

---

## Verify

```bash
# Icecast status
curl -s http://localhost:8000/status-json.xsl | python3 -m json.tool

# Liquidsoap status
systemctl status liquidsoap@station1

# Station listeners
curl -s "http://admin:changeme-admin@localhost:8000/admin/stats" | head -20

# Listen
vlc http://radio-server:8000/station1
# or
mpv http://radio-server:8000/station1.mp3

# ZFS compression savings on music library
zfs get compressratio rpool/srv/music
```
