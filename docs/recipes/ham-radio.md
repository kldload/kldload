# Appliance Recipe: IRLP Ham Radio Node

A kldloadOS appliance that bridges ham radio voice over the internet using WireGuard. Captures audio from a radio receiver via USB sound card, encodes it, and sends it through an encrypted tunnel to a remote IRLP/EchoLink node — allowing ham radio communication across the internet without antennas on the remote end.

**The problem:** Ham radio repeaters have limited range. Linking them over the internet traditionally requires exposed public ports, unencrypted VoIP, and complex NAT configuration.

**The solution:** Two kldloadOS nodes connected via WireGuard. Voice goes in one radio, comes out the other — encrypted, NAT-friendly, single UDP port.

---

## Architecture

```
Site A (radio + antenna)              Site B (radio + antenna)
┌──────────────────────┐              ┌──────────────────────┐
│  FM Transceiver      │              │  FM Transceiver      │
│       │              │              │       │              │
│  ┌────▼────┐         │              │  ┌────▼────┐         │
│  │USB Audio│ CM108   │              │  │USB Audio│ CM108   │
│  │  Card   │ + PTT   │              │  │  Card   │ + PTT   │
│  └────┬────┘         │              │  └────┬────┘         │
│       │              │              │       │              │
│  ┌────▼────────────┐ │              │  ┌────▼────────────┐ │
│  │  kldloadOS      │ │              │  │  kldloadOS      │ │
│  │  SvxLink        │ │              │  │  SvxLink        │ │
│  │  wg0: 10.99.0.1 ├─┼── UDP ──────┼──┤  wg0: 10.99.0.2│ │
│  └─────────────────┘ │   51820      │  └─────────────────┘ │
└──────────────────────┘              └──────────────────────┘
```

---

## Hardware

| Component | Details | Cost |
|-----------|---------|------|
| Mini PC | Any x86_64 (Raspberry Pi works too with ARM build) | $100-200 |
| USB sound card | CM108/CM119 chipset (has GPIO for PTT) | $5-15 |
| FM transceiver | Handheld or mobile radio (e.g., Baofeng UV-5R) | $25-50 |
| Audio cables | 3.5mm to radio mic/speaker jacks | $10 |
| USB stick | kldloadOS installer | $5 |
| Total | | ~$150-280 |

### CM108 PTT wiring

The CM108 USB audio chipset has a GPIO3 pin (pin 13) that can be used for Push-To-Talk control without a separate interface board:

```
CM108 GPIO3 (pin 13) → 2N2222 transistor base (via 4.7K resistor)
Transistor collector → Radio PTT line
Transistor emitter → Ground
```

Hamlib supports this natively as PTT type `CM108`.

---

## Step 1: Install kldloadOS

```bash
cat > /tmp/answers.env << 'EOF'
KLDLOAD_DISTRO=debian
KLDLOAD_DISK=/dev/sda
KLDLOAD_HOSTNAME=irlp-node-a
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=changeme
KLDLOAD_PROFILE=server
KLDLOAD_NET_METHOD=dhcp
EOF
kldload-install-target --config /tmp/answers.env
```

---

## Step 2: Install SvxLink

```bash
apt install -y svxlink-server svxlink-calibration-tools
apt install -y alsa-utils sox hamlib-utils
```

---

## Step 3: Configure USB audio

```bash
# Find the USB sound card
arecord -l
# card 1: Device [USB Audio Device], device 0: USB Audio [USB Audio]

# Test recording (speak into the radio, key up)
arecord -D plughw:1,0 -f S16_LE -r 8000 -c 1 -d 5 /tmp/test.wav
aplay /tmp/test.wav

# Set levels
alsamixer -c 1
# Set capture to ~80%, playback to ~70%

# Save ALSA state
alsactl store 1
```

---

## Step 4: Set up CM108 PTT

```bash
# udev rule for CM108 GPIO access
cat > /etc/udev/rules.d/50-cm108-ptt.rules << 'EOF'
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0d8c", MODE="0666"
EOF
udevadm control --reload-rules
udevadm trigger

# Test PTT with hamlib
rigctl -m 1 -p /dev/hidraw0 -P CM108 T 1   # key up
rigctl -m 1 -p /dev/hidraw0 -P CM108 T 0   # key down
```

---

## Step 5: Configure SvxLink

```ini
# /etc/svxlink/svxlink.conf

[GLOBAL]
LOGICS=SimplexLogic
CFG_DIR=/etc/svxlink/svxlink.d
TIMESTAMP_FORMAT="%c"
CARD_SAMPLE_RATE=48000

[SimplexLogic]
TYPE=Simplex
RX=Rx1
TX=Tx1
MODULES=ModuleEchoLink
CALLSIGN=YOURCALL-L
SHORT_IDENT_INTERVAL=10
LONG_IDENT_INTERVAL=60
ROGER_SOUND=0

[Rx1]
TYPE=Local
AUDIO_DEV=alsa:plughw:1
AUDIO_CHANNEL=0
SQL_DET=VOX
VOX_FILTER_DEPTH=20
VOX_THRESH=500
DEEMPHASIS=0
PEAK_METER=1
DTMF_DEC_TYPE=INTERNAL

[Tx1]
TYPE=Local
AUDIO_DEV=alsa:plughw:1
AUDIO_CHANNEL=0
PTT_TYPE=Hidraw
HID_DEVICE=/dev/hidraw0
HID_PTT_PIN=GPIO3
PREEMPHASIS=0
DTMF_TONE_LENGTH=100
DTMF_TONE_SPACING=50
```

