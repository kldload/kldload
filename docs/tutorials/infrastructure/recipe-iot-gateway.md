# Appliance Recipe: Building Automation IoT Gateway

A quad-NIC kldloadOS appliance that captures unencrypted BACnet and Modbus traffic from building automation devices (HVAC pumps, air handlers, heat exchangers), secures it with WireGuard, and delivers it to a RabbitMQ message queue for downstream processing.

**The problem:** Building automation devices broadcast unencrypted UDP (BACnet on port 47808, Modbus on TCP 502). These protocols were designed in the 1990s for isolated serial networks. They have zero encryption, zero authentication. Connecting them to anything outside the building is a security nightmare.

**The solution:** A kldloadOS gateway sits on the BACnet/Modbus network, captures the data, and tunnels it encrypted over WireGuard to a collection server. The building's OT network never touches the internet directly.

---

## Architecture

```
Building Network                          Data Center / Cloud
┌────────────────────┐                   ┌──────────────────────┐
│  AHU-1 (BACnet)    │                   │                      │
│  Pump-3 (Modbus)   │──eth1──┐          │  RabbitMQ            │
│  VFD-7 (Modbus)    │        │          │  InfluxDB / Grafana  │
│  Chiller (BACnet)  │        │          │                      │
└────────────────────┘        │          └──────────┬───────────┘
                              │                     │
                    ┌─────────▼──────────┐          │
                    │  kldloadOS Gateway  │          │
                    │                    │          │
                    │  eth0: management  │          │
                    │  eth1: BACnet VLAN │          │
                    │  eth2: Modbus/OT   │          │
                    │  wg0:  encrypted   ├──────────┘
                    │        backhaul    │  WireGuard tunnel
                    └────────────────────┘  (UDP 51820)
```

---

## Step 1: Install kldloadOS

Boot the ISO, select **Server** profile, **Debian** (lightest footprint for an appliance).

Unattended:
```bash
cat > /tmp/answers.env << 'EOF'
KLDLOAD_DISTRO=debian
KLDLOAD_DISK=/dev/sda
KLDLOAD_HOSTNAME=iot-gateway-01
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=changeme
KLDLOAD_PROFILE=server
KLDLOAD_NET_METHOD=static
KLDLOAD_NET_IP=192.168.1.10/24
KLDLOAD_NET_GATEWAY=192.168.1.1
KLDLOAD_NET_DNS=192.168.1.1
EOF
kldload-install-target --config /tmp/answers.env
```

---

## Step 2: Configure the four NICs

```bash
# eth0 — Management (IT network, SSH, updates)
cat > /etc/systemd/network/10-eth0-mgmt.network << 'EOF'
[Match]
Name=eth0

[Network]
Address=192.168.1.10/24
Gateway=192.168.1.1
DNS=192.168.1.1
EOF

# eth1 — BACnet VLAN (building automation devices)
cat > /etc/systemd/network/20-eth1-bacnet.network << 'EOF'
[Match]
Name=eth1

[Network]
Address=10.1.1.10/24
EOF

# eth2 — Modbus/OT (field devices, RS-485 gateways)
cat > /etc/systemd/network/30-eth2-modbus.network << 'EOF'
[Match]
Name=eth2

[Network]
Address=10.2.1.10/24
EOF

# Enable systemd-networkd
systemctl enable --now systemd-networkd

# Disable reverse-path filtering on BACnet interface (required for broadcast reception)
cat > /etc/sysctl.d/99-bacnet.conf << 'EOF'
net.ipv4.conf.eth1.rp_filter=2
net.ipv4.conf.eth2.rp_filter=2
EOF
sysctl -p /etc/sysctl.d/99-bacnet.conf
```

---

## Step 3: Set up WireGuard backhaul

```bash
# Generate keys
umask 077
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key

# Configure tunnel to collection server
cat > /etc/wireguard/wg0.conf << 'EOF'
[Interface]
Address = 10.99.0.1/24
ListenPort = 51820
PrivateKey = <gateway-private-key>

[Peer]
PublicKey = <collection-server-pubkey>
Endpoint = collection.example.com:51820
AllowedIPs = 10.99.0.2/32
PersistentKeepalive = 25
EOF

systemctl enable --now wg-quick@wg0
ping 10.99.0.2   # verify tunnel
```

---

## Step 4: Firewall — isolate OT from IT

