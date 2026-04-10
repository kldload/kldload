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
      local _browser="firefox-esr"
      local _viewer="loupe"
      local _terminal="gnome-terminal"
      # Ubuntu uses different package names for some GNOME components.
      # Ubuntu's firefox package is a snapd transitional stub that pulls in
      # the snap daemon — use GNOME Web (epiphany) instead to avoid snapd.
      if [[ "$_distro" == "ubuntu" ]]; then
        _browser="epiphany-browser"
        _viewer="eog"
        _terminal="gnome-terminal"
      fi
      echo "openssh-server sudo curl ca-certificates vim less network-manager \
        gnome-shell gnome-session gnome-control-center gnome-settings-daemon \
        gdm3 nautilus ${_terminal} ${_viewer} \
        adwaita-icon-theme fonts-cantarell gvfs gvfs-backends \
        gnome-keyring xserver-xorg \
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

  # ── Core profile: skip all kldload tools, sanoid, webui, snapshot hooks ────
  # Core gets ZFS on root + boot environments + stock distro. Nothing else.
  if [[ "$_profile" == "core" ]]; then
    k_log "Core profile — skipping kldload tools, sanoid, webui, snapshot hooks."
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
      if [[ -x "/usr/local/sbin/${_sb}" ]] && ! chroot "${target}" command -v "${_sb}" >/dev/null 2>&1; then
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
  for f in kldload-srv-snapshot.service kldload-srv-snapshot.timer kldload-firstboot.service kldload-webui.service kldload-export.service; do
    [[ -f "/usr/lib/systemd/system/${f}" ]] && \
      cp "/usr/lib/systemd/system/${f}" "${target}/usr/lib/systemd/system/${f}"
  done
  # Move management webui to port 9000 on installed systems (8080 reserved for Open WebUI)
  if [[ -f "${target}/usr/lib/systemd/system/kldload-webui.service" ]]; then
    sed -i 's/--port 8080/--port 9000/' "${target}/usr/lib/systemd/system/kldload-webui.service"
  fi

  # Enable services in the installed system via symlinks — we can't run
  # "systemctl enable" because systemd is not running inside the chroot.
  # Creating the symlinks manually achieves the same effect.
  mkdir -p "${target}/etc/systemd/system/timers.target.wants"
  ln -sf "/usr/lib/systemd/system/kldload-srv-snapshot.timer" \
    "${target}/etc/systemd/system/timers.target.wants/kldload-srv-snapshot.timer" || true
  # Sanoid scheduled snapshots (daily/weekly/monthly/yearly)
  ln -sf "/lib/systemd/system/sanoid.timer" \
    "${target}/etc/systemd/system/timers.target.wants/sanoid.timer" || true

  mkdir -p "${target}/etc/systemd/system/multi-user.target.wants"
  ln -sf "/usr/lib/systemd/system/kldload-firstboot.service" \
    "${target}/etc/systemd/system/multi-user.target.wants/kldload-firstboot.service" || true
  # kldload-webui enabled at boot (firstboot also starts it, but enable here for robustness)
  ln -sf "/usr/lib/systemd/system/kldload-webui.service" \
    "${target}/etc/systemd/system/multi-user.target.wants/kldload-webui.service" || true

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

  # ── Firefox autostart to dashboard (desktop profiles) ──────────────────────
  if [[ "${KLDLOAD_PROFILE:-server}" == "desktop" ]]; then
    mkdir -p "${target}/etc/xdg/autostart"
    # Same autostart pattern as the live installer — wait for port, then open Firefox
    mkdir -p "${target}/etc/xdg/autostart"
    cat > "${target}/etc/xdg/autostart/kldload-dashboard.desktop" <<'DASHSTART'
