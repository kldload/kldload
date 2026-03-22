# NFS and iSCSI Storage Sharing

Share ZFS datasets over the network via NFS or iSCSI. Both work on CentOS/RHEL and Debian.

---

## NFS — File-level sharing

### Server setup

```bash
# CentOS/RHEL
kpkg install nfs-utils
systemctl enable --now nfs-server

# Debian
kpkg install nfs-kernel-server
systemctl enable --now nfs-kernel-server
```

### Create a shared dataset

```bash
# Create a ZFS dataset for sharing
zfs create -o mountpoint=/srv/nfs-share \
           -o compression=lz4 \
           rpool/srv/nfs-share

# Set ZFS NFS sharing (alternative to /etc/exports)
zfs set sharenfs="rw=@10.78.0.0/16,no_root_squash" rpool/srv/nfs-share
```

Or use traditional `/etc/exports`:

```bash
cat >> /etc/exports << 'EOF'
/srv/nfs-share  10.78.0.0/16(rw,no_root_squash,no_subtree_check,sync)
EOF

exportfs -ra
```

### Open the firewall

```bash
# CentOS/RHEL
firewall-cmd --permanent --add-service=nfs
firewall-cmd --permanent --add-service=rpc-bind
firewall-cmd --permanent --add-service=mountd
firewall-cmd --reload

# Debian
nft add rule inet filter input tcp dport 2049 accept
```

### Client setup

```bash
# CentOS/RHEL
kpkg install nfs-utils

# Debian
kpkg install nfs-common
```

```bash
# Mount
mkdir -p /mnt/shared
mount -t nfs 10.78.7.1:/srv/nfs-share /mnt/shared

# Verify
df -h /mnt/shared

# Persist in fstab
echo "10.78.7.1:/srv/nfs-share /mnt/shared nfs defaults,_netdev 0 0" >> /etc/fstab
```

### Multiple exports with different permissions

```bash
# Read-write share for the team
zfs create rpool/srv/project-data
echo "/srv/project-data 10.78.0.0/16(rw,sync,no_subtree_check)" >> /etc/exports

# Read-only ISO library
zfs create rpool/srv/iso-library
echo "/srv/iso-library 10.78.0.0/16(ro,sync,no_subtree_check)" >> /etc/exports

# Home directories with root squash
echo "/home 10.78.0.0/16(rw,sync,no_subtree_check,root_squash)" >> /etc/exports

exportfs -ra
```

---

## iSCSI — Block-level sharing

iSCSI presents a ZFS volume as a raw block device over the network. Useful for VMs, databases, or any workload that needs a dedicated block device.

### Server setup (target)

```bash
# CentOS/RHEL
kpkg install targetcli

# Debian
kpkg install targetcli-fb
```

### Create a ZFS volume (zvol)

```bash
# Create a 100GB zvol (thin-provisioned by default on ZFS)
zfs create -V 100G rpool/iscsi/vm-disk-1

# The block device appears at:
ls -l /dev/zvol/rpool/iscsi/vm-disk-1
# → /dev/zd0 (or similar)
```

### Configure the iSCSI target

```bash
targetcli

# Inside targetcli:
/> cd /backstores/block
/backstores/block> create vm-disk-1 /dev/zvol/rpool/iscsi/vm-disk-1

/> cd /iscsi
/iscsi> create iqn.2026-03.com.kldload:storage.vm-disk-1

/> cd /iscsi/iqn.2026-03.com.kldload:storage.vm-disk-1/tpg1/luns
/iscsi/.../luns> create /backstores/block/vm-disk-1

/> cd /iscsi/iqn.2026-03.com.kldload:storage.vm-disk-1/tpg1/acls
/iscsi/.../acls> create iqn.2026-03.com.kldload:client1

/> saveconfig
/> exit
```

```bash
systemctl enable --now target
```

### Open the firewall

```bash
# CentOS/RHEL
firewall-cmd --permanent --add-port=3260/tcp
firewall-cmd --reload

# Debian
nft add rule inet filter input tcp dport 3260 accept
```

### Client setup (initiator)

```bash
# CentOS/RHEL
kpkg install iscsi-initiator-utils

# Debian
kpkg install open-iscsi
```

Set the client IQN:

```bash
echo "InitiatorName=iqn.2026-03.com.kldload:client1" > /etc/iscsi/initiatorname.iscsi
systemctl restart iscsid
```

### Discover and connect

```bash
# Discover targets
iscsiadm -m discovery -t sendtargets -p 10.78.7.1:3260

# Login
iscsiadm -m node \
  -T iqn.2026-03.com.kldload:storage.vm-disk-1 \
  -p 10.78.7.1:3260 \
  --login

# Find the new block device
lsblk
# sdb   8:16   0  100G  0 disk

# Format and mount (or use as a raw device for a VM)
mkfs.ext4 /dev/sdb
mkdir -p /mnt/iscsi-vol
mount /dev/sdb /mnt/iscsi-vol
```

### Auto-connect at boot

```bash
iscsiadm -m node \
  -T iqn.2026-03.com.kldload:storage.vm-disk-1 \
  -p 10.78.7.1:3260 \
  --op update -n node.startup -v automatic

systemctl enable iscsid
```

---

## ZFS advantages for storage sharing

### Snapshots of shared data

```bash
# Snapshot the NFS share
zfs snapshot rpool/srv/nfs-share@hourly-$(date +%H)

# Expose snapshots to NFS clients (ZFS .zfs directory)
zfs set snapdir=visible rpool/srv/nfs-share

# Clients can access snapshots at:
# /mnt/shared/.zfs/snapshot/hourly-14/
```

### Snapshot an iSCSI zvol

```bash
zfs snapshot rpool/iscsi/vm-disk-1@before-migration

# Clone for testing
zfs clone rpool/iscsi/vm-disk-1@before-migration rpool/iscsi/vm-disk-1-test
# New block device at /dev/zvol/rpool/iscsi/vm-disk-1-test
```

### Compression

NFS data is compressed transparently by ZFS on the server side. Clients see uncompressed data:

```bash
zfs get compressratio rpool/srv/nfs-share
# NAME                  PROPERTY       VALUE
# rpool/srv/nfs-share   compressratio  2.31x
```

### Quotas per share

```bash
# Limit an NFS share to 500GB
zfs set quota=500G rpool/srv/nfs-share

# Guarantee 200GB (reservation)
zfs set reservation=200G rpool/srv/nfs-share
```

---

## Troubleshooting

```bash
# NFS — show current exports
exportfs -v
showmount -e localhost

# NFS — client can't mount
rpcinfo -p <server-ip>    # check RPC services running
mount -v -t nfs <server>:/path /mnt   # verbose mount

# iSCSI — show active sessions
iscsiadm -m session

# iSCSI — disconnect
iscsiadm -m node -T <iqn> -p <ip>:3260 --logout

# iSCSI — show target config
targetcli ls
```
