# kldload-live.ks — Full kickstart for KLDload live CentOS Stream 9 ISO
# ZFS from zfsonlinux.org, GNOME desktop, live user with auto-login

# ---------------------------------------------------------------------------
# System configuration
# ---------------------------------------------------------------------------
lang en_US.UTF-8
keyboard us
timezone UTC --utc
selinux --enforcing
firewall --enabled --service=ssh
rootpw --plaintext kldload
network --bootproto=dhcp --device=link --activate --hostname=kldload

# Install method — required by livemedia-creator --no-virt
url --mirrorlist=https://mirrors.centos.org/metalink?repo=centos-baseos-9-stream&arch=$basearch&protocol=https

# Live image — no disk partitioning (runs from RAM/squashfs)
zerombr
clearpart --all
autopart --type=plain

# ---------------------------------------------------------------------------
# Repositories
# ---------------------------------------------------------------------------
repo --name=baseos      --mirrorlist=https://mirrors.centos.org/metalink?repo=centos-baseos-9-stream&arch=$basearch&protocol=https
repo --name=appstream   --mirrorlist=https://mirrors.centos.org/metalink?repo=centos-appstream-9-stream&arch=$basearch&protocol=https
repo --name=crb         --mirrorlist=https://mirrors.centos.org/metalink?repo=centos-crb-9-stream&arch=$basearch&protocol=https
repo --name=epel        --metalink=https://mirrors.fedoraproject.org/metalink?repo=epel-9&arch=$basearch
repo --name=zfs         --baseurl=https://zfsonlinux.org/epel/9/$basearch/

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
%packages
# ── Core / Init ───────────────────────────────────────────────────────────
@core
kernel
kernel-devel
kernel-headers
systemd
bash
dracut
dracut-live

# ── Essential utilities ───────────────────────────────────────────────────
vim-enhanced
tmux
jq
curl
wget
rsync
ca-certificates
gnupg2
openssh-server
sudo
less
tar
gzip
xz
bzip2
unzip
bc
file
man-db
bind-utils
bash-completion

# ── Networking ────────────────────────────────────────────────────────────
iproute
iputils
net-tools
nftables
NetworkManager
NetworkManager-wifi
wireguard-tools
ethtool
tcpdump
socat
nmap-ncat

# ── System / hardware ────────────────────────────────────────────────────
chrony
logrotate
cronie
efibootmgr
mokutil
eject
lvm2
parted
gdisk
dosfstools
pciutils
usbutils

# ── ZFS from zfsonlinux.org ──────────────────────────────────────────────
zfs
zfs-dkms
dkms

# ── Snapshot management ──────────────────────────────────────────────────
sanoid

# ── Python / Web UI backend ──────────────────────────────────────────────
python3
python3-pip
python3-pyyaml
python3-websockets

# ── GNOME Desktop ────────────────────────────────────────────────────────
@gnome-desktop
gnome-shell
gnome-session
gnome-control-center
gnome-settings-daemon
gdm
nautilus
gnome-terminal
gnome-text-editor
gnome-tweaks
gnome-system-monitor
file-roller
adwaita-icon-theme
adwaita-cursor-theme
# liberation-fonts is not a package on F44 — the family is split into
# sans/mono/serif/narrow, and the bare name silently resolves to nothing.
liberation-sans-fonts
google-noto-sans-fonts
# Color emoji, or every icon in the installer's own web UI is a box.
#
# HISTORY: 2026-08-13. The live ISO shipped with NO emoji font at all, so
# the installer SPA — and every other browser surface an operator sees
# before the system is even installed — rendered emoji as tofu. The first
# impression of kldload was a UI full of empty squares. It is 4.6 MB.
google-noto-color-emoji-fonts
firefox

# ── Monitoring / ops ─────────────────────────────────────────────────────
htop
iotop
lsof
strace
sysstat
ncdu

# ── Hypervisor guest tools ───────────────────────────────────────────────
qemu-guest-agent
open-vm-tools
# kldload-webview deps: GTK4 + WebKit 6.0 + python3-gobject. Without
# these the per-launcher windows fall back to Chrome --app= which on
# Wayland cannot set per-window app_id, breaking the dock icons.
webkitgtk6.0
gtk4
python3-gobject

# ── Exclude unwanted packages ────────────────────────────────────────────
-plymouth
-plymouth-system-theme

%end

# ---------------------------------------------------------------------------
# Post-install script — runs inside the live image chroot
# ---------------------------------------------------------------------------
%post --nochroot
# Nothing needed outside chroot
%end

%post
#!/bin/bash
set -euo pipefail

# ── Enable services ──────────────────────────────────────────────────────
systemctl enable NetworkManager
systemctl enable sshd
systemctl enable chronyd
systemctl enable gdm
systemctl enable nftables
systemctl enable qemu-guest-agent
systemctl enable sanoid.timer

# ── Create live user (auto-login, passwordless sudo) ─────────────────────
useradd -m -G wheel -s /bin/bash live
echo "live" | passwd --stdin live
echo "live ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/live
chmod 0440 /etc/sudoers.d/live

# ── GDM auto-login for live user ─────────────────────────────────────────
mkdir -p /etc/gdm
cat > /etc/gdm/custom.conf << 'EOGDM'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=live

[security]

[xdmcp]

[chooser]

[debug]
EOGDM

# ── ZFS module load at boot ──────────────────────────────────────────────
echo "zfs" > /etc/modules-load.d/zfs.conf

# ── kldload-webui systemd service ──────────────────────────────────────────
cat > /usr/lib/systemd/system/kldload-webui.service << 'EOSVC'
[Unit]
Description=KLDload Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/kldload-webui
WorkingDirectory=/usr/local/share/kldload-webui
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOSVC
systemctl enable kldload-webui.service || true

# ── Shell prompt ─────────────────────────────────────────────────────────
cat >> /etc/profile.d/kldload.sh << 'EOPROFILE'
# KLDload live environment
export PS1='\[\e[1;36m\]kldload\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
alias ll='ls -lah --color=auto'
alias zl='zfs list'
alias zs='zpool status'
EOPROFILE

# ── MOTD ─────────────────────────────────────────────────────────────────
cat > /etc/motd << 'EOMOTD'

  KLDload — ZFS-native CentOS Stream 9
  Run 'kldload-status' for system health at a glance.
  Run 'kldload-install-target' to install to disk.

EOMOTD

%end
