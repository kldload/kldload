# Appliance Recipe: Live TV Streaming (SRT/HLS/DASH/IPTV)

A kldloadOS appliance that captures over-the-air or HDMI video via a capture card, encodes it with ffmpeg, and distributes it as live streams — SRT for broadcast-grade contribution, HLS/DASH for web viewers, IPTV multicast for LAN distribution. Carrier-grade live video, not webcam quality.

**What this replaces:** $50,000-200,000 in broadcast encoding/distribution hardware. A capture card, a kldloadOS box, and ffmpeg.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          kldloadOS Streamer                             │
│                                                                         │
│  OTA Antenna ──► Tuner/Capture Card ──► /dev/video0                    │
│  HDMI Source ──► HDMI Capture Card  ──► /dev/video1                    │
│                                                                         │
│                    ┌──────────┐                                         │
│                    │  ffmpeg  │                                         │
│                    │ (decode  │                                         │
│                    │  encode) │                                         │
│                    └────┬─────┘                                         │
│                         │                                               │
│              ┌──────────┼──────────┬──────────────┐                    │
│              │          │          │              │                    │
│         ┌────▼───┐ ┌───▼────┐ ┌──▼──────┐ ┌────▼────────┐           │
│         │  SRT   │ │  HLS   │ │  DASH   │ │  IPTV       │           │
│         │:9000   │ │ nginx  │ │ nginx   │ │  multicast  │           │
│         │        │ │:8080   │ │:8080    │ │  udp://     │           │
│         └────────┘ └────────┘ └─────────┘ └─────────────┘           │
│              │                     │                                    │
│    SRT callers                Web viewers          LAN TVs/VLC         │
│   (remote contributors)      (any browser)        (multicast)          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Hardware

| Component | Examples | Cost |
|-----------|---------|------|
| Mini PC / server | Any x86_64 with USB 3.0 (or PCIe slot) | $200-500 |
| HDMI capture card | Elgato HD60 X, AVerMedia Live Gamer, Magewell USB Capture | $100-400 |
| OTA TV tuner (optional) | HDHomeRun, Hauppauge WinTV | $50-150 |
| GPU (optional, for NVENC) | NVIDIA GTX 1650+ | $150-300 |
| USB stick | kldloadOS installer | $5 |

For software encoding (no GPU): a modern 4-core CPU handles 1080p30 x264 with `veryfast` preset.
For hardware encoding: NVIDIA NVENC does 4K60 with minimal CPU usage.

---

## Step 1: Install kldloadOS

```bash
cat > /tmp/answers.env << 'EOF'
KLDLOAD_DISTRO=debian
KLDLOAD_DISK=/dev/sda
KLDLOAD_HOSTNAME=tv-streamer
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=changeme
KLDLOAD_PROFILE=server
KLDLOAD_NVIDIA_DRIVERS=1
KLDLOAD_NET_METHOD=dhcp
EOF
kldload-install-target --config /tmp/answers.env
```

---

## Step 2: Install streaming packages

```bash
# ffmpeg with full codec support
apt install -y ffmpeg

# SRT library and tools
apt install -y libsrt-openssl-dev srt-tools

# nginx for HLS/DASH serving
apt install -y nginx

# Video4Linux utils
apt install -y v4l-utils

# Optional: NVIDIA NVENC (if GPU installed)
# The NVIDIA driver from the kldload install includes NVENC support
```

---

## Step 3: Verify capture card

```bash
# List video devices
v4l2-ctl --list-devices

# Check capabilities
v4l2-ctl -d /dev/video0 --all

# Test capture (5 seconds)
ffmpeg -f v4l2 -i /dev/video0 -t 5 -c copy /tmp/test-capture.ts

# For HDMI capture cards, check supported formats
v4l2-ctl -d /dev/video0 --list-formats-ext
```

---

## Step 4: ZFS datasets for media

```bash
# Live stream segments (HLS/DASH — high write, short retention)
zfs create -o mountpoint=/srv/stream \
           -o compression=off \
           -o recordsize=1M \
           -o atime=off \
           -o logbias=throughput \
           rpool/srv/stream

# Recordings (long-term archive)
zfs create -o mountpoint=/srv/recordings \
           -o compression=zstd \
           -o recordsize=1M \
           rpool/srv/recordings

# nginx web root
mkdir -p /srv/stream/hls /srv/stream/dash
```

---

## Step 5: Configure nginx for HLS/DASH

```nginx
# /etc/nginx/sites-available/streaming
server {
    listen 8080;
    server_name _;

    # HLS
    location /hls {
        alias /srv/stream/hls;
        types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t ts;
        }
        add_header Cache-Control no-cache;
        add_header Access-Control-Allow-Origin *;
    }

    # DASH
    location /dash {
        alias /srv/stream/dash;
        types {
            application/dash+xml mpd;
            video/mp4 m4s mp4;
        }
        add_header Cache-Control no-cache;
        add_header Access-Control-Allow-Origin *;
    }

    # Simple player page
    location / {
        root /srv/stream/web;
        index index.html;
    }
}
```

