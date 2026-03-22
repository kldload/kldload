# 16-Node Cluster Setup Guide

This walks through building a full 16-node kldload cluster from scratch — one Cluster Manager hub and 15 worker nodes, connected over a 4-plane WireGuard mesh.

---

## Architecture overview

```
                        ┌─────────────────────────────┐
                        │   Node 0 — Cluster Manager   │
                        │   10.78.0.1/24 (hub)         │
                        │   wg0: 10.77.0.1             │
                        │   Salt master, state DB,      │
                        │   web UI, WireGuard hub       │
                        └──────────┬──────────────────┘
                                   │
               ┌───────────────────┼───────────────────┐
               │                   │                   │
    ┌──────────▼───────┐ ┌────────▼─────────┐ ┌──────▼──────────┐
    │  Blue cluster     │ │                  │ │  Green cluster   │
    │  Nodes 1–7        │ │   WireGuard      │ │  Nodes 8–15     │
    │  10.78.1.0/24 –   │ │   4 planes       │ │  10.78.8.0/24 – │
    │  10.78.7.0/24     │ │   (wg0–wg3)      │ │  10.78.15.0/24  │
    └───────────────────┘ └──────────────────┘ └─────────────────┘
```

The /20 CIDR (e.g., `10.78.0.0/20`) gives you 16 x /24 subnets. Nodes 0–7 form the **blue** cluster, nodes 8–15 form the **green** cluster. This enables blue/green upgrades — upgrade the green side, test it, then cut traffic over.

---

## Step 1 — Build the ISO

```bash
cd kldload-free

./deploy.sh clean
./deploy.sh builder-image
./deploy.sh build-debian-darksite
PROFILE=desktop ./deploy.sh build
```

Burn to USB or deploy to your hypervisor:

```bash
# USB (burn one, boot 16 machines from it)
./deploy.sh burn

# Or deploy to Proxmox (repeat with different VMIDs for each node)
VMID=900 VM_NAME=cm-hub ./deploy.sh proxmox-deploy
VMID=901 VM_NAME=node-01 ./deploy.sh proxmox-deploy
VMID=902 VM_NAME=node-02 ./deploy.sh proxmox-deploy
# ... continue for all 16
```

---

## Step 2 — Install the Cluster Manager (node 0)

Boot the ISO on the first machine. In the web UI or guided installer:

1. **Distro:** CentOS (or Debian)
2. **Profile:** Desktop (you want the web UI for management)
3. **Disk:** Select target disk
4. **Hostname:** `cm-hub` (or whatever you prefer)
5. **Deployment intent:** `cluster-manager`
6. **Cluster CIDR:** `10.78.0.0/20`
7. **Cluster domain:** `infra.local`
8. **Cluster size:** `16`
9. **WireGuard planes:** Accept defaults

The installer will:
- Install the OS with ZFS on root
- Generate all WireGuard keypairs for the hub
- Start the Salt master
- Initialize the state database
- Launch the web management UI

After reboot, the CM is reachable at its LAN IP on port 8080.

---

## Step 3 — Install worker nodes (nodes 1–15)

Boot each remaining machine from the same ISO. The installer auto-detects the Cluster Manager on the LAN:

```
★ Cluster Manager found at 10.100.10.45
```

1. **Deployment intent:** `join`
2. **Cluster Manager IP:** Auto-detected (or enter manually)

Each node will:
- Install the OS with ZFS on root
- Fetch cluster config from `http://<CM-IP>/hub.env` at first boot
- Configure all 4 WireGuard interfaces
- Register with the Salt master
- Appear in the cluster database automatically

### Assigning roles

From the CM web UI or command line, assign roles to each node:

