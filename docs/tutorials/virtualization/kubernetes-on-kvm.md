# Kubernetes on KVM with kldload

This guide covers running Kubernetes clusters on KVM virtual machines managed by a kldload host. You create golden images once, clone them instantly with CoW, and spin up Kubernetes nodes on demand.

---

## Prerequisites

A kldload system with:
- At least 32GB RAM (4GB per VM, 3 control + 3 worker + host overhead)
- 200GB+ free disk space on ZFS
- Network bridge configured (the installer sets up `br0` or you can use the default NAT)

Install KVM if not already present:

```bash
# CentOS/RHEL
dnf install -y qemu-kvm libvirt virt-install libguestfs-tools

# Debian
apt-get install -y qemu-kvm libvirt-daemon-system virtinst libguestfs-tools

systemctl enable --now libvirtd
```

---

## Step 1 — Create a ZFS dataset for VMs

```bash
zfs create -o mountpoint=/var/lib/libvirt/images \
           -o compression=lz4 \
           -o recordsize=64k \
           rpool/vms

# Subdatasets for organization
zfs create rpool/vms/golden    # base images
zfs create rpool/vms/k8s       # kubernetes node disks
```

---

## Step 2 — Build a golden image

Start from the kldload ISO to create a base VM:

```bash
ISO=$(ls -t /root/kldload-free/live-build/output/*.iso | head -1)

virt-install \
  --name golden-k8s-base \
  --ram 4096 --vcpus 4 \
  --disk path=/var/lib/libvirt/images/golden/k8s-base.qcow2,size=40,format=qcow2 \
  --cdrom "$ISO" \
  --os-variant centos-stream9 \
  --network bridge=br0 \
  --graphics vnc,listen=0.0.0.0 \
  --boot uefi \
  --noautoconsole
```

Connect via VNC, install the OS, then shut down the VM and take a snapshot:

```bash
virsh shutdown golden-k8s-base

# Snapshot the golden image at ZFS level
zfs snapshot rpool/vms/golden@k8s-base-ready
```

### Prep the golden image for cloning

Before cloning, generalize the image so each clone gets a unique identity:

```bash
# Remove machine-specific state
virt-sysprep -d golden-k8s-base \
  --operations defaults,-ssh-userdir \
  --hostname localhost
```

---

## Step 3 — Clone VMs instantly

Use `qemu-img` CoW cloning — each clone starts at near-zero disk space:

```bash
# Create 3 control plane nodes
for i in 1 2 3; do
  qemu-img create -f qcow2 \
    -b /var/lib/libvirt/images/golden/k8s-base.qcow2 \
    -F qcow2 \
    /var/lib/libvirt/images/k8s/k8s-cp-${i}.qcow2
done

# Create 3 worker nodes
for i in 1 2 3; do
  qemu-img create -f qcow2 \
    -b /var/lib/libvirt/images/golden/k8s-base.qcow2 \
    -F qcow2 \
    /var/lib/libvirt/images/k8s/k8s-worker-${i}.qcow2
done
```

Register each VM with libvirt:

```bash
for i in 1 2 3; do
  virt-install \
    --name k8s-cp-${i} \
    --ram 4096 --vcpus 2 \
    --disk path=/var/lib/libvirt/images/k8s/k8s-cp-${i}.qcow2 \
    --os-variant centos-stream9 \
    --network bridge=br0 \
    --graphics vnc \
    --boot uefi \
    --import --noautoconsole
done

for i in 1 2 3; do
  virt-install \
    --name k8s-worker-${i} \
    --ram 8192 --vcpus 4 \
    --disk path=/var/lib/libvirt/images/k8s/k8s-worker-${i}.qcow2 \
    --os-variant centos-stream9 \
    --network bridge=br0 \
    --graphics vnc \
    --boot uefi \
    --import --noautoconsole
done
```

### Set unique hostnames

After each VM boots:

```bash
for i in 1 2 3; do
  virsh qemu-agent-command k8s-cp-${i} \
    '{"execute":"guest-exec","arguments":{"path":"/usr/bin/hostnamectl","arg":["set-hostname","k8s-cp-'${i}'"]}}'
done

for i in 1 2 3; do
  virsh qemu-agent-command k8s-worker-${i} \
    '{"execute":"guest-exec","arguments":{"path":"/usr/bin/hostnamectl","arg":["set-hostname","k8s-worker-'${i}'"]}}'
done
```

Or SSH in and set them manually.

