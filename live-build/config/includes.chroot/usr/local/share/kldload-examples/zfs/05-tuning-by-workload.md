# ZFS tuning recipes by workload

Cheat-sheet for the recordsize / compression / cache / logbias /
primarycache properties on a per-workload basis. These are the
defaults kldload's CSI provisioner applies based on the
`kldload.io/dataset-class` PVC label.

## Why these knobs matter on ZFS

- **recordsize** — the *maximum* block size ZFS uses for new writes
  in this dataset. Reads pull whole records into ARC. Mismatched
  recordsize vs application I/O size is the #1 cause of "ZFS is slow":
  Postgres on default 128K does 16× read-amp on every 8K page fault.

- **compression** — `lz4` is free (faster than no compression on most
  CPUs due to less I/O). `zstd-3` is the sweet spot for cold data.
  `zstd-9+` only for archive datasets.

- **primarycache** — `all` caches both data + metadata in ARC.
  `metadata` for datasets where the application has its own buffer
  cache (Postgres shared_buffers, etc.) and double-caching wastes RAM.

- **logbias** — `latency` (default) commits via the ZIL for crash
  durability. `throughput` skips the ZIL on synchronous writes, halves
  write amplification on streaming workloads where the app already
  does its own WAL.

- **sync** — `standard` honours O_SYNC + fsync(). `disabled` lets sync
  ops return immediately (DATA AT RISK on crash). Only for caches
  where loss is fine (e.g., browser caches, temp build artefacts).

- **atime** — almost always `off`. `relatime` (Linux ext4-style) isn't
  a ZFS thing; pick `off` and stop writing the access timestamp on
  every read.

## Recipes

### Postgres (OLTP, ~8K page workload)

```bash
zfs create -o recordsize=8K \
           -o compression=zstd-3 \
           -o primarycache=metadata \
           -o logbias=throughput \
           -o atime=off \
           -o relatime=off \
           rpool/postgres/data
```

Why: matches Postgres's 8K page size; primarycache=metadata avoids
double-buffering against shared_buffers; logbias=throughput because
the WAL already provides durability.

### SQLite (small writes, single-process)

```bash
zfs create -o recordsize=16K \
           -o compression=lz4 \
           -o atime=off \
           rpool/myapp/sqlite
```

Why: SQLite's default page is 4K; 16K record gives some read-ahead
without huge waste. lz4 keeps CPU low (mobile/edge boxes care).

### Big files / video / backups

```bash
zfs create -o recordsize=1M \
           -o compression=zstd-9 \
           -o atime=off \
           rpool/archive/videos
```

Why: big files read/write in big chunks; recordsize=1M reduces
metadata overhead 8× vs 128K. zstd-9 trades CPU for storage on
write-once-read-rarely content.

### Time-series databases (Prometheus, InfluxDB, VictoriaMetrics)

```bash
zfs create -o recordsize=128K \
           -o compression=zstd-3 \
           -o primarycache=all \
           -o atime=off \
           rpool/metrics/prom-data
```

Why: TSDBs write append-mostly in mid-size blocks. zstd compresses
time-series well (50-80% reduction common). primarycache=all because
the DB doesn't have its own buffer pool worth speaking of.

### Container images (Docker / containerd graph drivers)

```bash
zfs create -o recordsize=128K \
           -o compression=lz4 \
           -o atime=off \
           -o xattr=sa \
           -o acltype=posixacl \
           rpool/containers/storage
```

Why: lots of small files + occasional layer downloads; lz4 doesn't
slow image-pull. xattr=sa keeps extended attrs in inode (containerd
uses them heavily).

### Git repos (lots of small files, mostly cold)

```bash
zfs create -o recordsize=128K \
           -o compression=zstd-3 \
           -o atime=off \
           rpool/repos
```

Why: git's pack files compress poorly (already zlib'd) but loose
objects + workdir text compress well. Default record is fine.

### VM disks (qcow2 or zvol)

For qcow2 files on a dataset:

```bash
zfs create -o recordsize=64K \
           -o compression=lz4 \
           -o primarycache=metadata \
           -o atime=off \
           rpool/vm/images
```

For zvols directly:

```bash
zfs create -V 20G \
           -b 8K \
           -o compression=zstd-3 \
           -o sync=disabled \         # only if the GUEST FS handles sync (ext4 does)
           rpool/vm/myvm/disk
```

Why: -b 8K matches typical guest FS page; sync=disabled cuts write
latency in half (acceptable when the guest has its own journal).

## How to apply to an existing dataset

```bash
zfs set recordsize=8K rpool/postgres/data
# NOTE: recordsize changes only affect NEWLY-WRITTEN blocks; existing
# blocks keep their old size. To rewrite at the new size:
zfs send rpool/postgres/data@snap | zfs recv rpool/postgres/data-new
```

## Quick audit

```bash
zfs get recordsize,compression,primarycache,logbias,atime,sync \
       rpool/path/to/dataset
```
