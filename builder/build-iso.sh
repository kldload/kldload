#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build-iso.sh — runs INSIDE the builder container
# Builds a CentOS Stream 9 live ISO using dnf --installroot + squashfs + lorax
# No anaconda/livemedia-creator — works reliably inside containers.
# ---------------------------------------------------------------------------

PROFILE="${PROFILE:-desktop}"
EDITION="${EDITION:-free}"
ARCH="${ARCH:-x86_64}"
OUTPUT_DIR="${OUTPUT_DIR:-/build/live-build/output}"
LOG_DIR="${LOG_DIR:-/build/live-build/logs}"
BUILD_ROOT="/build"
BUILD_DATE="$(date +%Y%m%d)"

ROOTFS="/var/tmp/kldload-rootfs"
ISO_STAGING="/var/tmp/kldload-iso"
DISTRO_TAG="${DISTRO:-centos}"
VERSION="${KLDLOAD_VERSION:-1.0.2}"
ISO_NAME="kldload-${VERSION}-${ARCH}.iso"
SQUASHFS_DIR="${ISO_STAGING}/LiveOS"

log() { printf '[%s] [build-iso] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() { printf '[%s] [build-iso] ERROR: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; exit 1; }

log "Starting kldload ISO build."
log "Profile:    $PROFILE"
log "Edition:    $EDITION"
log "Arch:       $ARCH"
log "Date:       $BUILD_DATE"

mkdir -p "$OUTPUT_DIR" "$LOG_DIR"
LOG_FILE="$LOG_DIR/build-${PROFILE}-${ARCH}-${BUILD_DATE}.log"

# ---------------------------------------------------------------------------
# Clean previous state
# ---------------------------------------------------------------------------
rm -rf "$ROOTFS" "$ISO_STAGING" /var/tmp/kldload-*
mkdir -p "$ROOTFS" "$ISO_STAGING"

# ---------------------------------------------------------------------------
# Build darksite RPM mirror (free edition only)
# ---------------------------------------------------------------------------
if [[ "$EDITION" != "core" ]]; then
    DARKSITE_SCRIPT="${BUILD_ROOT}/build/darksite/build-darksite.sh"
    if [[ -x "$DARKSITE_SCRIPT" ]]; then
        log "Building darksite RPM mirror..."
        bash "$DARKSITE_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
    fi
else
    log "Core edition — skipping darksite RPM mirror build."
fi

# ---------------------------------------------------------------------------
# Step 1: Bootstrap CentOS root filesystem with dnf --installroot
# ---------------------------------------------------------------------------
log "Bootstrapping CentOS Stream 9 root filesystem..."

# Install base + profile packages
# Core packages: minimal OS + ZFS on root (both editions)
PKGS=(
    basesystem filesystem setup
    dnf rpm coreutils bash glibc glibc-langpack-en
    systemd systemd-udev dbus-daemon
    kernel kernel-core kernel-modules kernel-devel dracut dracut-live dracut-squash
    grub2-efi-x64 grub2-tools shim-x64 efibootmgr mokutil
    NetworkManager NetworkManager-wifi wpa_supplicant openssh-server openssh-clients sudo
    vim-enhanced tmux curl wget rsync jq less tar gzip
    iproute iputils net-tools nftables chrony
    # Hardware support — WiFi firmware, storage controllers, USB, etc.
    linux-firmware iwl*-firmware
    passwd shadow-utils util-linux procps-ng findutils grep sed gawk
    rootfiles parted gdisk dosfstools
    # Live environment disk & diagnostic tools
    hdparm smartmontools nvme-cli
    lshw dmidecode pciutils usbutils
    nmap-ncat tcpdump iperf3 ethtool
    blktrace iotop sysstat strace
    xfsprogs e2fsprogs btrfs-progs mdadm lvm2 cryptsetup
    fio bonnie++ stress-ng memtest86+
    bash-completion hostname
    # ZFS — DKMS build inside chroot against target kernel
    dkms gcc make autoconf automake libtool kernel-devel
    zfs zfs-dkms
    # RHEL support — subscription-manager needed on live system for RHEL installs
    subscription-manager
)

# Free edition: add tools needed for webui, installer, darksites, guest agents
if [[ "$EDITION" != "core" ]]; then
    PKGS+=(
        python3 python3-pip python3-websockets python3-pyyaml
        htop pv lzop mbuffer
        perl-Config-IniFiles perl-Capture-Tiny
        # Cross-distro installer (debootstrap for Debian targets from CentOS live)
        debootstrap
        # Arch Linux support — pacman-static (not in CentOS repos)
        # Downloaded during build and placed in /usr/local/bin/pacman
        # Guest agents
        qemu-guest-agent qemu-img open-vm-tools-desktop sshpass
        # Windows installer support (WIM image extraction)
        wimlib-utils ntfs-3g ntfsprogs
    )
fi

if [[ "$PROFILE" == "desktop" ]]; then
    PKGS+=(
        gnome-shell gnome-session gdm gnome-terminal nautilus
        gnome-control-center gnome-settings-daemon gedit
        gnome-keyring firefox mesa-dri-drivers
        pipewire wireplumber
        adwaita-icon-theme google-noto-sans-fonts
    )
fi

# Set up repos inside the installroot
mkdir -p "${ROOTFS}/etc/yum.repos.d" "${ROOTFS}/etc/pki/rpm-gpg"

cat > "${ROOTFS}/etc/yum.repos.d/centos.repo" << 'CENTREPO'
[baseos]
name=CentOS Stream 9 - BaseOS
metalink=https://mirrors.centos.org/metalink?repo=centos-baseos-9-stream&arch=$basearch&protocol=https
gpgcheck=0
enabled=1

[appstream]
name=CentOS Stream 9 - AppStream
metalink=https://mirrors.centos.org/metalink?repo=centos-appstream-9-stream&arch=$basearch&protocol=https
gpgcheck=0
enabled=1

