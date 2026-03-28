# Appliance Recipe: Satellite DVR and Signal Observatory

A kldloadOS appliance that turns a satellite dish, SDR dongles, and a GPU into a full signals observatory -- capturing satellite TV (DVB-S2), aircraft transponders (ADS-B/ACARS), weather imagery (NOAA APT, GOES HRIT), and wideband RF for anomaly detection. Everything records to ZFS with per-signal-type datasets, hardware GPU transcoding, and forensic watermarking for chain-of-custody provenance.

---

## Architecture

```
                         kldloadOS Signal Observatory
  SIGNAL SOURCES                    PROCESSING                  OUTPUT
  ──────────────                    ──────────────              ──────────
  Satellite Dish ──► DVB-S2 Tuner ──┐
    (Ku/C-band)      (TBS/DD)       │
                                     ├──► tvheadend ──► DVR recordings
  RTL-SDR v3 ──► USB ──────────────┤     (mux/EPG)    (ZFS snapshots)
    (24-1766 MHz)                    │
                                     ├──► GNU Radio ──► wideband IQ capture
  HackRF/Airspy ──► USB ──────────┤     (SDR engine)   (ZFS raw dataset)
    (1 MHz-6 GHz)                    │
                                     ├──► dump1090 ──► ADS-B aircraft map
                                     │     (1090 MHz)
                                     ├──► acarsdec ──► ACARS messages
                                     │     (131 MHz)    (airline telemetry)
                                     │
                                     ├──► satdump ──► NOAA/GOES imagery
                                     │     (weather)    (APT/HRIT decode)
                                     │
                                     └──► anomaly ──► unknown signal log
                                           detector    (SETI-style scan)

  ALL OUTPUTS ──► ffmpeg (GPU transcode) ──► forensic watermark ──► ZFS
```

---

## Hardware

| Component | Examples | Cost |
|-----------|---------|------|
| Edge server | Any x86_64 with PCIe + multiple USB 3.0 | $300-800 |
| DVB-S2 tuner card | TBS 6904 (4 tuner), Digital Devices Max S8 | $80-300 |
| Satellite dish + LNB | 60-120cm dish, Ku-band LNB, DiSEqC switch | $50-200 |
| SDR dongle (VHF/UHF) | RTL-SDR Blog v3/v4 (24-1766 MHz) | $25-40 |
| SDR wideband (optional) | Airspy R2, HackRF One (1 MHz-6 GHz) | $100-350 |
| L-band feed + LNA | Patch antenna + SAWbird+ LNA for Inmarsat | $50-100 |
| GPU (hardware transcode) | NVIDIA GTX 1650+ or Intel Arc A380 | $100-300 |
| Storage | 2x NVMe mirror + 4x HDD raidz2 for bulk capture | $200-600 |

---

## Step 1: Install kldloadOS

```bash
cat > /tmp/answers.env << 'EOF'
KLDLOAD_DISTRO=debian
KLDLOAD_DISK=/dev/sda
KLDLOAD_HOSTNAME=signal-obs
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=changeme
KLDLOAD_PROFILE=server
KLDLOAD_NVIDIA_DRIVERS=1
KLDLOAD_NET_METHOD=dhcp
EOF
kldload-install-target --config /tmp/answers.env
```

---

## Step 2: Install the signal stack

```bash
# SDR tools
apt install -y rtl-sdr librtlsdr-dev soapysdr-tools gnuradio

# DVB satellite tools
apt install -y dvb-tools dtv-scan-tables w-scan2

# Tvheadend -- satellite TV server
apt install -y tvheadend

# ADS-B aircraft tracking
apt install -y dump1090-mutability

# ACARS airline datalink
git clone https://github.com/TLeconte/acarsdec.git /opt/acarsdec
cd /opt/acarsdec && mkdir build && cd build && cmake .. && make && make install

# Weather satellite imagery
pip3 install satdump

# Transcoding + watermarking
apt install -y ffmpeg python3 python3-pip python3-opencv
pip3 install invisible-watermark numpy scipy

# Signal analysis
apt install -y inspectrum gqrx-sdr
```

---

## Step 3: Verify hardware

