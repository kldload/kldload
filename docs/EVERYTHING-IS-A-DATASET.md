# Everything is a dataset or a zvol

On a kldload install there is no ordinary filesystem holding your things.
The root, every boot environment, every home, every VM disk, every container
image layer, and every container volume is a ZFS dataset or zvol.

That single decision is what the rest of this document is about: once
everything is a dataset, **snapshot, clone and replicate stop being features
of particular tools and become properties of the whole machine.**

Measured on a live install (2026-08-15):

```
49 filesystems + 12 zvols

rpool/ROOT/...                          boot environments
rpool/home, /usr, /var, /var/log ...    the system
rpool/vms/<name>                        one zvol per virtual machine
rpool/var/lib/containers/storage        the container estate
rpool/var/lib/containers/storage/zfs/…  one dataset per image layer
```

---

## What if all of it was just one kind of thing?

Every technology below arrived with its own way of saving state, its own way
of making a copy, and its own way of going back. Boot loaders got boot
environments. Hypervisors got qcow2 chains. Containers got image registries.
Backup got agents. Each one solved the same three problems again, badly, in
its own vocabulary.

Now none of them are their own thing. They are all a dataset or a zvol.

And once that is true, three verbs apply to **everything on the machine**,
without any of those technologies knowing about it:

- **snapshot** — constant time, whatever the size
- **clone** — milliseconds, sharing blocks until something diverges
- **send** — only the blocks that changed, to any machine

### What if containers had undo?

They do, and not as a feature somebody wrote — as a consequence.

A bad `pull`, a migration that ate the database, an image that broke on
update: roll the store back. Every image, every container, every volume
returns to the moment before. The engine does not need to support it and does
not need to know it happened.

### You can clone a running container

Measured on a live box, off a 5.16 GB image:

```
commit the running container   3.9 s     (its state becomes an image)
clone + start a new container  0.328 s
state carried into the copy    yes — the file written into the original
                               was there in the clone
```

A third of a second to stand up a second copy of a container **with its
state**. Not a rebuild, not a registry push and pull, not a `docker save`
piped to another host: a clone, because the layer was a dataset the whole
time.

Stack the same idea up a level and the estate moves too — 22 datasets in one
recursive snapshot, one stream carrying every layer, the engine's database
and every volume, incremental after the first.

The point is not that any single one of these is impossible elsewhere. It is
that here they are all *the same operation*, on the same object, with the
same three commands — and that the machine did not need a plugin, an agent
or a registry to make it so.

---

## What this replaces

Each row is a thing you would otherwise install, learn and maintain. The
right-hand column is what does the job here.

### Snapshots and rollback

| The usual way | Here |
|---|---|
| LVM snapshots (fixed-size, fills up, degrades write speed) | `zfs snapshot` — constant time, no reserved space, no write penalty |
| Timeshift / Snapper / rsnapshot | snapshots, native, on every dataset |
| `dd` full-disk images | a snapshot, then send only the changed blocks |
| Windows System Restore equivalents | boot environments — the whole OS, bootable, in the boot menu |
| "reinstall to undo a bad upgrade" | roll the boot environment back |

### Copies and templates

| The usual way | Here |
|---|---|
| `cp -a` / `rsync` to duplicate a VM | `zfs clone` — instant, shares blocks until written |
| qcow2 backing files and snapshot chains | zvol clones, no chain to flatten, no performance cliff |
| Packer building a golden image per change | build once, clone per machine |
| VM templates that are full copies | a `@golden` snapshot, cloned in about 0.2s |
| "copy the 40 GB image to make a test box" | a clone costing 17–460 MB until it diverges |

### Backup and replication

| The usual way | Here |
|---|---|
| rsync (walks every inode to find changes) | `zfs send -I` — the filesystem already knows what changed |
| Borg / restic / Duplicati for whole-system backup | send/recv, block-exact, no re-scan, no dedup database |
| Clonezilla / disk imaging for machine moves | send the datasets while the machine runs |
| Backup agents per application | one mechanism for every dataset on the box |

