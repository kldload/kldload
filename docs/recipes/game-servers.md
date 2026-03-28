# Appliance Recipe: Game Servers on ZFS

Game servers on kldloadOS with per-game ZFS datasets, automatic 15-minute snapshots via sanoid, instant rollback after griefing or corruption, zero-cost clones for testing mods, and WireGuard for private server access. Covers Minecraft (Java + Bedrock), Valheim, Palworld, Rust, and Terraria.

---

## Step 1: Install kldloadOS

```bash
cat > /tmp/answers.env << 'EOF'
KLDLOAD_DISTRO=debian
KLDLOAD_DISK=/dev/sda
KLDLOAD_HOSTNAME=gameserver
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=changeme
KLDLOAD_PROFILE=server
KLDLOAD_NET_METHOD=dhcp
EOF
kldload-install-target --config /tmp/answers.env
```

---

## Step 2: ZFS datasets with quotas

```bash
# Each game gets its own dataset
kdir /srv/minecraft
kdir /srv/valheim
kdir /srv/palworld
kdir /srv/rust
kdir /srv/terraria

# Set quotas so one game can't eat all the disk
zfs set quota=50G rpool/srv/minecraft
zfs set quota=20G rpool/srv/valheim
zfs set quota=30G rpool/srv/palworld
zfs set quota=40G rpool/srv/rust
zfs set quota=10G rpool/srv/terraria
```

---

## Step 3: Sanoid auto-snapshots (every 15 minutes)

```ini
# /etc/sanoid/sanoid.conf
[rpool/srv/minecraft]
  use_template = gameserver
  recursive = yes

[rpool/srv/valheim]
  use_template = gameserver
  recursive = yes

[rpool/srv/palworld]
  use_template = gameserver
  recursive = yes

[rpool/srv/rust]
  use_template = gameserver
  recursive = yes

[rpool/srv/terraria]
  use_template = gameserver
  recursive = yes

[template_gameserver]
  frequently = 8
  hourly = 48
  daily = 30
  monthly = 3
  yearly = 0
  autosnap = yes
  autoprune = yes
  frequent_period = 15
```

```bash
systemctl restart sanoid.timer
```

---

## Step 4: Minecraft

### Java Edition

```bash
docker run -d --name minecraft-java \
  --restart unless-stopped \
  -p 25565:25565 \
  -e EULA=TRUE \
  -e MEMORY=4G \
  -e TYPE=PAPER \
  -e DIFFICULTY=normal \
  -e MAX_PLAYERS=20 \
  -v /srv/minecraft/java:/data \
  itzg/minecraft-server
```

### Bedrock Edition

```bash
docker run -d --name minecraft-bedrock \
  --restart unless-stopped \
  -p 19132:19132/udp \
  -e EULA=TRUE \
  -e DIFFICULTY=normal \
  -e MAX_PLAYERS=10 \
  -v /srv/minecraft/bedrock:/data \
  itzg/minecraft-bedrock-server
```

---

## Step 5: Valheim

```bash
docker run -d --name valheim \
  --restart unless-stopped \
  --cap-add=sys_nice \
  -p 2456-2458:2456-2458/udp \
  -e SERVER_NAME="Valhalla ZFS" \
  -e WORLD_NAME="Midgard" \
  -e SERVER_PASS="your-secret-password" \
  -v /srv/valheim/config:/config \
  -v /srv/valheim/data:/opt/valheim \
  lloesche/valheim-server
```

### Clone for mod testing

```bash
kclone /srv/valheim /srv/valheim-test

docker run -d --name valheim-test \
  --restart unless-stopped \
  -p 2459-2461:2456-2458/udp \
  -e SERVER_NAME="Valhalla TEST" \
  -e WORLD_NAME="Midgard" \
  -e SERVER_PASS="test-password" \
  -v /srv/valheim-test/config:/config \
  -v /srv/valheim-test/data:/opt/valheim \
  lloesche/valheim-server

# If it works, apply to production. If not, destroy the clone.
docker rm -f valheim-test
zfs destroy -r rpool/srv/valheim-test
```

---

## Step 6: Palworld

```bash
docker run -d --name palworld \
  --restart unless-stopped \
  -p 8211:8211/udp \
  -p 27015:27015/udp \
  -e MULTITHREADING=true \
  -e SERVER_NAME="Palworld ZFS" \
  -e SERVER_PASSWORD="your-secret" \
  -e MAX_PLAYERS=16 \
  -v /srv/palworld:/palworld \
  thijsvanloef/palworld-server-docker:latest
```

### Snapshot before every restart

```bash
cat > /usr/local/bin/palworld-restart << 'SCRIPT'
#!/bin/bash
echo "Snapshotting Palworld save data..."
ksnap /srv/palworld
echo "Stopping server..."
docker restart palworld
echo "Done. If anything goes wrong: ksnap rollback /srv/palworld"
SCRIPT
chmod +x /usr/local/bin/palworld-restart
```

---

## Step 7: Rust (with wipe-day support)

