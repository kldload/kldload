# kldloadOS

You know that thing where you install Linux and then spend two days configuring ZFS, setting up snapshots, fighting DKMS, wiring up boot environments, building offline mirrors, and writing wrapper scripts so your Debian and CentOS boxes behave the same way? I automated all of that into a single USB stick.

**kldload** is the builder. **kldloadOS** is what you're running after install.

You stick a USB drive into any x86_64 machine — bare metal, KVM, Proxmox, VMware, whatever — boot it, pick your distro, and two minutes later you have a fully configured Linux system with ZFS on root, boot environments, automatic snapshots, 30+ CLI tools, a web UI, and complete offline package mirrors. No internet required.

---

## It started as a kernel loader. It became an OS.

The original idea was simple — load a kernel, install ZFS on root, get out of the way. But once you have a consistent ZFS layout, you need snapshot tools. Once you have snapshot tools, you need boot environments. Once you have boot environments, you need a safe upgrade path. Once you support multiple distros, you need a universal package manager. And once you have all of that, you've built an operating system.

kldloadOS still installs stock CentOS, Debian, RHEL, or Rocky underneath. Stock kernel, stock packages, stock systemd. Nothing is patched, nothing is forked, nothing is removed. `apt` and `dnf` still work exactly as they always do.

What kldloadOS adds — optionally — is a set of `k*` convenience tools that automate common tasks and work identically across distro families. `kpkg` wraps the native package manager so you can use one command on both Debian and CentOS if you want to. Or don't — run `apt install nginx` directly, it works fine. The `k*` tools are there to make cross-distro workflows easier, not to replace anything.

You pick the distro. You use it as-is, or you use the kldloadOS tools. Both work.

---

## One USB, four distros

The ISO contains two complete offline package mirrors:

- **~900 RPMs** for CentOS/RHEL/Rocky
- **~2,700 .debs** for Debian

You pick the distro at install time. The installer dispatches to `dnf --installroot` or `debootstrap` underneath, but from the outside the experience is the same: same disk layout, same bootloader, same tools, same CLI, same web UI.

---

## The technology stack

Everything below ships on the ISO and is configured automatically during install.

### ZFS on root

Not bolted on as an afterthought — it's the foundation. The installer handles partitioning, pool creation with tuned properties (ashift=12, lz4 compression, acltype, xattr=sa), a proper dataset hierarchy with separate snapshots for `/home`, `/var/log`, `/srv`, and a ZFSBootMenu bootloader that understands boot environments.

Getting ZFS on root working manually on CentOS or Debian is an 8-step process involving custom partitioning, DKMS kernel module builds, initramfs regeneration, hostid configuration, and a bootloader that most distros don't ship. kldload does all of it in one pass.

### Boot environments

Every time you upgrade, kldloadOS snapshots the root filesystem. If the upgrade breaks something, reboot and pick the previous working state from the boot menu. Or from the CLI:

```
kbe activate before-risky-change && reboot
```

This is how Solaris, FreeBSD, and illumos have worked for years. Stock Linux doesn't have it. kldloadOS does.

### Optional CLI tools

kldloadOS ships a set of `k*` commands that work the same on CentOS and Debian. They're all optional — the native tools (`apt`, `dnf`, `zfs`, `zpool`) are untouched and work exactly as you'd expect. The `k*` tools just automate common patterns:

```
kpkg install nginx          # wraps dnf or apt (adds ZFS snapshot)
ksnap                       # snapshot all key datasets
kbe create my-checkpoint    # create a boot environment
kclone /srv/prod /srv/test  # instant CoW clone
kdf                         # ZFS-aware disk usage
kst                         # system health dashboard
kupgrade                    # safe upgrade with rollback
kexport qcow2               # export to disk image
```

If you use `kpkg`, it takes an automatic ZFS snapshot before every install/remove/upgrade. If you use `apt` or `dnf` directly, everything works — you just don't get the automatic snapshot. Nothing is intercepted or replaced.