---

## Step 6: Configure EchoLink module (optional)

```ini
# /etc/svxlink/svxlink.d/ModuleEchoLink.conf

[ModuleEchoLink]
NAME=EchoLink
ID=2
TIMEOUT=60
SERVERS=servers.echolink.org
CALLSIGN=YOURCALL-L
PASSWORD=your-echolink-password
SYSOPNAME=Your Name
LOCATION=[Svx] Your City, ST
MAX_QSOS=4
MAX_CONNECTIONS=4
LINK_IDLE_TIMEOUT=300
```

---

## Step 7: Set up WireGuard between nodes

**Node A:**
```bash
umask 077
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key

cat > /etc/wireguard/wg0.conf << 'EOF'
[Interface]
Address = 10.99.0.1/24
ListenPort = 51820
PrivateKey = <node-a-private-key>

[Peer]
PublicKey = <node-b-public-key>
Endpoint = node-b.example.com:51820
AllowedIPs = 10.99.0.2/32
PersistentKeepalive = 25
EOF

systemctl enable --now wg-quick@wg0
```

**Node B:** Same config, swap IPs and keys.

---

## Step 8: Link nodes over WireGuard with remotetrx

Instead of EchoLink (which requires public servers), use SvxLink's `remotetrx` to link two nodes directly over the WireGuard tunnel.

**Node A** — runs `svxlink` (the repeater controller):
```ini
# In svxlink.conf, change Rx1 to use a network receiver
[Rx1]
TYPE=Net
HOST=10.99.0.2
TCP_PORT=5210
CODEC=S16
```

**Node B** — runs `remotetrx` (remote transceiver):
```ini
# /etc/svxlink/remotetrx.conf

[GLOBAL]
LOGICS=Trx1
CFG_DIR=/etc/svxlink/svxlink.d
TIMESTAMP_FORMAT="%c"

[Trx1]
TYPE=Net
RX=Rx1
TX=Tx1
LISTEN_PORT=5210
AUTH_KEY=shared-secret-key

[Rx1]
TYPE=Local
AUDIO_DEV=alsa:plughw:1
AUDIO_CHANNEL=0
SQL_DET=VOX
VOX_FILTER_DEPTH=20
VOX_THRESH=500

[Tx1]
TYPE=Local
AUDIO_DEV=alsa:plughw:1
AUDIO_CHANNEL=0
PTT_TYPE=Hidraw
HID_DEVICE=/dev/hidraw0
HID_PTT_PIN=GPIO3
```

```bash
# Node B
systemctl enable --now remotetrx

# Node A
systemctl enable --now svxlink
```

Now voice on Node A's radio comes out Node B's radio and vice versa — over an encrypted WireGuard tunnel. No public ports exposed except UDP 51820.

---

## Step 9: Firewall

```bash
cat > /etc/nftables.d/irlp.nft << 'EOF'
table inet filter {
  chain input {
    # SSH
    tcp dport 22 accept

    # WireGuard
    udp dport 51820 accept

    # SvxLink remotetrx (only on WireGuard interface)
    iifname "wg0" tcp dport 5210 accept

    # EchoLink (if used — only needed on one node)
    udp dport { 5198, 5199 } accept
    tcp dport 5200 accept
  }
}
EOF
systemctl reload nftables
```

---

## Step 10: ZFS snapshots for audio logs

```bash
# Dataset for recorded audio
zfs create -o mountpoint=/srv/radio-logs -o compression=zstd rpool/srv/radio-logs

# SvxLink can log audio — configure in svxlink.conf:
# REC_DIR=/srv/radio-logs

# Daily snapshots
echo '0 0 * * * root zfs snapshot rpool/srv/radio-logs@daily-$(date +\%Y\%m\%d)' >> /etc/crontab

# Replicate logs to backup node
echo '0 2 * * * root syncoid rpool/srv/radio-logs 10.99.0.2:rpool/srv/radio-logs-backup' >> /etc/crontab
```

---

## Test

```bash
# Check audio
arecord -D plughw:1,0 -f S16_LE -r 8000 -c 1 -d 3 /tmp/test.wav && aplay /tmp/test.wav

# Check PTT
rigctl -m 1 -p /dev/hidraw0 -P CM108 T 1 && sleep 2 && rigctl -m 1 -p /dev/hidraw0 -P CM108 T 0

# Check WireGuard
wg show wg0

# Check SvxLink
systemctl status svxlink
journalctl -u svxlink -f

# Key up on the local radio, you should hear it on the remote radio
```

---

## FCC Note

FCC Part 97 prohibits obscuring the meaning of amateur radio transmissions **over the air**. The WireGuard encryption applies to the **internet backhaul**, not the RF transmission. The RF side remains unencrypted as required. This is the same approach used by IRLP, EchoLink, AllStarLink, and 44Net Connect — all of which encrypt internet traffic while keeping RF transmissions in the clear.
