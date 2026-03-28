# Changelog

All notable changes to kldload are documented here.

---

## [1.0.1] — 2026-03-27

### Added
- **Fedora 41** — new distro target. DNF bootstrap, same path as CentOS. RPM darksite.
- **Arch Linux** — new distro target. pacstrap bootstrap via pacman-static binary. pacman darksite with archzfs repo.
- **Golden image export with SCP** — export images and SCP them directly to a remote host (key or password auth). Images sealed for cloning: machine-id cleared, SSH host keys removed, cloud-init enabled with multi-datasource config.
- **Hardware/firmware packages** — linux-firmware, nvme-cli, pciutils, usbutils, smartmontools on all targets. linux-modules-extra-generic on Ubuntu. Debian firmware packages (firmware-linux-nonfree, firmware-iwlwifi, firmware-realtek).
- **Distro wallpapers** — dconf sets the distro's default wallpaper on desktop installs (Ubuntu, Debian, CentOS, Fedora).
- **pacman support in kpkg** — `kpkg install/remove/upgrade` now works across apt, dnf, and pacman with ZFS snapshot before each operation.
- **Fedora darksite builder** — `./deploy.sh build-fedora-darksite` (port 3145).
- **Arch darksite builder** — `./deploy.sh build-arch-darksite` (port 3144).
- **pacman-static** — embedded in live ISO for Arch bootstrap from CentOS live environment.

### Fixed
- **Ubuntu darksite not built** — `cmd_build` now auto-builds Ubuntu darksite alongside Debian. Previously required manual `build-ubuntu-darksite`.
- **Firefox/snapd on Ubuntu** — replaced with epiphany-browser. Ubuntu's firefox package is a snapd transitional shim.
- **Xorg missing on desktop** — added xserver-xorg to desktop profile package list. GDM black screen on VMs resolved.
- **Wayland on VMs** — Wayland remains default; Xorg installed as automatic fallback. Removed forced Wayland disable.
- **websockets module** — CentOS 9 RPM lacks `websockets.http11`. Restored pip install with better error handling.
- **Core profile dotfiles** — .bashrc/.tmux.conf/.vimrc no longer copied on core profile. Stock distro only.
- **GDM config path** — Ubuntu/Debian use `/etc/gdm3/`, Fedora/Arch/CentOS use `/etc/gdm/`.
- **Loop device support** — ZFS partition prefix handles `/dev/loopN` devices.
- **kexport file input** — accepts raw files alongside block devices for OVA size detection.
- **network-manager postinst** — added `file` package to Ubuntu base (required by NM postinst script).

### Changed
- **Messaging** — "base image factory" positioning. Executive summary rewritten with 4-step how-to-use guide.
- **7 distros** — all docs, README, website updated.
- **Removed "100% bash"** — replaced with "fully auditable" across all docs and website.
- **Canonical ZFS warning** — added to executive summary (Ubuntu 26.10 dropping ZFS from signed GRUB).

---

## [1.0] — 2026-03-26

### Released
- kldloadOS 1.0 "Du-Nn" — 5 distros (CentOS, Debian, Ubuntu, Rocky, RHEL), ZFS on root, offline install.
- Image export to qcow2, VMDK, VHD, OVA, raw.
- WireGuard, eBPF, NVIDIA support.
- 30+ CLI tools, web UI installer, ZFSBootMenu.

---

## [RC-2] — 2026-03-23