### Automatic snapshots

Sanoid runs in the background — hourly, daily, weekly, monthly snapshot rotation with automatic pruning. Plus the tools take their own snapshots before destructive operations. The result is a continuous safety net you never have to think about.

### Offline package mirrors (darksites)

Both mirrors are baked into the ISO. Install 50 machines from the same USB stick and every one gets identical packages — no mirror drift, no network dependency, no waiting for downloads. This matters in air-gapped environments, on unreliable connections, and anywhere you want reproducible deploys.

### Web UI

A Python-based web interface on port 8080 for installation, disk selection, and system management. No browser plugins, no npm, no node_modules — one Python file and one HTML file.

### WireGuard

`wireguard-tools` is pre-installed on every system. For cluster deployments, kldloadOS supports a 4-plane WireGuard mesh that separates bootstrap, control, metrics, and data traffic across isolated networks.

### eBPF observability

On Debian installs: `bpftrace`, `bpftool`, `bpfcc-tools`, and `linux-perf` are included in the base image. Trace syscalls, profile I/O, debug networking — out of the box, no additional packages needed.

### NVIDIA support

Set `KLDLOAD_NVIDIA_DRIVERS=1` during install and the NVIDIA CUDA repo and drivers are installed automatically. On CentOS/RHEL, this includes MOK signing for Secure Boot.

### Export anywhere

`kexport` converts a running system to qcow2 (KVM/Proxmox), VHD (Azure/Hyper-V), VMDK (VMware), OVA (VirtualBox), or raw disk images. Build once, run anywhere.

### Secure Boot + encryption

Shim-signed UEFI boot chain with automatic MOK key generation for DKMS modules. Optional ZFS native encryption (AES-256-GCM) with passphrase or keyfile.

---

## Who it's for

- **Sysadmins** who want ZFS on root without the manual setup pain
- **Home labbers** who want boot environments and instant rollbacks
- **Teams** who deploy both CentOS and Debian and want one tool set
- **Air-gapped environments** that need offline installs with no internet
- **Anyone** who's tired of reinstalling Linux because an upgrade broke something

---

## What it looks like

```bash
$ kst

  kldload web-server-01  (free edition, build a1b2c3d)

  Pool       ● rpool ONLINE  (No known data errors)
  Root       4.1G used / 35.9G available  (compression: 2.31x)
  Snapshots  47 total  (newest: 2026-03-21 14:30:00)
  Boot envs  3 available
  Memory     2.1G / 8.0G  |  CPUs  4  |  Uptime  12 days, 3 hours

  Services   ● kldload-webui  ● sshd  ● zfs-zed  ● sanoid.timer  ● NetworkManager
```

---

## Three profiles

When you boot the ISO, you choose a profile:

- **Desktop** — GNOME workstation + ZFS on root + all kldloadOS tools
- **Server** — Headless + SSH + ZFS on root + all kldloadOS tools
- **Core** — ZFS on root only. Stock distro, no kldload tools, no extras. For advanced users who want to manage everything themselves with native `zfs`/`zpool`/`apt`/`dnf` commands.

Desktop and Server include the full kldloadOS experience — `k*` tools, web UI, automatic snapshots, offline darksites. Core gives you just the hard part (ZFS on root with ZFSBootMenu and DKMS) and gets out of the way.

All three profiles are available for all four distros (CentOS, Debian, RHEL, Rocky).

See [Editions](editions.md) for the full comparison.

---

## Get started

```bash
git clone https://github.com/kldload/kldload.git
cd kldload

./deploy.sh clean
./deploy.sh builder-image
./deploy.sh build-debian-darksite
PROFILE=desktop ./deploy.sh build
./deploy.sh burn                    # write to USB
```

Boot from the USB. Pick your distro. Pick your profile. Install. That's it.

**[Full documentation →](README.md)**
