# One storage rule

Every block size and record size kldload sets, in one table. Any tool that
creates a zvol or a dataset for a workload takes its value from here; a tool
that disagrees with this file is the defect. Settled 2026-09-27 on fiend,
after a survey found the same kind of disk at 8K, 16K and 64K depending on
which tool had made it.

| What | Where it is created | Size | Why |
|---|---|---|---|
| A machine's system disk, every golden | klab, kvm-golden, kube-cluster, vmxplore | volblocksize 64K | a guest filesystem writes 4K-64K; 64K keeps metadata small and compresses well; clones inherit it, so the golden decides |
| A data disk for media and bulk files | vmxplore appliances (default) | volblocksize 128K | written once, read whole |
| A database disk | klab db, vmxplore Web Stack and LAMP | volblocksize 16K | InnoDB's page exactly, two PostgreSQL pages; 16x less amplification than 128K |
| Container layers, host (podman, docker) | installer (profiles.sh), kvm component | recordsize 128K | layers are written once and read whole |
| etcd, on a Kubernetes node or host | kube-setup, installer | recordsize 16K | a database: small writes, each waits on fsync |
| containerd and kubelet, node or host | kube-setup, installer | recordsize 128K | image layers and pod scratch |
| PersistentVolume, class `zfs` (default) | kube-init | recordsize 128K | files and bulk data |
| PersistentVolume, class `zfs-db` | kube-init | recordsize 16K | databases; same as every other database disk |

Everything above also gets `compression=lz4` and `atime=off`.

## Notes

- volblocksize is fixed when a zvol is created and every clone inherits it.
  Changing this table changes new disks only; an existing golden keeps its
  size until it is rebuilt.
- recordsize is a ceiling, not a fixed size, and it applies only to blocks
  written after it is set. A PersistentVolume made under the old 8K
  `zfs-db` class keeps 8K.
- A database in a plain container (not Kubernetes) should get its own
  dataset at 16K bind-mounted in, rather than living in the 128K layer
  store.