[crb]
name=CentOS Stream 9 - CRB
metalink=https://mirrors.centos.org/metalink?repo=centos-crb-9-stream&arch=$basearch&protocol=https
gpgcheck=0
enabled=1
CENTREPO

cat > "${ROOTFS}/etc/yum.repos.d/epel.repo" << 'EPELREPO'
[epel]
name=EPEL 9
metalink=https://mirrors.fedoraproject.org/metalink?repo=epel-9&arch=$basearch
gpgcheck=0
enabled=1
EPELREPO

cat > "${ROOTFS}/etc/yum.repos.d/zfs.repo" << 'ZFSREPO'
[zfs]
name=ZFS on Linux for EL9 - dkms
baseurl=http://download.zfsonlinux.org/epel/9/$basearch/
enabled=1
gpgcheck=0

ZFSREPO

# Note: DKMS autoinstall will fail here (host kernel != target kernel).
# That's expected — we rebuild DKMS explicitly below with --kernelsourcedir.
# Don't let the scriptlet failure kill the build.
set +o pipefail
dnf --installroot="$ROOTFS" --releasever=9 --setopt=install_weak_deps=False \
    --setopt=tsflags=nodocs --nogpgcheck -y install "${PKGS[@]}" 2>&1 | tee -a "$LOG_FILE"
DNF_RC=${PIPESTATUS[0]}
set -o pipefail
# Check if packages actually installed (ignore DKMS scriptlet exit code)
if ! chroot "$ROOTFS" rpm -q zfs zfs-dkms kernel-core >/dev/null 2>&1; then
    die "dnf --installroot failed — core packages missing"
fi
log "dnf completed (exit $DNF_RC — DKMS scriptlet failures are expected and handled below)"

log "Root filesystem bootstrapped: $(du -sh "$ROOTFS" | cut -f1)"

# Install sanoid from GitHub (free edition only)
if [[ "$EDITION" != "core" ]]; then
    log "Installing sanoid from GitHub..."
    SANOID_VER="2.2.0"
    curl -sL "https://github.com/jimsalterjrs/sanoid/archive/refs/tags/v${SANOID_VER}.tar.gz" | \
        tar xz -C /tmp/
    cp "/tmp/sanoid-${SANOID_VER}/sanoid" "${ROOTFS}/usr/local/sbin/sanoid"
    cp "/tmp/sanoid-${SANOID_VER}/syncoid" "${ROOTFS}/usr/local/sbin/syncoid"
    cp "/tmp/sanoid-${SANOID_VER}/findoid" "${ROOTFS}/usr/local/sbin/findoid"
    chmod +x "${ROOTFS}/usr/local/sbin/sanoid" "${ROOTFS}/usr/local/sbin/syncoid" "${ROOTFS}/usr/local/sbin/findoid"
    # Sanoid systemd units
    cp "/tmp/sanoid-${SANOID_VER}/packages/debian/sanoid.timer" "${ROOTFS}/usr/lib/systemd/system/"
    cp "/tmp/sanoid-${SANOID_VER}/packages/debian/sanoid.service" "${ROOTFS}/usr/lib/systemd/system/"
    sed -i 's|/usr/sbin/sanoid|/usr/local/sbin/sanoid|' "${ROOTFS}/usr/lib/systemd/system/sanoid.service"
    chroot "$ROOTFS" systemctl enable sanoid.timer 2>/dev/null || true
    rm -rf "/tmp/sanoid-${SANOID_VER}"
    log "Sanoid ${SANOID_VER} installed."

    # Install eza from GitHub (not in EPEL)
    log "Installing eza from GitHub..."
    EZA_VER="$(curl -fsSL https://api.github.com/repos/eza-community/eza/releases/latest 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')" || true
    if [[ -n "$EZA_VER" ]]; then
        curl -fsSL "https://github.com/eza-community/eza/releases/download/v${EZA_VER}/eza_x86_64-unknown-linux-gnu.tar.gz" \
            | tar xz -C "${ROOTFS}/usr/local/bin/"
        chmod +x "${ROOTFS}/usr/local/bin/eza"
        log "eza ${EZA_VER} installed."
    else
        log "WARNING: could not fetch eza version — skipping"
    fi
else
    log "Core edition — skipping sanoid."
fi

# ---------------------------------------------------------------------------
# Step 1b: Build ZFS DKMS module inside the rootfs
# ---------------------------------------------------------------------------
KVER=$(ls "${ROOTFS}/lib/modules/" | grep -v '^$' | head -1)
log "Kernel version: $KVER"
log "Building ZFS DKMS module for $KVER..."

# Mount chroot filesystems for DKMS
mount -t sysfs sysfs "${ROOTFS}/sys" 2>/dev/null || true
mount --bind /dev "${ROOTFS}/dev" 2>/dev/null || true
mount --bind /dev/pts "${ROOTFS}/dev/pts" 2>/dev/null || true

# DO NOT mount host /proc — it exposes the host kernel (Fedora 6.18.x).
# Instead mount a fresh procfs so DKMS doesn't see the wrong kernel version.
mount -t proc proc "${ROOTFS}/proc" 2>/dev/null || true

# Ensure the kernel headers symlink is correct
ln -sfn "/usr/src/kernels/${KVER}" "${ROOTFS}/lib/modules/${KVER}/build" 2>/dev/null || true

