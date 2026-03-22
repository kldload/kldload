# What is kldloadOS

**kldload** is the builder and installer. **kldloadOS** is what you're running afterward — an opinionated OS layer on top of CentOS, Debian, or RHEL that gives you ZFS on root, universal CLI tools, boot environments, offline package mirrors, and a consistent experience across distro families.

This page covers what kldloadOS gives you that a stock Linux install doesn't.

> **Just want ZFS on root with no extras?** Choose the **Core** profile during install. You get ZFS on root, ZFSBootMenu, and a stock distro — nothing else. See [Editions](editions.md).

---

## Nothing removed, everything optional

kldloadOS does not modify, patch, replace, or remove anything from the base distro. `apt`, `dnf`, `zfs`, `zpool`, `systemctl` — they all work exactly as they do on a stock install. The underlying OS is completely standard.

What kldloadOS adds is a set of optional `k*` convenience commands that automate common tasks and provide a consistent interface across distro families. You can use them, or ignore them entirely and operate the system with native tools. Both approaches are fully supported.

## One optional command set across Debian and CentOS/RHEL

Every kldload system ships the same `k*` CLI tools regardless of distro. If you don't want to remember whether it's `apt` or `dnf`, `dpkg -l` or `rpm -qa`, the `k*` tools abstract away the differences:

| You type | On CentOS/RHEL it runs | On Debian it runs |
|----------|----------------------|-------------------|
| `kpkg install nginx` | `dnf install -y nginx` | `apt-get install -y nginx` |
| `kpkg remove nginx` | `dnf remove -y nginx` | `apt-get remove -y nginx` |
| `kpkg search redis` | `dnf search redis` | `apt-cache search redis` |
| `kpkg update` | `dnf check-update` | `apt-get update` |
| `kpkg upgrade` | `dnf upgrade -y` | `apt-get upgrade -y` |
| `kpkg list` | `rpm -qa \| sort` | `dpkg -l` |
| `kpkg info nginx` | `dnf info nginx` | `apt-cache show nginx` |

And every `kpkg install`, `remove`, and `upgrade` takes an automatic ZFS snapshot first. If a package breaks something, roll back in seconds.

This is significant: you can write scripts, documentation, and automation that work on both distro families with zero conditional logic. `kpkg install htop tmux nginx` works everywhere.

---

## Automatic safety net for every operation

kldload tools create ZFS snapshots before destructive operations:

| Tool | Snapshot before | Naming |
|------|----------------|--------|
| `kpkg install` | Package install | `kpkg-YYYYMMDD-HHMMSS` |
| `kpkg remove` | Package removal | `kpkg-YYYYMMDD-HHMMSS` |
| `kpkg upgrade` | Package upgrade | `kpkg-YYYYMMDD-HHMMSS` |
| `kupgrade` | Full system upgrade | `pre-upgrade-YYYYMMDD-HHMMSS` |
| `ksnap` | Manual snapshot | `manual-YYYYMMDD-HHMMSS` |

Plus sanoid runs automatic hourly/daily/weekly/monthly snapshots in the background.

The result: you can't permanently break your system with a package operation. Every change is reversible.

---

## Boot environments

Stock Linux doesn't have boot environments. If a kernel update breaks your system, you're in recovery mode or reinstalling.

kldload gives you ZFSBootMenu + boot environments:

```bash
kbe create before-risky-change    # checkpoint
kupgrade                          # upgrade the system
# Broken? Reboot, pick the old BE from the menu
# Or: kbe activate before-risky-change && reboot
```

Every upgrade, every kernel change, every DKMS rebuild — you can always go back to the last working state in one command.

---

## ZFS on root (not bolted on)

Stock CentOS and Debian don't support ZFS on root out of the box. Getting ZFS on root working manually requires:

1. Custom partitioning (EFI + ZFS partition)
2. Pool creation with the right properties (ashift, compression, acltype, xattr, relatime)
3. Dataset hierarchy (separate /home, /var/log, /var/cache, /srv)
4. DKMS module build for the running kernel
5. Initramfs with ZFS support
6. Bootloader that understands ZFS (ZFSBootMenu or GRUB with ZFS patches)
7. Hostid configuration (zgenhostid)
8. Proper fstab/mount ordering

kldload does all of this automatically during install. The dataset hierarchy is deterministic:

```
rpool
├── ROOT/default      /                (the OS)
├── home              /home            (user data, separate snapshots)
├── root              /root
├── srv               /srv             (application data)
└── var
    ├── log           /var/log         (logs, separate snapshots)
    ├── cache         /var/cache       (no auto-snapshot, cache is disposable)
    └── tmp           /var/tmp         (no auto-snapshot)
```

Each path is an independent ZFS dataset with its own:
- Snapshot schedule
- Compression settings
- Quotas
- Send/receive replication

---

## Offline installation

Both RPM and APT package mirrors are baked into the ISO:

- **~900 RPMs** for CentOS/RHEL installs
- **~2,700 .debs** for Debian installs

No internet required. Boot from USB, pick your distro, install. This matters for:
- Air-gapped environments
- Unreliable network connections
- Consistent, reproducible installs (same packages every time)
- Fast deployment (no downloading 2GB+ of packages per machine)

---

## Instant CoW cloning

`kclone` creates copy-on-write clones of any directory:

```bash
kclone /srv/production /srv/staging
```

The clone is instant (takes milliseconds) and starts at near-zero disk space. Only divergent blocks consume space. Use cases:

- Clone a production database for testing
- Create a staging environment from live data
- Duplicate a project directory without doubling disk usage

---

## Multi-distro from one ISO

One ISO installs:
- CentOS Stream 9
- Debian Trixie
- RHEL 9
- Rocky Linux 9

The same USB stick works for all four. Same installer, same ZFS layout, same tools, same boot environments. The native package manager is still there — `dnf` on CentOS/RHEL, `apt` on Debian — fully functional. `kpkg` is an optional wrapper if you want one command for both.

---

## Export to any hypervisor

`kexport` converts a running system to portable disk images:

```bash
kexport qcow2   # KVM / Proxmox / OpenStack
kexport vhd     # Azure / Hyper-V
kexport vmdk    # VMware ESXi / vSphere
kexport ova     # VMware / VirtualBox
kexport raw     # dd-ready image
```

Build one system, deploy it everywhere.

---

## Health dashboard in one command

```bash
kst
```

Instantly shows pool health, disk usage, compression ratios, snapshot counts, boot environments, memory, CPU, uptime, and service status. No setup, no agents, no configuration.

---

## What's not changed

kldloadOS is deliberately non-invasive. The base distro is stock:

- **Kernel** — unmodified distro kernel. ZFS is built via DKMS, not a custom kernel.
- **Package managers** — `apt` and `dnf` are untouched. `kpkg` wraps them optionally; it does not replace, intercept, or modify them.
- **Init system** — stock systemd. No custom init, no wrapper services around systemd.
- **Filesystem tools** — `zfs`, `zpool`, `zdb` are standard OpenZFS. The `k*` tools call them underneath.
- **Network stack** — standard NetworkManager. WireGuard is the stock kernel module.
- **No proprietary components** — everything is open source (BSD 3-Clause).
- **No lock-in** — exports to any format, runs on any hardware. `kexport` uses `qemu-img`, not a custom tool.

If you uninstalled every `k*` tool, you'd have a standard CentOS or Debian system with ZFS on root. The `k*` tools are additions, not modifications.
