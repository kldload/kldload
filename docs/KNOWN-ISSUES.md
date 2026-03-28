# Known Issues — v1.0.1

Report issues at [github.com/kldload/kldload/issues](https://github.com/kldload/kldload/issues).

---

## Minimum Requirements

| Profile | RAM | Disk | Notes |
|---------|-----|------|-------|
| **Core** | 4 GB | 20 GB | Minimal install, no desktop |
| **Server** | 4 GB | 30 GB | Headless + tools |
| **Desktop (Debian/Ubuntu)** | 4 GB | 40 GB | GNOME + tools, fast offline install |
| **Desktop (CentOS/Fedora/Rocky/RHEL)** | 8 GB | 40 GB | RPM installs need 2GB live overlay for 875+ packages |
| **Desktop (Arch)** | 4 GB | 40 GB | pacstrap + GNOME |
| **Image export (kexport)** | 8 GB+ | 2x disk size | Needs space for the output image |

The live installer uses a tmpfs overlay in RAM for write operations. RPM-based desktop installs (CentOS, Fedora, Rocky, RHEL) install 875+ packages which requires more overlay space than Debian's debootstrap or Arch's pacstrap. If you get "No space left on device" during install, increase VM RAM.

---

## Tested Platforms

| Target | Desktop | Server | Core | Darksite | Notes |
|--------|---------|--------|------|----------|-------|
| CentOS Stream 9 | ✓ | ✓ | ✓ | Offline | Fastest RPM path |
| Debian 13 (Trixie) | ✓ | ✓ | ✓ | Offline | Fastest overall (~2 min) |
| Ubuntu 24.04 (Noble) | ✓ | ✓ | ✓ | Offline | debootstrap, universe enabled |
| Fedora 41 | ✓ | ✓ | ✓ | Offline | DNF bootstrap |
| Rocky Linux 9 | ✓ | ✓ | ✓ | Offline | Shares RPM darksite with CentOS |
| RHEL 9 | ✓ | ✓ | ✓ | Internet | Requires Red Hat Developer account |
| Arch Linux | ✓ | ✓ | ✓ | Offline | pacstrap, archzfs repo |
| RHEL 10 | ✗ | ✗ | ✗ | — | Subscription content not available |
| CentOS 10 | ? | ? | ? | — | Untested — repos exist |
| Rocky 10 | ? | ? | ? | — | Untested — repos exist |

**Validated hypervisors:**
- KVM/libvirt (Fedora host, UEFI, Secure Boot disabled)
- Proxmox VE (q35, OVMF, TPM 2.0)
- Bare metal USB boot (x86_64)

---

## Secure Boot

**Status: Not working on KVM VMs.**

The ZFS DKMS module on the live ISO is not signed with an enrolled MOK key. `modprobe zfs` fails and the installer crashes.

**Workaround:** Disable Secure Boot in VM firmware, or pass `--boot uefi,firmware.feature0.enabled=no,firmware.feature0.name=secure-boot` to virt-install. Bare metal with Secure Boot disabled works fine.

**Fix:** Auto-generate and enroll MOK key during ISO build, sign the ZFS module.

---

## GDM first-boot hang (Desktop profile)

**Status: Fixed in 1.0.1.**

GDM could hang on first boot if the display driver hadn't finished initializing. Fixed by adding a 3s delay in the GDM service override.

---

## Core profile crash

**Status: Fixed in 1.0.1.**

The core profile installer crashed with an unbound `_user_home` variable when `profiles.sh` was sourced. Fixed by guarding the variable.

---

## Arch Linux + archzfs

**Status: Known limitation.**

When the upstream archzfs repo hasn't caught up to the latest Arch kernel, `kupgrade` will hold the kernel back to prevent breaking ZFS. This is expected behavior — `kupgrade` prints a warning when this happens.

---

## RHEL 10

RHEL 10 installs fail. The version selector offers RHEL 10, but the ISO only ships `redhat-release-9.7`. The Red Hat Developer subscription may not serve RHEL 10 content depending on account type.

**Workaround:** Use RHEL 9.

---

## RHEL password special characters

RHEL passwords with shell special characters (`{}()$!`) may fail when passed through the web UI -> answers file -> subscription-manager.

**Workaround:** Use a password without shell metacharacters, or use activation key auth.

---

## ZFS encryption

ZFS encryption (AES-256-GCM) is not fully tested. The UI toggle and `storage-zfs.sh` support it, but end-to-end testing with passphrase prompt at boot, key management, and Clevis/TPM sealing has not been validated across all distro/profile combinations.

---

## Image export (kexport)

`kexport` uses `qemu-img convert` for all formats (qcow2, raw, VHD, VMDK, OVA). End-to-end testing of exported images booting on Azure, VMware, VirtualBox, and Hyper-V is ongoing.

---

## Pool Designer

The Pool Designer is experimental. It visualizes ZFS topologies and generates `zpool create` commands, but does not drive the actual install. The installer uses its own layout. Use the Core profile's manual storage mode (shell escape) for custom pool layouts.

---

## ISO size

The ISO is ~3.7 GB due to embedded RPM + APT + pacman darksites. This is intentional — offline installs require all packages baked in. Installed system size: ~1.5 GB (desktop), ~800 MB (server).

---

## Install speed

Debian, Ubuntu, Arch, CentOS, Fedora, and Rocky all install from local darksites on the ISO (~2-4 min). RHEL installs are slower because packages come from the Red Hat CDN over the internet.
