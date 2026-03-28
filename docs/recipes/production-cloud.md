# Appliance Recipe: Production Cloud

A production-grade cloud platform on kldloadOS with enterprise networking (VXLAN + Open vSwitch), dynamic routing (FRRouting with BGP and OSPF), L4/L7 load balancing (HAProxy + keepalived), internal PKI (step-ca), DNS (PowerDNS + CoreDNS), identity (Keycloak), and multi-tenant isolation. Builds on the Multi-Site Cloud recipe -- WireGuard mesh, ZFS replication, and multi-node infrastructure are assumed to be in place.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                        kldloadOS Production Cloud                                   │
│                                                                                     │
│  ┌── Internet ──────────────────────────────────────────────────────────────────┐    │
│  │  Floating IP (anycast or DNS failover)                                      │    │
│  │  HAProxy (L4/L7 load balancer) + keepalived (VRRP failover)                 │    │
│  └──────────┬──────────────────────────────────────────────────────────────────┘    │
│             │                                                                       │
│  ┌── Control Plane ─────────────────────────────────────────────────────────────┐    │
│  │  FRRouting        — BGP/OSPF dynamic routing between all nodes              │    │
│  │  PowerDNS         — authoritative DNS (public zones)                         │    │
│  │  CoreDNS          — internal service discovery (*.cloud.internal)            │    │
│  │  Keycloak         — identity / SSO / RBAC                                    │    │
│  │  step-ca          — internal PKI / automatic TLS certs                       │    │
│  │  Consul           — service mesh / health checking / KV store                │    │
│  └──────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                     │
│  ┌── Data Plane (VXLAN overlay) ────────────────────────────────────────────────┐    │
│  │  Open vSwitch bridges — per-tenant VXLAN segments (VNIs)                     │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │    │
│  │  │ VNI 100     │  │ VNI 200     │  │ VNI 300     │  │ VNI 400     │        │    │
│  │  │ tenant-a    │  │ tenant-b    │  │ staging     │  │ management  │        │    │
│  │  │ 10.100.0/24 │  │ 10.200.0/24 │  │ 10.30.0/24  │  │ 10.40.0/24  │        │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘        │    │
│  └──────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                     │
│  ┌── Compute ───────────────────────────────────────────────────────────────────┐    │
│  │  KVM/libvirt VMs   │  Nomad/K8s containers   │  Firecracker microVMs        │    │
│  └──────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                     │
│  ┌── Storage ───────────────────────────────────────────────────────────────────┐    │
│  │  ZFS pools (block/file)  │  MinIO (S3 object)  │  NFS/iSCSI (shared)        │    │
│  │  Sanoid snapshots → Syncoid replication across all sites                     │    │
│  └──────────────────────────────────────────────────────────────────────────────┘    │
│                                                                                     │
│  ┌── Underlay (physical / WireGuard) ───────────────────────────────────────────┐    │
│  │  Site A (Montreal) ◄──WireGuard──► Site B (Frankfurt) ◄──WG──► Site C (Home) │    │
│  │  BGP AS 65001          BGP AS 65002           BGP AS 65003                   │    │
│  └──────────────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### AWS equivalents

| AWS Service | Open-Source Replacement |
|-------------|------------------------|
| VPC / Subnets | VXLAN + Open vSwitch |
| Route Tables / Transit Gateway | FRRouting (BGP + OSPF) |
| ELB / ALB / NLB | HAProxy + keepalived |
| Route 53 | PowerDNS + CoreDNS |
| EC2 | KVM + libvirt |
| S3 | MinIO |
| CloudWatch | Prometheus + Grafana + Loki |
| IAM | Keycloak |
| ACM (certificates) | step-ca + ACME |
| CloudFormation | Terraform + Ansible |

---

## Step 1: FRRouting -- dynamic routing

```bash
dnf install -y frr frr-pythontools   # CentOS/RHEL/Rocky
# apt install -y frr                 # Debian

sed -i 's/bgpd=no/bgpd=yes/' /etc/frr/daemons
sed -i 's/ospfd=no/ospfd=yes/' /etc/frr/daemons
sed -i 's/bfdd=no/bfdd=yes/' /etc/frr/daemons
sed -i 's/zebra=no/zebra=yes/' /etc/frr/daemons
systemctl enable --now frr
```

### OSPF -- internal routing

```
! /etc/frr/frr.conf (OSPF section for Site A)
router ospf
 ospf router-id 10.10.0.1
 network 10.10.0.0/24 area 0.0.0.0
 network 10.100.0.0/16 area 0.0.0.0
 passive-interface default
 no passive-interface wg0
 no passive-interface br-mgmt
!
bfd
 peer 10.10.0.2
  no shutdown
 peer 10.10.0.3
  no shutdown
!
```

### BGP -- inter-site routing