```bash
docker run -d --name rust-server \
  --restart unless-stopped \
  -p 28015:28015/udp \
  -p 28016:28016 \
  -e RUST_SERVER_NAME="ZFS Rust | Wipe Thursdays" \
  -e RUST_SERVER_SEED=12345 \
  -e RUST_SERVER_MAXPLAYERS=50 \
  -e RUST_RCON_PASSWORD="your-rcon-pass" \
  -v /srv/rust:/steamcmd/rust \
  didstopia/rust-server

# After first boot and map generation, create the "day 1" snapshot
ksnap /srv/rust
zfs rename rpool/srv/rust@$(zfs list -t snapshot -o name -H rpool/srv/rust | tail -1 | cut -d@ -f2) rpool/srv/rust@wipe-day-clean

# Wipe day -- one command
docker stop rust-server
ksnap rollback /srv/rust
docker start rust-server
```

### Automated monthly wipe

```bash
cat > /usr/local/bin/rust-wipe << 'SCRIPT'
#!/bin/bash
echo "[$(date)] Rust wipe day"
docker stop rust-server
ksnap rollback /srv/rust
docker start rust-server
echo "[$(date)] Wipe complete"
SCRIPT
chmod +x /usr/local/bin/rust-wipe

# First Thursday of every month at 3 AM
cat > /etc/cron.d/rust-wipe << 'EOF'
0 3 1-7 * 4 root /usr/local/bin/rust-wipe
EOF
```

---

## Step 8: Multi-server Docker Compose

```yaml
# /srv/docker-compose.yml
services:
  minecraft:
    image: itzg/minecraft-server
    restart: unless-stopped
    ports: ["25565:25565"]
    environment: { EULA: "TRUE", MEMORY: "4G", TYPE: "PAPER" }
    volumes: ["/srv/minecraft/java:/data"]
    deploy: { resources: { limits: { cpus: "2.0", memory: 6G } } }

  valheim:
    image: lloesche/valheim-server
    restart: unless-stopped
    ports: ["2456-2458:2456-2458/udp"]
    environment: { SERVER_NAME: "Valhalla", WORLD_NAME: "Midgard", SERVER_PASS: "secret" }
    volumes: ["/srv/valheim/config:/config", "/srv/valheim/data:/opt/valheim"]
    deploy: { resources: { limits: { cpus: "2.0", memory: 4G } } }

  palworld:
    image: thijsvanloef/palworld-server-docker:latest
    restart: unless-stopped
    ports: ["8211:8211/udp"]
    environment: { SERVER_NAME: "Palworld ZFS", MAX_PLAYERS: "16" }
    volumes: ["/srv/palworld:/palworld"]
    deploy: { resources: { limits: { cpus: "2.0", memory: 8G } } }

  rust:
    image: didstopia/rust-server
    restart: unless-stopped
    ports: ["28015:28015/udp", "28016:28016"]
    environment: { RUST_SERVER_NAME: "ZFS Rust", RUST_SERVER_MAXPLAYERS: "50" }
    volumes: ["/srv/rust:/steamcmd/rust"]
    deploy: { resources: { limits: { cpus: "2.0", memory: 8G } } }

  terraria:
    image: ryshe/terraria:latest
    restart: unless-stopped
    ports: ["7777:7777"]
    volumes: ["/srv/terraria:/root/.local/share/Terraria/Worlds"]
    deploy: { resources: { limits: { cpus: "1.0", memory: 2G } } }
    stdin_open: true
    tty: true
```

```bash
cd /srv && docker compose up -d
```

---

## Anti-grief toolkit

```bash
# List all snapshots for a game
ksnap list /srv/minecraft

# Roll back to before grief happened
docker stop minecraft-java
ksnap rollback /srv/minecraft       # interactive: pick the snapshot
docker start minecraft-java

# Or target a specific snapshot
zfs rollback rpool/srv/minecraft@autosnap_2026-03-23_15:00_frequent

# Clone for forensics without rolling back
kclone /srv/minecraft /srv/minecraft-forensics
docker run -d --name mc-forensics -p 25566:25565 \
  -e EULA=TRUE -v /srv/minecraft-forensics/java:/data \
  itzg/minecraft-server
```

---

## WireGuard for private servers

```bash
wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub

cat > /etc/wireguard/wg-games.conf << EOF
[Interface]
Address = 10.100.0.1/24
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/server.key)
PostUp = iptables -A FORWARD -i wg-games -j ACCEPT
PostDown = iptables -D FORWARD -i wg-games -j ACCEPT
EOF

# Generate a config for each player
mkdir -p /etc/wireguard/peers
for player in alice bob charlie; do
  wg genkey | tee /etc/wireguard/peers/${player}.key | wg pubkey > /etc/wireguard/peers/${player}.pub
  NEXT_IP=$(($(wg show wg-games peers 2>/dev/null | wc -l) + 2))
  cat >> /etc/wireguard/wg-games.conf << PEER
[Peer]
PublicKey = $(cat /etc/wireguard/peers/${player}.pub)
AllowedIPs = 10.100.0.${NEXT_IP}/32
PEER
done

systemctl enable --now wg-quick@wg-games
```

Players connect via WireGuard -- the game server is invisible to the public internet.

---

## Bill of materials

| Component | Cost |
|-----------|------|
| Server (8+ cores, 32GB RAM) | $400-800 |
| Storage (1TB NVMe) | $60-100 |
| kldloadOS on USB | Free |
| **Total** | **~$460-900** |
