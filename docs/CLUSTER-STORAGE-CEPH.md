# Cluster storage: ZFS underneath, Ceph across

Status: **DESIGN** (2026-09-30). Nothing here is implemented. It answers the
open question at the end of `master-profile-architecture.md` §20 ("ZFS +
NFS/iSCSI + democratic-csi vs Ceph for large scale-out"): both, at different
tiers, and never stacked on the same disks.

## 1. Why clustering needs something ZFS does not have

A single kldload machine gets everything from ZFS: the root, boot
environments, goldens, instant clones, snapshots before every change. None of
that goes away. What a cluster adds is two asks ZFS cannot meet on its own:

- **Live migration.** A running VM moves to another host. The disk has to be
  readable from both hosts at once, which a pool on one machine's disks is not.
- **Failover without loss.** A host dies and its VMs start elsewhere. With
  `zfs send` replication the copy is only as new as the last send; everything
  written since is gone.

Replication is a fine answer for two machines, and it is what I would ship
first. From three machines up there is a real answer, and it is Ceph: every
write lands on several hosts before it is acknowledged, so any host can run
the VM and losing one loses nothing.

Ceph is not a Proxmox feature. Proxmox bundles it behind `pveceph`; the
project itself is upstream open source, and it installs on Fedora, EL and
Debian with its own tooling.

## 2. The layering

| Nodes | Storage | What the operator gets |
|---|---|---|
| 1 | ZFS | everything kldload does today |
| 2 | ZFS + `zfs send` replication | failover that loses the last interval; no live migration of the disk |
| 3 or more | ZFS on every node, Ceph on disks set aside for it | live migration and lossless failover for the VMs that ask for it |

Rules that hold at every tier:

- **ZFS stays the foundation on every node.** Root, boot environments,
  goldens and fast local clones never move to Ceph. A node must boot and be
  recoverable without the cluster.
- **Ceph gets whole disks of its own.** Never a zvol, never a partition of a
  pool disk. Ceph on a zvol is copy-on-write on copy-on-write, and its
  guidance is one daemon (OSD) per raw disk.
- **HA is per machine, not per cluster.** A VM that needs to move lives on
  Ceph; a lab clone that exists for twenty minutes stays a ZFS clone, because
  nothing is faster than that.
- **Below three nodes the tooling refuses to create Ceph.** Its monitors need
  a majority to stay writable; two cannot lose one and keep going.

## 3. How it pairs with the rest of kldload

### dRAID: same problem, different scope, so pair them side by side

dRAID and Ceph both keep data alive when disks die, and that is exactly why
they should not be stacked. dRAID protects inside one box; Ceph protects
across boxes. Ceph on top of dRAID pays for parity and for replicas at once,
and puts two copy-on-write layers under every write. Ceph under ZFS is the
same mistake the other way round.

Where they fit together is on the same node, on different disks:

- A node with a large shelf of disks splits it: a dRAID pool for what stays
  local (bulk data, the backup landing zone, `zfs send` targets from other
  nodes), and a set of raw disks handed to Ceph for the shared VM tier.
- A dedicated archive node with a big dRAID pool receives replication and
  RBD exports from the cluster. dRAID's distributed spare rebuilds a failed
  disk across every disk in the vdev instead of onto one spare, which is what
  makes wide pools of large disks survivable. That is the backup tier's
  problem, not the VM tier's.

The zxplore Builder already proposes dRAID layouts. The installer does not
offer dRAID for the root pool and should not: a root pool is small, and a
mirror is the right shape for it.

### Netboot: the pairing that makes Ceph worth having

A Ceph cluster grows by adding hosts and heals by replacing them, and kldload
already installs hosts unattended over the network from the full darksite.
Together:

1. A new machine netboots with an answers file that names its role and the
   disks Ceph may take.
2. It installs, joins the mesh, and at first boot asks the cluster to add it
   and create OSDs on exactly those disks.
3. Ceph rebalances onto it. Nothing is copied by hand.

Replacing a dead host is the same three steps. Because the data already lives
on the other hosts, the machine itself is disposable, which is the kldload
update model ("USB DR = upgrade = install, one mechanism") carried up to the
cluster: a node is rebuilt, never repaired.

### Goldens and clones

The moat is instant clones from goldens, and Ceph's block device (RBD) has
the same primitive: snapshot an image, protect the snapshot, clone it
copy-on-write. A golden promoted to the cluster tier gives instant clones that
can run on, and move to, any host. ZFS clones stay the default for local
speed; an RBD clone is what `kvm-clone` would make when asked for a machine
that must survive its host.

## 4. Components

- **cephadm, not Rook, for the VM tier.** The VMs are libvirt, not
  Kubernetes, so Ceph belongs at the host level. cephadm is upstream's own
  installer and runs the daemons as podman containers, which kldload already
  ships.
- **libvirt speaks RBD natively** (a network disk with protocol `rbd`), so
  vmxplore and `kvm-clone` gain a storage target, not a new data path.
- **ceph-csi for Kubernetes**, pointed at the same cluster, so the k8s
  profile's PersistentVolumes can be shared storage too. One cluster, two
  consumers. The ZFS classes in `STORAGE.md` stay for node-local volumes.
- **CephFS** is optional, for shared filesystems; NFS from a ZFS storage node
  (§20 of the architecture draft) already covers most of that.

## 5. Decisions to make before any code

These are expensive to change after the first install, so they come first.

1. **Network.** Ceph separates a public network (clients) from a cluster
   network (replication and recovery). Replication multiplies write traffic
   by the replica count, and recovery after a host loss is heavier still.
   Running that through WireGuard costs CPU on every byte. Options: a plain
   10G link or VLAN for the cluster network, with Ceph's own on-wire
   encryption (msgr2 secure mode) where the link is not trusted; or the
   draft's storage plane (wg3) and accept the cost. Management stays on the
   mesh either way.
2. **Which disks.** The installer needs a "these disks go to Ceph" choice next
   to pool layout, and the answers file needs the same field, so the split is
   decided at install time and never guessed at first boot.
3. **Offline.** cephadm pulls its images from quay.io. They go into the
   darksite like every other artefact, cephadm is pointed at the local
   registry, and the Ceph version is resolved at build time and locked, never
   written as a literal.
4. **Encryption.** Ceph encrypts OSDs with its own LUKS layer and keeps the
   keys in the cluster. That is a second key story next to ZFS native
   encryption and the tang/TPM unlock design; it has to be one story before
   it ships.
5. **Which machines get HA.** A per-VM flag, a per-template default, or a
   separate class of golden. I lean to the golden: a machine's storage tier
   follows the image it was cloned from.

## 6. Failure surface

- **Quorum.** Three monitors minimum, always an odd number. Losing a majority
  stops writes cluster-wide; the tooling must say that plainly instead of
  showing hung VMs.
- **Full.** Ceph stops accepting writes when an OSD reaches its full ratio
  (0.95 by default) and warns at nearfull (0.85). Capacity has to be watched
  per OSD, not per cluster, and belongs on the Grafana dashboards from day one.
- **Recovery competes with the VMs.** After a host loss the survivors copy
  its data back to full redundancy while still serving I/O. Recovery limits
  are a tuning decision, not a default to leave alone.
- **A host rebuilt during recovery** must rejoin as a new host with fresh
  OSDs, never with the old IDs.
- **Cluster down, node up.** Every node must still boot, reach its console and
  run its local ZFS machines with Ceph unavailable. Nothing on the boot path
  may wait on the cluster.

## 7. Phasing

1. **Prototype on fiend.** Three VMs, each with its own virtual disk for an
   OSD, a cephadm cluster on them, and one RBD-backed VM live-migrated between
   two of them. This proves the libvirt side and costs nothing to throw away.
   Test names only; fiend's pool is not touched.
2. cephadm from the darksite, offline, version derived at build time.
3. The installer and answers-file disk role.
4. Netboot join: first boot adds the host and its OSDs.
5. `kvm-clone` and vmxplore: a shared storage target and RBD clones from
   cluster goldens; live migration in the console.
6. ceph-csi for the k8s profile.
7. The two-node tier (`zfs send` replication failover) can ship before all of
   this, since it needs none of it.

## 8. Open

- Network plane for Ceph's cluster traffic (§5.1).
- One encryption story across ZFS, Ceph and tang/TPM (§5.4).
- Whether the archive node (dRAID) is a profile of its own or a role on the
  storage profile.
- Minimum hardware the tooling enforces (NICs, RAM per OSD), measured on the
  prototype rather than copied from a guide.