# DKMS build — force the target kernel explicitly
ZFS_VER=$(chroot "$ROOTFS" rpm -q --qf '%{VERSION}' zfs-dkms 2>/dev/null || echo "")
if [[ -n "$ZFS_VER" ]]; then
    # Remove any failed autoinstall attempt, then add fresh
    chroot "$ROOTFS" dkms remove -m zfs -v "$ZFS_VER" --all 2>/dev/null || true
    chroot "$ROOTFS" dkms add -m zfs -v "$ZFS_VER" 2>&1 | tee -a "$LOG_FILE" || true

    # Force DKMS to use the CentOS kernel headers, not autodetect from /proc
    # ARCH=x86_64 prevents "arch/amd64/Makefile: No such file" in cross-arch Docker builds
    # || true because DKMS may fail — we check for zfs.ko below
    chroot "$ROOTFS" env ARCH=x86_64 dkms build -m zfs -v "$ZFS_VER" -k "$KVER" \
        --kernelsourcedir "/usr/src/kernels/${KVER}" \
        --force \
        2>&1 | tee -a "$LOG_FILE" || true

    # Dump make.log to stdout so we can see the actual error
    if [[ -f "${ROOTFS}/var/lib/dkms/zfs/${ZFS_VER}/build/make.log" ]]; then
        log "=== DKMS make.log (last 50 lines) ==="
        tail -50 "${ROOTFS}/var/lib/dkms/zfs/${ZFS_VER}/build/make.log" | tee -a "$LOG_FILE"
        log "=== end make.log ==="
    fi

    chroot "$ROOTFS" dkms install -m zfs -v "$ZFS_VER" -k "$KVER" --force \
        2>&1 | tee -a "$LOG_FILE" || \
        log "WARNING: DKMS install failed"
fi

chroot "$ROOTFS" depmod -a "$KVER" 2>/dev/null || true

# Verify
if find "${ROOTFS}/lib/modules/${KVER}" -name 'zfs.ko*' 2>/dev/null | grep -q .; then
    log "ZFS kernel module built successfully for $KVER"
elif find "${ROOTFS}/lib/modules/" -name 'zfs.ko*' 2>/dev/null | grep -q .; then
    log "ZFS kernel module found (alternate path)"
else
    die "ZFS kernel module NOT found — DKMS build failed for $KVER"
fi

# Unmount chroot mounts
umount "${ROOTFS}/dev/pts" 2>/dev/null || true
umount "${ROOTFS}/dev" 2>/dev/null || true
umount "${ROOTFS}/sys" 2>/dev/null || true
umount "${ROOTFS}/proc" 2>/dev/null || true

# Download pacman-static for Arch Linux bootstrap support
# (CentOS has no pacman package — we need a static binary)
if [[ "$EDITION" != "core" ]]; then
    log "Downloading pacman-static for Arch support..."
    curl -sfL "https://pkgbuild.com/~morganamilo/pacman-static/x86_64/bin/pacman-static" \
        -o "${ROOTFS}/usr/local/bin/pacman" || {
        log "WARNING: pacman-static download failed — Arch installs will not work"
    }
    if [[ -f "${ROOTFS}/usr/local/bin/pacman" ]]; then
        chmod +x "${ROOTFS}/usr/local/bin/pacman"
        ln -sf /usr/local/bin/pacman "${ROOTFS}/usr/bin/pacman"
        mkdir -p "${ROOTFS}/etc/pacman.d"
        # pacman-static looks for /etc/ssl/certs/ca-certificates.crt (Arch path)
        # CentOS has /etc/ssl/certs -> /etc/pki/tls/certs (symlink), so create the file at the real path
        ln -sf /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem "${ROOTFS}/etc/pki/tls/certs/ca-certificates.crt"
        printf 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch\n' > "${ROOTFS}/etc/pacman.d/mirrorlist"
        log "pacman-static installed: $(chroot "$ROOTFS" /usr/bin/pacman --version 2>&1 | head -1)"
    fi
fi

# Download apk-tools-static for Alpine Linux bootstrap support
# (CentOS has no apk package — we need a static binary)
if [[ "$EDITION" != "core" ]]; then
    log "Downloading apk-tools-static for Alpine support..."
    _apk_ver=""
    _apk_ver="$(curl -sfL 'https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/' \
        | grep -oP 'apk-tools-static-\K[0-9][^"]*(?=\.apk)' | head -1)" || true
    if [[ -n "$_apk_ver" ]]; then
        curl -sfL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/apk-tools-static-${_apk_ver}.apk" \
            -o /tmp/apk-tools-static.apk || {
            log "WARNING: apk-tools-static download failed — Alpine installs will not work"
        }
    fi
    if [[ -f /tmp/apk-tools-static.apk ]]; then
        tar -xzf /tmp/apk-tools-static.apk -C /tmp/ sbin/apk.static 2>/dev/null || true
        if [[ -f /tmp/sbin/apk.static ]]; then
            cp /tmp/sbin/apk.static "${ROOTFS}/usr/local/bin/apk.static"
            chmod +x "${ROOTFS}/usr/local/bin/apk.static"
            log "apk-tools-static installed"
        else
            log "WARNING: apk.static not found in downloaded package"
        fi
        rm -rf /tmp/apk-tools-static.apk /tmp/sbin
    fi
fi

# ---------------------------------------------------------------------------
# Step 2: Configure the live system
# ---------------------------------------------------------------------------
log "Configuring live system..."

# Hostname
echo "kldload" > "${ROOTFS}/etc/hostname"

# Live user
chroot "$ROOTFS" useradd -m -G wheel -s /bin/bash live 2>/dev/null || true
echo "live:live" | chroot "$ROOTFS" chpasswd
echo "root:kldload" | chroot "$ROOTFS" chpasswd

# Passwordless sudo for wheel
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > "${ROOTFS}/etc/sudoers.d/wheel-nopasswd"
chmod 440 "${ROOTFS}/etc/sudoers.d/wheel-nopasswd"

# Enable SSH password auth on the live ISO (CentOS 9 disables it by default)
mkdir -p "${ROOTFS}/etc/ssh/sshd_config.d"
cat > "${ROOTFS}/etc/ssh/sshd_config.d/50-kldload-live.conf" <<'SSHEOF'
PasswordAuthentication yes
PermitRootLogin yes
SSHEOF

# CentOS 9 python3-websockets RPM lacks websockets.http11 module needed by webui.
# Remove the RPM and install a compatible version via pip at build time.
# The wheel is downloaded during build (builder container has network access).
if [[ "$EDITION" != "core" ]]; then
    chroot "$ROOTFS" dnf remove -y python3-websockets 2>/dev/null || true
    chroot "$ROOTFS" pip3 install --no-cache-dir websockets 2>&1 | tail -3 || {
        log "WARNING: pip install websockets failed — webui may not start"
    }