```bash
ln -sf /etc/nginx/sites-available/streaming /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx
```

Simple HLS player page:
```html
<!-- /srv/stream/web/index.html -->
<!DOCTYPE html>
<html><head>
  <title>kldloadOS Live TV</title>
  <script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
</head><body style="background:#000;margin:0;display:flex;justify-content:center;align-items:center;height:100vh">
  <video id="video" controls autoplay style="max-width:100%;max-height:100%"></video>
  <script>
    const video = document.getElementById('video');
    if (Hls.isSupported()) {
      const hls = new Hls();
      hls.loadSource('/hls/live.m3u8');
      hls.attachMedia(video);
    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = '/hls/live.m3u8';
    }
  </script>
</body></html>
```

---

## Step 6: Streaming with ffmpeg

### Software encoding (CPU — x264)

```bash
# Capture → HLS + DASH + SRT simultaneously
ffmpeg -f v4l2 -video_size 1920x1080 -framerate 30 -i /dev/video0 \
  -f alsa -i hw:1,0 \
  \
  -map 0:v -map 1:a -c:v libx264 -preset veryfast -b:v 4000k -maxrate 4500k -bufsize 8000k \
  -c:a aac -b:a 128k -ar 44100 \
  \
  -f hls -hls_time 4 -hls_list_size 10 -hls_flags delete_segments \
  /srv/stream/hls/live.m3u8 \
  \
  -f dash -seg_duration 4 -window_size 10 -remove_at_exit 1 \
  /srv/stream/dash/live.mpd \
  \
  -f mpegts "srt://0.0.0.0:9000?mode=listener&latency=200" \
  \
  -f mpegts "udp://239.1.1.1:5000?pkt_size=1316"
```

### Hardware encoding (NVIDIA NVENC)

```bash
ffmpeg -f v4l2 -video_size 1920x1080 -framerate 30 -i /dev/video0 \
  -f alsa -i hw:1,0 \
  \
  -map 0:v -map 1:a -c:v h264_nvenc -preset p4 -b:v 6000k -maxrate 7000k -bufsize 12000k \
  -c:a aac -b:a 128k -ar 44100 \
  \
  -f hls -hls_time 4 -hls_list_size 10 -hls_flags delete_segments \
  /srv/stream/hls/live.m3u8 \
  \
  -f mpegts "srt://0.0.0.0:9000?mode=listener&latency=200"
```

### Multi-bitrate adaptive (ABR)

```bash
ffmpeg -f v4l2 -video_size 1920x1080 -framerate 30 -i /dev/video0 \
  -f alsa -i hw:1,0 \
  \
  -map 0:v -map 0:v -map 0:v -map 1:a \
  \
  -c:v:0 libx264 -b:v:0 5000k -s:v:0 1920x1080 -preset veryfast \
  -c:v:1 libx264 -b:v:1 2500k -s:v:1 1280x720 -preset veryfast \
  -c:v:2 libx264 -b:v:2 1000k -s:v:2 854x480 -preset veryfast \
  -c:a aac -b:a 128k \
  \
  -f hls -hls_time 4 -hls_list_size 10 -hls_flags delete_segments \
  -var_stream_map "v:0,a:0 v:1,a:0 v:2,a:0" \
  -master_pl_name live.m3u8 \
  /srv/stream/hls/stream_%v.m3u8
```

---

## Step 7: SRT — the carrier-grade transport

SRT (Secure Reliable Transport) is what actual broadcast infrastructure uses. Sub-second latency, handles packet loss and jitter, AES-128/256 encryption, and works over the public internet.

### SRT listener (the streamer — accepts incoming callers)

```bash
# Already running from the ffmpeg command above on port 9000
# Callers connect to: srt://your-ip:9000
```

### SRT caller (a remote contributor sending video TO the server)

```bash
# Remote camera/contributor sends to the streamer
ffmpeg -f v4l2 -i /dev/video0 -f alsa -i hw:0,0 \
  -c:v libx264 -preset veryfast -b:v 4000k \
  -c:a aac -b:a 128k \
  -f mpegts "srt://streamer-ip:9001?mode=caller&latency=200"
```

### Receive SRT caller and mix into the live stream

```bash
# On the streamer — accept a caller on port 9001
ffmpeg \
  -f v4l2 -i /dev/video0 \
  -f mpegts -i "srt://0.0.0.0:9001?mode=listener&latency=200" \
  -filter_complex "[0:v][1:v]hstack=inputs=2[out]" \
  -map "[out]" -c:v libx264 -preset veryfast -b:v 6000k \
  -f hls -hls_time 4 /srv/stream/hls/live.m3u8
```

### SRT over WireGuard

