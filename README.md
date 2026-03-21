# kldload — free edition

**[kldload.ca](https://kldload.ca) · Debian 13 (trixie) · ZFS on root · ZFSBootMenu · Live installer**

kldload is a live bootable Debian 13 ISO that installs a production-ready ZFS-on-root system in minutes — no internet required. Boot the ISO, pick your target type in the browser-based installer, and go.

---

## What you get

- **GNOME live desktop** — boots straight to a desktop with the installer UI ready to go
- **Browser-based installer** — disk selector, target picker, live progress log
- **ZFS on root** — single-vdev pool with full dataset layout and boot environments baked in (mirror/RAIDZ arrays available in Pro)
- **ZFSBootMenu** — UEFI bootloader with boot environment management built in
- **Offline installer** — all packages baked into the ISO, no internet required
- **ZFS encryption** — optional AES-256-GCM full-disk encryption with passphrase unlock at boot
- **Automatic snapshots** — taken before/after every package change, and on a daily/weekly/monthly/yearly schedule from first boot
- **Post-install snapshot** — instant rollback point created automatically after every install

## Install targets

| Target | What gets installed |
|---|---|
| **Desktop** | GNOME, GDM, NetworkManager, Firefox, SSH |
| **Server** | Base system, SSH, systemd-resolved, common ops tools |

KVM, Storage, Monitoring, Proxmox, and VDI targets are available in **kldload Pro**. See [kldload.ca](https://kldload.ca).

---

## Using the installer

1. Boot the ISO (UEFI, bare metal or VM)
2. GNOME desktop loads — the installer opens automatically in Firefox
3. Fill in disk, hostname, username, target type, and click **Install**
4. Watch the live log — system powers off when complete
5. Boot the installed disk — ZFSBootMenu loads, then your system

The installer is also reachable over the network at `https://<ip>:8080` from any machine on the same network.

---

## ZFS pool layout

```
bpool  (grub2 compatibility)
└── BOOT/<hostname>          ← /boot

rpool
├── ROOT/<hostname>          ← /  (boot environment, canmount=noauto)
├── home                     ← /home
├── root                     ← /root
├── srv                      ← /srv
├── opt                      ← /opt
├── tmp                      ← /tmp  (sync=disabled)
├── usr/local                ← /usr/local
└── var/
    ├── cache                ← /var/cache
    ├── lib                  ← /var/lib
    ├── log                  ← /var/log
    ├── spool                ← /var/spool
    └── tmp                  ← /var/tmp
```

Pool properties: `ashift=12`, `compression=lz4`, `autotrim=on`, `xattr=sa`, `acltype=posixacl`, `dnodesize=auto`, `normalization=formD`

---

## What's baked into the installed system

kldload isn't just an installer — every system gets a set of quality-of-life improvements configured and ready from first boot.

### Automatic snapshots

**Before and after every package change** — a snapshot is taken automatically before and after every `apt install`, `apt upgrade`, or `apt remove`. The last 10 are kept automatically. Bad update? Roll back in seconds.

```bash
# See all snapshots
zfs list -t snapshot -r rpool

# Roll back to before a package install
zfs rollback rpool/ROOT/<hostname>@apt-pre-20260101-120000
```

**Scheduled snapshots** — no config needed, running from first boot:

| Cadence | Kept | Covers |
|---------|------|--------|
| Daily   | 7    | 1 week |
| Weekly  | 12   | 3 months |
| Monthly | 12   | 1 year |
| Yearly  | 1    | long-term anchor |

Applied to: `/` (root), `/home`, `/var/lib`, `/srv`, `/root`

**Post-install snapshot** — immediately after install completes, before first boot:
```
rpool@install-20260101T120000Z   ← instant factory reset point
bpool@install-20260101T120000Z
```

### Snapshot management tools

```bash
snapshot-create.sh manual              # take a manual snapshot of root
snapshot-create.sh manual rpool/home   # snapshot a specific dataset
snapshot-policy.sh                     # report — counts vs limits for all groups
snapshot-prune.sh rpool/ROOT/<h> apt-pre 10  # prune a specific group manually
```

### Boot environment management

ZFSBootMenu is the bootloader. At boot, hold Space to access the boot environment menu — roll back to any previous boot environment without booting into the OS at all.

From a running system:

```bash
kldload-be list                           # list all boot environments and snapshots
kldload-be create pre-upgrade             # snapshot current root before a major change
kldload-be rollback rpool/ROOT/<h>@pre-upgrade  # roll back if something goes wrong
kldload-be activate rpool/ROOT/<h>@pre-upgrade  # set a snapshot as next boot target
kldload-be delete rpool/ROOT/<h>@old      # clean up old boot environments
```

### ZFS dataset layout

Each major subtree is its own dataset — rolling back `/` doesn't affect `/home` or `/var/lib`. Service state survives OS rollbacks. Logs survive. Home directories survive.

```bash
# Add a dataset for a new user (survives OS rollbacks, independent snapshots)
zfs create -o mountpoint=/home/alice rpool/home/alice
chown alice:alice /home/alice

# Add a workload dataset under /srv
zfs create rpool/srv/myapp
```

### Hypervisor guest tools

At install time kldload auto-detects the hypervisor and installs the appropriate guest agent:

| Hypervisor | Installed |
|------------|-----------|
| KVM / QEMU / Proxmox | `qemu-guest-agent` |
| VMware / ESXi | `open-vm-tools` |
| Xen | `xe-guest-utilities` |

---

## ZFS and RAM — what's actually going on

If you're new to ZFS, `free -h` after boot will show most of your RAM as "used" and you'll wonder if something is wrong. Nothing is wrong — that's ZFS doing its job.

### The ARC (Adaptive Replacement Cache)

ZFS uses free RAM as a read cache called the ARC. The more RAM it has, the more data it can serve from memory instead of disk. This is intentional and a core part of how ZFS performs.

**The key thing to understand:** ARC memory is immediately released to applications that need it. It's not locked, it's not a leak — it's just free RAM being put to work. When an application asks for memory, the ARC shrinks to make room automatically.

```bash
# See actual ARC usage
arc_summary        # full ARC stats
cat /proc/spl/kstat/zfs/arcstats | grep -E "^size|^c |^hits|^misses"

# Quick view — ARC size vs limit
zpool get all | grep cache
```

### How much RAM does ZFS need?

ZFS runs on systems with as little as 2GB RAM, but the sweet spot for a desktop or light server is **4GB+**. More RAM = bigger ARC = faster reads, especially for datasets that get accessed repeatedly.

| RAM   | ARC behaviour |
|-------|--------------|
| 2 GB  | ARC limited to ~1 GB, tight but functional |
| 4 GB  | Comfortable for desktop + server workloads |
| 8 GB+ | ARC has room to cache heavily-accessed data |

### Tuning the ARC limit

If you want to cap how much RAM ZFS can use — for example on a shared host — set a limit in `/etc/modprobe.d/zfs.conf`:

```bash
# Cap ARC at 4 GB (value in bytes)
echo "options zfs zfs_arc_max=4294967296" > /etc/modprobe.d/zfs.conf
update-initramfs -u
```

Changes take effect after reboot. To apply without rebooting:
```bash
echo 4294967296 > /sys/module/zfs/parameters/zfs_arc_max
```

### Checking ARC performance

```bash
# Hit rate — if this is above 90% your working set fits in RAM
arc_summary | grep "Cache Hit Ratio"

# Watch ARC size live
watch -n1 'cat /proc/spl/kstat/zfs/arcstats | grep "^size"'
```

A high hit rate means most reads are served from RAM, not disk — exactly what you want.

---

## ZFS quick reference

New to ZFS? Here are the commands you'll use day-to-day.

### Pools and datasets

```bash
zpool list                          # show pools — size, used, health
zpool status                        # detailed health, any errors
zfs list                            # all datasets — used, available, mountpoint
zfs list -r rpool/home              # recursive — dataset + all children
```

### Snapshots

```bash
# Take a snapshot
zfs snapshot rpool/ROOT/<hostname>@before-upgrade
zfs snapshot -r rpool@weekly-backup    # -r snapshots all child datasets too

# List snapshots
zfs list -t snapshot
zfs list -t snapshot -r rpool/home     # snapshots of a specific dataset

# See what changed since a snapshot
zfs diff rpool/ROOT/<hostname>@before-upgrade

# Roll back (destroys changes made after the snapshot)
zfs rollback rpool/ROOT/<hostname>@before-upgrade

# Destroy a snapshot you no longer need
zfs destroy rpool/ROOT/<hostname>@before-upgrade
```

### Replication

ZFS replication sends a full dataset — or just the changes since the last send — to another pool or host. This is the gold standard for backups and DR.

```bash
# Full initial send to a local pool
zfs send rpool/home@snapshot1 | zfs receive backup/home

# Incremental send (only changes between two snapshots)
zfs send -i rpool/home@snapshot1 rpool/home@snapshot2 | zfs receive backup/home

# Send to a remote host over SSH
zfs send -R rpool/home@snapshot2 | ssh backup-host zfs receive backup/home

# Compressed send (saves bandwidth)
zfs send -c rpool/home@snapshot2 | ssh backup-host zfs receive backup/home

# Resume an interrupted send
zfs send -t <resume-token> | ssh backup-host zfs receive -s backup/home
```

### Dataset properties

```bash
# Check compression ratio
zfs get compressratio rpool

# Enable/change compression on a dataset
zfs set compression=zstd rpool/srv/myapp

# Check how much space snapshots are using
zfs list -o name,used,usedbysnapshots -r rpool

# Set quota on a dataset
zfs set quota=100G rpool/home/alice

# Set reservation (guaranteed space)
zfs set reservation=10G rpool/srv/mydb
```

### Common recipes

```bash
# Create a dataset for a new user
zfs create rpool/home/alice
chown alice:alice /home/alice

# Create a dataset for an application with its own snapshot schedule
zfs create -o compression=zstd rpool/srv/myapp

# Clone a dataset (instant copy-on-write — uses no extra space until data diverges)
zfs snapshot rpool/srv/myapp@v1
zfs clone rpool/srv/myapp@v1 rpool/srv/myapp-test

# Factory reset — roll back to the post-install snapshot
zfs rollback -r rpool@install-<timestamp>
```

---

## Web UI

Served at `https://<ip>:8080` on the live system. Single port — HTTP static files and WebSocket on the same connection.

- **Dashboard** — hostname, uptime, CPU, memory, NIC status
- **Install** — target selector, disk wipe, encrypted or plain ZFS, live progress log
- **ZFS** — pool status, snapshot list, snapshot create/rollback, boot environment management

Backend: Python asyncio + websockets. No framework dependencies beyond the standard library and `websockets`.

---

## License

BSD 3-Clause. See [LICENSE](LICENSE).

Third-party components (Linux kernel, OpenZFS, GNOME, etc.) retain their own licenses. All GPL/AGPL components are installed unmodified from official Debian APT repositories — source available from `deb-src` entries.

---

## Pro edition

The free edition installs the foundation. **kldload Pro** adds 1-touch cluster deployment, golden image management, node orchestration, and automated networking. See [kldload.ca](https://kldload.ca) for details.