fi

# Enable services
chroot "$ROOTFS" systemctl enable NetworkManager sshd 2>/dev/null || true
if [[ "$PROFILE" == "desktop" ]]; then
    chroot "$ROOTFS" systemctl enable gdm 2>/dev/null || true
    chroot "$ROOTFS" systemctl set-default graphical.target 2>/dev/null || true
else
    chroot "$ROOTFS" systemctl set-default multi-user.target 2>/dev/null || true
fi

# GDM autologin for live session
if [[ "$PROFILE" == "desktop" ]]; then
    mkdir -p "${ROOTFS}/etc/gdm"
    cat > "${ROOTFS}/etc/gdm/custom.conf" << 'GDMCONF'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=live

[security]

[xdmcp]

[chooser]

[debug]
GDMCONF
fi

# Auto-launch Firefox to webui on live session login (free edition only)
if [[ "$PROFILE" == "desktop" && "$EDITION" != "core" ]]; then
    # XDG autostart — waits for GNOME Shell to be ready, then opens Firefox
    # PostLogin removed: it raced with the compositor and caused black windows
    mkdir -p "${ROOTFS}/etc/xdg/autostart"
    cat > "${ROOTFS}/etc/xdg/autostart/kldload-webui.desktop" << 'AUTOSTART'
[Desktop Entry]
Type=Application
Name=kldload Web UI
Exec=bash -c 'for i in $(seq 1 60); do (echo >/dev/tcp/localhost/8080) 2>/dev/null && break; sleep 1; done; sleep 3; firefox --no-remote http://localhost:8080'
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=8
AUTOSTART

    # Firefox policy — suppress first-run tabs, privacy notice, default browser check
    mkdir -p "${ROOTFS}/usr/lib64/firefox/distribution"
    cat > "${ROOTFS}/usr/lib64/firefox/distribution/policies.json" << 'FFPOLICY'
{
  "policies": {
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "DontCheckDefaultBrowser": true,
    "DisablePrivateBrowsing": false,
    "NoDefaultBookmarks": true,
    "Homepage": {
      "URL": "http://localhost:8080",
      "StartPage": "homepage"
    }
  }
}
FFPOLICY

    # Disable screensaver / screen blank / auto-lock on live session
    # Method 1: dconf system database (GNOME settings)
    mkdir -p "${ROOTFS}/etc/dconf/db/local.d" "${ROOTFS}/etc/dconf/profile"
    cat > "${ROOTFS}/etc/dconf/profile/user" << 'DCONFPROFILE'
user-db:user
system-db:local
DCONFPROFILE
    cat > "${ROOTFS}/etc/dconf/db/local.d/00-kldload-desktop" << 'DCONF'