```bash
rtl_test -t                  # RTL-SDR
hackrf_info                  # HackRF (if installed)
ls /dev/dvb/                 # DVB-S2 tuner
dvb-fe-tool -a 0
nvidia-smi                   # GPU

# Quick FM capture test
rtl_fm -f 101.1e6 -M wbfm -s 200000 -r 48000 - | \
  aplay -r 48000 -f S16_LE -t raw -c 1
```

---

## Step 4: ZFS datasets

```bash
# Raw IQ captures -- incompressible noise, no compression
zfs create -o mountpoint=/srv/iq-capture \
           -o compression=off -o recordsize=1M \
           -o atime=off -o logbias=throughput rpool/srv/iq-capture

# DVR recordings -- compressed MPEG-TS
zfs create -o mountpoint=/srv/dvr \
           -o compression=zstd-3 -o recordsize=1M \
           -o atime=off rpool/srv/dvr

# Weather satellite imagery
zfs create -o mountpoint=/srv/imagery \
           -o compression=zstd -o atime=off rpool/srv/imagery

# Aircraft and datalink logs -- text-heavy, compresses well
zfs create -o mountpoint=/srv/adsb \
           -o compression=zstd-9 -o recordsize=16K rpool/srv/adsb

# Anomaly detection -- flagged signals
zfs create -o mountpoint=/srv/anomalies \
           -o compression=zstd -o recordsize=128K rpool/srv/anomalies

# Watermarked output
zfs create -o mountpoint=/srv/watermarked \
           -o compression=off -o recordsize=1M rpool/srv/watermarked

# Hourly snapshots, prune after 7 days
cat > /etc/cron.d/signal-snapshots << 'EOF'
0 * * * * root for ds in iq-capture dvr imagery adsb anomalies; do zfs snapshot rpool/srv/${ds}@auto-$(date +\%Y\%m\%d-\%H\%M); done
15 3 * * * root for ds in iq-capture dvr imagery adsb anomalies; do zfs list -t snapshot -o name -H rpool/srv/${ds} | grep @auto- | head -n -168 | xargs -r -n1 zfs destroy; done
EOF
```

---

## Step 5: Satellite TV (DVB-S2)

```bash
systemctl enable --now tvheadend
# Web UI: http://signal-obs:9981
# Configure: DVB Inputs > TV Adapters > set LNB type
#            DVB Inputs > Networks > add satellite
#            DVB Inputs > Muxes > auto-scan transponders
#            Configuration > DVR > Recording path: /srv/dvr

# Transcode and redistribute to LAN
ffmpeg \
  -i "http://localhost:9981/stream/channel/1?profile=pass" \
  -c:v hevc_nvenc -preset p4 -b:v 4M \
  -c:a aac -b:a 128k \
  -f hls -hls_time 4 -hls_list_size 20 -hls_flags delete_segments \
  /srv/dvr/live/channel1.m3u8
```

---

## Step 6: Aircraft tracking (ADS-B + ACARS)

```bash
# ADS-B -- 1090 MHz
cat > /etc/systemd/system/adsb-tracker.service << 'UNIT'
[Unit]
Description=ADS-B aircraft tracker (1090 MHz)
After=network.target
[Service]
Type=simple
ExecStart=/usr/bin/dump1090-mutability \
  --device-index 0 --net --net-http-port 8090 \
  --write-json /srv/adsb/live --write-json-every 1 \
  --lat YOUR_LAT --lon YOUR_LON
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl enable --now adsb-tracker
# Web map: http://signal-obs:8090

# ACARS -- 131.550, 131.525, 131.725 MHz (requires second RTL-SDR)
cat > /etc/systemd/system/acars-decoder.service << 'UNIT'
[Unit]
Description=ACARS airline message decoder
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/acarsdec \
  -d 1 -v -f 131.550 131.525 131.725 \
  -o 4 -j /srv/adsb/acars.json
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
systemctl enable --now acars-decoder
```

---

## Step 7: Weather satellite imagery