| Node | Subnet | Role | Purpose |
|------|--------|------|---------|
| 0 | 10.78.0.0/24 | master/hub | Cluster Manager, Salt master |
| 1 | 10.78.1.0/24 | k8s-control | Kubernetes control plane + etcd |
| 2 | 10.78.2.0/24 | k8s-control | Kubernetes control plane + etcd |
| 3 | 10.78.3.0/24 | k8s-control | Kubernetes control plane + etcd |
| 4 | 10.78.4.0/24 | k8s-worker | Application workloads |
| 5 | 10.78.5.0/24 | k8s-worker | Application workloads |
| 6 | 10.78.6.0/24 | k8s-worker | Application workloads |
| 7 | 10.78.7.0/24 | storage | ZFS storage node (NFS/iSCSI) |
| 8 | 10.78.8.0/24 | k8s-worker | Green cluster workloads |
| 9 | 10.78.9.0/24 | k8s-worker | Green cluster workloads |
| 10 | 10.78.10.0/24 | k8s-worker | Green cluster workloads |
| 11 | 10.78.11.0/24 | k8s-worker | Green cluster workloads |
| 12 | 10.78.12.0/24 | prometheus | Metrics collection |
| 13 | 10.78.13.0/24 | grafana | Dashboards |
| 14 | 10.78.14.0/24 | k8s-lb | HAProxy load balancer |
| 15 | 10.78.15.0/24 | storage | Green storage node |

Available roles: `minion`, `k8s-control`, `k8s-worker`, `k8s-lb`, `storage`, `prometheus`, `grafana`, `custom`

---

## Step 4 — Verify the mesh

From the Cluster Manager:

```bash
# Check all WireGuard planes
wg show wg0   # bootstrap plane
wg show wg1   # control plane
wg show wg2   # metrics plane
wg show wg3   # data plane

# Every node should show a recent handshake
wg show wg1 | grep "latest handshake"
```

From the Salt master:

```bash
# List all connected minions
salt-key -L

# Accept pending keys
salt-key -A -y

# Ping all nodes
salt '*' test.ping

# Check node roles
salt '*' grains.get kldload:role
```

---

## Step 5 — WireGuard plane layout

Each plane isolates a class of traffic:

### wg0 — Bootstrap (10.77.0.0/16, port 51820)

Used during initial node enrollment. The new node contacts the CM over wg0 to fetch its cluster config, keys, and role assignment. After enrollment, wg0 can be restricted or torn down.

### wg1 — Control (10.78.0.0/16, port 51821)

SSH, Salt commands, cluster management traffic. This is the plane you use for day-to-day administration. All Salt minion/master communication flows here.

```bash
# SSH to a node over the control plane
ssh admin@10.78.0.5   # node 5's wg1 address
```

### wg2 — Metrics (10.79.0.0/16, port 51822)

Prometheus scrapes, Grafana queries, node_exporter traffic. Keeping metrics traffic on a dedicated plane prevents monitoring from competing with control or data traffic.

### wg3 — Data (10.80.0.0/16, port 51823)

Storage replication, Kubernetes pod-to-pod networking, NFS/iSCSI traffic. This is the high-throughput plane.

---

## Step 6 — Blue/green upgrades

The blue/green split means you can upgrade half the cluster while the other half serves traffic:

1. **Drain green nodes** — move workloads to blue (nodes 0–7)
2. **Upgrade green** — run `kupgrade` on nodes 8–15
3. **Test green** — verify services are healthy
4. **Drain blue** — move workloads to green
5. **Upgrade blue** — run `kupgrade` on nodes 0–7
6. **Rebalance** — spread workloads across all nodes

Each upgrade creates a ZFS boot environment snapshot (`pre-upgrade-YYYYMMDD-HHMMSS`). If an upgrade breaks a node, roll back:

```bash
# On the broken node
kbe list
kbe activate pre-upgrade-20260321-143000
reboot
```

---

## Scaling beyond 16

The /20 CIDR gives 16 x /24 subnets (4,094 usable IPs total). Each /24 subnet can hold 254 hosts. For larger deployments:

- Use a /16 CIDR for 256 x /24 subnets
- Or stack multiple /20 clusters with separate CIDRs
- Node roles can be reassigned at any time via the CM web UI

---

## Troubleshooting

```bash
# Node can't reach Cluster Manager
curl -fsSL http://<CM-LAN-IP>/hub.env   # should return WG1_PUB=...

# WireGuard handshake stuck
wg show wg1   # check "latest handshake" — if never, check firewall:
firewall-cmd --list-ports   # should show 51820-51823/udp

# Salt minion not registering
systemctl status salt-minion
salt-key -L   # check if key is pending on the master

# Node got the wrong role
# Reassign from the CM web UI or:
salt '<node-hostname>' state.apply kldload.role pillar='{"role": "k8s-worker"}'
```
