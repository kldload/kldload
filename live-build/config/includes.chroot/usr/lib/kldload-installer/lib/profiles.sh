#!/usr/bin/env bash
# Sourced by kldload-install-target — k_profile_packages, k_profile_optional_packages, k_install_system_files (called from bootstrap.sh)
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

k_profile_packages() {
  local profile="${KLDLOAD_PROFILE:-server}"
  case "$profile" in
    server)
      echo "openssh-server sudo curl ca-certificates vim less systemd-resolved chrony wireguard-tools iproute2 tmux eject sanoid python3 python3-websockets python3-yaml htop btop net-tools ethtool nftables tcpdump fzf bat eza fd-find ripgrep zoxide fastfetch"
      ;;
    client)
      echo "openssh-server sudo curl ca-certificates vim less network-manager wireguard-tools iproute2"
      ;;
    desktop)
      # task-gnome-desktop pulls gnome-core → gnome-snapshot → gstreamer1.0-plugins-bad
      # → libfluidsynth3 → sf3-soundfont-gm which is not in the darksite (soundfonts
      # are blacklisted). Install individual packages that avoid gnome-snapshot entirely.
      # Only packages confirmed present in the darksite pool are listed here.
      # loupe = GNOME image viewer (replaces eog in trixie). firefox-esr confirmed in darksite pool.
      echo "openssh-server sudo curl ca-certificates vim less network-manager \
        gnome-shell gnome-session gnome-control-center gnome-settings-daemon \
        gdm3 nautilus gnome-terminal loupe \
        adwaita-icon-theme fonts-cantarell gvfs gvfs-backends \
        gnome-keyring \
        firefox-esr \
        tmux eject sanoid python3 python3-websockets python3-yaml htop btop net-tools wireguard-tools iproute2 fzf bat eza fd-find ripgrep zoxide fastfetch"
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
      # Hypervisor: KVM + libvirt + containerd for microVMs (Firecracker pulled by firstboot)
      echo "openssh-server sudo curl ca-certificates vim less iproute2 \
        qemu-kvm qemu-utils \
        libvirt-daemon-system libvirt-clients virtinst \
        bridge-utils ovmf cpu-checker \
        containerd \
        nftables chrony \
        wireguard-tools"
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
      # Bare minimum — ZFS on root, SSH, networking. No kldload tools, no sanoid, no webui.
      echo "openssh-server sudo curl ca-certificates vim less iproute2 chrony nftables"
      ;;

    *)
      k_die "unsupported profile: $profile"
      ;;
  esac
}