For private streaming between two kldloadOS nodes:

```bash
# Streamer sends to receiver over WireGuard
ffmpeg -f v4l2 -i /dev/video0 -f alsa -i hw:1,0 \
  -c:v libx264 -preset veryfast -b:v 5000k -c:a aac -b:a 128k \
  -f mpegts "srt://10.200.0.2:9000?mode=caller&latency=120&passphrase=secret123"
```

---

## Step 8: IPTV multicast (LAN distribution)

For distributing to smart TVs, VLC, and set-top boxes on the LAN:

```bash
# Multicast stream (any device on the LAN can tune in with VLC)
ffmpeg -f v4l2 -i /dev/video0 -f alsa -i hw:1,0 \
  -c:v libx264 -preset veryfast -b:v 4000k -c:a aac -b:a 128k \
  -f mpegts "udp://239.1.1.1:5000?pkt_size=1316&ttl=10"
```

Watch with VLC:
```
vlc udp://@239.1.1.1:5000
```

Or add to an M3U playlist:
```m3u
#EXTM3U
#EXTINF:-1,Live TV - kldloadOS
udp://@239.1.1.1:5000
```

---

## Step 9: The receiver (live TV appliance)

A second kldloadOS box that receives the stream and displays it — your own TV station receiver.

```bash
# Install on the receiver
apt install -y ffmpeg vlc mpv

# Receive SRT stream and display
mpv "srt://streamer-ip:9000?mode=caller&latency=200"

# Or receive and re-stream to a local HDMI output
ffmpeg -i "srt://10.200.0.1:9000?mode=caller&latency=200" \
  -c copy -f v4l2 /dev/video0

# Or receive and serve HLS locally for smart TVs
ffmpeg -i "srt://10.200.0.1:9000?mode=caller&latency=200" \
  -c copy -f hls -hls_time 2 -hls_list_size 5 \
  /srv/stream/hls/live.m3u8
```

---

## Step 10: Record everything to ZFS

```bash
# Record the live stream with timestamps
ffmpeg -f v4l2 -video_size 1920x1080 -framerate 30 -i /dev/video0 \
  -f alsa -i hw:1,0 \
  -c:v libx264 -preset veryfast -b:v 8000k -c:a aac -b:a 192k \
  -f segment -segment_time 3600 -strftime 1 \
  "/srv/recordings/%Y-%m-%d_%H-%M-%S.ts" \
  \
  -c:v libx264 -preset veryfast -b:v 4000k -c:a aac -b:a 128k \
  -f hls -hls_time 4 -hls_list_size 10 -hls_flags delete_segments \
  /srv/stream/hls/live.m3u8
```

Hourly ZFS snapshots of recordings:
```bash
echo '0 * * * * root zfs snapshot rpool/srv/recordings@hourly-$(date +\%Y\%m\%d-\%H)' >> /etc/crontab
```

Replicate recordings to backup over WireGuard:
```bash
syncoid rpool/srv/recordings 10.200.0.2:rpool/srv/recordings-backup
```

---

## Step 11: systemd service

```bash
cat > /etc/systemd/system/live-stream.service << 'EOF'
[Unit]
Description=Live TV streaming (ffmpeg)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/ffmpeg \
  -f v4l2 -video_size 1920x1080 -framerate 30 -i /dev/video0 \
  -f alsa -i hw:1,0 \
  -map 0:v -map 1:a \
  -c:v libx264 -preset veryfast -b:v 4000k -maxrate 4500k -bufsize 8000k \
  -c:a aac -b:a 128k -ar 44100 \
  -f hls -hls_time 4 -hls_list_size 10 -hls_flags delete_segments \
  /srv/stream/hls/live.m3u8
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now live-stream
```

---

## Verify

```bash
# Check capture device
v4l2-ctl --list-devices

# Check ffmpeg is encoding
systemctl status live-stream
journalctl -u live-stream -f

# Test HLS stream
curl -s http://localhost:8080/hls/live.m3u8 | head -10

# Test SRT stream (from another machine)
ffplay "srt://streamer-ip:9000?mode=caller&latency=200"

# Check IPTV multicast
vlc udp://@239.1.1.1:5000

# Check stream health with eBPF
bpftrace -e 'tracepoint:net:net_dev_xmit /str(args.name) == "eth0"/ { @bytes = hist(args.len); }'
```

---

## Bill of materials

| Component | Cost |
|-----------|------|
| Mini PC (4-core, 8GB RAM) | $200 |
| HDMI capture card (Elgato/Magewell) | $150-400 |
| OTA antenna + tuner (optional) | $50-100 |
| NVIDIA GPU (optional, for NVENC) | $150-300 |
| kldloadOS on USB | Free |
| **Total (software encoding)** | **~$400** |
| **Total (hardware encoding)** | **~$700** |

Compare to a broadcast encoder: $10,000-50,000.