```bash
cat > /etc/nftables.d/iot-gateway.nft << 'NFTEOF'
table inet filter {
  chain input {
    # Management (eth0)
    iifname "eth0" tcp dport 22 accept

    # BACnet broadcast (eth1)
    iifname "eth1" udp dport 47808 accept

    # Modbus TCP (eth2)
    iifname "eth2" tcp dport 502 accept

    # WireGuard
    udp dport 51820 accept

    # WireGuard tunnel traffic
    iifname "wg0" accept
  }

  chain forward {
    # BLOCK cross-traffic between OT and IT — this is critical
    iifname "eth1" oifname "eth0" drop
    iifname "eth2" oifname "eth0" drop
    iifname "eth0" oifname "eth1" drop
    iifname "eth0" oifname "eth2" drop

    # Allow OT → WireGuard (data collection only)
    iifname "eth1" oifname "wg0" accept
    iifname "eth2" oifname "wg0" accept
  }
}
NFTEOF

systemctl reload nftables
```

---

## Step 5: Install BACnet and Modbus tools

```bash
# BACnet — Python library
apt install -y python3-pip python3-venv
python3 -m venv /opt/bacnet
/opt/bacnet/bin/pip install BAC0 bacpypes3

# Modbus
apt install -y python3-pymodbus

# Traffic capture
apt install -y tshark tcpdump

# Serial tools (for RS-485 Modbus RTU adapters)
apt install -y minicom picocom setserial
```

---

## Step 6: Install RabbitMQ

```bash
apt install -y erlang-nox

curl -1sLf 'https://packagecloud.io/rabbitmq/rabbitmq-server/gpgkey' | \
  gpg --dearmor > /usr/share/keyrings/rabbitmq.gpg

echo "deb [signed-by=/usr/share/keyrings/rabbitmq.gpg] https://packagecloud.io/rabbitmq/rabbitmq-server/debian/ bookworm main" \
  > /etc/apt/sources.list.d/rabbitmq.list

apt update && apt install -y rabbitmq-server

# Enable management UI + MQTT broker
rabbitmq-plugins enable rabbitmq_management
rabbitmq-plugins enable rabbitmq_mqtt

# Create a user for the collectors
rabbitmqctl add_user iot_collector changeme
rabbitmqctl set_permissions -p / iot_collector ".*" ".*" ".*"

systemctl enable --now rabbitmq-server
```

RabbitMQ management UI: `http://10.99.0.1:15672`

---

## Step 7: BACnet collector service

```python
#!/usr/bin/env python3
# /opt/bacnet/bacnet-collector.py
# Discovers BACnet devices, polls Present-Value, publishes to RabbitMQ

import BAC0
import pika
import json
import time
from datetime import datetime, timezone

RABBITMQ_HOST = "localhost"
RABBITMQ_USER = "iot_collector"
RABBITMQ_PASS = "changeme"
EXCHANGE = "building_data"
POLL_INTERVAL = 30  # seconds

def main():
    # Connect to BACnet network on eth1
    bacnet = BAC0.connect(ip="10.1.1.10/24")

    # Connect to RabbitMQ
    credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASS)
    connection = pika.BlockingConnection(
        pika.ConnectionParameters(RABBITMQ_HOST, credentials=credentials)
    )
    channel = connection.channel()
    channel.exchange_declare(exchange=EXCHANGE, exchange_type="fanout", durable=True)

    # Discover devices
    bacnet.discover()
    time.sleep(5)

    while True:
        for device in bacnet.devices:
            try:
                name = device[0]
                addr = device[1]
                dev = BAC0.device(addr, device[2], bacnet)

                for point in dev.points:
                    msg = {
                        "timestamp": datetime.now(timezone.utc).isoformat(),
                        "device": name,
                        "address": str(addr),
                        "point": point.properties.name,
                        "value": point.lastValue,
                        "units": str(point.properties.units_state),
                        "type": "bacnet",
                    }
                    channel.basic_publish(
                        exchange=EXCHANGE,
                        routing_key="",
                        body=json.dumps(msg),
                    )
            except Exception as e:
                print(f"Error polling {device}: {e}")

        time.sleep(POLL_INTERVAL)

if __name__ == "__main__":
    main()
```

```bash
# systemd service
cat > /etc/systemd/system/bacnet-collector.service << 'EOF'
[Unit]
Description=BACnet data collector
After=network-online.target rabbitmq-server.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/bacnet/bin/python /opt/bacnet/bacnet-collector.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now bacnet-collector
```

---

## Step 8: Modbus collector service

