#!/usr/bin/env bash
# =============================================================================
# profiles.sh — profile-aware package lists and system file provisioning
# =============================================================================
#
# Part of the kldload installer pipeline. Sourced by kldload-install-target
# (via bootstrap.sh) AFTER the target root filesystem has been bootstrapped
# by debootstrap, dnf --installroot, or pacstrap.
#
# Three entry points:
#   k_profile_packages          — returns the base package list for a profile
#   k_profile_optional_packages — returns packages gated by checkboxes (eBPF,
#                                 ZFS, KVM, K8s) and auto-detected hypervisor
#   k_install_system_files      — copies kldload tools, configs, systemd units,
#                                 darksites, and desktop branding into the target
#
# The live environment is always CentOS Stream 9 — the TARGET distro is set
# by $KLDLOAD_DISTRO (debian, ubuntu, arch, alpine, centos, rocky, rhel, fedora).
# Package names differ between distros, so each function has distro-specific
# branches (e.g., "openssh-server" on Debian vs. "openssh" on Arch).
#
# Profiles:
#   desktop — GNOME + full kldload tooling
#   server  — headless SSH + full kldload tooling
#   core    — ZFS on root only, no kldload tools / webui / sanoid / darksites
#   kvm     — libvirt hypervisor + ZFS storage + K8s tools
#   ai      — Ollama + Open WebUI + modern CLI
#   master, storage, vdi, proxmox, monitoring — specialized appliance profiles
# =============================================================================
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# k_profile_packages — emit the space-separated list of packages for the
# selected profile and distro. Called by the bootstrap module to feed into
# apt-get install, dnf install, or pacman -S. Each profile is a curated
# bundle — dependencies resolve automatically via the package manager.
k_profile_packages() {
  local profile="${KLDLOAD_PROFILE:-server}"
  local _distro="${KLDLOAD_DISTRO:-debian}"

  # fastfetch is not in Ubuntu noble repos (it landed in oracular) — skip it
  # for Ubuntu installs. Fedora, Arch, and CentOS EPEL all ship it.
  local _fastfetch="fastfetch"
  [[ "$_distro" == "ubuntu" ]] && _fastfetch=""

  # Alpine Linux — core profile only (Alpine is a musl-based distro that lacks
  # the glibc ecosystem needed by GNOME, sanoid, k* tools, etc.)
  if [[ "$_distro" == "alpine" ]]; then
    case "$profile" in
      core)
        echo "openssh sudo curl ca-certificates vim less iproute2 nftables wireguard-tools"
        ;;
      *)
        k_die "Alpine only supports 'core' profile (got: $profile)"
        ;;
    esac
    return
  fi

  # Arch Linux uses different package names (e.g., "openssh" not "openssh-server",
  # "python" not "python3", no "-find" suffix on fd, etc.). Arch also lacks
  # sanoid in its repos — it gets installed from GitHub by k_install_system_files.
  if [[ "$_distro" == "arch" ]]; then
    case "$profile" in
      server)
        echo "openssh sudo curl ca-certificates vim less chrony wireguard-tools iproute2 tmux python python-websockets python-yaml htop btop net-tools ethtool nftables tcpdump fzf bat eza fd ripgrep zoxide podman fastfetch"
        ;;
      client)
        echo "openssh sudo curl ca-certificates vim less networkmanager wireguard-tools iproute2"
        ;;
      desktop)
        echo "openssh sudo curl ca-certificates vim less networkmanager \
          gnome-shell gnome-session gnome-control-center gnome-settings-daemon \
          gdm nautilus gnome-terminal eog \
          adwaita-icon-theme cantarell-fonts gvfs gvfs-mtp gvfs-smb \
          gnome-keyring \
          firefox \
          tmux python python-websockets python-yaml htop btop net-tools wireguard-tools iproute2 fzf bat eza fd ripgrep zoxide podman fastfetch"
        ;;
      core)
        echo "openssh sudo curl ca-certificates vim less iproute2 chrony nftables wireguard-tools"
        ;;
      ai)
        echo "openssh sudo curl ca-certificates vim less iproute2 chrony nftables \
          wireguard-tools tmux python python-pip jq htop btop fzf bat eza fd ripgrep zoxide podman fastfetch \
          zstd cloud-init qemu-guest-agent \
          python-websockets python-yaml net-tools ethtool tcpdump \
          pipewire cmake gcc make git"
        ;;
      *)
        k_die "unsupported profile: $profile"
        ;;
    esac
    return
  fi

  # ── Debian / Ubuntu / RPM distro package lists ─────────────────────────────
  # These use Debian-style package names (openssh-server, fd-find, etc.)
  # which also work on RPM distros via the darksite package sets.
  case "$profile" in
    server)
      echo "openssh-server sudo curl ca-certificates vim less systemd-resolved chrony wireguard-tools iproute2 tmux eject sanoid python3 python3-websockets python3-yaml htop btop net-tools ethtool nftables tcpdump fzf bat eza fd-find ripgrep zoxide podman pciutils ${_fastfetch}"
      ;;
    client)
      echo "openssh-server sudo curl ca-certificates vim less network-manager wireguard-tools iproute2"
      ;;
    desktop)
      # Desktop package names diverge sharply between Debian/Ubuntu
      # and RPM distros. The previous single package list used Debian
      # names (`network-manager`, `gdm3`, `fonts-cantarell`) which
      # silently no-op'd on Fedora/Rocky/CentOS/RHEL — installs
      # "succeeded" with no NetworkManager, no display manager,
      # dropping Fedora users into a wifi-less terminal on first boot.
      local _browser="firefox-esr"
      local _viewer="loupe"
      local _terminal="gnome-terminal"
      local _nm="network-manager"
      # Debian/Ubuntu desktop profile uses LightDM, NOT gdm3. GDM 48 on
      # Debian Trixie has a systemd-integration bug where it can't pass
      # the session type to gnome-session — gnome-session-binary errors:
      #   "Unit name gnome-session-(null)@gnome.target is not valid"
      # — and GDM aborts with "GdmSession: no session desktop files
      # installed". Reproduces consistently even with all PAM modules
      # (libpam-gnome-keyring, libpam-systemd) and xdg portals
      # (xdg-desktop-portal-gnome) installed. The user-shell GNOME
      # session itself works fine — just GDM 48's per-session systemd
      # unit naming is broken on Trixie. LightDM bypasses that path
      # entirely (no systemd-managed session unit), launches gnome-
      # session via Xsession scripts, lands in a working GNOME desktop.
      # Lose the GDM greeter chrome, gain a working desktop.
      local _gdm="lightdm"
      local _fonts="fonts-cantarell"
      local _gvfs_extra="gvfs-backends"
      local _xsrv="xserver-xorg"
      local _netools_extra="iputils-ping"
      # gnome-session-xsession is a separate sub-package on EL9 that
      # ships /usr/share/xsessions/gnome.desktop. Without it, GDM 40
      # crashes on NVIDIA hardware. Empty for distros where gnome-session
      # already includes the X session entries (Debian/Ubuntu/Arch).
      local _xsession_pkg=""
      if [[ "$_distro" == "ubuntu" ]]; then
        _browser="epiphany-browser"
        _viewer="eog"
        # Ubuntu 24.04 LTS ships GDM 46, not affected by the GDM 48
        # systemd-integration bug we hit on Debian Trixie. Keep gdm3
        # there. (Switch to lightdm if/when Ubuntu lands GDM 48 with
        # the same bug.)
        _gdm="gdm3"
      elif [[ "$_distro" == "centos" || "$_distro" == "rocky" || "$_distro" == "rhel" || "$_distro" == "fedora" ]]; then
        # RPM branch — match package naming on those ecosystems.
        # Note: on RHEL 10+ and Fedora 41+, Red Hat dropped gnome-terminal
        # and eog from AppStream in favor of modern GNOME 47 replacements
        # (ptyxis + loupe). dnf without --skip-broken errors out if the
        # package list contains a name that's not in any enabled repo.
        # Ship BOTH the legacy and the modern names so dnf installs
        # whichever is available — gnome-terminal/eog on older releases,
        # ptyxis/loupe on RHEL 10 / Fedora 41+. Caught 2026-05-14 on .143
        # RHEL 10 desktop install: gnome-terminal silently dropped,
        # operator booted into a desktop with no terminal app.
        _browser="firefox"
        _viewer="eog loupe"
        _terminal="gnome-terminal ptyxis"
        _nm="NetworkManager NetworkManager-wifi NetworkManager-tui"
        # GDM works on RPM distros once the right session-files package
        # is present. The bug seen on Rocky 9 desktop install 2026-05-04:
        #   "Gdm: GdmSession: no session desktop files installed, aborting"
        # core-dumped 8x then gave up. Root cause was a missing sub-package:
        #   gnome-session ships at minimum, but on EL9 the X session entry
        #   files (/usr/share/xsessions/*.desktop) live in a SEPARATE
        #   sub-package: `gnome-session-xsession`. Without it, that dir
        #   is empty. NVIDIA proprietary blocks Wayland → GDM falls back
        #   to xsessions → empty → SIGTRAP loop.
        # Validated fix on .109 (2026-05-04): `dnf install -y
        # gnome-session-xsession` populates /usr/share/xsessions with
        # gnome.desktop + gnome-xorg.desktop + gnome-custom-session.desktop;
        # `systemctl restart gdm` → active, GNOME login works.
        # We also tried switching RHEL/Rocky to lightdm but Rocky's stock
        # repo ships lightdm in EPEL only (not in our darksite), so dnf
        # quietly fell back to gdm without lightdm. Sticking with gdm +
        # the missing sub-package is simpler and avoids EPEL.
        _gdm="gdm"
        _fonts="cantarell-fonts"
        _gvfs_extra="gvfs-mtp gvfs-smb gvfs-archive"
        _xsrv="xorg-x11-server-Xorg xorg-x11-xauth"
        _netools_extra="iputils"
        _xsession_pkg="gnome-session-xsession"
      fi
      # Debian/Ubuntu split PAM modules into separate libpam-* packages
      # (libpam-gnome-keyring provides /usr/lib/.../security/pam_gnome_keyring.so;
      # libpam-systemd is required by user session activation; etc.).
      # gnome-keyring without libpam-gnome-keyring = GDM autologin PAM
      # warns "PAM unable to dlopen(pam_gnome_keyring.so)" then GDM
      # session worker aborts. RPM bundles these into the parent package.
      # xdg-desktop-portal-gnome is the Wayland portal backend gnome-session
      # needs to launch the user shell — without it Debian Trixie GDM 48
      # fails session enumeration.
      local _pam_extras=""
      local _portal_extras="xdg-desktop-portal xdg-desktop-portal-gnome xdg-desktop-portal-gtk"
      local _dbus_extras=""
      if [[ "$_distro" == "debian" || "$_distro" == "ubuntu" ]]; then
        # libpam-gnome-keyring + libpam-systemd: split-out PAM modules.
        # dbus-x11: provides /usr/bin/dbus-launch which gnome-session
        # invokes when not under systemd-managed user login. Without
        # it the user gets bounced back to the lightdm greeter on
        # login (gnome-session-binary errors "Failed to execute child
        # process dbus-launch").
        _pam_extras="libpam-gnome-keyring libpam-systemd"
        _dbus_extras="dbus-x11"
      fi
      echo "openssh-server sudo curl ca-certificates vim less ${_nm} \
        gnome-shell gnome-session ${_xsession_pkg} gnome-control-center gnome-settings-daemon \
        ${_gdm} nautilus ${_terminal} ${_viewer} \
        adwaita-icon-theme ${_fonts} gvfs ${_gvfs_extra} \
        gnome-keyring ${_pam_extras} ${_portal_extras} ${_dbus_extras} \
        ${_xsrv} ${_netools_extra} \
        ${_browser} \
        tmux eject sanoid python3 python3-websockets python3-yaml htop btop net-tools wireguard-tools iproute2 fzf bat eza fd-find ripgrep zoxide podman pciutils ${_fastfetch}"
      ;;

    # ── kldload templates ────────────────────────────────────────────────────────

    master)
      # Control plane: Salt master + WireGuard hub + PXE + APT mirror
      echo "openssh-server sudo curl ca-certificates vim less iproute2 \
        salt-master salt-minion salt-api \
        wireguard-tools \
        dnsmasq tftp-hpa \
        nginx \
        nftables chrony \
        qemu-utils ovmf \
        htop iperf3 tcpdump ethtool nmap"
      ;;

    kvm)
      # Hypervisor: KVM + libvirt (KVM-specific qemu/libvirt added by k_profile_optional_packages per-distro)
      echo "openssh-server sudo curl ca-certificates vim less iproute2 chrony nftables \
        wireguard-tools tmux python3 python3-websockets python3-yaml htop btop net-tools ethtool tcpdump \
        fzf bat eza fd-find ripgrep zoxide podman sanoid qemu-utils pciutils ${_fastfetch}"
      ;;

    storage)
      # ZFS storage server: NFS + iSCSI exports, managed by Salt minion
      # ZFS datasets are the core — nfs-kernel-server + targetcli serve them
      echo "openssh-server sudo curl ca-certificates vim less iproute2 \
        nfs-kernel-server nfs-common \
        tgt \
        samba \
        prometheus-node-exporter \
        nftables chrony \
        salt-minion wireguard-tools"
      ;;

    vdi)
      # Virtual desktop delivery: Wayland + FFmpeg/SRT + mediamtx (binary via hook)
      echo "openssh-server sudo curl ca-certificates vim less iproute2 \
        mutter gnome-session gdm3 \
        ffmpeg libsrt1.5 \
        pipewire wireplumber \
        wf-recorder \
        xdotool xclip \
        python3-websockets \
        evemu-tools \
        nginx \
        nftables chrony \
        salt-minion wireguard-tools"
      ;;

    proxmox)
      # Proxmox VE hypervisor node — installs base system; Proxmox repo + packages added by firstboot
      echo "openssh-server sudo curl ca-certificates vim less iproute2 \
        nftables chrony \
        bridge-utils \
        wireguard-tools"
      ;;

    monitoring)
      # Monitoring stack: Prometheus + Grafana + Alertmanager + node exporter
      echo "openssh-server sudo curl ca-certificates vim less iproute2 \
        prometheus prometheus-node-exporter prometheus-alertmanager \
        grafana \
        nftables chrony \
        wireguard-tools"
      ;;

    core)
      # Bare minimum — ZFS on root, SSH, networking, WireGuard. No kldload tools, no sanoid, no webui.
      echo "openssh-server sudo curl ca-certificates vim less iproute2 chrony nftables wireguard-tools"
      ;;

    ai)
      # AI learning tool — core + WireGuard + Python + tmux + modern CLI. Ollama on firstboot.
      echo "openssh-server sudo curl ca-certificates vim less iproute2 chrony nftables \
        wireguard-tools tmux python3 python3-pip jq htop btop fzf bat eza fd-find ripgrep zoxide ${_fastfetch} \
        sanoid cloud-init qemu-guest-agent qemu-utils eject zstd \
        python3-websockets python3-yaml net-tools ethtool tcpdump \
        alsa-utils pipewire pipewire-utils cmake gcc-c++ make git podman"
      ;;

    *)
      k_die "unsupported profile: $profile"
      ;;
  esac
}