---

## Step 4 — Install Kubernetes

SSH into each VM and install the container runtime and Kubernetes components.

### On ALL nodes (control plane + workers)

```bash
# Disable swap (ZFS handles memory better than swap)
swapoff -a
sed -i '/swap/d' /etc/fstab

# Load kernel modules
cat > /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# Sysctl settings
cat > /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# Install containerd
dnf install -y containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable --now containerd

# Add Kubernetes repo
cat > /etc/yum.repos.d/kubernetes.repo << 'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/repodata/repomd.xml.key
EOF

# Install kubelet, kubeadm, kubectl
dnf install -y kubelet kubeadm kubectl
systemctl enable kubelet
```

### On the first control plane node (k8s-cp-1)

```bash
# Initialize the cluster
kubeadm init \
  --control-plane-endpoint "k8s-cp-1:6443" \
  --pod-network-cidr 10.244.0.0/16 \
  --upload-certs

# Save the output — it contains join commands for other nodes

# Set up kubectl
mkdir -p ~/.kube
cp /etc/kubernetes/admin.conf ~/.kube/config

# Install a CNI (Flannel example)
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

### Join additional control plane nodes

```bash
# On k8s-cp-2 and k8s-cp-3, use the join command from kubeadm init output:
kubeadm join k8s-cp-1:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <cert-key>
```

### Join worker nodes

```bash
# On each worker:
kubeadm join k8s-cp-1:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

### Verify

```bash
kubectl get nodes
```

```
NAME           STATUS   ROLES           AGE   VERSION
k8s-cp-1       Ready    control-plane   10m   v1.31.x
k8s-cp-2       Ready    control-plane   8m    v1.31.x
k8s-cp-3       Ready    control-plane   7m    v1.31.x
k8s-worker-1   Ready    <none>          5m    v1.31.x
k8s-worker-2   Ready    <none>          4m    v1.31.x
k8s-worker-3   Ready    <none>          3m    v1.31.x
```

---

## Step 5 — ZFS snapshots for cluster safety

Before any cluster operation (upgrades, config changes), snapshot all VM disks:

```bash
# Snapshot all Kubernetes VM disks at once
zfs snapshot -r rpool/vms/k8s@pre-upgrade-$(date +%Y%m%d)

# List snapshots
zfs list -t snapshot -r rpool/vms/k8s
```

To roll back a broken node:

```bash
virsh shutdown k8s-worker-1
zfs rollback rpool/vms/k8s/k8s-worker-1@pre-upgrade-20260321
virsh start k8s-worker-1
```

---

## Scaling — add nodes on demand

Need more workers? Clone from the golden image and join in minutes:

```bash
# Create a new worker
qemu-img create -f qcow2 \
  -b /var/lib/libvirt/images/golden/k8s-base.qcow2 \
  -F qcow2 \
  /var/lib/libvirt/images/k8s/k8s-worker-4.qcow2

virt-install \
  --name k8s-worker-4 \
  --ram 8192 --vcpus 4 \
  --disk path=/var/lib/libvirt/images/k8s/k8s-worker-4.qcow2 \
  --os-variant centos-stream9 \
  --network bridge=br0 \
  --boot uefi \
  --import --noautoconsole

# After it boots, SSH in and join:
kubeadm join k8s-cp-1:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

To generate a new join token (they expire after 24h):

```bash
# On any control plane node
kubeadm token create --print-join-command
```

---

## Tear down a node

```bash
# Drain and remove from Kubernetes
kubectl drain k8s-worker-3 --ignore-daemonsets --delete-emptydir-data
kubectl delete node k8s-worker-3

# Destroy the VM
virsh destroy k8s-worker-3
virsh undefine k8s-worker-3 --nvram
rm /var/lib/libvirt/images/k8s/k8s-worker-3.qcow2
```

---

## Using the wg3 data plane for pod networking

If your kldload nodes are connected via WireGuard (cluster mode), use the `wg3` data plane (10.80.0.0/16) for Kubernetes pod traffic instead of the LAN:

1. Set `--apiserver-advertise-address` to the wg3 IP during `kubeadm init`
2. Configure Flannel/Calico to use the wg3 interface
3. This keeps pod-to-pod traffic encrypted and isolated from LAN traffic

```bash
# Example: init using wg3 address
kubeadm init \
  --apiserver-advertise-address 10.80.0.1 \
  --pod-network-cidr 10.244.0.0/16
```
