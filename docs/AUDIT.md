# Audit & Verification Guide

Don't trust us. Verify everything.

kldload is designed so that **every byte is traceable back to an official upstream source**. No pre-built binaries ship in the repository. Every package is fetched from official distro mirrors at build time, with native package-manager verification at every step.

## What ships in the git repo

- **Build scripts** — bash, Python, HTML/CSS. Zero compiled binaries.
- **Package lists** — `.txt` files with one package name per line (e.g. `build/darksite-arch/config/package-sets/target-base.txt`)
- **No cached packages** — all `live-build/darksite-*-cache/` directories are in `.gitignore`

A fresh `git clone` contains **no packages**. They are downloaded from official upstream mirrors during `./deploy.sh build`.

## Build from source

```bash
# 1. Clone the repository (no binaries, just build scripts)
git clone https://github.com/kldload/kldload-free
cd kldload-free

# 2. Read every build script (all readable bash)
cat deploy.sh                    # Build orchestration
cat builder/build-iso.sh         # ISO assembly
cat build/darksite-debian/build-darksite-debian.sh
cat build/darksite-arch/build-darksite-arch.sh
cat build/darksite-alpine/build-darksite-alpine.sh

# 3. Read the package lists
cat build/darksite-debian/config/package-sets/target-base.txt
cat build/darksite-arch/config/package-sets/target-base.txt
cat build/darksite-alpine/config/package-sets/target-base.txt
cat build/darksite/config/package-sets/base.txt

# 4. Build from scratch — all packages fetched from official repos
./deploy.sh clean
./deploy.sh builder-image
PROFILE=desktop ./deploy.sh build

# 5. Verify the ISO checksum
cat live-build/output/*.sha256
sha256sum live-build/output/*.iso
```

## Package verification by distro

Every package manager verifies integrity automatically. This happens at darksite build time (when packages are fetched) **and** at install time (when packages are installed into the target).

| Distro | Package format | Verification |
|--------|---------------|-------------|
| CentOS, Rocky, Fedora, RHEL | `.rpm` | GPG signatures + SHA-256 checksums in repodata |
| Debian, Ubuntu | `.deb` | GPG-signed `Release` file + SHA-256 per package in `Packages` index |
| Arch | `.pkg.tar.zst` | Signatures + SHA-256 in sync database |
| Alpine | `.apk` | Signed `APKINDEX.tar.gz` + per-package checksums |

## Verify darksite packages against upstream

```bash
# Debian/Ubuntu: checksums are in the Packages index
grep -A2 "^Package: zfsutils-linux" \
  live-build/darksite-debian-cache/apt/dists/trixie/main/binary-amd64/Packages

# Arch: checksum any cached package
sha256sum live-build/darksite-arch-cache/pkg/zfs-linux-*.pkg.tar.zst

# Alpine: checksum any cached package
sha256sum live-build/darksite-alpine-cache/apk/zfs-*.apk

# RPM: verify GPG signatures
rpm -K live-build/darksite-fedora-cache/rpm/*.rpm 2>/dev/null | head

# Watch what gets downloaded during a darksite build
./deploy.sh build-debian-darksite  2>&1 | grep -i download
./deploy.sh build-arch-darksite    2>&1 | grep -i download
./deploy.sh build-alpine-darksite  2>&1 | grep -i download
```

## Darksite integrity model

Each darksite is a **frozen snapshot** of official upstream packages at build time.

- **During install**: only the darksite is used. No internet mirror is contacted. No DNS queries, no HTTP requests. You can verify this by installing with the network cable unplugged.
- **After install**: the system's package manager is configured with standard internet repositories. The user runs `apt upgrade`, `dnf update`, or `pacman -Syu` to get current.

| Darksite | Build method | Served during install |
|----------|-------------|----------------------|
| RPM (CentOS/Rocky/Fedora) | `dnf download --resolve --alldeps` | `file://` local repo |
| Debian APT | `apt-get download` in native container | `localhost:3142` |
| Ubuntu APT | `apt-get download` in native container | `localhost:3143` |
| Arch pacman | `pacman -Sw` with dependency resolution | `file://` local repo |
| Alpine apk | `apk fetch --recursive` | `file://` local repo |

## Key files to audit

| File | Purpose |
|------|---------|
| `deploy.sh` | Build orchestration — darksite builds, ISO assembly, VM deploy |
| `builder/build-iso.sh` | Rootfs bootstrap, squashfs, EFI, xorriso |
| `build/darksite-*/build-darksite-*.sh` | Per-distro package downloaders |
| `kldload-install-target` | Installer entry point |
| `lib/bootstrap.sh` | Per-distro bootstrap functions (dnf, apt, pacman, apk) |
| `lib/profiles.sh` | Package lists per profile/distro |
| `lib/bootloader.sh` | ZFSBootMenu + initramfs |
| `kldload-webui` | Single-file Python web UI backend |

## Network access

| Phase | Internet required? |
|-------|-------------------|
| Building the ISO | Yes — fetches packages from official distro mirrors |
| Installing from the ISO (darksite present) | **No** — 100% offline |
| Installing from the ISO (no darksite) | Yes — falls back to internet mirrors |
| Post-install system updates | Yes — normal package manager repos |

## Reproducibility

Two builds from the same commit, run against the same mirror state, will produce darksites with identical packages. For full bit-for-bit reproducibility:

- Pin the mirror snapshot (Debian: `snapshot.debian.org`, Arch: `archive.archlinux.org`)
- Set `SOURCE_DATE_EPOCH` in the build environment

See also: [Security](https://kldload.com/platform/security.html) | [Audit & Verification (web)](https://kldload.com/platform/audit.html)
