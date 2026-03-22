# CLI Tools Reference

kldload ships a set of optional `k*` CLI tools for system management. All tools work on CentOS/RHEL and Debian.

**Nothing is replaced.** The native tools (`zfs`, `zpool`, `apt`, `dnf`, `qemu-img`, etc.) are untouched and always work directly. The `k*` tools are thin wrappers that simplify common operations by removing repetitive flags, adding sensible defaults, and taking advantage of the ZFS safety net (automatic snapshots before destructive operations, cleanup after upgrades, DKMS verification after kernel changes). They exist to reduce the number of steps in routine tasks — not to replace the underlying commands.

---

## kst — System status

One-command health dashboard.

```bash
kst
```

Shows:
- ZFS pool status (ONLINE/DEGRADED/FAULTED)
- Root filesystem usage and compression ratio
- Snapshot count and latest snapshot age
- Boot environment count
- Memory, CPU, uptime
- Service status: kldload-webui, sshd, zfs-zed, sanoid.timer, NetworkManager

---

## ksnap — Snapshot management

```bash
ksnap                    # snapshot all key datasets
ksnap /home              # snapshot a specific path
ksnap list               # list all snapshots with dates and sizes
ksnap rollback /home     # roll back to the last snapshot
ksnap destroy <name>     # delete a specific snapshot
```

Snapshot naming: `manual-YYYYMMDD-HHMMSS`

---

## kbe — Boot environments

```bash
kbe list                         # list all boot environments
kbe create my-checkpoint         # create a named BE
kbe activate my-checkpoint       # set it as the default for next boot
kbe rollback my-checkpoint       # roll back to a BE
kbe delete old-environment       # remove a BE
```

Boot environments are ZFS datasets under `rpool/ROOT/`. ZFSBootMenu lets you choose between them at boot time.

---

## kclone — Copy-on-Write cloning

```bash
kclone /srv/production /srv/staging
```

Creates an instant ZFS clone. The clone starts at near-zero space and grows only as you make changes. Uses:
- Testing database changes without affecting production
- Creating dev/staging environments from live data
- Duplicating any directory with zero copy cost

---

## kdf — ZFS disk usage

```bash
kdf              # all datasets
kdf /home        # specific path
```

Shows: used/available space, compression ratio (color-coded), quota, mountpoint for every ZFS dataset. Also shows pool-level stats: size, allocated, free, fragmentation.

---

## kdir — Create ZFS datasets

```bash
kdir /srv/myproject                               # create a dataset
kdir -p /srv/apps/frontend/static                  # create parents too
kdir -o compression=zstd -o quota=50G /srv/archive # with properties
```

Like `mkdir`, but creates a ZFS dataset instead of a plain directory. Each `kdir` path gets its own snapshots, compression, and quotas.

---

## kpkg — Universal package manager

```bash
kpkg install nginx       # install (auto-detects apt/dnf)
kpkg remove nginx        # remove
kpkg search redis        # search
kpkg info nginx          # package details
kpkg update              # refresh package lists
kpkg upgrade             # upgrade all packages
kpkg list                # list installed
```

Automatically takes a ZFS snapshot before every install/remove/upgrade. Snapshot naming: `kpkg-YYYYMMDD-HHMMSS`.

---

## kupgrade — Safe system upgrade

```bash
kupgrade
```

1. Creates boot environment snapshot: `pre-upgrade-YYYYMMDD-HHMMSS`
2. Runs full system upgrade (`apt dist-upgrade` or `dnf upgrade`)
3. Cleans up old packages
4. Verifies ZFS DKMS modules for every installed kernel
5. Re-signs DKMS modules if Secure Boot is active

If the upgrade breaks something:

```bash
kbe activate pre-upgrade-20260321-143000
reboot
```

---

## kexport — Disk image export

```bash
kexport qcow2    # KVM/Proxmox/OpenStack
kexport raw      # dd-ready sparse image
kexport vhd      # Azure/Hyper-V
kexport vmdk     # VMware ESXi/vSphere
kexport ova      # VMware/VirtualBox portable
kexport all      # all five formats

KEXPORT_NAME=myserver kexport qcow2   # custom filename
```

See [export-formats.md](export-formats.md) for details on each format and how to import them.

---

## krecovery — Disaster recovery

Boot from the kldload ISO to recover a broken system:

```bash
krecovery import rpool                    # import the ZFS pool
krecovery list-be                         # list boot environments
krecovery list-snapshots rpool/home       # list snapshots
krecovery activate <snapshot>             # set which BE to boot
krecovery rollback <snapshot>             # roll back a dataset
krecovery chroot                          # enter the system for manual fixes
krecovery reinstall-bootloader /dev/sda   # rebuild ZFSBootMenu
krecovery export-logs /mnt/usb            # copy logs for diagnosis
```

---

## kldload-webui — Web management UI

```bash
systemctl status kldload-webui    # check if running
systemctl restart kldload-webui   # restart
```

Access at `http://<host>:8080`. Features:
- Disk selection and install wizard
- ZFS dataset listing
- System status and log viewing
- WebSocket-based real-time log streaming during install

---

## kldload-install-target — The installer

```bash
# Interactive (called by the web UI)
kldload-install-target

# Unattended with answers file
kldload-install-target --config /path/to/answers.env
```

See [unattended-install.md](unattended-install.md) for answer file format.