# k_profile_optional_packages — emit additional packages gated by web UI
# checkboxes (eBPF, ZFS, KVM, K8s) and auto-detected hypervisor guest tools.
# These are appended to k_profile_packages output before the install command.
# Package names differ across distros because upstream projects ship under
# different names (e.g., bpfcc-tools on Debian/Ubuntu vs. bpftool on RHEL).
k_profile_optional_packages() {
  local out=()
  local _distro="${KLDLOAD_DISTRO:-debian}"
  local _profile="${KLDLOAD_PROFILE:-server}"
  if [[ "${KLDLOAD_ENABLE_EBPF:-0}" == "1" ]]; then
    if [[ "$_distro" == "arch" ]]; then
      out+=(bcc bcc-tools bpftrace perf)
    elif [[ "$_distro" == "ubuntu" ]]; then
      out+=(bpfcc-tools bpftrace linux-tools-common linux-tools-generic)
    else
      out+=(bpftool bpfcc-tools bpftrace linux-perf)
    fi
  fi
  if [[ "${KLDLOAD_ENABLE_ZFS:-0}" == "1" ]]; then
    if [[ "$_distro" == "alpine" ]]; then
      out+=(zfs zfs-lts zfs-libs zfs-openrc)
    elif [[ "$_distro" == "arch" ]]; then
      out+=(zfs-dkms zfs-utils)
    else
      out+=(zfsutils-linux zfs-zed zfs-initramfs zfs-dkms sanoid)
    fi
  fi

  # KVM Host (profile or optional checkbox)
  # Package names diverge significantly across distros for libvirt/QEMU:
  #   Arch:         monolithic "qemu-full" + "libvirt" meta-packages
  #   Debian/Ubuntu: split packages (libvirt-daemon-system, virtinst, ovmf)
  #   RPM (CentOS/Rocky/RHEL/Fedora): further split — individual driver packages
  #     must be listed explicitly because the meta-packages don't exist
  if [[ "$_profile" == "kvm" ]] || [[ "${KLDLOAD_ENABLE_KVM:-0}" == "1" ]]; then
    if [[ "$_distro" == "arch" ]]; then
      out+=(qemu-full libvirt virt-install bridge-utils edk2-ovmf dnsmasq sshpass)
    elif [[ "$_distro" == "ubuntu" || "$_distro" == "debian" ]]; then
      out+=(qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst bridge-utils ovmf dnsmasq-base sshpass)
    else
      out+=(qemu-kvm libvirt-daemon libvirt-daemon-driver-qemu libvirt-daemon-driver-storage libvirt-daemon-config-network libvirt-client virt-install bridge-utils edk2-ovmf dnsmasq sshpass)
    fi
  fi

  # Kubernetes (optional checkbox)
  # Debian/Ubuntu use "containerd" from distro repos; RPM distros use
  # "containerd.io" from the Docker CE repo (different binary package name).
  # Arch and FreeBSD are excluded — K8s support not implemented for them yet.
  if [[ "${KLDLOAD_ENABLE_K8S:-0}" == "1" ]]; then
    if [[ "$_distro" == "ubuntu" || "$_distro" == "debian" ]]; then
      out+=(containerd conntrack socat ipset ipvsadm nftables)
    elif [[ "$_distro" != "arch" && "$_distro" != "freebsd" ]]; then
      out+=(containerd.io conntrack-tools socat ipvsadm)
    fi
  fi

  # Auto-detect hypervisor and add guest tools so the installed system
  # cooperates with the host (graceful shutdown, time sync, etc.)
  local virt
  virt="$(systemd-detect-virt 2>/dev/null || true)"
  case "${virt}" in
    vmware)   out+=(open-vm-tools) ;;
    kvm|qemu) out+=(qemu-guest-agent) ;;
    xen)      out+=(xe-guest-utilities) ;;
  esac

  printf '%s ' "${out[@]:-}"
}