```
! Site A (AS 65001)
router bgp 65001
 bgp router-id 10.10.0.1
 bgp log-neighbor-changes
 bgp bestpath as-path multipath-relax

 neighbor 10.10.0.2 remote-as 65002
 neighbor 10.10.0.2 description Site-B-Frankfurt
 neighbor 10.10.0.2 bfd
 neighbor 10.10.0.2 timers 10 30

 neighbor 10.10.0.3 remote-as 65003
 neighbor 10.10.0.3 description Site-C-HomeLab
 neighbor 10.10.0.3 bfd
 neighbor 10.10.0.3 timers 10 30

 address-family ipv4 unicast
  network 10.100.0.0/16
  network 172.20.0.0/14
  neighbor 10.10.0.2 route-map SITE-B-OUT out
  neighbor 10.10.0.3 route-map SITE-C-OUT out
 exit-address-family

 address-family l2vpn evpn
  neighbor 10.10.0.2 activate
  neighbor 10.10.0.3 activate
  advertise-all-vni
 exit-address-family
!
route-map SITE-B-OUT permit 10
 set metric 100
!
route-map SITE-C-OUT permit 10
 set metric 200
!
```

### Maintenance mode -- drain with BGP

```bash
# Drain Site A before maintenance
vtysh << 'DRAIN'
configure terminal
route-map DRAIN-OUT permit 10
 set as-path prepend 65001 65001 65001
!
router bgp 65001
 address-family ipv4 unicast
  neighbor 10.10.0.2 route-map DRAIN-OUT out
  neighbor 10.10.0.3 route-map DRAIN-OUT out
 exit-address-family
end
clear bgp * soft out
DRAIN
echo "Site A drained -- wait 30s for convergence, then do maintenance"

# After maintenance -- restore
vtysh << 'RESTORE'
configure terminal
no route-map DRAIN-OUT
router bgp 65001
 address-family ipv4 unicast
  neighbor 10.10.0.2 route-map SITE-B-OUT out
  neighbor 10.10.0.3 route-map SITE-C-OUT out
 exit-address-family
end
clear bgp * soft out
RESTORE
```

---

## Step 2: VXLAN + Open vSwitch

```bash
dnf install -y openvswitch libibverbs   # CentOS/RHEL
# apt install -y openvswitch-switch     # Debian
systemctl enable --now openvswitch

# Create the OVS bridge
ovs-vsctl add-br br-overlay

# VXLAN tunnels to other sites (key=flow means VNI per-flow)
ovs-vsctl add-port br-overlay vxlan-site-b -- \
    set interface vxlan-site-b type=vxlan \
    options:remote_ip=10.10.0.2 options:key=flow options:dst_port=4789

ovs-vsctl add-port br-overlay vxlan-site-c -- \
    set interface vxlan-site-c type=vxlan \
    options:remote_ip=10.10.0.3 options:key=flow options:dst_port=4789
```

### Create tenant networks

```bash
cat > /usr/local/bin/cloud-network << 'SCRIPT'
#!/bin/bash
set -euo pipefail
ACTION="${1:-help}"; VNI="${2:-}"; NAME="${3:-}"; SUBNET="${4:-}"

case "$ACTION" in
    create)
        [ -z "$VNI" ] || [ -z "$NAME" ] || [ -z "$SUBNET" ] && {
            echo "Usage: $0 create <VNI> <name> <subnet>"; exit 1; }
        ovs-vsctl add-port br-overlay "vni-$VNI" tag="$VNI" -- \
            set interface "vni-$VNI" type=internal
        GW_IP=$(echo "$SUBNET" | sed 's|0/|1/|')
        ip addr add "$GW_IP" dev "vni-$VNI"
        ip link set "vni-$VNI" up
        ovs-ofctl add-flow br-overlay \
            "table=0,priority=100,tun_id=$VNI,actions=output:vni-$VNI"
        echo "Network $NAME (VNI $VNI) created, gateway $GW_IP"
        ;;
    list)
        ovs-vsctl list-ports br-overlay | grep "^vni-" | while read port; do
            IP=$(ip -4 addr show "$port" 2>/dev/null | grep inet | awk '{print $2}')
            echo "  ${port}: $IP"
        done
        ;;
    delete)
        ovs-ofctl del-flows br-overlay "tun_id=$VNI"
        ovs-vsctl del-port br-overlay "vni-$VNI" 2>/dev/null || true
        echo "Network VNI $VNI deleted"
        ;;
esac
SCRIPT
chmod +x /usr/local/bin/cloud-network

cloud-network create 100 production  10.100.0.0/24
cloud-network create 200 staging     10.200.0.0/24
cloud-network create 300 development 10.30.0.0/24
cloud-network create 900 management  10.90.0.0/24
```

### Attach VMs to overlay networks

```bash
# Create an OVS port for a VM on VNI 100
ovs-vsctl add-port br-overlay "vm-web-01" tag=100 -- \
    set interface "vm-web-01" type=internal

# In virt-install, use the OVS bridge:
virt-install --network bridge=br-overlay,virtualport_type=openvswitch ...
```

---

## Verify

```bash
# BGP
vtysh -c "show bgp summary"
vtysh -c "show bgp ipv4 unicast"
vtysh -c "show ip ospf neighbor"
vtysh -c "show bfd peers"

# VXLAN
ovs-vsctl show
ovs-ofctl dump-flows br-overlay
cloud-network list
```
