# kldload

**Not an OS. Not a distro. A kernel loader.**

kldload builds a single bootable ISO that installs CentOS, Debian, or RHEL with ZFS on root — offline, from a USB stick, in under 2 minutes. Both package mirrors (RPM + APT) are baked into the image. No internet required.

**Website & ZFS Wiki:** [kldload.com](https://kldload.com) | **Architecture & Developer Guide:** [ARCHITECTURE.md](ARCHITECTURE.md)

---

## Quickstart

```bash
git clone https://github.com/kldload/kldload.git
cd kldload

# Full build: builder image + Debian darksite + CentOS ISO
./deploy.sh clean
./deploy.sh builder-image
./deploy.sh build-debian-darksite
PROFILE=desktop ./deploy.sh build

# Deploy
./deploy.sh kvm-deploy          # local KVM
./deploy.sh proxmox-deploy      # Proxmox (set PROXMOX_HOST in kldload.env)
./deploy.sh burn                # USB (/dev/sda)
```

Output: `live-build/output/kldload-free-centos-desktop-x86_64-DATE.iso`

---

## What's inside the ISO

```
ISO 9660 image
├── LiveOS/squashfs.img          ← CentOS live environment (GNOME + web UI)
├── /root/darksite/rpm/          ← offline CentOS package mirror (~900 RPMs)
├── /root/darksite/debian/apt/   ← offline Debian package mirror (~2,700 debs)
├── /root/darksite/boot/         ← ZFSBootMenu EFI binary
├── kldload-install-target       ← installer (bash)
├── kldload-webui                ← web UI (Python)
└── 30+ CLI tools (kst, ksnap, kbe, kdf, kdir, kpkg, ...)
```

Boot the ISO → web UI opens → pick distro + profile → install to disk. Two separate bootstrap paths run underneath — `dnf --installroot` for CentOS/RHEL, `debootstrap` for Debian. Same ZFS layout, same bootloader, same tools on both.

---

## deploy.sh commands

| Command | What it does |
|---------|-------------|
| `full` | Clean + rebuild everything |
| `build` | Build ISO (uses cached darksite) |
| `build-debian-darksite` | Rebuild Debian APT mirror cache |
| `builder-image` | Rebuild builder container |
| `clean` | Remove build artifacts |
| `kvm-deploy` | Deploy to local KVM |
| `proxmox-deploy` | Deploy to Proxmox |
| `deploy-all` | KVM + Proxmox + print USB command |
| `burn` | Write ISO to USB |

---

## Project structure

```
kldload-free/
├── deploy.sh                    ← entry point
├── builder/
│   ├── Dockerfile               ← CentOS builder container
│   └── build-iso.sh             ← ISO assembly (runs in container)
├── build/
│   ├── darksite/                ← RPM darksite builder + package lists
│   └── darksite-debian/         ← APT darksite builder + package lists
├── live-build/
│   ├── output/                  ← built ISOs
│   └── config/includes.chroot/  ← everything baked into the live ISO
│       ├── usr/sbin/kldload-install-target
│       ├── usr/lib/kldload-installer/lib/   ← 9 installer libraries
│       ├── usr/local/bin/kldload-webui
│       └── usr/local/bin/kst, ksnap, ...
└── profiles/                    ← desktop.yaml, server.yaml
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the full developer guide — build pipeline, installer internals, how to add packages, postinstallers, and custom profiles.

---

## What you get

- **ZFS on root** with ZFSBootMenu boot environments
- **Automatic snapshots** before every package change
- **30+ CLI tools** — `kst`, `ksnap`, `kbe`, `kdf`, `kdir`, `kpkg`
- **Web UI** installer and management (Python, port 8080)
- **Offline install** — both darksites baked in
- **Secure Boot** support via MOK enrollment
- **Multi-distro** — CentOS, Debian, RHEL from one ISO

## What you don't get

- Not an OS — it installs one
- Not a distro — you pick yours
- Not a cluster manager — build your own on top
- Not opinionated — ZFS on root is the only non-negotiable

---

## License

BSD 3-Clause. See [LICENSE](LICENSE).