k_profile_optional_packages() {
  local out=()
  if [[ "${KLDLOAD_ENABLE_EBPF:-0}" == "1" ]]; then
    out+=(bpftool bpfcc-tools bpftrace linux-perf)
  fi
  if [[ "${KLDLOAD_ENABLE_ZFS:-0}" == "1" ]]; then
    out+=(zfsutils-linux zfs-zed zfs-initramfs zfs-dkms sanoid)
  fi

  # Auto-detect hypervisor and add guest tools
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

  # ── Core profile: skip all kldload tools, sanoid, webui, snapshot hooks ────
  # Core gets ZFS on root + boot environments + stock distro. Nothing else.
  if [[ "$_profile" == "core" ]]; then
    k_log "Core profile — skipping kldload tools, sanoid, webui, snapshot hooks."
  else

  # ── Sanoid snapshot automation ─────────────────────────────────────────────
  if [[ -f /etc/sanoid/sanoid.conf ]]; then
    mkdir -p "${target}/etc/sanoid"
    cp /etc/sanoid/sanoid.conf "${target}/etc/sanoid/sanoid.conf"
  fi
  # Sanoid binaries — Debian installs via apt, but RPM targets need the live copies
  for _sb in sanoid syncoid findoid; do
    if [[ -x "/usr/local/sbin/${_sb}" ]] && ! chroot "${target}" command -v "${_sb}" >/dev/null 2>&1; then
      cp "/usr/local/sbin/${_sb}" "${target}/usr/local/sbin/${_sb}"
      chmod +x "${target}/usr/local/sbin/${_sb}"
    fi
  done
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

  # Enable services in the installed system via symlinks (no systemctl in chroot)
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

  # ── Web UI binary + static files ──────────────────────────────────────────
  [[ -x /usr/local/bin/kldload-webui ]] && \
    cp /usr/local/bin/kldload-webui "${target}/usr/local/bin/kldload-webui" && \
    chmod +x "${target}/usr/local/bin/kldload-webui"
  # The service WorkingDirectory is /usr/local/share/kldload-webui — copy static files
  if [[ -d /usr/local/share/kldload-webui/active ]]; then
    mkdir -p "${target}/usr/local/share/kldload-webui"
    cp -r /usr/local/share/kldload-webui/active/. "${target}/usr/local/share/kldload-webui/"
  fi

  fi # end non-core block

  # ── Build SHA marker ──────────────────────────────────────────────────────
  [[ -f /etc/kldload-build-sha ]] && cp /etc/kldload-build-sha "${target}/etc/kldload-build-sha"

  # ── Virtio / VMware kernel modules ──────────────────────────────────────
  if [[ -f /etc/modules-load.d/virtio.conf ]]; then
    mkdir -p "${target}/etc/modules-load.d"
    cp /etc/modules-load.d/virtio.conf "${target}/etc/modules-load.d/virtio.conf"
  fi

  # ── Edition marker ────────────────────────────────────────────────────────
  mkdir -p "${target}/etc/kldload"
  [[ -f /etc/kldload/edition ]] && cp /etc/kldload/edition "${target}/etc/kldload/edition"

  # ── User tools: ZFS helpers + adduser.local hook (skip for core) ─────────────
  mkdir -p "${target}/usr/local/bin" "${target}/usr/local/sbin"
  if [[ "$_profile" != "core" ]]; then
    # eza not in EPEL — copy from live if target doesn't have it
    if [[ -x /usr/local/bin/eza ]] && ! chroot "${target}" command -v eza >/dev/null 2>&1; then
      cp /usr/local/bin/eza "${target}/usr/local/bin/eza"
      chmod +x "${target}/usr/local/bin/eza"
    fi
    for _tool in kst kst-dashboard ksnap kclone kdf kdir kpkg kldload-help; do
      [[ -x "/usr/local/bin/${_tool}" ]] && \
        cp "/usr/local/bin/${_tool}" "${target}/usr/local/bin/${_tool}" && \
        chmod +x "${target}/usr/local/bin/${_tool}"
    done
    [[ -f /usr/local/sbin/adduser.local ]] && \
      cp /usr/local/sbin/adduser.local "${target}/usr/local/sbin/adduser.local" && \
      chmod +x "${target}/usr/local/sbin/adduser.local"
  fi

  # ── OS branding ───────────────────────────────────────────────────────────────
  [[ -f /etc/os-release ]] && cp /etc/os-release "${target}/etc/os-release"

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
  # GDM config: no auto-login on installed system (live has AutomaticLogin=live)
  mkdir -p "${target}/etc/gdm3"
  cat > "${target}/etc/gdm3/daemon.conf" <<'EOGDM'
[daemon]

[security]

[xdmcp]

[chooser]

[debug]
EOGDM

  # ── Custom .desktop launchers ───────────────────────────────────────────────
  mkdir -p "${target}/usr/share/applications"
  for _dt in vim.desktop kst.desktop kst-dashboard.desktop ksnap.desktop kexport.desktop kldload-terminal.desktop kldload-docs.desktop; do
    [[ -f "/usr/share/applications/${_dt}" ]] && \
      cp "/usr/share/applications/${_dt}" "${target}/usr/share/applications/${_dt}"
  done

  # ── Wallpaper ─────────────────────────────────────────────────────────────
  if [[ -d /usr/share/backgrounds/kldload ]]; then
    mkdir -p "${target}/usr/share/backgrounds/kldload"
    cp -r /usr/share/backgrounds/kldload/. "${target}/usr/share/backgrounds/kldload/"
  fi

  # ── Shell dotfiles (.bashrc, .tmux.conf, .vimrc) for root, skel, and admin user
  # k_create_users runs before k_install_system_files so useradd copies from skel
  # before these files exist — explicitly push them to the admin home dir too.
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
  # Fix ownership of admin home dotfiles
  if [[ -d "$_user_home" ]]; then
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

  # ── Darksite (full APT mirror + support scripts) → target /root/darksite/ ──
  # Core profile skips darksites — installs from internet
  if [[ "$_profile" != "core" ]]; then
    local darksite_src="/root/darksite"
    local darksite_tgt="${target}/root/darksite"
    if [[ -d "$darksite_src" ]]; then
      mkdir -p "$darksite_tgt"
      rsync -a --exclude='*.lock' "${darksite_src}/" "${darksite_tgt}/"
      for f in kldload-syscheck.sh audit.sh; do
        [[ -f "${darksite_tgt}/${f}" ]] && chmod +x "${darksite_tgt}/${f}"
      done
      k_log "Darksite installed to target: ${darksite_tgt}"
    fi
  else
    k_log "Core profile — skipping darksite copy."
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

  k_log "System files installed (root_ds=${root_ds})"
}
