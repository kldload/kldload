# Changelog

All notable changes to kldload are documented here.

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
- **Smoke test framework** — automated post-install verification for all 3 profiles × 4 distros. Tests ZFS pool health, dataset hierarchy, boot environments, SSH, networking, k* tools, webui, sanoid, WireGuard, eBPF, NVIDIA, kpkg snapshot integration, GNOME desktop, and more.
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
- Single bootable ISO installs CentOS Stream 9, Debian 13 (Trixie), Rocky Linux 9, or RHEL 9 with ZFS on root.
- Three profiles: Desktop (GNOME), Server (headless), Core (ZFS only).
- Dual offline darksites: RPM (~900 packages) + APT (~2,700 packages) baked into ISO.
- ZFS on root with ZFSBootMenu, boot environments, automatic snapshots via sanoid.
- 30+ CLI tools: kst, ksnap, kbe, kclone, kdf, kdir, kpkg, kupgrade, kexport, krecovery.
- Web UI installer on port 8080 with distro selection, profile selection, disk management.
- WireGuard pre-installed with kernel module.
- eBPF tools (bpftrace, bpfcc-tools, bpftool, linux-perf) on Debian.
- NVIDIA driver support via install checkbox.
- Export to qcow2, raw, VHD, VMDK, OVA via kexport.
- Pool Designer in web UI for visual ZFS topology calculation.
- BSD-3-Clause license. Free forever.