[Desktop Entry]
Type=Application
Name=kldload Dashboard
Exec=bash -c 'for i in $(seq 1 60); do (echo >/dev/tcp/localhost/9000) 2>/dev/null && break; sleep 1; done; sleep 3; firefox --no-remote http://localhost:9000'
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=8
DASHSTART

    # Firefox policies — same path as live ISO, suppress first-run junk
    mkdir -p "${target}/usr/lib64/firefox/distribution"
    cat > "${target}/usr/lib64/firefox/distribution/policies.json" <<'FFPOLICY'
{
  "policies": {
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "DontCheckDefaultBrowser": true,
    "NoDefaultBookmarks": true,
    "DisplayBookmarksToolbar": "always",
    "Homepage": {
      "URL": "http://localhost:9000",
      "StartPage": "homepage",
      "Additional": ["http://localhost:8080"]
    },
    "Bookmarks": [
      {"Title": "Dashboard", "URL": "http://localhost:9000", "Placement": "toolbar"},
      {"Title": "AI Chat", "URL": "http://localhost:8080", "Placement": "toolbar"},
      {"Title": "kldload Docs", "URL": "https://kldload.com", "Placement": "toolbar"}
    ],
    "UserMessaging": {
      "WhatsNewMessaging": false,
      "ExtensionRecommendations": false,
      "SkipOnboarding": true
    }
  }
}
FFPOLICY
  fi

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
    # eza not in EPEL — copy from live if target doesn't have it
    if [[ -x /usr/local/bin/eza ]] && ! chroot "${target}" command -v eza >/dev/null 2>&1; then
      cp /usr/local/bin/eza "${target}/usr/local/bin/eza"
      chmod +x "${target}/usr/local/bin/eza"
    fi
    for _tool in kst kst-dashboard ksnap kclone kdf kdir kpkg kexport kbe krecovery kupgrade kldload-help kldload-overview kube-demo kzfs-lab; do
      [[ -x "/usr/local/bin/${_tool}" ]] && \
        cp "/usr/local/bin/${_tool}" "${target}/usr/local/bin/${_tool}" && \
        chmod +x "${target}/usr/local/bin/${_tool}"
    done
    [[ -f /usr/local/sbin/adduser.local ]] && \
      cp /usr/local/sbin/adduser.local "${target}/usr/local/sbin/adduser.local" && \
      chmod +x "${target}/usr/local/sbin/adduser.local"
  fi

  # ── OS branding ───────────────────────────────────────────────────────────────
  # Write os-release for the TARGET distro, not the live ISO (which is always CentOS)
  local _target_distro="${KLDLOAD_DISTRO:-centos}"
  local _target_suite=""
  case "$_target_distro" in
    centos)  _target_suite="stream9" ;;
    rocky)   _target_suite="9" ;;
    rhel)    _target_suite="9" ;;
    fedora)  _target_suite="${KLDLOAD_FEDORA_RELEASE:-41}" ;;
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
    for tool in kvm-create kvm-clone kvm-snap kvm-delete kvm-list kvm-demo kube-cluster kzfs-lab; do
      if [[ -f "/usr/local/bin/${tool}" ]]; then
        cp "/usr/local/bin/${tool}" "${target}/usr/local/bin/${tool}"
        chmod +x "${target}/usr/local/bin/${tool}"
      fi
    done

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

    # First-boot auto-bootstrap (optional checkbox)
    # Uses "kube-cluster bootstrap" rather than "kube-init" because kube-cluster
    # handles the full multi-node workflow: build a golden image, clone it into
    # 3 worker VMs via ZFS instant clone, kubeadm init on the host, kubeadm join
    # on each worker, then deploy Cilium + MetalLB + Hubble. kube-init only does
    # the single-node control plane setup.
    if [[ "${KLDLOAD_K8S_BOOTSTRAP:-0}" == "1" ]]; then
      k_log "Enabling first-boot Kubernetes cluster bootstrap..."
      cat > "${target}/etc/systemd/system/kube-firstboot.service" <<'KUBEFB'
