# Known Issues — RC-1 Beta

> kldload went from concept to working multi-distro installer in one week. This is a rapid prototype that works — but not everything has been fully validated. Expect rough edges. Report issues at [github.com/kldload/kldload/issues](https://github.com/kldload/kldload/issues).

## Minimum Requirements

| Profile | RAM | Disk | Notes |
|---------|-----|------|-------|
| **Core** | 4 GB | 20 GB | Minimal install, no desktop |
| **Server** | 4 GB | 30 GB | Headless + tools |
| **Desktop (Debian)** | 4 GB | 40 GB | GNOME + tools, fast offline install |
| **Desktop (CentOS/Rocky/RHEL)** | 8 GB | 40 GB | RPM installs need 2GB live overlay for 875+ packages |
| **Image export (kexport)** | 8 GB+ | 2× disk size | Runs after install, needs space for the output image |
| **Custom darksites / extra repos** | 8-16 GB | 60 GB+ | More packages = more RAM for RPM database + cache |

The live installer uses a tmpfs overlay in RAM for write operations. RPM-based desktop installs (CentOS, Rocky, RHEL) install 875+ packages which requires more overlay space than Debian's debootstrap approach. If you get "No space left on device" during install, increase VM RAM.

---

## Tested On

| Target | Desktop | Server | Core | Notes |
|--------|---------|--------|------|-------|
| CentOS Stream 9 | ✓ | ✓ | ✓ | Offline darksite, fastest RPM path |
| Debian 13 (Trixie) | ✓ | ✓ | ✓ | Offline darksite, fastest overall (~2 min) |
| Ubuntu 24.04 (Noble) | ✓ | ✓ | ✓ | Offline darksite, debootstrap |
| Fedora 41 | ✓ | ✓ | ✓ | Offline darksite, DNF bootstrap |
| Rocky Linux 9 | ✓ | ✓ | ✓ | Same RPM darksite as CentOS |
| RHEL 9 | ✓ | ✓ | ✓ | Requires internet + Red Hat account |
| Arch Linux | ✓ | ✓ | ✓ | Offline darksite, pacstrap bootstrap |
| RHEL 10 | ✗ | ✗ | ✗ | Subscription content not available |
| CentOS 10 | ? | ? | ? | Untested — repos exist |
| Rocky 10 | ? | ? | ? | Untested — repos exist |

**Tested platforms:**
- KVM/libvirt (Fedora host, UEFI, no Secure Boot)
- Proxmox VE (q35, OVMF, TPM 2.0)
- Bare metal USB boot (x86_64)

---

## Secure Boot

**KVM VMs fail to boot with Secure Boot enabled.** The ZFS DKMS module on the live ISO is not signed with an enrolled MOK key. `modprobe zfs` fails and the installer crashes.

**Workaround:** Disable Secure Boot in the VM firmware settings, or use `--boot uefi,firmware.feature0.enabled=no,firmware.feature0.name=secure-boot` with virt-install. Bare metal with Secure Boot disabled works fine.

**Fix planned:** Auto-generate and enroll MOK key during ISO build, sign the ZFS module.

---

## RHEL 10

**RHEL 10 installs fail.** The version selector offers RHEL 10, but the ISO only ships `redhat-release-9.7`. The Red Hat Developer subscription may not serve RHEL 10 content depending on account type.

**Workaround:** Use RHEL 9. CentOS 10 Stream may work (untested — repos exist).

**Fix planned:** Bake `redhat-release-10` RPM into the ISO, test RHEL 10 CDN access.

---

## RHEL password special characters

**RHEL passwords with shell special characters may fail** when passed through the web UI → answers file → subscription-manager. Characters like `}`, `{`, `)`, `(` can break shell quoting.

**Workaround:** Use a password without shell metacharacters, or use activation key auth instead.

---

## CentOS 10 / Rocky 10

**Version 10 for CentOS and Rocky is untested.** The version selector offers it and the repo URLs are correct, but no install has been validated. Packages come from the internet (no darksite for v10).

---

## ISO size

**The ISO is ~3.7 GB** due to the embedded RPM + APT darksites. This is intentional — offline installs require all packages baked in. The installed system is ~1.5 GB (desktop) or ~800 MB (server).

---

## ZFS encryption

**ZFS encryption (AES-256-GCM) is not fully tested.** The UI toggle exists and the `storage-zfs.sh` code supports it, but end-to-end testing with passphrase prompt at boot, key management, and Clevis/TPM sealing has not been validated across all distros and profiles.

---

## Image export (kexport)

**`kexport` has not been fully validated.** The tool exists and uses `qemu-img convert` for all formats (qcow2, raw, VHD, VMDK, OVA), but end-to-end testing of exported images booting on target hypervisors (Azure, VMware, VirtualBox, Hyper-V) is ongoing.

---

## Pool Designer

**The Pool Designer is experimental.** It visualizes ZFS topologies and generates `zpool create` commands, but it does not yet drive the actual install. The installer uses its own hardcoded layout. The Core profile's manual storage mode (shell escape) is the current way to use custom pool layouts.

---

## Cross-distro verification

**Full verification of all OS + profile + version combinations is ongoing.** The tested matrix above reflects confirmed working installs. Untested combinations may have package name differences, missing dependencies, or repo configuration issues. Report issues at [github.com/kldload/kldload/issues](https://github.com/kldload/kldload/issues).

---

## Debian install speed vs CentOS/RHEL

**Debian and Ubuntu installs are significantly faster** (~2 minutes) because all packages come from the local APT darksite on the ISO. CentOS, Fedora, and Rocky installs from the local RPM darksite are also fast. Arch installs from the local pacman darksite are similarly quick. RHEL installs are slower because packages come from the Red Hat CDN over the internet.