[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false

[org/gnome/settings-daemon/plugins/power]
idle-dim=false
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'

[org/gnome/shell]
welcome-dialog-last-shown-version='99'
DCONF
    # Lock these settings so the user can't accidentally re-enable
    mkdir -p "${ROOTFS}/etc/dconf/db/local.d/locks"
    cat > "${ROOTFS}/etc/dconf/db/local.d/locks/kldload-live" << 'LOCKS'
/org/gnome/desktop/session/idle-delay
/org/gnome/desktop/screensaver/lock-enabled
/org/gnome/desktop/screensaver/idle-activation-enabled
/org/gnome/settings-daemon/plugins/power/idle-dim
/org/gnome/settings-daemon/plugins/power/sleep-inactive-ac-type
/org/gnome/settings-daemon/plugins/power/sleep-inactive-battery-type
LOCKS
    chroot "$ROOTFS" dconf update 2>/dev/null || true

    # Method 2: systemd — disable any screen blanking services
    chroot "$ROOTFS" systemctl mask gnome-screensaver.service 2>/dev/null || true

    # Method 3: xset/xorg — disable DPMS and screensaver at X level
    mkdir -p "${ROOTFS}/etc/X11/xinit/xinitrc.d"
    cat > "${ROOTFS}/etc/X11/xinit/xinitrc.d/99-no-blank.sh" << 'XSET'
#!/bin/sh
xset s off s noblank 2>/dev/null || true
xset -dpms 2>/dev/null || true
XSET
    chmod +x "${ROOTFS}/etc/X11/xinit/xinitrc.d/99-no-blank.sh"

    # Method 4: kernel — disable console blanking
    mkdir -p "${ROOTFS}/etc/sysctl.d"
    echo "kernel.consoleblank=0" > "${ROOTFS}/etc/sysctl.d/99-no-blank.conf"
fi

# Edition marker
mkdir -p "${ROOTFS}/etc/kldload"
echo "$EDITION" > "${ROOTFS}/etc/kldload/edition"
GIT_SHA=$(git -C /build rev-parse --short HEAD 2>/dev/null || echo "unknown")
echo "$GIT_SHA" > "${ROOTFS}/etc/kldload-build-sha"

# OS branding
cat > "${ROOTFS}/etc/os-release" << OSREL
PRETTY_NAME="kldload (stream9)"
NAME="kldload"
VERSION_ID="9"
VERSION="9 (stream9)"
ID=centos
HOME_URL="https://kldload.ca"
SUPPORT_URL="https://kldload.ca"
OSREL

# ---------------------------------------------------------------------------
# Free edition: copy kldload tools, webui, installer, darksites, sanoid config
# Core edition: skip all of this — just ZFS on root with stock tools
# ---------------------------------------------------------------------------
if [[ "$EDITION" != "core" ]]; then
    # Copy kldload tools (short names)
    for tool in kst kst-dashboard ksnap kclone kdf kdir kpkg kexport kldload-help kldload-test kldload-install-target kldload-webui; do
        src="/build/live-build/config/includes.chroot/usr/local/bin/${tool}"
        [[ -f "$src" ]] && cp "$src" "${ROOTFS}/usr/local/bin/${tool}" && chmod +x "${ROOTFS}/usr/local/bin/${tool}"
    done

    # Copy .desktop files for GNOME menu
    for dt in kst.desktop kst-dashboard.desktop ksnap.desktop kexport.desktop kldload-terminal.desktop kldload-docs.desktop vim.desktop; do
        src="/build/live-build/config/includes.chroot/usr/share/applications/${dt}"
        [[ -f "$src" ]] && cp "$src" "${ROOTFS}/usr/share/applications/${dt}"
    done

    # Copy the main installer to /usr/sbin
    for sbin_tool in kldload-install-target kldload-firstboot kldload-recovery kldload-apply-platform-holds kldload-export-deferred; do
        src="/build/live-build/config/includes.chroot/usr/sbin/${sbin_tool}"
        [[ -f "$src" ]] && cp "$src" "${ROOTFS}/usr/sbin/${sbin_tool}" && chmod +x "${ROOTFS}/usr/sbin/${sbin_tool}"
    done

    # Copy installer library files
    if [[ -d /build/live-build/config/includes.chroot/usr/lib/kldload-installer ]]; then
        cp -r /build/live-build/config/includes.chroot/usr/lib/kldload-installer "${ROOTFS}/usr/lib/"
        chmod +x "${ROOTFS}/usr/lib/kldload-installer/backend/bin/"* 2>/dev/null || true
        # Symlink backend tools to PATH
        for be_tool in kbe krecovery kupgrade; do
            [[ -f "${ROOTFS}/usr/lib/kldload-installer/backend/bin/${be_tool}" ]] && \
                ln -sf "/usr/lib/kldload-installer/backend/bin/${be_tool}" "${ROOTFS}/usr/local/bin/${be_tool}"
        done
    fi

    # Copy sanoid config
    mkdir -p "${ROOTFS}/etc/sanoid"
    [[ -f /build/live-build/config/includes.chroot/etc/sanoid/sanoid.conf ]] && \
        cp /build/live-build/config/includes.chroot/etc/sanoid/sanoid.conf "${ROOTFS}/etc/sanoid/"

    # Copy webui binary + static files
    if [[ -x /build/live-build/config/includes.chroot/usr/local/bin/kldload-webui ]]; then
        cp /build/live-build/config/includes.chroot/usr/local/bin/kldload-webui \
           "${ROOTFS}/usr/local/bin/kldload-webui"
        chmod +x "${ROOTFS}/usr/local/bin/kldload-webui"
        # Remove the old active/ UI and replace with the correct edition
        rm -rf "${ROOTFS}/usr/local/share/kldload-webui/active" 2>/dev/null || true
        mkdir -p "${ROOTFS}/usr/local/share/kldload-webui/active"
        if [[ "$EDITION" != "core" ]]; then
            if [[ -d /build/live-build/config/includes.chroot/usr/local/share/kldload-webui/free ]]; then
                cp -r /build/live-build/config/includes.chroot/usr/local/share/kldload-webui/free/. \
                      "${ROOTFS}/usr/local/share/kldload-webui/active/"
                log "Free UI copied to active/"
            fi
        fi
    fi

    # Copy snapshot scripts
    for script in snapshot-create.sh snapshot-prune.sh snapshot-policy.sh; do
        src="/build/live-build/config/includes.chroot/usr/local/sbin/${script}"
        [[ -f "$src" ]] && cp "$src" "${ROOTFS}/usr/local/sbin/${script}" && chmod +x "${ROOTFS}/usr/local/sbin/${script}"
    done

    # Copy adduser hook
    if [[ -f /build/live-build/config/includes.chroot/usr/local/sbin/adduser.local ]]; then
        cp /build/live-build/config/includes.chroot/usr/local/sbin/adduser.local \
           "${ROOTFS}/usr/local/sbin/adduser.local"
        chmod +x "${ROOTFS}/usr/local/sbin/adduser.local"
    fi

    # Copy .bashrc with tmux auto-attach
    if [[ -f /build/live-build/config/includes.chroot/etc/skel/.bashrc ]]; then
        cp /build/live-build/config/includes.chroot/etc/skel/.bashrc "${ROOTFS}/etc/skel/.bashrc"
        cp /build/live-build/config/includes.chroot/etc/skel/.bashrc "${ROOTFS}/home/live/.bashrc" 2>/dev/null || true
        cp /build/live-build/config/includes.chroot/etc/skel/.bashrc "${ROOTFS}/root/.bashrc"
    fi
    [[ -f /build/live-build/config/includes.chroot/etc/skel/.tmux.conf ]] && \
        cp /build/live-build/config/includes.chroot/etc/skel/.tmux.conf "${ROOTFS}/etc/skel/.tmux.conf" && \
        cp /build/live-build/config/includes.chroot/etc/skel/.tmux.conf "${ROOTFS}/home/live/.tmux.conf" 2>/dev/null || true
    [[ -f /build/live-build/config/includes.chroot/etc/skel/.vimrc ]] && \
        cp /build/live-build/config/includes.chroot/etc/skel/.vimrc "${ROOTFS}/etc/skel/.vimrc"
    # vim colorscheme
    if [[ -d /build/live-build/config/includes.chroot/etc/skel/.vim ]]; then
        cp -r /build/live-build/config/includes.chroot/etc/skel/.vim "${ROOTFS}/etc/skel/.vim"
        cp -r /build/live-build/config/includes.chroot/etc/skel/.vim "${ROOTFS}/root/.vim"
        cp -r /build/live-build/config/includes.chroot/etc/skel/.vim "${ROOTFS}/home/live/.vim" 2>/dev/null || true
    fi

    # Create kldload-webui systemd service
    cat > "${ROOTFS}/usr/lib/systemd/system/kldload-webui.service" << 'SVCEOF'
[Unit]
Description=kldload Web UI (installer + management frontend)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/kldload-webui --port 8080 --no-browser
WorkingDirectory=/usr/local/share/kldload-webui
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

    chroot "$ROOTFS" systemctl enable kldload-webui 2>/dev/null || true

    # Debian darksite APT mirror service (serves on port 3142 for debootstrap)
    cat > "${ROOTFS}/usr/lib/systemd/system/kldload-apt-mirror.service" << 'APTEOF'
[Unit]
Description=kldload Debian darksite APT mirror
After=network.target
ConditionPathExists=/root/darksite/debian/apt/dists/trixie/Release

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 3142 --bind 127.0.0.1 --directory /root/darksite/debian
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
APTEOF

    chroot "$ROOTFS" systemctl enable kldload-apt-mirror 2>/dev/null || true

    # Ubuntu darksite APT mirror service (serves on port 3143)
    cat > "${ROOTFS}/usr/lib/systemd/system/kldload-apt-mirror-ubuntu.service" << 'UAPTEOF'
[Unit]
Description=kldload Ubuntu darksite APT mirror
After=network.target
ConditionPathExists=/root/darksite/ubuntu/apt/dists/noble/Release

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 3143 --bind 127.0.0.1 --directory /root/darksite/ubuntu
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UAPTEOF

    chroot "$ROOTFS" systemctl enable kldload-apt-mirror-ubuntu 2>/dev/null || true

    # Arch Linux darksite pacman mirror service (serves on port 3144)
    cat > "${ROOTFS}/usr/lib/systemd/system/kldload-pacman-mirror.service" << 'PACEOF'
[Unit]
Description=kldload Arch darksite pacman mirror
After=network.target
ConditionPathIsDirectory=/root/darksite/arch/pkg

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 3144 --bind 127.0.0.1 --directory /root/darksite/arch
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
PACEOF

    chroot "$ROOTFS" systemctl enable kldload-pacman-mirror 2>/dev/null || true

    # Fedora darksite RPM mirror service (serves on port 3145)
    cat > "${ROOTFS}/usr/lib/systemd/system/kldload-fedora-mirror.service" << 'FEDEOF'
[Unit]
Description=kldload Fedora darksite RPM mirror
After=network.target
ConditionPathIsDirectory=/root/darksite/fedora/rpm

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 3145 --bind 127.0.0.1 --directory /root/darksite/fedora
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
FEDEOF

    chroot "$ROOTFS" systemctl enable kldload-fedora-mirror 2>/dev/null || true

    # Alpine Linux darksite apk mirror service (serves on port 3146)
    cat > "${ROOTFS}/usr/lib/systemd/system/kldload-apk-mirror.service" << 'ALPEOF'
[Unit]
Description=kldload Alpine darksite apk mirror
After=network.target
ConditionPathIsDirectory=/root/darksite/alpine/apk

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 3146 --bind 127.0.0.1 --directory /root/darksite/alpine
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
ALPEOF

    chroot "$ROOTFS" systemctl enable kldload-apk-mirror 2>/dev/null || true

    # Copy systemd service units from includes.chroot
    for _svc in kldload-firstboot.service kldload-srv-snapshot.service kldload-srv-snapshot.timer \
                kldload-snapshot.service kldload-snapshot.timer kldload-export.service; do
        _src="/build/live-build/config/includes.chroot/usr/lib/systemd/system/${_svc}"
        [[ -f "$_src" ]] && cp "$_src" "${ROOTFS}/usr/lib/systemd/system/${_svc}"
    done

    # Copy kldload-firstboot and kldload-export-deferred to sbin
    for _sb in kldload-firstboot kldload-export-deferred; do
        _src="/build/live-build/config/includes.chroot/usr/local/sbin/${_sb}"
        [[ -f "$_src" ]] && cp "$_src" "${ROOTFS}/usr/local/sbin/${_sb}" && chmod +x "${ROOTFS}/usr/local/sbin/${_sb}"
    done

    log "Free edition tools and services installed."
else
    log "Core edition — no kldload tools, webui, or darksites."
fi

# ── Autoinstall service + baked-in answers (AI appliance, seed-disk boot) ─────
_autoinstall_svc="/build/live-build/config/includes.chroot/etc/systemd/system/kldload-autoinstall.service"
_autoinstall_bin="/build/live-build/config/includes.chroot/usr/local/sbin/kldload-autoinstall"
_autoinstall_env="/build/live-build/config/includes.chroot/etc/kldload/autoinstall.env"
if [[ -f "$_autoinstall_svc" ]]; then
    mkdir -p "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
    cp "$_autoinstall_svc" "${ROOTFS}/etc/systemd/system/kldload-autoinstall.service"
    ln -sf "/etc/systemd/system/kldload-autoinstall.service" \
        "${ROOTFS}/etc/systemd/system/multi-user.target.wants/kldload-autoinstall.service"
    [[ -f "$_autoinstall_bin" ]] && cp "$_autoinstall_bin" "${ROOTFS}/usr/local/sbin/kldload-autoinstall" && chmod +x "${ROOTFS}/usr/local/sbin/kldload-autoinstall"
    log "Autoinstall service installed"
fi
if [[ -f "$_autoinstall_env" ]]; then
    mkdir -p "${ROOTFS}/etc/kldload"
    cp "$_autoinstall_env" "${ROOTFS}/etc/kldload/autoinstall.env"
    log "Baked-in autoinstall.env — this ISO will auto-install on boot"
fi

# Copy virtio modules config (both editions — needed for VM guests)
mkdir -p "${ROOTFS}/etc/modules-load.d"
[[ -f /build/live-build/config/includes.chroot/etc/modules-load.d/virtio.conf ]] && \
    cp /build/live-build/config/includes.chroot/etc/modules-load.d/virtio.conf "${ROOTFS}/etc/modules-load.d/"

# Ensure ZFS module loads at boot
cat > "${ROOTFS}/etc/modules-load.d/zfs.conf" << 'ZFSMOD'
zfs
ZFSMOD

# ZFS modprobe tuning
mkdir -p "${ROOTFS}/etc/modprobe.d"
cat > "${ROOTFS}/etc/modprobe.d/zfs.conf" << 'ZFSTUNE'
# Limit ARC to 25% of RAM on systems with <8GB
options zfs zfs_arc_max=0
ZFSTUNE

# RHEL release RPMs (both editions — needed for RHEL installs)
if [[ -d /build/build/rhel-release ]]; then
    mkdir -p "${ROOTFS}/usr/share/kldload/rhel-release"
    cp /build/build/rhel-release/redhat-release*.rpm "${ROOTFS}/usr/share/kldload/rhel-release/"
    log "RHEL release RPMs copied to rootfs"
else
    log "WARNING: No RHEL release RPMs found at /build/build/rhel-release/"
fi

# ZFSBootMenu EFI binary (both editions — needed for ZFS boot)
mkdir -p "${ROOTFS}/root/darksite/boot"
log "Downloading ZFSBootMenu EFI binary..."
curl -sL --connect-timeout 30 --max-time 300 \
    -o "${ROOTFS}/root/darksite/boot/zfsbootmenu.EFI" \
    "https://get.zfsbootmenu.org/efi" || log "WARNING: ZFSBootMenu download failed"
if [[ -f "${ROOTFS}/root/darksite/boot/zfsbootmenu.EFI" ]]; then
    log "ZFSBootMenu EFI: $(du -sh "${ROOTFS}/root/darksite/boot/zfsbootmenu.EFI" | cut -f1)"
else
    log "WARNING: ZFSBootMenu EFI not available — installer will try to download at install time"
fi

# Offline package darksites (free edition only — core requires internet for installs)
if [[ "$EDITION" != "core" ]]; then
    # Copy darksite RPM repo into the rootfs for offline target installs
    if [[ -d /build/live-build/config/includes.chroot/root/darksite ]]; then
        cp -r /build/live-build/config/includes.chroot/root/darksite/. "${ROOTFS}/root/darksite/"
        log "RPM darksite copied to rootfs: $(du -sh "${ROOTFS}/root/darksite" 2>/dev/null | cut -f1)"
    fi

    # Copy Debian darksite APT mirror into the rootfs
    if [[ -d /build/live-build/darksite-debian-cache/apt ]]; then
        mkdir -p "${ROOTFS}/root/darksite/debian"
        cp -r /build/live-build/darksite-debian-cache/apt "${ROOTFS}/root/darksite/debian/"
        log "Debian darksite copied to rootfs: $(du -sh "${ROOTFS}/root/darksite/debian" 2>/dev/null | cut -f1)"
    else
        log "WARNING: No Debian darksite found — Debian installs will require internet"
    fi

    # Copy Ubuntu darksite APT mirror into the rootfs
    if [[ -d /build/live-build/darksite-ubuntu-cache/apt ]]; then
        mkdir -p "${ROOTFS}/root/darksite/ubuntu"
        cp -r /build/live-build/darksite-ubuntu-cache/apt "${ROOTFS}/root/darksite/ubuntu/"
        log "Ubuntu darksite copied to rootfs: $(du -sh "${ROOTFS}/root/darksite/ubuntu" 2>/dev/null | cut -f1)"
    else
        log "No Ubuntu darksite found — Ubuntu installs will require internet"
    fi

    # Arch darksite disabled — rolling release causes version drift.
    # Arch installs pull from live mirrors + archzfs (internet required).
    log "Arch darksite: skipped (internet required for Arch installs)"

    # Copy Fedora darksite RPM repo into the rootfs
    if [[ -d /build/live-build/darksite-fedora-cache/rpm ]]; then
        mkdir -p "${ROOTFS}/root/darksite/fedora"
        cp -r /build/live-build/darksite-fedora-cache/rpm "${ROOTFS}/root/darksite/fedora/"
        log "Fedora darksite copied to rootfs: $(du -sh "${ROOTFS}/root/darksite/fedora" 2>/dev/null | cut -f1)"
    else
        log "No Fedora darksite found — Fedora installs will require internet"
    fi

    # Copy Alpine darksite apk cache into the rootfs
    if [[ -d /build/live-build/darksite-alpine-cache/apk ]]; then
        mkdir -p "${ROOTFS}/root/darksite/alpine"
        cp -r /build/live-build/darksite-alpine-cache/apk "${ROOTFS}/root/darksite/alpine/"
        # Copy signing keys
        if [[ -d /build/live-build/darksite-alpine-cache/keys ]]; then
            mkdir -p "${ROOTFS}/root/darksite/alpine/keys"
            cp -r /build/live-build/darksite-alpine-cache/keys/. "${ROOTFS}/root/darksite/alpine/keys/"
        fi
        # Copy version file
        [[ -f /build/live-build/darksite-alpine-cache/alpine-version ]] && \
            cp /build/live-build/darksite-alpine-cache/alpine-version "${ROOTFS}/root/darksite/alpine/"
        log "Alpine darksite copied to rootfs: $(du -sh "${ROOTFS}/root/darksite/alpine" 2>/dev/null | cut -f1)"
    else
        log "No Alpine darksite found — Alpine installs will require internet"
    fi

    # Copy BSD/illumos base sets into the rootfs for offline installs
    if [[ -d /build/live-build/darksite-bsd-cache ]]; then
        mkdir -p "${ROOTFS}/root/darksite-bsd"
        cp -r /build/live-build/darksite-bsd-cache/. "${ROOTFS}/root/darksite-bsd/"
        log "BSD darksite copied to rootfs: $(du -sh "${ROOTFS}/root/darksite-bsd" 2>/dev/null | cut -f1)"
    else
        log "No BSD darksite found — BSD installs will require internet"
    fi
else
    log "Core edition — no offline darksites (internet required for target installs)."
fi

# Fix ownership for live user
chroot "$ROOTFS" chown -R live:live /home/live 2>/dev/null || true

# Clean dnf cache inside rootfs
dnf --installroot="$ROOTFS" clean all 2>/dev/null || true

log "Live system configured."

# ---------------------------------------------------------------------------
# Step 3: Build initramfs with dracut (live boot support)
# ---------------------------------------------------------------------------
log "Building initramfs with dracut live support..."

KVER=$(ls "${ROOTFS}/lib/modules/" | head -1)
[[ -n "$KVER" ]] || die "No kernel found in rootfs"
log "Kernel version: $KVER"

chroot "$ROOTFS" dracut --force --add "dmsquash-live" \
    --no-hostonly \
    --force-drivers "xhci_pci xhci_hcd ehci_pci ehci_hcd ohci_pci ohci_hcd uhci_hcd usb_storage uas usbhid hid_generic cdc_ether usbnet r8152 ax88179_178a thunderbolt typec_ucsi ucsi_acpi nvme nvme_core ahci virtio_blk virtio_scsi virtio_net virtio_pci sdhci sdhci_pci mmc_block" \
    --kver "$KVER" "/boot/initramfs-${KVER}.img" 2>&1 | tee -a "$LOG_FILE" || \
    die "dracut failed"

# ---------------------------------------------------------------------------
# Step 4: Create squashfs
# ---------------------------------------------------------------------------
log "Creating squashfs image..."

mkdir -p "$SQUASHFS_DIR"
mksquashfs "$ROOTFS" "${SQUASHFS_DIR}/squashfs.img" \
    -comp xz -Xbcj x86 -b 1M -noappend 2>&1 | tail -5

log "Squashfs: $(du -sh "${SQUASHFS_DIR}/squashfs.img" | cut -f1)"

# ---------------------------------------------------------------------------
# Step 5: Build ISO with EFI boot
# ---------------------------------------------------------------------------
log "Building ISO..."

# Set up boot structure
mkdir -p "${ISO_STAGING}/EFI/BOOT" "${ISO_STAGING}/images/pxeboot" "${ISO_STAGING}/isolinux"

# Copy kernel + initramfs
cp "${ROOTFS}/boot/vmlinuz-${KVER}" "${ISO_STAGING}/images/pxeboot/vmlinuz"
cp "${ROOTFS}/boot/initramfs-${KVER}.img" "${ISO_STAGING}/images/pxeboot/initrd.img"

# EFI bootloader
cp "${ROOTFS}/boot/efi/EFI/centos/shimx64.efi" "${ISO_STAGING}/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || \
    cp "${ROOTFS}/boot/efi/EFI/BOOT/BOOTX64.EFI" "${ISO_STAGING}/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || \
    cp /boot/efi/EFI/centos/shimx64.efi "${ISO_STAGING}/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || \
    find "$ROOTFS" -name 'shimx64.efi' -exec cp {} "${ISO_STAGING}/EFI/BOOT/BOOTX64.EFI" \; 2>/dev/null || \
    log "WARNING: shimx64.efi not found"

find "$ROOTFS" -name 'grubx64.efi' -exec cp {} "${ISO_STAGING}/EFI/BOOT/grubx64.efi" \; 2>/dev/null || \
    log "WARNING: grubx64.efi not found"

# GRUB config
cat > "${ISO_STAGING}/EFI/BOOT/grub.cfg" << 'GRUBCFG'
set default=0
set timeout=5
set timeout_style=countdown

menuentry "KLDload Live (CentOS Stream 9 + ZFS)" --hotkey=l {
    linuxefi /images/pxeboot/vmlinuz root=live:CDLABEL=KLDLOAD rd.live.image rd.live.overlay.size=10240
    initrdefi /images/pxeboot/initrd.img
}

menuentry "KLDload Live (troubleshooting)" {
    linuxefi /images/pxeboot/vmlinuz root=live:CDLABEL=KLDLOAD rd.live.image rd.live.overlay.size=10240 rd.shell
    initrdefi /images/pxeboot/initrd.img
}
GRUBCFG

# Create EFI boot image (using mtools — no loop device needed in containers)
dd if=/dev/zero of="${ISO_STAGING}/images/efiboot.img" bs=1M count=10
mkfs.vfat "${ISO_STAGING}/images/efiboot.img"
mmd -i "${ISO_STAGING}/images/efiboot.img" ::EFI
mmd -i "${ISO_STAGING}/images/efiboot.img" ::EFI/BOOT
mcopy -i "${ISO_STAGING}/images/efiboot.img" "${ISO_STAGING}/EFI/BOOT/BOOTX64.EFI" ::EFI/BOOT/ 2>/dev/null || true
mcopy -i "${ISO_STAGING}/images/efiboot.img" "${ISO_STAGING}/EFI/BOOT/grubx64.efi" ::EFI/BOOT/ 2>/dev/null || true
mcopy -i "${ISO_STAGING}/images/efiboot.img" "${ISO_STAGING}/EFI/BOOT/grub.cfg" ::EFI/BOOT/

# Build ISO (EFI-only, no legacy BIOS)
xorriso -as mkisofs \
    -o "${OUTPUT_DIR}/${ISO_NAME}" \
    -R -J -joliet-long \
    -iso-level 3 \
    -V "KLDLOAD" \
    -e images/efiboot.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    "$ISO_STAGING" 2>&1 | tee -a "$LOG_FILE" || \
    die "xorriso failed"

# ---------------------------------------------------------------------------
# Checksum
# ---------------------------------------------------------------------------
log "Generating SHA256 checksum..."
(cd "$OUTPUT_DIR" && sha256sum "$ISO_NAME" > "${ISO_NAME}.sha256")

ISO_DEST="${OUTPUT_DIR}/${ISO_NAME}"
ISO_SIZE="$(du -sh "$ISO_DEST" | cut -f1)"
log "Build complete."
log "  ISO:      $ISO_DEST"
log "  Size:     $ISO_SIZE"
log "  Checksum: ${ISO_DEST}.sha256"
log "  Log:      $LOG_FILE"

echo "$ISO_DEST"