### Storage layout

| The usual way | Here |
|---|---|
| Partition sizing decided at install, resized later with risk | datasets share the pool; quotas and reservations, not partitions |
| LVM: pv/vg/lv, `lvextend`, `resize2fs` | `zfs create`; grow by writing |
| ext4 + separate RAID + separate volume manager | one layer: integrity, redundancy and volumes together |
| `fsck` after a bad shutdown | transactional; no fsck exists |
| Silent bit rot | every block checksummed, repaired from redundancy on read |
| Compression as a per-application feature | pool-wide, transparent |

### Containers

This is the part most people do not expect.

With the `zfs` storage driver, **every image layer is a real dataset** and
the store also holds the engine's database, the layer graph and the volumes.
That makes the container estate one replicable unit.

| The usual way | Here |
|---|---|
| overlay2 / overlayfs storage driver | zfs driver — layers are datasets |
| devicemapper (thin pools, loopback files) | gone; zvols and datasets do it natively |
| aufs, btrfs, vfs drivers | gone |
| `docker save` / `load` (images only, full copy every time) | `zfs send -R` — images, containers **and volumes**, incremental |
| `docker commit` to preserve a state (loses volumes) | a snapshot of the store, volumes included |
| Volume backup plugins and sidecar containers | volumes are datasets; snapshot them like anything else |
| Registry round-trip to move an image between hosts | send the layer datasets directly |
| "rebuild the image to roll back a bad pull" | roll the store back |

Measured on a live box: **22 datasets captured in one recursive snapshot,
24.7 GB for the entire container estate** — every image layer, the engine's
database, and every volume, in one stream.

---

## Why this is not available on an ext4/LVM system

It is not a matter of effort or tooling. The capability is structural:

- **ext4 has no snapshot.** LVM provides one *below* the filesystem, so it
  cannot know which blocks matter, must reserve fixed space in advance, and
  slows every write while it exists.
- **A copy is a copy.** Without copy-on-write at the storage layer, a
  template duplicate costs its full size in time and space. Clone-on-write is
  what makes "clone a golden image" a sub-second operation rather than a
  coffee break.
- **rsync must look.** It walks the tree comparing metadata to discover
  change. ZFS already recorded what changed, so an incremental send is
  proportional to the delta, not to the size of the filesystem.
- **Layers cannot be addressed.** With overlay2 an image layer is a
  directory inside one filesystem. There is no handle to snapshot, clone or
  send it independently — which is why moving containers between hosts means
  a registry.

---

## The honest limits

A features list that only lists wins is an advertisement. These are real:

- **A snapshot of a running store is crash-consistent, not
  application-consistent.** ZFS snapshots are atomic, so a database inside a
  container sees exactly what it would see after a power cut — which
  journalled engines recover from, but it is not the same as a quiesced
  backup. Stop the container, or use its own dump, when that matters.
- **The receiving host must match.** A replicated container estate lands on a
  host running the same engine with the zfs driver. This does not move
  containers to a stock Docker host on overlay2.
- **Encrypted pools need raw sends.** kldload encrypts by default, and
  `zfs send -R` refuses on an encrypted dataset without `-w`. The tooling
  handles it; anyone scripting it by hand will meet that error.
- **Kubernetes image layers are not datasets.** containerd runs on
  `overlayfs` here. Its snapshotter is a separate, riskier change; the k8s
  path is deliberately conventional.
- **Clones share blocks with their origin.** A clone cannot outlive its
  origin snapshot without being promoted — cheap, but a relationship to know
  about.
- **ZFS wants memory.** The ARC earns its keep, but a 2 GB box is not where
  this shines.

---

## The one-sentence version

Everything on the machine — the OS, its history, the VMs, the containers and
their volumes — is the same kind of object, and that object can be
snapshotted in constant time, cloned in milliseconds, and replicated by
sending only what changed.
