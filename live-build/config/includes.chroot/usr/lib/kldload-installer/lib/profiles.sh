#!/usr/bin/env bash
# Sourced by kldload-install-target — k_profile_packages, k_profile_optional_packages, k_install_system_files (called from bootstrap.sh)
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

k_profile_packages() {
  local profile="${KLDLOAD_PROFILE:-server}"
  local _distro="${KLDLOAD_DISTRO:-debian}"

  # fastfetch is not in Ubuntu noble repos — skip it there (Fedora has it)
  local _fastfetch="fastfetch"
  [[ "$_distro" == "ubuntu" ]] && _fastfetch=""

  # Alpine Linux — core profile only
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

  # Arch Linux uses different package names
  if [[ "$_distro" == "arch" ]]; then
    case "$profile" in
      server)
        echo "openssh sudo curl ca-certificates vim less chrony wireguard-tools iproute2 tmux python python-websockets python-yaml htop btop net-tools ethtool nftables tcpdump fzf bat eza fd ripgrep zoxide fastfetch"
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
          tmux python python-websockets python-yaml htop btop net-tools wireguard-tools iproute2 fzf bat eza fd ripgrep zoxide fastfetch"
        ;;
      core)
        echo "openssh sudo curl ca-certificates vim less iproute2 chrony nftables wireguard-tools"
        ;;
      ai)
        echo "openssh sudo curl ca-certificates vim less iproute2 chrony nftables \
          wireguard-tools tmux python python-pip jq htop btop fzf bat eza fd ripgrep zoxide fastfetch \
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

  case "$profile" in
    server)
      echo "openssh-server sudo curl ca-certificates vim less systemd-resolved chrony wireguard-tools iproute2 tmux eject sanoid python3 python3-websockets python3-yaml htop btop net-tools ethtool nftables tcpdump fzf bat eza fd-find ripgrep zoxide podman ${_fastfetch}"
      ;;
    client)
      echo "openssh-server sudo curl ca-certificates vim less network-manager wireguard-tools iproute2"
      ;;
    desktop)
      local _browser="firefox-esr"
      local _viewer="loupe"
      local _terminal="gnome-terminal"
      # Ubuntu uses different package names for some GNOME components
      # Ubuntu's firefox is a snapd transitional package — use GNOME Web instead
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
        tmux eject sanoid python3 python3-websockets python3-yaml htop btop net-tools wireguard-tools iproute2 fzf bat eza fd-find ripgrep zoxide podman ${_fastfetch}"
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

k_profile_optional_packages() {
  local out=()
  local _distro="${KLDLOAD_DISTRO:-debian}"
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
  # Move management webui to port 9000 on installed systems (8080 reserved for Open WebUI)
  if [[ -f "${target}/usr/lib/systemd/system/kldload-webui.service" ]]; then
    sed -i 's/--port 8080/--port 9000/' "${target}/usr/lib/systemd/system/kldload-webui.service"
  fi

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

  # ── Fix websockets version (CentOS 9 RPM is too old for websockets.http11) ──
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
    cat > "${target}/etc/xdg/autostart/kldload-dashboard.desktop" <<'DASHSTART'
[Desktop Entry]
Type=Application
Name=kldload Dashboard
Exec=firefox http://localhost:9000
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
DASHSTART
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

  k_log "System files installed (root_ds=${root_ds})"
}