[Unit]
Description=kldload Kubernetes cluster bootstrap — golden image + 3 worker VMs + Cilium + MetalLB + Hubble
After=network-online.target libvirtd.service
Wants=network-online.target
ConditionPathExists=!/etc/kubernetes/admin.conf

[Service]
Type=oneshot
ExecStartPre=/bin/bash -c 'for i in $(seq 1 30); do curl -sf --connect-timeout 5 https://cloud.debian.org >/dev/null 2>&1 && exit 0; echo "Waiting for internet ($i/30)..."; sleep 10; done; echo "No internet after 5 minutes — continuing anyway"'
ExecStart=/usr/local/bin/kube-cluster bootstrap --workers 3
ExecStartPost=/bin/bash -c 'systemctl disable kube-firstboot.service'
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=3600

[Install]
WantedBy=multi-user.target
KUBEFB
      ln -sf /etc/systemd/system/kube-firstboot.service \
        "${target}/etc/systemd/system/multi-user.target.wants/kube-firstboot.service" 2>/dev/null || true
      k_log "First-boot cluster bootstrap enabled — will deploy 1 CP + 3 workers on ZFS instant clones"
    fi

    k_log "Kubernetes node configured: containerd, kernel modules, sysctl, ZFS datasets (etcd 8K, containerd, kubelet)"
    k_log "After boot: kube-cluster bootstrap (auto if checkbox selected), or manual: kube-init / kube-join"
  fi

  # ── ZFS Lab (profile tile) ──────────────────────────────────────────
  # ZFS Lab spawns a fleet of core VMs (one per supported distro) for OpenZFS
  # testing. Like the K8s bootstrap, this runs on first boot because it needs
  # a running libvirtd and network access to download ISOs. The build phase
  # creates golden images, then "deploy blue" instantiates the blue site VMs.
  if [[ "${KLDLOAD_ENABLE_ZFSLAB:-0}" == "1" ]]; then
    k_log "Enabling ZFS Lab first-boot deployment..."
    cat > "${target}/etc/systemd/system/kzfs-lab-firstboot.service" <<'ZFSLABFB'
[Unit]
Description=kldload ZFS Lab — build 6 distro golden images + deploy blue site
After=network-online.target libvirtd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/bash -c 'for i in $(seq 1 30); do curl -sf --connect-timeout 5 https://cloud.debian.org >/dev/null 2>&1 && exit 0; echo "Waiting for internet ($i/30)..."; sleep 10; done'
ExecStart=/usr/local/bin/kzfs-lab build all
ExecStartPost=/usr/local/bin/kzfs-lab deploy blue
ExecStartPost=/bin/bash -c 'systemctl disable kzfs-lab-firstboot.service'
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=7200

[Install]
WantedBy=multi-user.target
ZFSLABFB
    ln -sf /etc/systemd/system/kzfs-lab-firstboot.service \
      "${target}/etc/systemd/system/multi-user.target.wants/kzfs-lab-firstboot.service" 2>/dev/null || true
    k_log "ZFS Lab will auto-deploy on first boot (builds 6 golden images + blue site)"
  fi

  # ── SELinux on ZFS — set permissive and trigger autorelabel ────────────
  # ZFS does not support xattr-based SELinux labels natively. All files on a
  # ZFS dataset get the unlabeled_t context by default. If SELinux is set to
  # enforcing, unlabeled_t is denied for virtually everything: login fails,
  # SSH fails, systemd services fail. Setting permissive + autorelabel lets
  # the system boot, relabel files on the first boot, and then the user can
  # manually switch to enforcing if desired. This only applies to RPM distros
  # (CentOS, RHEL, Rocky, Fedora) — Debian/Ubuntu/Arch don't ship SELinux.
  if [[ -f "${target}/etc/selinux/config" ]]; then
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' "${target}/etc/selinux/config"
    touch "${target}/.autorelabel"
    k_log "SELinux set to permissive + autorelabel on first boot (ZFS unlabeled_t workaround)"
  fi

  k_log "System files installed (root_ds=${root_ds})"
}