```bash
# NOAA APT (137 MHz) -- polar-orbiting, ~4 passes/day
# Requires RTL-SDR + V-dipole antenna
cat > /usr/local/bin/noaa-capture.sh << 'CAPTURE'
#!/bin/bash
FREQ=$1; DUR=$2; NAME=$3
OUTDIR="/srv/imagery/noaa/$(date +%Y%m%d)"
mkdir -p "$OUTDIR"
timeout "${DUR}" rtl_fm -f "${FREQ}e6" -M fm -s 60000 -r 11025 \
  -E deemp -E dc "${OUTDIR}/${NAME}.wav" 2>/dev/null
satdump live noaa_apt "${OUTDIR}/${NAME}.wav" "${OUTDIR}/${NAME}" \
  --source file 2>/dev/null
CAPTURE
chmod +x /usr/local/bin/noaa-capture.sh

# GOES HRIT (1694.1 MHz) -- geostationary, continuous
satdump live goes_hrit \
  --source rtlsdr --frequency 1694.1e6 --samplerate 2.4e6 \
  --output_folder /srv/imagery/goes/
```

---

## Step 8: Wideband spectrum scanning

```bash
# Record 20 MHz of L-band spectrum (Inmarsat, Iridium, GPS)
hackrf_transfer -r /srv/iq-capture/lband-$(date +%Y%m%d-%H%M).raw \
  -f 1545000000 -s 20000000 -n 400000000

# Record VHF band
rtl_sdr -f 130e6 -s 2.4e6 -n 48000000 /srv/iq-capture/vhf-$(date +%s).iq
```

### Anomaly detection

```python
#!/usr/bin/env python3
# /usr/local/bin/spectrum-scan.py
# Sweeps RTL-SDR range, flags signals above noise floor
# that don't match known frequencies

import subprocess, json, time, os
from datetime import datetime

SCAN_RANGE = "24M:1766M:1M"
KNOWN_SIGNALS_FILE = "/etc/signal-obs/known-signals.json"
ANOMALY_DIR = "/srv/anomalies"

def scan():
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    outfile = f"/tmp/sweep-{timestamp}.csv"
    subprocess.run(["rtl_power", "-f", SCAN_RANGE, "-i", "10",
                     "-1", "-c", "20%", outfile], timeout=300)
    known = {}
    if os.path.exists(KNOWN_SIGNALS_FILE):
        known = json.load(open(KNOWN_SIGNALS_FILE))
    anomalies = []
    with open(outfile) as f:
        for line in f:
            parts = line.strip().split(",")
            if len(parts) < 7: continue
            freq_mhz = int(parts[2]) / 1e6
            powers = [float(x) for x in parts[6:] if x.strip()]
            peak = max(powers) if powers else -100
            if peak > -30 and str(round(freq_mhz, 1)) not in known:
                anomalies.append({"freq_mhz": round(freq_mhz, 2),
                                  "peak_db": round(peak, 1),
                                  "time": timestamp})
    if anomalies:
        with open(f"{ANOMALY_DIR}/anomaly-{timestamp}.json", "w") as f:
            json.dump(anomalies, f, indent=2)
    os.unlink(outfile)
    return anomalies

if __name__ == "__main__":
    while True:
        try: scan()
        except Exception as e: print(f"Scan error: {e}")
        time.sleep(60)
```

---

## Step 9: Forensic watermarking

```bash
# Video watermarking (invisible opacity)
ffmpeg \
  -i "http://localhost:9981/stream/channel/1?profile=pass" \
  -vf "drawtext=text='OBS_%{localtime\:%Y%m%d_%H%M%S}_STN01':
       fontsize=10:fontcolor=white@0.01:x=10:y=10" \
  -c:v hevc_nvenc -preset p4 -b:v 4M -c:a copy \
  -f mpegts /srv/watermarked/stn01-ch1.ts

# IQ recording provenance metadata
cat > /usr/local/bin/iq-provenance.sh << 'PROV'
#!/bin/bash
FILE="$1"
cat >> "${FILE}.meta" << META
station_id: STN01
capture_time: $(date -u +%Y-%m-%dT%H:%M:%SZ)
hostname: $(hostname)
sha256: $(sha256sum "$FILE" | cut -d' ' -f1)
META
PROV
chmod +x /usr/local/bin/iq-provenance.sh
```

---

## Verify

```bash
rtl_test -t                                    # SDR
systemctl status tvheadend adsb-tracker        # Services
curl -s http://localhost:8090/data.json | head  # ADS-B
zfs list -r rpool/srv -o name,used,compressratio
```
