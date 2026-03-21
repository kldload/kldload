# Architecture

How kldload works, end to end. For developers who want to understand, modify, or extend the project.

---

## What's in the ISO

A kldload ISO is an [ISO 9660](https://en.wikipedia.org/wiki/ISO_9660) image — the same read-only filesystem format used to ship operating systems since 1988. Microsoft ships Windows on it. Apple ships macOS on it. Every Linux distro you've ever downloaded is one.

Inside the ISO:

```
kldload-free-centos-desktop-x86_64-DATE.iso
├── EFI/BOOT/
│   ├── BOOTX64.EFI          ← shim (Secure Boot)
│   ├── grubx64.efi           ← GRUB2 EFI bootloader
│   └── grub.cfg              ← boot menu (live + troubleshooting)
├── images/
│   ├── pxeboot/
│   │   ├── vmlinuz           ← CentOS kernel
│   │   └── initrd.img        ← initramfs with dracut-live
│   └── efiboot.img           ← FAT32 EFI boot partition image
└── LiveOS/
    └── squashfs.img           ← compressed root filesystem (~2GB)
```

The `squashfs.img` is the live operating system — a complete CentOS Stream 9 environment compressed with xz. When the ISO boots, dracut mounts it as the root filesystem. Everything the live session needs is inside it:

```
squashfs.img (root filesystem)
├── usr/local/bin/kldload-webui       ← Python web UI (installer + management)
├── usr/sbin/kldload-install-target   ← main installer script
├── usr/lib/kldload-installer/lib/    ← installer library (9 bash files)
├── usr/local/share/kldload-webui/    ← web UI static files (HTML/JS/CSS)
├── root/darksite/
│   ├── rpm/                          ← CentOS offline RPM mirror (~900 packages)
│   ├── debian/apt/                   ← Debian offline APT mirror (~2,700 packages)
│   └── boot/zfsbootmenu.EFI         ← ZFSBootMenu UEFI binary
└── ... (standard CentOS root filesystem with GNOME, ZFS, etc.)
```

The darksites are complete package mirrors baked into the squashfs. When the user runs the installer and picks a distro, the installer pulls packages from these local mirrors — no internet required.

---

## Project structure

```
kldload-free/
├── deploy.sh                          ← top-level entry point for everything
├── kldload.env                        ← environment config (credentials, defaults)
├── builder/
│   ├── Dockerfile                     ← CentOS Stream 9 builder container
│   └── build-iso.sh                   ← ISO assembly script (runs inside container)
├── build/
│   ├── darksite/
│   │   ├── build-darksite.sh          ← RPM darksite builder
│   │   └── config/package-sets/       ← RPM package lists
│   └── darksite-debian/
│       ├── build-darksite-debian.sh   ← APT darksite builder (runs in Debian container)
│       └── config/package-sets/       ← APT package lists (*.txt)
├── live-build/
│   ├── output/                        ← built ISOs land here
│   ├── logs/                          ← build logs
│   └── config/includes.chroot/        ← files baked into the live squashfs
│       ├── usr/sbin/
│       │   └── kldload-install-target ← main installer
│       ├── usr/lib/kldload-installer/
│       │   ├── lib/                   ← installer libraries (see below)
│       │   └── backend/bin/           ← kbe, krecovery, kupgrade
│       ├── usr/local/bin/
│       │   ├── kldload-webui          ← Python web UI backend
│       │   ├── kst, ksnap, kclone... ← CLI tools
│       │   └── ...
│       ├── usr/local/share/kldload-webui/
│       │   ├── active/index.html      ← web UI frontend
│       │   └── free/index.html        ← free edition source
│       └── root/darksite/             ← darksites embedded here at build time
└── profiles/
    ├── desktop.yaml                   ← GNOME desktop profile
    └── server.yaml                    ← headless server profile
```

---

## Build pipeline

The full build runs four stages. Each stage is a `deploy.sh` subcommand.

### Stage 1: `deploy.sh clean`

Removes previous build artifacts (`live-build/output/`, chroot, binary).

### Stage 2: `deploy.sh builder-image`

Builds a Podman/Docker container image (`kldload-live-builder:latest`) from `builder/Dockerfile`. This is a CentOS Stream 9 image with the build tools: lorax, createrepo_c, squashfs-tools, xorriso, dracut, mtools, etc.

### Stage 3: `deploy.sh build-debian-darksite`

Runs a **separate Debian container** (`debian:trixie-slim`) that:
1. Reads package lists from `build/darksite-debian/config/package-sets/*.txt`
2. Resolves the full transitive dependency closure via `apt-cache depends --recurse`
3. Downloads every `.deb` with `apt-get download` (one at a time, cached)
4. Generates APT index with `dpkg-scanpackages`
5. Writes an unsigned Release file

Output is cached at `live-build/darksite-debian-cache/apt/`. Subsequent builds skip this step if the cache exists.

This runs in a Debian container because `apt-get download` and `dpkg-scanpackages` are Debian tools that don't exist on CentOS.

### Stage 4: `deploy.sh build`

Runs `build-iso.sh` inside the CentOS builder container. This is the main event:

```
1. Build RPM darksite (dnf download → createrepo_c)
2. Bootstrap CentOS root filesystem (dnf --installroot)
3. Install packages: kernel, ZFS, GNOME, tools, debootstrap
4. Build ZFS DKMS module (cross-kernel, ARCH=x86_64)
5. Install sanoid (from GitHub release)
6. Configure live system (users, services, GDM, Firefox policy)
7. Copy kldload tools, webui, installer libs, configs
8. Copy RPM darksite into rootfs (/root/darksite/rpm/)
9. Copy Debian darksite into rootfs (/root/darksite/debian/)
10. Download ZFSBootMenu EFI binary
11. Create APT mirror systemd service (port 3142)
12. Build initramfs with dracut (dmsquash-live)
13. Create squashfs (xz compressed, 1MB block)
14. Assemble EFI boot structure (GRUB + shim)
15. Create EFI boot image (mtools — no loop device needed)
16. Build ISO with xorriso (EFI-only, KLDLOAD label)
17. Generate SHA256 checksum
```

Output: `live-build/output/kldload-free-centos-desktop-x86_64-DATE.iso`

---

## Installer architecture

When the user boots the ISO and clicks "Install to Disk" in the web UI, this happens:

```
Browser (index.html)
  │
  │ WebSocket message: { action: "install", params: { distro, disk, hostname, ... } }
  │
  ▼
kldload-webui (Python, port 8080/8081)
  │
  │ Writes params to /tmp/kldload-webui-answers.env
  │ Spawns subprocess:
  │
  ▼
kldload-install-target --config /tmp/kldload-webui-answers.env
  │
  │ Sources 9 library files from /usr/lib/kldload-installer/lib/
  │
  ▼
main()
  ├── k_install_zfs_storage()        ← partition disk, create zpool
  ├── k_bootstrap_base()             ← detect distro, dispatch:
  │   ├── _k_bootstrap_dnf()         ←   CentOS/RHEL: dnf --installroot
  │   └── _k_bootstrap_apt()         ←   Debian: debootstrap from darksite
  ├── k_configure_network()          ← NetworkManager config
  ├── k_configure_security()         ← SSH, users, sudoers
  ├── k_apply_profile()              ← desktop/server packages
  ├── k_install_tools()              ← copy kldload CLI tools
  ├── k_write_install_manifest()     ← /etc/kldload/install-manifest.env
  ├── k_enable_firstboot()           ← firstboot service
  ├── k_install_bootloader()         ← ZFSBootMenu EFI, initramfs rebuild
  └── k_poweroff_after_success()     ← clean unmount, power off
```

### Installer library files

| File | Purpose |
|------|---------|
| `common.sh` | Logging, mounts, helpers |
| `logging.sh` | Log file paths and rotation |
| `storage-zfs.sh` | Pool creation, dataset hierarchy |
| `profiles.sh` | Profile-specific package lists |
| `bootstrap.sh` | Distro bootstrap (dnf/debootstrap), package install |
| `security.sh` | MOK keys, DKMS signing, user security |
| `bootloader.sh` | ZFSBootMenu EFI, initramfs, efibootmgr |
| `answers.sh` | Configuration loading from env files |
| `infra.sh` | Infrastructure mode (WireGuard, cluster) |

### The answers file

The installer is configured entirely through environment variables. The web UI writes these to a file; the installer sources it. Key variables:

```bash
KLDLOAD_DISTRO=centos           # centos, debian, rhel, rocky
KLDLOAD_DISK=/dev/vda           # target disk
KLDLOAD_HOSTNAME=myhost         # hostname
KLDLOAD_USERNAME=admin          # admin user
KLDLOAD_PASSWORD=...            # user password
KLDLOAD_PROFILE=desktop         # desktop or server
KLDLOAD_STORAGE_MODE=zfs        # always zfs
KLDLOAD_ZFS_ENCRYPT=0           # 0 or 1
KLDLOAD_NET_METHOD=dhcp         # dhcp or static
```

For unattended installs: `kldload-install-target --config /path/to/answers.env`

---

## Darksite mirrors

### RPM darksite (CentOS)

Built by `build/darksite/build-darksite.sh` inside the CentOS builder container.
- Reads package lists from `build/darksite/config/package-sets/*.txt`
- Downloads RPMs with `dnf download --resolve --alldeps`
- Creates repo metadata with `createrepo_c`
- Lives at `/root/darksite/rpm/` on the ISO

### APT darksite (Debian)

Built by `build/darksite-debian/build-darksite-debian.sh` inside a Debian container.
- Reads package lists from `build/darksite-debian/config/package-sets/*.txt`
- Resolves full dependency closure, downloads with `apt-get download`
- Creates APT index with `dpkg-scanpackages`
- Lives at `/root/darksite/debian/apt/` on the ISO
- Served on `localhost:3142` by `kldload-apt-mirror.service` (python3 http.server)

### Adding packages to a darksite

Add package names to the appropriate `.txt` file in `config/package-sets/`:

```
build/darksite/config/package-sets/target-base.txt          ← RPM packages for all installs
build/darksite/config/package-sets/target-desktop.txt       ← RPM packages for desktop
build/darksite-debian/config/package-sets/target-base.txt   ← APT packages for all installs
build/darksite-debian/config/package-sets/target-desktop.txt ← APT packages for desktop
```

One package name per line. Comments start with `#`. Dependencies are resolved automatically.

---

## Adding your own stuff

### Add a postinstaller

A postinstaller is any script you want to run after the base install completes. Drop it into the includes.chroot tree and it gets baked into the ISO:

```bash
# Create your postinstaller
cat > live-build/config/includes.chroot/usr/local/sbin/my-postinstall.sh << 'EOF'
#!/bin/bash
# This runs on the installed system after first boot
apt-get install -y my-custom-package
systemctl enable my-service
EOF
chmod +x live-build/config/includes.chroot/usr/local/sbin/my-postinstall.sh
```

Wire it into the firstboot service or call it from a custom profile.

### Add files to the live ISO

Anything placed under `live-build/config/includes.chroot/` mirrors the root filesystem of the live ISO. For example:

```
live-build/config/includes.chroot/etc/myapp/config.yaml  →  /etc/myapp/config.yaml
live-build/config/includes.chroot/usr/local/bin/mytool    →  /usr/local/bin/mytool
```

### Add a package set

Create a new `.txt` file in the darksite package-sets directory:

```bash
# RPM packages (CentOS installs)
echo "nginx" >> build/darksite/config/package-sets/target-base.txt

# APT packages (Debian installs)
echo "nginx" >> build/darksite-debian/config/package-sets/target-base.txt
```

Rebuild the ISO — the darksite builder resolves all dependencies automatically.

### Customize the web UI

The frontend is a single HTML file at:
```
live-build/config/includes.chroot/usr/local/share/kldload-webui/active/index.html
```

The backend is a single Python file at:
```
live-build/config/includes.chroot/usr/local/bin/kldload-webui
```

No build step. No bundler. No node_modules. Edit and rebuild the ISO.

---

## deploy.sh reference

| Command | What it does |
|---------|-------------|
| `./deploy.sh full` | Clean + rebuild builder + build ISO |
| `./deploy.sh build` | Build ISO (caches Debian darksite) |
| `./deploy.sh build-debian-darksite` | Rebuild Debian APT darksite cache |
| `./deploy.sh builder-image` | Rebuild the builder container image |
| `./deploy.sh clean` | Remove build artifacts |
| `./deploy.sh kvm-deploy` | Deploy ISO to local KVM (virsh) |
| `./deploy.sh proxmox-deploy` | Deploy ISO to Proxmox (VMID from env) |
| `./deploy.sh deploy-all` | KVM + Proxmox + print USB command |
| `./deploy.sh burn` | Write ISO to USB (USB_DEVICE, default /dev/sda) |

### Environment variables

```bash
PROFILE=desktop          # desktop or server
ARCH=x86_64              # target architecture
RELEASE=9                # CentOS release
USB_BURN_ON_DEPLOY=no    # auto-burn to USB after build
PROXMOX_HOST=10.x.x.x   # Proxmox host for proxmox-deploy
VMID=902                 # Proxmox VM ID
VM_MEMORY=4096           # VM RAM in MB
VM_CORES=4               # VM vCPUs
VM_DISK_GB=40            # VM disk size
```

### Canonical build + deploy

```bash
cd kldload-free
./deploy.sh clean
./deploy.sh builder-image
./deploy.sh build-debian-darksite
PROFILE=desktop ./deploy.sh build
./deploy.sh deploy-all
```

---

## Limitations

- **AMD64 only** — ARM64 is planned but the darksite package sets and ZFSBootMenu EFI need ARM64 variants
- **CentOS live environment** — the live session is always CentOS, regardless of which distro you install
- **Single disk** — the default install uses one disk. Mirror/RAIDZ topologies are supported but require the answers file
- **No cloud images** — kldload produces ISOs, not AMIs/qcow2/VHDs. You boot the ISO in a cloud VM but don't get a launchable cloud image
- **ZFS only** — no ext4/btrfs option. ZFS on root is the entire point

---

## License

BSD 3-Clause. See [LICENSE](LICENSE).