### Fixed
- **RPM darksite offline installs** — CentOS/Rocky now use `file:///root/darksite/rpm/` as a local repo. Previously pulled all packages from internet mirrors even though the darksite was baked into the ISO.
- **Profile-aware DNF package list** — desktop profile installs GNOME/GDM/Firefox/pipewire on CentOS/Rocky/RHEL. Server profile installs tcpdump/socat/sysstat. Core profile gets minimal packages only. Previously all RPM installs got the same base package set regardless of profile.
- **Missing packages on RPM targets** — sanoid, wireguard-tools, htop, ethtool, guest agents, pv, lzop, mbuffer now installed on CentOS/Rocky/RHEL server+desktop profiles.
- **Backend tool symlinks** — `kbe`, `kupgrade`, `krecovery` now correctly symlinked with short names. Previously symlinked as `kldload-be`, `kldload-recovery`, `kldload-upgrade` which didn't match what users and docs expected.
- **kexport missing** — `kexport` tool now copied to the installed system. Previously only existed on the live ISO.
- **vim colorscheme** — `.vim/colors/kldload.vim` now baked into the ISO and copied to installed systems. Previously `.vimrc` referenced `colorscheme kldload` but the color file was never included, causing vim errors on startup.
- **RHEL bootstrap** — fixed `cp: same file` error when copying CA certs. Suppressed with `2>/dev/null || true`.
- **RHEL subscription-manager** — register from live environment instead of chroot to avoid CentOS/RHEL package version conflicts. Disable sub-man dnf plugin to prevent conflicting `redhat.repo`.
- **RHEL entitlement certs** — copy to both host and installroot paths (dnf resolves SSL from host, not installroot). Use `find` instead of glob to match cert filenames.

### Added
- **Smoke test framework** — automated post-install verification for all 3 profiles × 7 distros. Tests ZFS pool health, dataset hierarchy, boot environments, SSH, networking, k* tools, webui, sanoid, WireGuard, eBPF, NVIDIA, kpkg snapshot integration, GNOME desktop, and more.
- **Integration test** — WireGuard tunnel + ZFS replication between two nodes. Proves full stack end-to-end.
- **Fleet test runner** — `run-fleet.sh` SSHs into multiple VMs and runs smoke tests remotely.
- **Core profile** — new install profile. Just ZFS on root, stock distro, no kldload tools. Manual storage mode drops to shell for custom pool layout.
- **Version selector** — web UI supports CentOS/RHEL/Rocky version 9 or 10.
- **RHEL username/password auth** — alternative to activation keys. Use your Red Hat portal login directly.
- **Appliance recipes** — IoT Gateway (BACnet/Modbus → WireGuard → RabbitMQ), IRLP Ham Radio (SvxLink voice bridging), Live TV Streaming (SRT/HLS/DASH/IPTV), Plex on ZFS (per-movie datasets).
- **The Bridge** — BSD/Linux crossover document. What kldloadOS changes, what it makes obsolete, Linux vs BSD comparison.
- **Systems Operators page** — copy-paste command reference for all kldloadOS operations.
- **22 tutorial docs** — ZFS zero-to-hero, WireGuard masterclass, networking, Docker on ZFS, Kubernetes on KVM, Proxmox, Cloud+Packer, observability (beginner/intermediate/advanced), and more.
- **Starter tools** — community tools from unixbox-net/linux-tools included in `tools/` directory.

### Changed
- **Website refactored** — split from 16K-line monolith into 80 separate HTML files with proper URLs, sidebar accordion, mobile hamburger menu.
- **Hero tagline** — "Choose your distro. Root it in ZFS. Ship it anywhere."
- **Documentation reorganized** — `docs/` split into `overview/`, `tutorials/`, `reference/` subdirectories.
- **rebuild-all.sh** — simplified to single ISO build, includes website deploy step.
- **EDITION variable** — configurable (`free` default, `core` available but not a separate ISO).

---

## [RC-1] — 2026-03-22

### Initial release
- Single bootable ISO installs CentOS Stream 9, Debian 13 (Trixie), Ubuntu 24.04, Fedora 41, RHEL 9, Rocky Linux 9, or Arch Linux with ZFS on root.
- Three profiles: Desktop (GNOME), Server (headless), Core (ZFS only).
- Dual offline darksites: RPM (~900 packages) + APT (~2,700 packages) baked into ISO.
- ZFS on root with ZFSBootMenu, boot environments, automatic snapshots via sanoid.
- 30+ CLI tools: kst, ksnap, kbe, kclone, kdf, kdir, kpkg, kupgrade, kexport, krecovery.
- Web UI installer on port 8080 with distro selection, profile selection, disk management.
- WireGuard pre-installed with kernel module.
- eBPF tools (bpftrace, bpfcc-tools, bpftool, linux-perf) on Debian.
- NVIDIA driver support via install checkbox.
- Export to qcow2, raw, VHD, VMDK, OVA via kexport with SCP to remote hosts and golden image sealing (cloud-init).
- Pool Designer in web UI for visual ZFS topology calculation.
- BSD-3-Clause license. Free forever.