```python
#!/usr/bin/env python3
# /opt/modbus-collector.py
# Polls Modbus TCP devices, publishes to RabbitMQ

from pymodbus.client import ModbusTcpClient
import pika
import json
import time
from datetime import datetime, timezone

RABBITMQ_HOST = "localhost"
RABBITMQ_USER = "iot_collector"
RABBITMQ_PASS = "changeme"
EXCHANGE = "building_data"
POLL_INTERVAL = 10  # seconds

# Define your Modbus devices and registers
DEVICES = [
    {
        "name": "pump-1",
        "host": "10.2.1.100",
        "port": 502,
        "registers": [
            {"name": "speed_rpm", "address": 40001, "count": 1, "scale": 1.0},
            {"name": "current_amps", "address": 40002, "count": 1, "scale": 0.1},
            {"name": "temperature_c", "address": 40003, "count": 1, "scale": 0.1},
            {"name": "run_status", "address": 40004, "count": 1, "scale": 1.0},
        ],
    },
    {
        "name": "vfd-3",
        "host": "10.2.1.101",
        "port": 502,
        "registers": [
            {"name": "frequency_hz", "address": 40001, "count": 1, "scale": 0.01},
            {"name": "output_power_kw", "address": 40002, "count": 1, "scale": 0.1},
        ],
    },
]

def main():
    credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASS)
    connection = pika.BlockingConnection(
        pika.ConnectionParameters(RABBITMQ_HOST, credentials=credentials)
    )
    channel = connection.channel()
    channel.exchange_declare(exchange=EXCHANGE, exchange_type="fanout", durable=True)

    while True:
        for device in DEVICES:
            client = ModbusTcpClient(device["host"], port=device["port"])
            if not client.connect():
                print(f"Cannot connect to {device['name']} at {device['host']}")
                continue

            for reg in device["registers"]:
                try:
                    result = client.read_holding_registers(
                        reg["address"] - 40001, count=reg["count"]
                    )
                    if not result.isError():
                        value = result.registers[0] * reg["scale"]
                        msg = {
                            "timestamp": datetime.now(timezone.utc).isoformat(),
                            "device": device["name"],
                            "address": f"{device['host']}:{device['port']}",
                            "point": reg["name"],
                            "value": value,
                            "type": "modbus",
                        }
                        channel.basic_publish(
                            exchange=EXCHANGE,
                            routing_key="",
                            body=json.dumps(msg),
                        )
                except Exception as e:
                    print(f"Error reading {device['name']}/{reg['name']}: {e}")

            client.close()

        time.sleep(POLL_INTERVAL)

if __name__ == "__main__":
    main()
```

```bash
cat > /etc/systemd/system/modbus-collector.service << 'EOF'
[Unit]
Description=Modbus data collector
After=network-online.target rabbitmq-server.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/modbus-collector.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now modbus-collector
```

---

## Step 9: ZFS datasets for data retention

```bash
# Time-series data store
zfs create -o mountpoint=/srv/iot-data -o compression=zstd rpool/srv/iot-data

# RabbitMQ persistence
zfs create -o mountpoint=/var/lib/rabbitmq -o recordsize=8k rpool/var/rabbitmq

# Capture archives
zfs create -o mountpoint=/srv/captures -o compression=zstd rpool/srv/captures

# Automated snapshots of collected data
echo '0 * * * * root zfs snapshot rpool/srv/iot-data@hourly-$(date +\%Y\%m\%d-\%H)' >> /etc/crontab
echo '0 0 * * * root zfs snapshot rpool/srv/captures@daily-$(date +\%Y\%m\%d)' >> /etc/crontab
```

---

## Step 10: Replicate data to collection server

On the collection server (10.99.0.2):
```bash
# Pull IoT data over WireGuard every hour
echo '15 * * * * root syncoid 10.99.0.1:rpool/srv/iot-data rpool/iot-ingestion/gateway-01' >> /etc/crontab
```

---

## Verify

```bash
# Check BACnet traffic on eth1
tcpdump -i eth1 udp port 47808 -c 5

# Check Modbus connections on eth2
ss -tn | grep :502

# Check RabbitMQ queues
rabbitmqctl list_queues

# Check WireGuard tunnel
wg show wg0

# Check data replication
zfs list -t snapshot -r rpool/srv/iot-data | tail -5
```

---

## Bill of materials

| Component | Example | Cost |
|-----------|---------|------|
| Quad-NIC mini PC | Protectli VP2420 or Topton N5105 | $200-400 |
| USB stick (installer) | Any 8GB+ USB | $5 |
| RS-485 adapter (if Modbus RTU) | USB-RS485 converter | $15 |
| Total | | ~$250-420 |

Compare to a commercial building automation gateway: $5,000-15,000.