# k_install_system_files — copy kldload system files from the live environment
# into the freshly bootstrapped target. These files live in the live ISO chroot
# but debootstrap creates a clean slate, so they must be copied explicitly.
k_install_system_files() {
  local target="${KLDLOAD_TARGET:?}"
  local root_ds
  root_ds="rpool/ROOT/${KLDLOAD_HOSTNAME:-kldload}"

  local _profile="${KLDLOAD_PROFILE:-server}"
  k_log "Installing system files into target (profile=${_profile})"

  # Fix sudo secure_path so k* tools in /usr/local/bin work with sudo
  mkdir -p "${target}/etc/sudoers.d"
  echo 'Defaults    secure_path = /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    > "${target}/etc/sudoers.d/kldload-path"
  chmod 440 "${target}/etc/sudoers.d/kldload-path"

  # Ghostty terminfo — applies to every profile, including core. Upstream ncurses
  # has not yet picked up xterm-ghostty, and no distro we target ships it in
  # their base ncurses-term, so SSH-in from Ghostty lands on a broken TERM.
  # The two files are 4KB combined and purely additive (no-op for non-Ghostty).
  for _ti in x/xterm-ghostty g/ghostty; do
    if [[ -f "/usr/share/terminfo/${_ti}" ]]; then
      install -Dm 0644 "/usr/share/terminfo/${_ti}" "${target}/usr/share/terminfo/${_ti}"
    fi
  done

  # ── Universal install markers (every profile, including core) ─────────────
  # These three files identify the install to runtime tools and the smoke
  # test suite. They are NOT kldload-feature artifacts — they're "this box
  # came from the kldload installer, build X, edition Y, BE Z" metadata
  # that even a stock-distro core install should ship. Bug seen 2026-05-06
  # by fiend CI: smoke-core.sh fails 3 tests on every distro because the
  # markers were written further down inside the non-core branch.
  mkdir -p "${target}/etc/kldload"
  [[ -f /etc/kldload-build-sha ]] && cp /etc/kldload-build-sha "${target}/etc/kldload-build-sha"
  [[ -f /etc/kldload-build-id  ]] && cp /etc/kldload-build-id  "${target}/etc/kldload-build-id"
  [[ -f /etc/kldload/edition   ]] && cp /etc/kldload/edition   "${target}/etc/kldload/edition"
  # Propagate VERSION from the live env so installed boxes can self-report
  # which kldload ISO built them — without this the target has no record
  # of its provenance, and tools (kst-summary, attestation, support
  # bug reports) fall back to a hardcoded placeholder string.
  [[ -f /etc/kldload/VERSION   ]] && cp /etc/kldload/VERSION   "${target}/etc/kldload/VERSION"
  echo "${_profile}" > "${target}/etc/kldload/profile"
  printf '%s\n' "${root_ds}" > "${target}/etc/kldload/boot-environment"

  # ── Core profile: skip all kldload tools, sanoid, webui, snapshot hooks ────
  # Core gets ZFS on root + boot environments + stock distro. Nothing else.
  # Bug seen 2026-05-06 (caught by fiend CI): the original if/else
  # structure here protected only the immediate next stanza — the
  # kldload-webui copy + service enable + dozens of other steps farther
  # down ran for ALL profiles including core. The smoke-test correctly
  # caught a kldload-webui binary in /usr/local/bin on a core install.
  # Belt-and-suspenders: early-return for core in addition to the else.
  if [[ "$_profile" == "core" ]]; then
    k_log "Core profile — skipping kldload tools, sanoid, webui, snapshot hooks."
    return 0
  else

  # ── Sanoid snapshot automation ─────────────────────────────────────────────
  # Sanoid provides automated ZFS snapshot scheduling (hourly/daily/weekly/etc.).
  # The handling differs between APT and RPM targets because:
  #   - Debian/Ubuntu: sanoid is an apt package that installs to /usr/sbin/ with
  #     defaults.conf in /usr/share/sanoid/. We must NOT overlay it with the
  #     GitHub build from the live ISO or paths break.
  #   - RPM distros (CentOS/Rocky/RHEL/Fedora): the CentOS EPEL sanoid package
  #     is too old (missing features), so build-iso.sh installs sanoid from
  #     GitHub into /usr/local/sbin/ on the live ISO. We copy those binaries
  #     to the target and ship defaults.conf in /etc/sanoid/.
  if [[ -f /etc/sanoid/sanoid.conf ]]; then
    mkdir -p "${target}/etc/sanoid"
    cp /etc/sanoid/sanoid.conf "${target}/etc/sanoid/sanoid.conf"
  fi
  # Sanoid binaries — Debian/Ubuntu install via apt; RPM targets need live copies
  if chroot "${target}" dpkg -s sanoid >/dev/null 2>&1; then
    # apt-installed sanoid — remove any /usr/local/sbin copies that override it
    # (apt puts sanoid in /usr/sbin, defaults.conf in /usr/share/sanoid/)
    for _sb in sanoid syncoid findoid; do
      rm -f "${target}/usr/local/sbin/${_sb}" 2>/dev/null
    done
    # Ensure defaults.conf is findable — apt's sanoid looks in /usr/share/sanoid/
    # but the config parser also checks /etc/sanoid/, so symlink for compatibility
    if [[ -f "${target}/usr/share/sanoid/sanoid.defaults.conf" ]] && [[ ! -f "${target}/etc/sanoid/sanoid.defaults.conf" ]]; then
      ln -sf /usr/share/sanoid/sanoid.defaults.conf "${target}/etc/sanoid/sanoid.defaults.conf"
    fi
  else
    # RPM target — copy GitHub-built sanoid binaries from the live ISO
    for _sb in sanoid syncoid findoid; do
      # `command -v` is a bash builtin, NOT a binary in $target's PATH, so
      # `chroot $target command -v X` always returns non-zero (chroot
      # can't find a `command` executable). The `!` flips that to "true"
      # and the copy happens unconditionally — broken-but-benign on a
      # fresh install. Test for the binary on disk instead, which is
      # what we actually mean.
      if [[ -x "/usr/local/sbin/${_sb}" ]] \
         && [[ ! -x "${target}/usr/sbin/${_sb}" ]] \
         && [[ ! -x "${target}/usr/local/sbin/${_sb}" ]] \
         && [[ ! -x "${target}/usr/bin/${_sb}" ]]; then
        cp "/usr/local/sbin/${_sb}" "${target}/usr/local/sbin/${_sb}"
        chmod +x "${target}/usr/local/sbin/${_sb}"
      fi
    done
    # Copy sanoid.defaults.conf — the GitHub build requires it at runtime in
    # /etc/sanoid/ (unlike apt which ships it in /usr/share/sanoid/)
    if [[ -f /etc/sanoid/sanoid.defaults.conf ]] && [[ ! -f "${target}/etc/sanoid/sanoid.defaults.conf" ]]; then
      mkdir -p "${target}/etc/sanoid"
      cp /etc/sanoid/sanoid.defaults.conf "${target}/etc/sanoid/sanoid.defaults.conf"
    fi
  fi
  # Sanoid systemd units — copy from live if not already on target (RPM)
  for _su in sanoid.service sanoid.timer; do
    if [[ -f "/lib/systemd/system/${_su}" ]] && [[ ! -f "${target}/lib/systemd/system/${_su}" ]]; then
      mkdir -p "${target}/lib/systemd/system"
      cp "/lib/systemd/system/${_su}" "${target}/lib/systemd/system/${_su}"
    fi
  done

  # ── APT pre/post snapshot hooks ────────────────────────────────────────────
  if [[ -d /etc/apt/apt.conf.d ]]; then
    mkdir -p "${target}/etc/apt/apt.conf.d"
    for f in /etc/apt/apt.conf.d/00-kldload-snapshot-*; do
      [[ -f "$f" ]] && cp "$f" "${target}/etc/apt/apt.conf.d/"
    done
  fi

  # ── Snapshot management scripts ────────────────────────────────────────────
  mkdir -p "${target}/usr/local/sbin"
  for f in /usr/local/sbin/snapshot-*.sh; do
    [[ -f "$f" ]] && cp "$f" "${target}/usr/local/sbin/" && chmod +x "${target}/usr/local/sbin/$(basename "$f")"
  done

  # ── Systemd units ──────────────────────────────────────────────────────────
  mkdir -p "${target}/usr/lib/systemd/system"
  for f in kldload-srv-snapshot.service kldload-srv-snapshot.timer kldload-firstboot.service kldload-webui.service kldload-proxy.service kldload-export.service kldload-autodeploy.service ttyd-k9s.service kldload-tls-cert.service kldload-tls-cert.timer kldload-journal-flush.service klab-prom-targets.service klab-prom-targets.timer kldload-headlamp.service kldload-session@.service; do
    [[ -f "/usr/lib/systemd/system/${f}" ]] && \
      cp "/usr/lib/systemd/system/${f}" "${target}/usr/lib/systemd/system/${f}"
  done
  # Ensure the proxy BINARY is present on target. Its systemd unit above
  # is useless without the script. build-iso.sh copies to the live ISO's
  # /usr/local/sbin but the target-side installer path doesn't always
  # mirror that — explicit copy here plugs the gap (same pattern used for
  # kldload-autodeploy just below).
  if [[ -f /usr/local/sbin/kldload-proxy ]]; then
    mkdir -p "${target}/usr/local/sbin"
    cp /usr/local/sbin/kldload-proxy "${target}/usr/local/sbin/kldload-proxy"
    chmod +x "${target}/usr/local/sbin/kldload-proxy"
  fi
  # Ship orchestrator + console scripts alongside the units. Ensure
  # /usr/sbin exists on the bootstrap — a minimal dnf install may not
  # create it before this function runs, and a silent cp failure here
  # was the 1.0.4 regression where kldload-autodeploy.service had a
  # symlink in multi-user.target.wants but no binary behind it.
  mkdir -p "${target}/usr/sbin"
  for bin in kldload-autodeploy; do
    if [[ -f "/usr/sbin/${bin}" ]]; then
      cp "/usr/sbin/${bin}" "${target}/usr/sbin/${bin}" && \
        chmod +x "${target}/usr/sbin/${bin}" && \
        k_log "installed /usr/sbin/${bin}"
    else
      k_log "WARNING: /usr/sbin/${bin} missing in live root — autodeploy will not run"
    fi
  done
  # Explicit bin copies — tools whose names don't match the `k*` wholesale
  # glob below. `lh` (LogHog, C binary compiled at build time) is the one
  # that slips through the glob. Without this, `kldload-lh` calls lh and
  # gets "command not found" on the installed target.
  # kldload-mgmt: the operator-catalog wrapper that the F1 popup invokes.
  # Without this on the installed target the F1 popup runs `kldload-mgmt`
  # which returns rc=127 (command not found); the popup briefly flashes
  # then exits, looking like "the popup is hidden" because nothing
  # renders. Caught 2026-05-14 on .111 after the help-popup refactor.
  for bin in kldload-console kldload-mgmt ttyd k9s lh; do
    [[ -f "/usr/local/bin/${bin}" ]] && \
      cp "/usr/local/bin/${bin}" "${target}/usr/local/bin/${bin}" && \
      chmod +x "${target}/usr/local/bin/${bin}"
  done
  # sbin-level CLI tools:
  #   kspawn            — ZFS-native cluster spawner
  #   kldload-tls-cert  — self-signed TLS cert script for webui HTTPS
  mkdir -p "${target}/usr/local/sbin"
  for bin in kspawn kldload-ca kldload-tls-cert kldload-wait-for-ip kldload-bounce-tls-services kldload-session kldload-headlamp-install kldload-secure-boot kldload-debug-bundle; do
    [[ -f "/usr/local/sbin/${bin}" ]] && \
      cp "/usr/local/sbin/${bin}" "${target}/usr/local/sbin/${bin}" && \
      chmod +x "${target}/usr/local/sbin/${bin}" && \
      k_log "installed /usr/local/sbin/${bin}"
  done
  # /usr/libexec/ — argv-safe helper for kldload-session@.service.
  # Missing this on target = nginx drop-in writes OK but systemd unit
  # fails on ExecStart (no wrapper to invoke).
  mkdir -p "${target}/usr/libexec"
  shopt -s nullglob
  for lx in /usr/libexec/kldload-*; do
    [[ -f "$lx" ]] || continue
    cp "$lx" "${target}/usr/libexec/$(basename "$lx")"
    chmod +x "${target}/usr/libexec/$(basename "$lx")"
    k_log "installed /usr/libexec/$(basename "$lx")"
  done
  shopt -u nullglob

  # Bob configs (personas.json + Modelfile.bob + Modelfile.bash). Without
  # these on target, firstboot's `ollama create bob` fails with "no
  # Modelfile found" and Bob never appears in the sidebar (the frontend
  # keys off having a "bob" model in ollama's list).
  if [[ -d /etc/bob ]]; then
    mkdir -p "${target}/etc/bob"
    cp -r /etc/bob/. "${target}/etc/bob/"
    k_log "Bob configs copied to target ($(ls "${target}/etc/bob" | tr '\n' ' '))"
  fi

  # Bob's knowledge corpus (scraped kldload.com docs + OCR'd PDF manual,
  # ~3.3 MB). Consumed by the docs_search WS tool — without this on
  # target, every kldload-specific Bob answer is pure confabulation
  # since the base model has zero kldload training.
  if [[ -d /usr/local/share/kldload-ai ]]; then
    mkdir -p "${target}/usr/local/share/kldload-ai"
    cp /usr/local/share/kldload-ai/*.txt "${target}/usr/local/share/kldload-ai/" 2>/dev/null || true
    k_log "Bob docs corpus copied to target ($(du -sh "${target}/usr/local/share/kldload-ai" 2>/dev/null | cut -f1))"
  fi
  # webui service already ships with --port 8443 baked into its unit file
  # (see builder/build-iso.sh). No post-install sed needed — removed the
  # empty if/fi block that used to flip the port, which was an install-
  # time syntax error ("bash: line 428: syntax error near unexpected token `fi`").

  # Enable services in the installed system via symlinks — we can't run
  # "systemctl enable" because systemd is not running inside the chroot.
  # Creating the symlinks manually achieves the same effect.
  mkdir -p "${target}/etc/systemd/system/timers.target.wants"
  ln -sf "/usr/lib/systemd/system/kldload-srv-snapshot.timer" \
    "${target}/etc/systemd/system/timers.target.wants/kldload-srv-snapshot.timer" || true
  # Sanoid scheduled snapshots (daily/weekly/monthly/yearly)
  ln -sf "/lib/systemd/system/sanoid.timer" \
    "${target}/etc/systemd/system/timers.target.wants/sanoid.timer" || true
  # Prometheus file_sd target regeneration (every 30s, zero hardcoded IPs)
  ln -sf "/usr/lib/systemd/system/klab-prom-targets.timer" \
    "${target}/etc/systemd/system/timers.target.wants/klab-prom-targets.timer" || true

  mkdir -p "${target}/etc/systemd/system/multi-user.target.wants"
  ln -sf "/usr/lib/systemd/system/kldload-firstboot.service" \
    "${target}/etc/systemd/system/multi-user.target.wants/kldload-firstboot.service" || true
  # kldload-webui enabled at boot (firstboot also starts it, but enable here for robustness)
  ln -sf "/usr/lib/systemd/system/kldload-webui.service" \
    "${target}/etc/systemd/system/multi-user.target.wants/kldload-webui.service" || true
  # ── 1.0.6 TLS-terminator: nginx ─────────────────────────────────────
  # nginx replaces the Python kldload-proxy as the :8443 listener.
  # HTTP/2 + graceful SIGHUP reload + drop-in dir pattern. The old
  # kldload-proxy unit is NOT symlinked into multi-user.target.wants —
  # nginx owns :8443 now. The unit file is kept on-disk for one release
  # as a rollback path: `systemctl enable kldload-proxy && systemctl
  # disable nginx` reverts cleanly.
  #
  # nginx config tree (/etc/nginx/conf.d/kldload.conf + helpers) was
  # copied into the live ISO rootfs via build-iso.sh; mirror it to the
  # target here so the installed system has the same config.
  if [[ -d /etc/nginx ]]; then
    mkdir -p "${target}/etc/nginx"
    # Preserve anything the target's nginx RPM/DEB shipped that our
    # includes.chroot tree doesn't touch (e.g. mime.types, modules-*).
    cp -r /etc/nginx/conf.d  "${target}/etc/nginx/" 2>/dev/null || true
    cp -r /etc/nginx/kldload "${target}/etc/nginx/" 2>/dev/null || true
    cp /etc/nginx/nginx.conf "${target}/etc/nginx/nginx.conf" 2>/dev/null || true
    mkdir -p "${target}/etc/nginx/conf.d/kldload-dyn"
    # Nginx system user differs by distro: RHEL/Fedora ship `nginx`,
    # Debian/Ubuntu ship `www-data`. Our shipped nginx.conf uses
    # `user nginx;` which works on RPM but on Debian fails with
    # `getpwnam("nginx") failed`, nginx -t errors, service crash-loops.
    # Patch the user line to match the target's package.
    case "${KLDLOAD_DISTRO:-centos}" in
      debian|ubuntu)
        sed -i 's|^[[:space:]]*user[[:space:]]\+nginx;|user www-data;|' \
          "${target}/etc/nginx/nginx.conf" 2>/dev/null || true
        ;;
    esac
    k_log "nginx config tree copied to target"
  fi
  # systemd drop-in for nginx.service (ExecStartPre kldload-tls-cert).
  mkdir -p "${target}/etc/systemd/system/nginx.service.d"
  if [[ -d /etc/systemd/system/nginx.service.d ]]; then
    cp /etc/systemd/system/nginx.service.d/*.conf \
       "${target}/etc/systemd/system/nginx.service.d/" 2>/dev/null || true
  fi
  # Session metadata dir (kldload-session writes here).
  mkdir -p "${target}/var/lib/kldload/sessions"
  # Enable nginx at boot.
  ln -sf "/usr/lib/systemd/system/nginx.service" \
    "${target}/etc/systemd/system/multi-user.target.wants/nginx.service" || true
  # kldload-proxy kept on disk for rollback, but NOT enabled AND MASKED
  # so systemd won't auto-restart-loop it against nginx (it'll keep
  # failing with port-in-use since nginx already owns :8443). Masking
  # is a hard-disable: systemd refuses to start it even on explicit
  # `systemctl start kldload-proxy` until an admin `systemctl unmask`s
  # it. Rollback path: `systemctl unmask kldload-proxy; systemctl
  # disable nginx; systemctl start kldload-proxy`.
  rm -f "${target}/etc/systemd/system/multi-user.target.wants/kldload-proxy.service" 2>/dev/null || true
  mkdir -p "${target}/etc/systemd/system"
  ln -sf /dev/null "${target}/etc/systemd/system/kldload-proxy.service" 2>/dev/null || true
  # Autodeploy orchestrator — runs once after firstboot, invokes AI pull
  # + K8s bootstrap + klab goldens in dependency order, writes phase-ready
  # markers the UI reads to turn the Lab Ready banner green.
  ln -sf "/usr/lib/systemd/system/kldload-autodeploy.service" \
    "${target}/etc/systemd/system/multi-user.target.wants/kldload-autodeploy.service" || true
  # ttyd — browser terminal (k9s + shell + logs inside a tmux session),
  # iframe'd from the Kubernetes tab. Enable at boot so the console panel
  # works as soon as the webui is reachable.
  [[ -f "${target}/usr/lib/systemd/system/ttyd-k9s.service" ]] && \
    ln -sf "/usr/lib/systemd/system/ttyd-k9s.service" \
      "${target}/etc/systemd/system/multi-user.target.wants/ttyd-k9s.service" || true

  # ── Fix websockets version (CentOS 9 RPM is too old for websockets.http11) ──
  # The kldload-webui Python server requires websockets.http11 (v11+ API).
  # The CentOS 9 python3-websockets RPM ships v10 which lacks that module.
  # pip-install a newer version to overwrite the system package on RPM targets.
  # (Debian/Ubuntu ship a compatible version, but this is harmless there.)
  chroot "${target}" pip3 install --quiet "websockets>=11" 2>/dev/null || true

  # ── Web UI binary + static files ──────────────────────────────────────────
  [[ -x /usr/local/bin/kldload-webui ]] && \
    cp /usr/local/bin/kldload-webui "${target}/usr/local/bin/kldload-webui" && \
    chmod +x "${target}/usr/local/bin/kldload-webui"
  # The service WorkingDirectory is /usr/local/share/kldload-webui — copy static files
  if [[ -d /usr/local/share/kldload-webui/active ]]; then
    mkdir -p "${target}/usr/local/share/kldload-webui"
    cp -r /usr/local/share/kldload-webui/active/. "${target}/usr/local/share/kldload-webui/"
  fi

  # ── Firefox autostart to dashboard — LAB profiles only ────────────────────
  # Workstation users (desktop profile) and headless (server) installs
  # should NOT have Firefox auto-open to the kldload dashboard on every
  # login — that's a daily driver, the user's homepage is theirs. Only
  # lab-focused profiles (kvm / ai / zfslab), where the user explicitly
  # booted kldload FOR the UI, get the auto-open.
  case "${KLDLOAD_PROFILE:-server}" in
    kvm|ai|zfslab)
      mkdir -p "${target}/etc/xdg/autostart"
      cat > "${target}/etc/xdg/autostart/kldload-dashboard.desktop" <<'DASHSTART'
[Desktop Entry]
Type=Application
Name=kldload Dashboard
Comment=Auto-open the kldload ops console at login (lab profile)
Exec=bash -c 'for i in $(seq 1 60); do (echo >/dev/tcp/localhost/8443) 2>/dev/null && break; sleep 1; done; sleep 3; firefox --no-remote https://localhost:8443'
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=8
DASHSTART
      ;;
  esac

  # Firefox policies — ALL GUI profiles get the bookmarks (discovery) and
  # first-run-junk suppression. Only lab profiles get Homepage set, so
  # workstation users land on their default new-tab page at launch.
  if [[ "${KLDLOAD_PROFILE:-server}" != "core" && "${KLDLOAD_PROFILE:-server}" != "server" ]]; then
    mkdir -p "${target}/usr/lib64/firefox/distribution"
    case "${KLDLOAD_PROFILE:-server}" in
      kvm|ai|zfslab)
        # Lab profile — autoload webui as homepage too
        cat > "${target}/usr/lib64/firefox/distribution/policies.json" <<'FFPOLICY_LAB'
{
  "policies": {
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "DontCheckDefaultBrowser": true,
    "NoDefaultBookmarks": true,
    "DisplayBookmarksToolbar": "always",
    "Homepage": {
      "URL": "https://localhost:8443",
      "StartPage": "homepage"
    },
    "Bookmarks": [
      {"Title": "kldload Web UI", "URL": "https://localhost:8443", "Placement": "toolbar"},
      {"Title": "kldload Docs",   "URL": "https://kldload.com",    "Placement": "toolbar"}
    ],
    "UserMessaging": {
      "WhatsNewMessaging": false,
      "ExtensionRecommendations": false,
      "SkipOnboarding": true
    }
  }
}
FFPOLICY_LAB
        ;;
      desktop)
        # Workstation profile — NO Homepage override. Still show the
        # bookmark on the toolbar so one click reaches the Web UI.
        cat > "${target}/usr/lib64/firefox/distribution/policies.json" <<'FFPOLICY_WS'
{
  "policies": {
    "DontCheckDefaultBrowser": true,
    "DisplayBookmarksToolbar": "always",
    "Bookmarks": [
      {"Title": "kldload Web UI", "URL": "https://localhost:8443", "Placement": "toolbar"},
      {"Title": "kldload Docs",   "URL": "https://kldload.com",    "Placement": "toolbar"}
    ],
    "UserMessaging": {
      "WhatsNewMessaging": false,
      "ExtensionRecommendations": false,
      "SkipOnboarding": true
    }
  }
}
FFPOLICY_WS
        ;;
    esac
  fi

  # Desktop shortcut in the apps menu — every non-core GUI profile gets this
  # so users can always find the webui even when it's not their homepage.
  # Ships in the live ISO at /usr/share/applications/kldload-webui.desktop;
  # copy it to the target.
  if [[ "${KLDLOAD_PROFILE:-server}" != "core" ]]; then
    if [[ -f /usr/share/applications/kldload-webui.desktop ]]; then
      mkdir -p "${target}/usr/share/applications"
      install -m 0644 /usr/share/applications/kldload-webui.desktop \
        "${target}/usr/share/applications/kldload-webui.desktop"
    fi
  fi

  # ── Service auto-start gate ────────────────────────────────────────────────
  # Lab profiles (kvm / ai / zfslab) auto-start the webui + proxy + ttyd
  # so the operator lands on the UI at first boot. Workstation / server /
  # core profiles: services are installed and working but NOT enabled at
  # boot — the user's daily-driver shouldn't spend RAM/CPU on an ops UI
  # they may never open. To turn it on:
  #     sudo systemctl enable --now kldload-proxy kldload-webui ttyd-k9s
  # The desktop shortcut + the "kldload Web UI" bookmark point at
  # https://localhost:8443/ so the discovery path is intact.
  case "${KLDLOAD_PROFILE:-server}" in
    kvm|ai|zfslab)
      : # keep defaults — enabled in the unit's [Install] WantedBy
      ;;
    *)
      # desktop / server / core — disable on target, keep installed.
      chroot "${target}" systemctl disable kldload-webui.service 2>/dev/null || true
      chroot "${target}" systemctl disable kldload-proxy.service 2>/dev/null || true
      chroot "${target}" systemctl disable ttyd-k9s.service 2>/dev/null || true
      ;;
  esac

  fi # end non-core block

  # ── Build markers ──────────────────────────────────────────────────────
  # Copy the ISO's build SHA and build ID to the installed target so that
  # "kst" and the management webui can display which ISO build was used.
  # These are generated by build-iso.sh from the git commit hash and count.
  [[ -f /etc/kldload-build-sha ]] && cp /etc/kldload-build-sha "${target}/etc/kldload-build-sha"
  [[ -f /etc/kldload-build-id ]]  && cp /etc/kldload-build-id  "${target}/etc/kldload-build-id"

  # ── Virtio / VMware kernel modules ──────────────────────────────────────
  if [[ -f /etc/modules-load.d/virtio.conf ]]; then
    mkdir -p "${target}/etc/modules-load.d"
    cp /etc/modules-load.d/virtio.conf "${target}/etc/modules-load.d/virtio.conf"
  fi

  # ── Edition + profile markers ──────────────────────────────────────────────
  # Written to /etc/kldload/ so runtime tools (kst, kbe, webui) can detect
  # which edition (free/core) and profile (desktop/server/kvm/...) was installed.
  # This drives conditional behavior like showing KVM tools only on kvm profile.
  mkdir -p "${target}/etc/kldload"
  [[ -f /etc/kldload/edition ]] && cp /etc/kldload/edition "${target}/etc/kldload/edition"
  echo "${_profile}" > "${target}/etc/kldload/profile"

  # ── User tools: ZFS helpers + adduser.local hook (skip for core) ─────────────
  mkdir -p "${target}/usr/local/bin" "${target}/usr/local/sbin"
  if [[ "$_profile" != "core" ]]; then
    # eza not in EPEL — copy from live if target doesn't have it.
    # See sanoid loop above for why we test paths instead of `chroot
    # ... command -v` (the latter doesn't work; `command` is a bash
    # builtin, not in PATH).
    if [[ -x /usr/local/bin/eza ]] \
       && [[ ! -x "${target}/usr/bin/eza" ]] \
       && [[ ! -x "${target}/usr/local/bin/eza" ]]; then
      cp /usr/local/bin/eza "${target}/usr/local/bin/eza"
      chmod +x "${target}/usr/local/bin/eza"
    fi
    # Wholesale copy of kldload CLI tools — everything matching k* or _k*
    # in /usr/local/bin. The `_` prefix tools (_ktoggle-win, _kconsole-home)
    # are helpers called from kldload-console's tmux keybindings; missing
    # them makes every F-key return 127. Skip installer-only internals.
    _skip_tools="kldload-install-target kldload-overview"
    shopt -s nullglob
    for _src in /usr/local/bin/k* /usr/local/bin/_k* /usr/local/bin/bob /usr/local/bin/bob-*; do
      [[ -x "$_src" ]] || continue
      _name="$(basename "$_src")"
      case " $_skip_tools kldload-webui " in *" $_name "*) continue ;; esac
      cp "$_src" "${target}/usr/local/bin/${_name}"
      chmod +x "${target}/usr/local/bin/${_name}"
    done
    shopt -u nullglob

    # ── Install ansible-core NOW, at install time, not first boot. ──
    # Autodeploy + kube-cluster + klab all call ansible-playbook for
    # provisioning. If it's missing when autodeploy fires, the first-boot
    # orchestration dies. We install eagerly here so it's baked in.
    # Works offline via the darksite repo — the package is listed in
    # target-base.txt for every supported distro.
    case "${KLDLOAD_DISTRO:-centos}" in
      centos|rocky|rhel|fedora)
        chroot "${target}" dnf install -y ansible-core >/dev/null 2>&1 \
          || k_log "WARNING: ansible-core install failed — autodeploy may retry at first boot"
        ;;
      debian|ubuntu)
        chroot "${target}" apt-get install -y ansible-core >/dev/null 2>&1 \
          || k_log "WARNING: ansible-core install failed — autodeploy may retry at first boot"
        ;;
    esac
    # Verify — if this fails the install is broken and should not claim
    # success. Test paths directly (see eza/sanoid blocks above for why
    # `chroot ... command -v` doesn't work).
    if [[ -x "${target}/usr/bin/ansible-playbook" ]] \
       || [[ -x "${target}/usr/local/bin/ansible-playbook" ]]; then
      k_log "ansible-playbook present on target: $(chroot "${target}" /usr/bin/ansible --version 2>&1 | head -1)"
    else
      k_log "WARNING: ansible-playbook MISSING on target — autodeploy will try to self-install at first boot"
    fi

    # Ship the Ansible playbook library — provision-golden, seal-golden,
    # node-prep, kube-join, smoke-test, asahi-convert plus ansible.cfg and
    # the default inventory. Required by kube-cluster and the Ansible tab.
    # Silent copy failures here were the root cause of kube-cluster
    # dying with "playbook not found" on fresh 1.0.4 installs.
    mkdir -p "${target}/usr/local/share/kldload-ansible"
    if [[ -d /usr/local/share/kldload-ansible ]]; then
      cp -r /usr/local/share/kldload-ansible/. "${target}/usr/local/share/kldload-ansible/" \
        && k_log "installed kldload-ansible ($(find /usr/local/share/kldload-ansible/playbooks -name '*.yml' 2>/dev/null | wc -l) playbooks)"
    else
      k_log "WARNING: /usr/local/share/kldload-ansible missing in live root — kube-cluster + Ansible tab will fail"
    fi
    [[ -f /usr/local/sbin/adduser.local ]] && \
      cp /usr/local/sbin/adduser.local "${target}/usr/local/sbin/adduser.local" && \
      chmod +x "${target}/usr/local/sbin/adduser.local"

    # Copy smoke tests to installed system
    if [[ -d /usr/local/share/kldload/tests ]]; then
      mkdir -p "${target}/usr/local/share/kldload/tests"
      cp /usr/local/share/kldload/tests/*.sh "${target}/usr/local/share/kldload/tests/" 2>/dev/null || true
      chmod +x "${target}/usr/local/share/kldload/tests/"*.sh 2>/dev/null || true
      # Convenience symlink: kldload-test runs the full report
      ln -sf /usr/local/share/kldload/tests/smoke-all.sh "${target}/usr/local/bin/kldload-test" 2>/dev/null || true
    fi
  fi

  # ── OS branding ───────────────────────────────────────────────────────────────
  # Write os-release for the TARGET distro, not the live ISO (which is always CentOS)
  local _target_distro="${KLDLOAD_DISTRO:-centos}"
  local _target_suite=""
  case "$_target_distro" in
    centos)  _target_suite="stream9" ;;
    rocky)   _target_suite="9" ;;
    rhel)    _target_suite="10" ;;
    fedora)  _target_suite="${KLDLOAD_FEDORA_RELEASE:-44}" ;;
    debian)  _target_suite="${KLDLOAD_SUITE:-trixie}" ;;
    ubuntu)  _target_suite="${KLDLOAD_SUITE:-noble}" ;;
    arch)    _target_suite="rolling" ;;
  esac
  cat > "${target}/etc/os-release" <<OSREL
PRETTY_NAME="kldload (${_target_distro} ${_target_suite})"
NAME="kldload"
ID=${_target_distro}
VERSION="${_target_suite}"
OSREL

  # ── GNOME dconf system settings (dock, theme, terminal defaults) ──────────────
  mkdir -p "${target}/etc/dconf/db/local.d" "${target}/etc/dconf/profile"
  for _f in 00-kldload-desktop 01-kldload-terminal-default; do
    [[ -f "/etc/dconf/db/local.d/${_f}" ]] && \
      cp "/etc/dconf/db/local.d/${_f}" "${target}/etc/dconf/db/local.d/${_f}"
  done
  [[ -f /etc/dconf/profile/user ]] && cp /etc/dconf/profile/user "${target}/etc/dconf/profile/user"

  # ── GDM login screen (dconf db + profile + config) ────────────────────────────
  if [[ -d /etc/dconf/db/gdm.d ]]; then
    mkdir -p "${target}/etc/dconf/db/gdm.d"
    cp /etc/dconf/db/gdm.d/00-kldload-login "${target}/etc/dconf/db/gdm.d/00-kldload-login" 2>/dev/null || true
    [[ -f /etc/dconf/profile/gdm ]] && cp /etc/dconf/profile/gdm "${target}/etc/dconf/profile/gdm"
  fi
  # GDM config — auto-login for desktop profile so firstboot show plays automatically
  # Debian/Ubuntu use /etc/gdm3/, Arch/CentOS use /etc/gdm/
  local _gdm_dir="gdm3"
  if [[ "${KLDLOAD_DISTRO:-centos}" == "arch" || "${KLDLOAD_DISTRO:-centos}" == "centos" || "${KLDLOAD_DISTRO:-centos}" == "rocky" || "${KLDLOAD_DISTRO:-centos}" == "rhel" || "${KLDLOAD_DISTRO:-centos}" == "fedora" ]]; then
    _gdm_dir="gdm"
  fi
  local _install_user="${KLDLOAD_USERNAME:-admin}"
  mkdir -p "${target}/etc/${_gdm_dir}"
  # CentOS/RHEL/Fedora use custom.conf, Debian/Ubuntu use daemon.conf — write both
  for _gdm_conf in custom.conf daemon.conf; do
  cat > "${target}/etc/${_gdm_dir}/${_gdm_conf}" <<EOGDM
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=${_install_user}

[security]

[xdmcp]

[chooser]

[debug]
EOGDM
  done

  # Wayland is the default — xserver-xorg is installed as fallback so GDM
  # can fall back to X11 if Wayland fails (older virtual GPUs, etc.)

  # ── Disable screen blanking / power saving (desktop profiles) ────────────────
  mkdir -p "${target}/etc/dconf/db/local.d"
  cat > "${target}/etc/dconf/db/local.d/00-kldload-power" <<'DCONF'
[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'

[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false
DCONF
  mkdir -p "${target}/etc/dconf/profile"
  echo -e "user-db:user\nsystem-db:local" > "${target}/etc/dconf/profile/user"
  chroot "${target}" dconf update 2>/dev/null || true

  # ── Custom .desktop launchers ───────────────────────────────────────────────
  mkdir -p "${target}/usr/share/applications"
  for _dt in vim.desktop kst.desktop kst-dashboard.desktop ksnap.desktop kexport.desktop kldload-terminal.desktop kldload-docs.desktop; do
    [[ -f "/usr/share/applications/${_dt}" ]] && \
      cp "/usr/share/applications/${_dt}" "${target}/usr/share/applications/${_dt}"
  done

  # ── Wallpaper — set the distro's default background ───────────────────────
  if [[ -d /usr/share/backgrounds/kldload ]]; then
    mkdir -p "${target}/usr/share/backgrounds/kldload"
    cp -r /usr/share/backgrounds/kldload/. "${target}/usr/share/backgrounds/kldload/"
  fi
  local _wp=""
  case "${KLDLOAD_DISTRO:-centos}" in
    ubuntu)  _wp="/usr/share/backgrounds/warty-final-ubuntu.png" ;;
    debian)  _wp="/usr/share/desktop-base/active-theme/wallpaper/contents/images/1920x1080.svg" ;;
    centos|rocky|rhel|fedora) _wp="/usr/share/backgrounds/default.png" ;;
  esac
  if [[ -n "$_wp" ]]; then
    mkdir -p "${target}/etc/dconf/db/local.d"
    cat > "${target}/etc/dconf/db/local.d/01-kldload-wallpaper" <<WPEOF
[org/gnome/desktop/background]
picture-uri='file://${_wp}'
picture-uri-dark='file://${_wp}'
picture-options='zoom'
WPEOF
    chroot "${target}" dconf update 2>/dev/null || true
  fi

  # ── Shell dotfiles (.bashrc, .tmux.conf, .vimrc) — non-core profiles only
  # Core profile gets the stock distro dotfiles untouched.
  if [[ "$_profile" != "core" ]]; then
    local _user="${KLDLOAD_USERNAME:-admin}"
    local _user_home="${target}/home/${_user}"
    for _f in .bashrc .tmux.conf .vimrc; do
      [[ -f "/etc/skel/${_f}" ]] || continue
      cp "/etc/skel/${_f}" "${target}/etc/skel/${_f}"
      cp "/etc/skel/${_f}" "${target}/root/${_f}"
      [[ -d "$_user_home" ]] && cp "/etc/skel/${_f}" "${_user_home}/${_f}"
    done
    # vim colorscheme
    if [[ -d /etc/skel/.vim ]]; then
      cp -r /etc/skel/.vim "${target}/etc/skel/.vim"
      cp -r /etc/skel/.vim "${target}/root/.vim"
      [[ -d "$_user_home" ]] && cp -r /etc/skel/.vim "${_user_home}/.vim"
    fi
  fi
  # Fix ownership of admin home dotfiles
  if [[ -n "${_user_home:-}" && -d "${_user_home}" ]]; then
    local _uid _gid
    _uid="$(chroot "${target}" id -u "${_user}" 2>/dev/null || echo '')"
    _gid="$(chroot "${target}" id -g "${_user}" 2>/dev/null || echo '')"
    [[ -n "$_uid" && -n "$_gid" ]] && \
      chown -R "${_uid}:${_gid}" "${_user_home}/" 2>/dev/null || true
  fi

  # ── Performance tuning (sysctl, ZFS ARC, I/O scheduler) ─────────────────────
  [[ -f /etc/sysctl.d/99-kldload.conf ]] && \
    { mkdir -p "${target}/etc/sysctl.d"; cp /etc/sysctl.d/99-kldload.conf "${target}/etc/sysctl.d/99-kldload.conf"; }
  [[ -f /etc/modprobe.d/zfs.conf ]] && \
    { mkdir -p "${target}/etc/modprobe.d"; cp /etc/modprobe.d/zfs.conf "${target}/etc/modprobe.d/zfs.conf"; }
  [[ -f /etc/udev/rules.d/60-kldload-scheduler.rules ]] && \
    { mkdir -p "${target}/etc/udev/rules.d"; cp /etc/udev/rules.d/60-kldload-scheduler.rules "${target}/etc/udev/rules.d/60-kldload-scheduler.rules"; }

  # ── Backend runtime tools (kbe, krecovery, kupgrade) — skip for core ──────────
  if [[ "$_profile" != "core" && -d /usr/lib/kldload-installer/backend ]]; then
    mkdir -p "${target}/usr/lib/kldload-installer/backend/bin"
    cp -r /usr/lib/kldload-installer/backend/. "${target}/usr/lib/kldload-installer/backend/"
    chmod +x "${target}/usr/lib/kldload-installer/backend/bin/"* 2>/dev/null || true
    # Expose backend tools in PATH with short names
    mkdir -p "${target}/usr/local/bin"
    for _bt in kbe krecovery kupgrade; do
      [[ -f "${target}/usr/lib/kldload-installer/backend/bin/${_bt}" ]] && \
        ln -sf "/usr/lib/kldload-installer/backend/bin/${_bt}" "${target}/usr/local/bin/${_bt}"
    done
    # kexport lives in the main tools directory
    [[ -x "/usr/local/bin/kexport" ]] && \
      cp "/usr/local/bin/kexport" "${target}/usr/local/bin/kexport" && \
      chmod +x "${target}/usr/local/bin/kexport"
  fi

  # ── Boot environment marker — tells kldload-be which dataset is active ─────────
  mkdir -p "${target}/etc/kldload"
  printf '%s\n' "${root_ds}" > "${target}/etc/kldload/boot-environment"

  # ── Darksite — copy ONLY the matching distro's darksite to target ──────────
  # Core profile and RHEL skip darksites (RHEL uses Red Hat CDN)
  local _distro="${KLDLOAD_DISTRO:-centos}"
  if [[ "$_profile" != "core" && "$_distro" != "rhel" ]]; then
    local darksite_tgt="${target}/root/darksite"
    mkdir -p "$darksite_tgt"

    case "$_distro" in
      debian|ubuntu)
        # Copy only the APT darksite
        if [[ -d /root/darksite/debian ]]; then
          rsync -a --exclude='*.lock' /root/darksite/debian/ "${darksite_tgt}/debian/"
          k_log "Debian APT darksite installed to target"
        fi
        ;;
      centos|rocky)
        # Copy only the RPM darksite
        if [[ -d /root/darksite/rpm ]]; then
          rsync -a --exclude='*.lock' /root/darksite/rpm/ "${darksite_tgt}/rpm/"
          k_log "RPM darksite installed to target"
        fi
        ;;
      fedora)
        # Copy only the Fedora RPM darksite
        if [[ -d /root/darksite/fedora/rpm ]]; then
          mkdir -p "${darksite_tgt}/fedora"
          rsync -a --exclude='*.lock' /root/darksite/fedora/ "${darksite_tgt}/fedora/"
          k_log "Fedora RPM darksite installed to target"
        fi
        ;;
      arch)
        # Copy only the pacman darksite
        if [[ -d /root/darksite/arch ]]; then
          rsync -a --exclude='*.lock' /root/darksite/arch/ "${darksite_tgt}/arch/"
          k_log "Arch pacman darksite installed to target"
        fi
        ;;
      *)
        k_log "No darksite for distro: ${_distro}"
        ;;
    esac

    # Copy support scripts if present
    for f in kldload-syscheck.sh audit.sh; do
      [[ -f "/root/darksite/${f}" ]] && cp "/root/darksite/${f}" "${darksite_tgt}/${f}" && chmod +x "${darksite_tgt}/${f}"
    done

    # Ollama model darksite — distro-independent. kldload-firstboot
    # rsyncs from here to /srv/ollama/models so Bob is chat-ready
    # without an internet roundtrip. Missing this copy was the reason
    # Bob fell back to online pulls on installed systems even though
    # the ISO had the weights baked in.
    if [[ -d /root/darksite/ollama/models ]]; then
      mkdir -p "${darksite_tgt}/ollama"
      rsync -a --exclude='*.lock' /root/darksite/ollama/ "${darksite_tgt}/ollama/"
      k_log "Ollama darksite installed to target: $(du -sh "${darksite_tgt}/ollama" 2>/dev/null | cut -f1)"
    fi
  else
    k_log "Skipping darksite copy (profile=${_profile}, distro=${_distro})"
  fi

  # ── Kernel module pinning (Debian: APT conf, CentOS: dnf versionlock) ────────
  local tgt_files="/usr/lib/kldload-installer/target-files"
  local _distro="${KLDLOAD_DISTRO:-debian}"
  if [[ -d "${tgt_files}" && ( "$_distro" == "debian" || "$_distro" == "ubuntu" ) ]]; then
    mkdir -p "${target}/etc/apt/apt.conf.d"
    cp "${tgt_files}/etc/apt/apt.conf.d/60-kldload-kernel" \
       "${target}/etc/apt/apt.conf.d/60-kldload-kernel" 2>/dev/null || true
    mkdir -p "${target}/etc/kernel/postinst.d"
    cp "${tgt_files}/etc/kernel/postinst.d/kldload-dkms-verify" \
       "${target}/etc/kernel/postinst.d/kldload-dkms-verify" 2>/dev/null || true
    chmod +x "${target}/etc/kernel/postinst.d/kldload-dkms-verify" 2>/dev/null || true
  fi

  # ── APT mirror service on the installed target (skip for core) ────────────────
  if [[ "$_profile" != "core" ]]; then
    local mirror_svc="/usr/lib/systemd/system/kldload-apt-mirror.service"
    if [[ -f "$mirror_svc" ]]; then
      cp "$mirror_svc" "${target}/usr/lib/systemd/system/kldload-apt-mirror.service"
      mkdir -p "${target}/etc/systemd/system/multi-user.target.wants"
      ln -sf "/usr/lib/systemd/system/kldload-apt-mirror.service" \
        "${target}/etc/systemd/system/multi-user.target.wants/kldload-apt-mirror.service" || true
      k_log "kldload-apt-mirror.service enabled on target"
    fi
  fi

  # ── KVM Host profile: ZFS datasets, ARC tuning, sysctl, replication ────────
  if [[ "$_profile" == "kvm" ]] || [[ "${KLDLOAD_ENABLE_KVM:-0}" == "1" ]]; then
    k_log "Configuring KVM host with ZFS-optimized storage"

    # VM zvol parent — canmount=off, VMs are zvols accessed via /dev/zvol/rpool/vms/
    zfs create -o canmount=off \
               -o mountpoint=none \
               -o compression=off \
               -o primarycache=metadata \
               rpool/vms 2>/dev/null || true
    # Create the libvirt images directory for ISO storage and any qcow2 fallback
    mkdir -p "${target}/var/lib/libvirt/images" 2>/dev/null || true

    # ISO storage — compressed, read-mostly
    zfs create -o mountpoint=/var/lib/libvirt/isos \
               -o compression=zstd \
               -o atime=off \
               rpool/vms/isos 2>/dev/null || true

    # ARC tuning — cap at 50% of system RAM, leave the rest for KVM guests
    local _total_ram_bytes
    _total_ram_bytes=$(awk '/MemTotal/{print $2 * 1024}' /proc/meminfo 2>/dev/null || echo 0)
    local _arc_max=$(( _total_ram_bytes / 2 ))
    [[ "$_arc_max" -gt 0 ]] || _arc_max=8589934592  # fallback 8GB

    mkdir -p "${target}/etc/modprobe.d"
    cat > "${target}/etc/modprobe.d/zfs.conf" <<ZFSMOD
# kldload KVM host — ZFS tuning
# ARC capped at 50% of RAM to leave memory for KVM guests
options zfs zfs_arc_max=${_arc_max}
options zfs zfs_txg_timeout=10
options zfs zfs_vdev_scheduler=none
options zfs l2arc_noprefetch=0
ZFSMOD

    # Kernel VM tuning for ZFS on root + KVM
    mkdir -p "${target}/etc/sysctl.d"
    cat > "${target}/etc/sysctl.d/99-zfs-kvm.conf" <<SYSCTL
# ZFS on root + KVM host — let ARC handle caching, reduce dirty pages
vm.swappiness = 1
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
fs.inotify.max_user_watches = 524288
# Network tuning for bridge/VM traffic
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
SYSCTL

    # ZFS replication script — send VM snapshots to a remote host over WireGuard
    mkdir -p "${target}/usr/local/sbin"
    cat > "${target}/usr/local/sbin/kvm-replicate" <<'REPL'
#!/bin/bash
# kvm-replicate — incremental ZFS replication of VM zvols to a remote host
# Usage: kvm-replicate <dataset> <remote_host> [remote_dataset]
# Example: kvm-replicate rpool/vms/images/vm1 backup-host rpool/vms/replicas/vm1
set -euo pipefail

DS="${1:?Usage: kvm-replicate <dataset> <remote_host> [remote_dataset]}"
REMOTE="${2:?Usage: kvm-replicate <dataset> <remote_host> [remote_dataset]}"
REMOTE_DS="${3:-${DS}}"
SNAP="${DS}@repl-$(date -u +%Y%m%dT%H%M%SZ)"

# Create new snapshot
zfs snapshot "$SNAP"

# Find previous replication snapshot
PREV=$(zfs list -H -t snapshot -o name "$DS" 2>/dev/null | grep '@repl-' | tail -2 | head -1)

if [[ -n "$PREV" && "$PREV" != "$SNAP" ]]; then
  echo "Incremental send: $PREV → $SNAP → $REMOTE:$REMOTE_DS"
  zfs send -i "$PREV" "$SNAP" | ssh "$REMOTE" "zfs recv -F $REMOTE_DS"
  # Clean old replication snapshots (keep last 2)
  zfs list -H -t snapshot -o name "$DS" | grep '@repl-' | head -n -2 | xargs -r -n1 zfs destroy
else
  echo "Full send: $SNAP → $REMOTE:$REMOTE_DS"
  zfs send "$SNAP" | ssh "$REMOTE" "zfs recv -F $REMOTE_DS"
fi
echo "Replication complete: $SNAP"
REPL
    chmod +x "${target}/usr/local/sbin/kvm-replicate"

    # Copy KVM management tools from live ISO to target
    mkdir -p "${target}/usr/local/bin"
    for tool in kvm-create kvm-clone kvm-snap kvm-delete kvm-list kvm-demo kube-cluster kzfs-lab kzfs-test klab klab-exporter klab-prom-targets \
                zfs_exporter smartctl_exporter loki promtail ebpf_exporter zpool-scrub-exporter klab-vm-debug-bundle; do
      if [[ -f "/usr/local/bin/${tool}" ]]; then
        cp "/usr/local/bin/${tool}" "${target}/usr/local/bin/${tool}"
        chmod +x "${target}/usr/local/bin/${tool}"
      fi
    done

    # Copy klab share files (Prometheus config, Grafana dashboard)
    if [[ -d /usr/local/share/klab ]]; then
      mkdir -p "${target}/usr/local/share/klab"
      cp -r /usr/local/share/klab/* "${target}/usr/local/share/klab/"
    fi

    # ── observability-stack: configs, dashboards, enable services ─────
    # ── Observability unit + timer copy (glob-driven, not hardcoded) ─────
    # Lesson from pass-21/22: hardcoded lists of unit filenames repeatedly
    # missed new units (smartctl_exporter, ebpf_exporter, zpool-scrub-
    # exporter all skipped at least once). Now we glob the live rootfs's
    # systemd dir for observability units by naming-convention and copy
    # everything matched. Adding a new obs unit = drop a file in
    # includes.chroot/usr/lib/systemd/system/ with a matching name and
    # it's picked up automatically.
    #
    # Matched patterns:
    #   *_exporter.service / *_exporter.timer  (loki, promtail, zfs, ebpf)
    #   *-exporter.service / *-exporter.timer  (arcstats, zpool-scrub,
    #                                            smartctl, klab)
    #   loki.service, promtail.service         (named exceptions)
    mkdir -p "${target}/usr/lib/systemd/system" \
             "${target}/etc/systemd/system/multi-user.target.wants" \
             "${target}/etc/systemd/system/timers.target.wants"
    shopt -s nullglob
    for _unit_path in \
        /usr/lib/systemd/system/*_exporter.service \
        /usr/lib/systemd/system/*-exporter.service \
        /usr/lib/systemd/system/*_exporter.timer \
        /usr/lib/systemd/system/*-exporter.timer \
        /usr/lib/systemd/system/loki.service \
        /usr/lib/systemd/system/promtail.service; do
      [[ -f "$_unit_path" ]] || continue
      _u="$(basename "$_unit_path")"
      install -m 0644 "$_unit_path" "${target}/usr/lib/systemd/system/${_u}"
      # Enable: services whose companion .timer exists are driven BY the
      # timer — only enable the timer (systemd auto-pulls the .service).
      # Services without a timer get enabled directly at multi-user.
      if [[ "$_u" == *.timer ]]; then
        ln -sfn "/usr/lib/systemd/system/${_u}" \
          "${target}/etc/systemd/system/timers.target.wants/${_u}"
      elif [[ -f "/usr/lib/systemd/system/${_u%.service}.timer" ]]; then
        continue  # driven by its timer, don't enable .service directly
      else
        ln -sfn "/usr/lib/systemd/system/${_u}" \
          "${target}/etc/systemd/system/multi-user.target.wants/${_u}"
      fi
    done
    shopt -u nullglob
    # ebpf_exporter configs (biolatency, bio-trace yaml + .bpf.o)
    if [[ -d /etc/ebpf_exporter ]]; then
      mkdir -p "${target}/etc/ebpf_exporter"
      cp -r /etc/ebpf_exporter/* "${target}/etc/ebpf_exporter/" 2>/dev/null || true
    fi
    # zed → Loki event shipping script
    if [[ -f /etc/zfs/zed.d/all-loki.sh ]]; then
      mkdir -p "${target}/etc/zfs/zed.d"
      install -m 0755 /etc/zfs/zed.d/all-loki.sh \
        "${target}/etc/zfs/zed.d/all-loki.sh"
    fi
    # NetworkManager dispatcher hook for TLS cert regen on IP change
    if [[ -f /etc/NetworkManager/dispatcher.d/99-kldload-tls-cert ]]; then
      mkdir -p "${target}/etc/NetworkManager/dispatcher.d"
      install -m 0755 /etc/NetworkManager/dispatcher.d/99-kldload-tls-cert \
        "${target}/etc/NetworkManager/dispatcher.d/99-kldload-tls-cert"
    fi
    # Admin-editable TLS extra-SANs config (custom DNS names / VIPs)
    if [[ -d /etc/kldload ]]; then
      mkdir -p "${target}/etc/kldload"
      cp /etc/kldload/*.txt "${target}/etc/kldload/" 2>/dev/null || true
    fi
    # node_exporter override (disable broken zfs collector, enable textfile)
    if [[ -f /etc/systemd/system/node_exporter.service.d/textfile.conf ]]; then
      mkdir -p "${target}/etc/systemd/system/node_exporter.service.d"
      install -m 0644 /etc/systemd/system/node_exporter.service.d/textfile.conf \
        "${target}/etc/systemd/system/node_exporter.service.d/textfile.conf"
    fi
    # arcstats-exporter binary
    if [[ -x /usr/local/bin/arcstats-exporter ]]; then
      cp /usr/local/bin/arcstats-exporter "${target}/usr/local/bin/arcstats-exporter"
      chmod +x "${target}/usr/local/bin/arcstats-exporter"
    fi
    # textfile collector dir
    mkdir -p "${target}/var/lib/node_exporter/textfile_collector"
    # configs
    mkdir -p "${target}/etc/loki" "${target}/etc/promtail" \
             "${target}/etc/systemd/journald.conf.d" \
             "${target}/var/lib/loki" "${target}/var/lib/promtail" \
             "${target}/var/log/journal"
    [[ -f /etc/loki/loki.yaml ]] && \
      cp /etc/loki/loki.yaml "${target}/etc/loki/loki.yaml"
    [[ -f /etc/promtail/promtail.yaml ]] && \
      cp /etc/promtail/promtail.yaml "${target}/etc/promtail/promtail.yaml"
    [[ -f /etc/systemd/journald.conf.d/persistent.conf ]] && \
      cp /etc/systemd/journald.conf.d/persistent.conf \
         "${target}/etc/systemd/journald.conf.d/persistent.conf"
    # Grafana Loki datasource + dashboards (firstboot also copies the
    # dashboards to /var/lib/grafana/dashboards — belt + suspenders)
    if [[ -f /etc/grafana/provisioning/datasources/loki.yaml ]]; then
      mkdir -p "${target}/etc/grafana/provisioning/datasources"
      cp /etc/grafana/provisioning/datasources/loki.yaml \
         "${target}/etc/grafana/provisioning/datasources/loki.yaml"
    fi
    # Copy ALL dashboards from the live ISO — not a hardcoded list. New
    # dashboards added to live-build/config/includes.chroot/var/lib/
    # grafana/dashboards/ pick up automatically; no profile.sh edit
    # required each time. Previous hardcoded-3-entries loop was missing
    # 5 of 8 dashboards baked into pass-22.
    if [[ -d /var/lib/grafana/dashboards ]]; then
      mkdir -p "${target}/var/lib/grafana/dashboards"
      cp /var/lib/grafana/dashboards/*.json \
         "${target}/var/lib/grafana/dashboards/" 2>/dev/null || true
    fi

    # Hourly VM snapshot timer
    mkdir -p "${target}/etc/systemd/system"
    cat > "${target}/etc/systemd/system/kvm-snapshot.service" <<'SNAPSVC'
[Unit]
Description=ZFS snapshot all VM datasets
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'TS=$(date -u +%%Y%%m%%dT%%H%%M%%SZ); for ds in $(zfs list -H -o name -r rpool/vms | tail -n+2); do zfs snapshot ${ds}@auto-${TS}; done; for ds in $(zfs list -H -o name -r rpool/vms | tail -n+2); do zfs list -H -t snapshot -o name ${ds} 2>/dev/null | grep @auto- | head -n -48 | xargs -r -n1 zfs destroy; done'
SNAPSVC
    cat > "${target}/etc/systemd/system/kvm-snapshot.timer" <<'SNAPTMR'
[Unit]
Description=Hourly ZFS snapshots for VM datasets
[Timer]
OnCalendar=hourly
Persistent=true
[Install]
WantedBy=timers.target
SNAPTMR
    ln -sf /etc/systemd/system/kvm-snapshot.timer \
      "${target}/etc/systemd/system/timers.target.wants/kvm-snapshot.timer" 2>/dev/null || true

    # Add VM datasets to sanoid for snapshot management
    if [[ -f "${target}/etc/sanoid/sanoid.conf" ]]; then
      cat >> "${target}/etc/sanoid/sanoid.conf" <<'KVMSANOID'

# KVM VM datasets — hourly snapshots for VM zvols
[rpool/vms]
use_template = kvm
recursive = yes

[template_kvm]
frequently = 0
hourly     = 48
daily      = 14
weekly     = 4
monthly    = 3
yearly     = 0
autosnap   = yes
autoprune  = yes
KVMSANOID
    fi

    # Configure Podman to use ZFS storage driver
    mkdir -p "${target}/etc/containers"
    cat > "${target}/etc/containers/storage.conf" <<'STORAGE'
[storage]
driver = "zfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options.zfs]
fsname = "rpool/var/lib/containers/storage/zfs"
STORAGE

    # Create the container storage dataset
    chroot "${target}" bash -c 'zfs create -p -o mountpoint=/var/lib/containers/storage/zfs rpool/var/lib/containers/storage/zfs' 2>/dev/null || true

    # Enable libvirtd + default network (virbr0)
    chroot "${target}" systemctl enable libvirtd 2>/dev/null || true
    # virsh can't run in a chroot because there's no running libvirtd daemon to
    # connect to. We also can't just run "virsh net-autostart default" in a
    # firstboot ExecStart because libvirtd takes variable time to initialize
    # (it must register drivers and create the default network). A simple oneshot
    # After=libvirtd.service races and fails. Instead, use a systemd timer that
    # fires 30s after boot, then retry in a loop until libvirtd is actually ready.
    # The service self-disables after success so it only runs on first boot.
    cat > "${target}/etc/systemd/system/kldload-virbr0.service" <<'VIRBR0SVC'
[Unit]
Description=Enable libvirt default network (virbr0) autostart
After=libvirtd.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for i in $(seq 1 10); do virsh net-autostart default 2>/dev/null && virsh net-start default 2>/dev/null && exit 0; sleep 3; done; echo "virbr0 setup failed after 10 attempts"'
ExecStartPost=/bin/bash -c 'systemctl disable kldload-virbr0.timer 2>/dev/null; systemctl disable kldload-virbr0.service 2>/dev/null; true'
RemainAfterExit=yes
VIRBR0SVC
    cat > "${target}/etc/systemd/system/kldload-virbr0.timer" <<'VIRBR0TMR'
[Unit]
Description=Delayed virbr0 setup (30s after boot)

[Timer]
OnBootSec=30s
Unit=kldload-virbr0.service

[Install]
WantedBy=timers.target
VIRBR0TMR
    chroot "${target}" systemctl enable kldload-virbr0.timer 2>/dev/null || true

    # Ensure default libvirt network starts on boot (virbr0 — required for klab VMs)
    chroot "${target}" bash -c 'virsh net-autostart default 2>/dev/null || true' 2>/dev/null || true

    k_log "KVM host configured: ZFS datasets, ARC tuning, sysctl, replication, VM snapshots, kvm-* tools, Podman ZFS driver"
  fi

  # ── Kubernetes node setup ──────────────────────────────────────────────
  if [[ "${KLDLOAD_ENABLE_K8S:-0}" == "1" ]]; then
    k_log "Configuring Kubernetes node..."

    # Copy kube-* tools from live ISO to target
    mkdir -p "${target}/usr/local/bin"
    for tool in kube-setup kube-init kube-join kube-status kube-reset kube-network kube-load-images kube-smoke-test; do
      if [[ -f "/usr/local/bin/${tool}" ]]; then
        cp "/usr/local/bin/${tool}" "${target}/usr/local/bin/${tool}"
        chmod +x "${target}/usr/local/bin/${tool}"
      fi
    done

    # Copy kubectl helper functions
    if [[ -f "/etc/profile.d/kube-helpers.sh" ]]; then
      cp "/etc/profile.d/kube-helpers.sh" "${target}/etc/profile.d/kube-helpers.sh"
      chmod +x "${target}/etc/profile.d/kube-helpers.sh"
    fi

    # Kernel modules for K8s
    cat > "${target}/etc/modules-load.d/k8s.conf" <<'K8SMOD'
overlay
br_netfilter
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
K8SMOD

    # sysctl for K8s
    cat > "${target}/etc/sysctl.d/99-kubernetes.conf" <<'K8SSYS'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
K8SSYS

    # Disable swap (kubeadm requires it)
    sed -ri '/\sswap\s/s/^/#/' "${target}/etc/fstab" 2>/dev/null || true

    # ZFS datasets for K8s components
    local root_pool
    root_pool="${root_ds%%/*}"
    chroot "${target}" bash -c "
      zfs create -p -o mountpoint=/var/lib/etcd -o recordsize=8K -o compression=lz4 -o atime=off ${root_pool}/var/lib/etcd 2>/dev/null || true
      zfs create -p -o mountpoint=/var/lib/containerd -o compression=lz4 -o atime=off ${root_pool}/var/lib/containerd 2>/dev/null || true
      zfs create -p -o mountpoint=/var/lib/kubelet -o compression=lz4 -o atime=off ${root_pool}/var/lib/kubelet 2>/dev/null || true
    " 2>/dev/null || true

    # containerd config with SystemdCgroup
    mkdir -p "${target}/etc/containerd"
    chroot "${target}" bash -c 'containerd config default > /etc/containerd/config.toml 2>/dev/null; sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml 2>/dev/null' || true

    # crictl config
    cat > "${target}/etc/crictl.yaml" <<'CRICTLCFG'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
CRICTLCFG

    # Enable containerd and kubelet
    chroot "${target}" systemctl enable containerd 2>/dev/null || true
    chroot "${target}" systemctl enable kubelet 2>/dev/null || true

    # K8s bootstrap is manual — the user runs "kube-cluster bootstrap" after
    # first login so they can watch the full deployment live: ZFS clones,
    # WireGuard mesh, Cilium, Hubble, everything streaming to their terminal.
    # The installer lays down KVM + ZFS + all tools; the user pulls the trigger.

    # Login banner telling the user what to do
    cat > "${target}/etc/profile.d/kube-banner.sh" <<'KUBEBANNER'
if [[ $EUID -eq 0 ]] && ! [[ -f /etc/kubernetes/admin.conf ]] && command -v kube-cluster >/dev/null 2>&1; then
  echo ""
  echo -e "\033[1;36m══════════════════════════════════════════════════════════════\033[0m"
  echo -e "\033[1;37m  kldloadOS — Kubernetes Platform Ready                      \033[0m"
  echo -e "\033[1;36m══════════════════════════════════════════════════════════════\033[0m"
  echo ""
  echo -e "  KVM + ZFS + WireGuard installed. Deploy Kubernetes:"
  echo ""
  echo -e "  \033[1;32mkube-cluster bootstrap --workers 3\033[0m"
  echo ""
  echo -e "  This will: clone golden image → 4 VMs → WireGuard mesh"
  echo -e "           → Cilium eBPF → MetalLB → Hubble → kubectl on host"
  echo ""
  echo -e "\033[1;36m══════════════════════════════════════════════════════════════\033[0m"
  echo ""
fi
KUBEBANNER
    chmod +x "${target}/etc/profile.d/kube-banner.sh"

    k_log "Kubernetes node configured: containerd, kernel modules, sysctl, ZFS datasets (etcd 8K, containerd, kubelet)"
    k_log "After boot: run 'kube-cluster bootstrap --workers 3' to deploy the full stack"
  fi

  # ── DevOps Lab (profile tile) ──────────────────────────────────────────
  # DevOps Lab spawns a fleet of core VMs (one per supported distro) for OpenZFS
  # testing. Like the K8s bootstrap, this runs on first boot because it needs
  # a running libvirtd and network access to download ISOs. The build phase
  # creates golden images, then "deploy blue" instantiates the blue site VMs.
  if [[ "${KLDLOAD_ENABLE_DEVOPS:-0}" == "1" ]]; then
    k_log "Enabling klab first-boot deployment..."
    cat > "${target}/etc/systemd/system/klab-firstboot.service" <<'KLABFB'
[Unit]
Description=klab — build golden images for all distros
After=network-online.target libvirtd.service kldload-firstboot.service
Wants=network-online.target
ConditionPathExists=!/var/lib/kldload/klab-firstboot-done

[Service]
Type=oneshot
ExecStartPre=/bin/bash -c 'for i in $(seq 1 30); do curl -sf --connect-timeout 5 https://cloud.debian.org >/dev/null 2>&1 && exit 0; echo "Waiting for internet ($i/30)..."; sleep 10; done'
# Per-distro `-` prefix makes systemd ignore non-zero exits — without it,
# the first failing distro aborts the unit and the rest never run. Caught
# 2026-05-12 on the first RHEL 10 install: rocky golden failed silently
# (zero-byte console log) at the IP-wait step, klab exit=1, and fedora /
# debian / ubuntu / rhel were skipped by systemd. Each distro is now
# independently allowed to fail; the unit ends in `success` overall and
# operator inspects per-golden logs at /root/klab/goldens/<distro>-*.log
# to see which built and which didn't.
ExecStart=-/usr/local/bin/klab golden centos
ExecStart=-/usr/local/bin/klab golden rocky
ExecStart=-/usr/local/bin/klab golden fedora
ExecStart=-/usr/local/bin/klab golden debian
ExecStart=-/usr/local/bin/klab golden ubuntu
# RHEL 10 golden: builds only if both (1) RHEL creds are present in the
# secrets store (webui Dashboard → RHEL Subscription panel writes them to
# /var/lib/kldload/secrets/rhel-{username,password}) AND (2) a RHEL 10
# KVM Guest Image is available — either at /var/lib/klab/images/rhel-10-
# cloud.qcow2, via KLAB_RHEL_IMAGE=/path, or KLAB_RHEL_IMAGE_URL=<one-shot
# Customer Portal URL>. Either condition missing → klab returns 0 (skip)
# so this service still goes green for the other five distros.
ExecStart=-/usr/local/bin/klab golden rhel
ExecStartPost=/bin/mkdir -p /var/lib/kldload
ExecStartPost=/bin/touch /var/lib/kldload/klab-firstboot-done
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=7200

[Install]
WantedBy=multi-user.target
KLABFB
    ln -sf /etc/systemd/system/klab-firstboot.service \
      "${target}/etc/systemd/system/multi-user.target.wants/klab-firstboot.service" 2>/dev/null || true
    k_log "klab will auto-build golden images on first boot (centos/rocky/fedora/debian/ubuntu/rhel — RHEL skipped if creds+image unavailable)"

    # Enable klab services: Prometheus exporter + Hubble relay (captures from second zero)
    for _svc in klab-exporter klab-hubble-relay; do
      if [[ -f "${target}/usr/lib/systemd/system/${_svc}.service" ]]; then
        ln -sf "/usr/lib/systemd/system/${_svc}.service" \
          "${target}/etc/systemd/system/multi-user.target.wants/${_svc}.service" 2>/dev/null || true
        k_log "Enabled ${_svc}.service"
      fi
    done
  fi

  # ── SELinux on ZFS — disabled ─────────────────────────────────────────
  # ZFS does not support xattr-based SELinux labels. All files get unlabeled_t
  # which triggers thousands of AVC denials. Permissive still floods the
  # console and audit log with noise. Disabled is the only clean option until
  # OpenZFS ships proper SELinux policy modules.
  # RPM distros only (CentOS, RHEL, Rocky, Fedora) — Debian/Ubuntu/Arch don't ship SELinux.
  if [[ -f "${target}/etc/selinux/config" ]]; then
    sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' "${target}/etc/selinux/config"
    sed -i 's/^SELINUX=permissive/SELINUX=disabled/' "${target}/etc/selinux/config"
    k_log "SELinux disabled (ZFS has no SELinux policy — re-enable manually if needed)"
  fi

  k_log "System files installed (root_ds=${root_ds})"
}
