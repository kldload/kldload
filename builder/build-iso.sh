#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# build-iso.sh — runs INSIDE the builder container
# Builds a CentOS Stream 9 live ISO using dnf --installroot + squashfs + lorax
# No anaconda/livemedia-creator — works reliably inside containers.
# ---------------------------------------------------------------------------

PROFILE="${PROFILE:-desktop}"
EDITION="free"
ARCH="${ARCH:-x86_64}"
OUTPUT_DIR="${OUTPUT_DIR:-/build/live-build/output}"
LOG_DIR="${LOG_DIR:-/build/live-build/logs}"
BUILD_ROOT="/build"
BUILD_DATE="$(date +%Y%m%d)"

ROOTFS="/var/tmp/kldload-rootfs"
ISO_STAGING="/var/tmp/kldload-iso"
ISO_NAME="kldload-${EDITION}-${ARCH}-${BUILD_DATE}.iso"
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
# Build darksite RPM mirror
# ---------------------------------------------------------------------------
DARKSITE_SCRIPT="${BUILD_ROOT}/build/darksite/build-darksite.sh"
if [[ -x "$DARKSITE_SCRIPT" ]]; then
    log "Building darksite RPM mirror..."
    bash "$DARKSITE_SCRIPT" 2>&1 | tee -a "$LOG_FILE"
fi

# ---------------------------------------------------------------------------
# Step 1: Bootstrap CentOS root filesystem with dnf --installroot
# ---------------------------------------------------------------------------
log "Bootstrapping CentOS Stream 9 root filesystem..."

# Install base + profile packages
PKGS=(
    basesystem filesystem setup
    dnf rpm coreutils bash glibc glibc-langpack-en
    systemd systemd-udev dbus-daemon
    kernel kernel-core kernel-modules kernel-devel dracut dracut-live dracut-squash
    grub2-efi-x64 grub2-tools shim-x64 efibootmgr mokutil
    NetworkManager openssh-server openssh-clients sudo
    vim-enhanced tmux curl wget rsync jq less tar gzip
    iproute iputils net-tools nftables chrony
    passwd shadow-utils util-linux procps-ng findutils grep sed gawk
    rootfiles parted gdisk dosfstools
    python3 python3-pip python3-websockets python3-pyyaml
    htop pv lzop mbuffer
    perl-Config-IniFiles perl-Capture-Tiny
    # ZFS — DKMS build (kmod-zfs requires exact kernel match)
    dkms gcc make autoconf automake libtool
    zfs zfs-dkms
    # Cross-distro installer (debootstrap for Debian targets from CentOS live)
    debootstrap
    # Guest agents
    qemu-guest-agent open-vm-tools-desktop
)

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

dnf --installroot="$ROOTFS" --releasever=9 --setopt=install_weak_deps=False \
    --setopt=tsflags=nodocs --nogpgcheck -y install "${PKGS[@]}" 2>&1 | tee -a "$LOG_FILE" || \
    die "dnf --installroot failed"

log "Root filesystem bootstrapped: $(du -sh "$ROOTFS" | cut -f1)"

# Install sanoid from GitHub (not in EPEL for EL9)
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

# ---------------------------------------------------------------------------
# Step 1b: Build ZFS DKMS module inside the rootfs
# ---------------------------------------------------------------------------
KVER=$(ls "${ROOTFS}/lib/modules/" | grep -v '^$' | head -1)
log "Kernel version: $KVER"
log "Building ZFS DKMS module for $KVER..."

# Chroot needs /proc, /sys, /dev for DKMS
mount -t proc proc "${ROOTFS}/proc"
mount -t sysfs sysfs "${ROOTFS}/sys"
mount --bind /dev "${ROOTFS}/dev"
mount --bind /dev/pts "${ROOTFS}/dev/pts"

# DKMS build
ZFS_VER=$(chroot "$ROOTFS" rpm -q --qf '%{VERSION}' zfs-dkms 2>/dev/null || echo "")
if [[ -n "$ZFS_VER" ]]; then
    chroot "$ROOTFS" dkms add -m zfs -v "$ZFS_VER" 2>&1 | tee -a "$LOG_FILE" || true
    chroot "$ROOTFS" dkms build -m zfs -v "$ZFS_VER" -k "$KVER" 2>&1 | tee -a "$LOG_FILE" || \
        log "WARNING: DKMS build failed"
    chroot "$ROOTFS" dkms install -m zfs -v "$ZFS_VER" -k "$KVER" 2>&1 | tee -a "$LOG_FILE" || \
        log "WARNING: DKMS install failed"
fi

chroot "$ROOTFS" depmod -a "$KVER" 2>/dev/null || true

# Verify
if find "${ROOTFS}/lib/modules/${KVER}" -name 'zfs.ko*' 2>/dev/null | grep -q .; then
    log "ZFS kernel module built successfully for $KVER"
else
    log "WARNING: ZFS kernel module not found after DKMS build"
fi

# Unmount chroot mounts
umount "${ROOTFS}/dev/pts" 2>/dev/null || true
umount "${ROOTFS}/dev" 2>/dev/null || true
umount "${ROOTFS}/sys" 2>/dev/null || true
umount "${ROOTFS}/proc" 2>/dev/null || true

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

# Fix websockets — CentOS ships old version that's incompatible with webui
# Remove the system package, install latest via pip
chroot "$ROOTFS" dnf remove -y python3-websockets 2>/dev/null || true
chroot "$ROOTFS" pip3 install websockets 2>&1 | tail -2 || true

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

# Auto-launch Firefox to webui on live session login
if [[ "$PROFILE" == "desktop" ]]; then
    # GDM PostLogin script — most reliable on CentOS
    mkdir -p "${ROOTFS}/etc/gdm/PostLogin"
    cat > "${ROOTFS}/etc/gdm/PostLogin/Default" << 'POSTLOGIN'
#!/bin/sh
# Wait for GNOME shell to settle, then launch Firefox to the installer
(sleep 5 && su - live -c 'DISPLAY=:0 firefox http://localhost:8080' &) &
POSTLOGIN
    chmod +x "${ROOTFS}/etc/gdm/PostLogin/Default"

    # XDG autostart as backup
    mkdir -p "${ROOTFS}/etc/xdg/autostart"
    cat > "${ROOTFS}/etc/xdg/autostart/kldload-webui.desktop" << 'AUTOSTART'
[Desktop Entry]
Type=Application
Name=kldload Web UI
Exec=firefox http://localhost:8080
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
AUTOSTART

    # Disable screensaver / screen blank / auto-lock on live session
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
    chroot "$ROOTFS" dconf update 2>/dev/null || true
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

# Copy kldload tools (short names)
for tool in kst ksnap kclone kdf kdir kpkg kldload-install-target kldload-webui; do
    src="/build/live-build/config/includes.chroot/usr/local/bin/${tool}"
    [[ -f "$src" ]] && cp "$src" "${ROOTFS}/usr/local/bin/${tool}" && chmod +x "${ROOTFS}/usr/local/bin/${tool}"
done

# Copy the main installer to /usr/sbin
for sbin_tool in kldload-install-target kldload-firstboot kldload-recovery kldload-apply-platform-holds; do
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

# Copy virtio modules config
mkdir -p "${ROOTFS}/etc/modules-load.d"
[[ -f /build/live-build/config/includes.chroot/etc/modules-load.d/virtio.conf ]] && \
    cp /build/live-build/config/includes.chroot/etc/modules-load.d/virtio.conf "${ROOTFS}/etc/modules-load.d/"

# Copy webui binary + static files
if [[ -x /build/live-build/config/includes.chroot/usr/local/bin/kldload-webui ]]; then
    # Use kldload-webui as-is for now (works on any distro — it's Python)
    cp /build/live-build/config/includes.chroot/usr/local/bin/kldload-webui \
       "${ROOTFS}/usr/local/bin/kldload-webui"
    chmod +x "${ROOTFS}/usr/local/bin/kldload-webui"
    # Copy webui static files
    if [[ -d /build/live-build/config/includes.chroot/usr/local/share/kldload-webui/active ]]; then
        mkdir -p "${ROOTFS}/usr/local/share/kldload-webui"
        cp -r /build/live-build/config/includes.chroot/usr/local/share/kldload-webui/active/. \
              "${ROOTFS}/usr/local/share/kldload-webui/"
    fi
fi

# Copy snapshot scripts
for script in snapshot-create.sh snapshot-prune.sh snapshot-policy.sh; do
    src="/build/live-build/config/includes.chroot/usr/local/sbin/${script}"
    [[ -f "$src" ]] && cp "$src" "${ROOTFS}/usr/local/sbin/${script}" && chmod +x "${ROOTFS}/usr/local/sbin/${script}"
done

# Copy adduser hook (works the same — useradd on CentOS triggers /usr/local/sbin/useradd.local)
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

# Copy darksite RPM repo into the rootfs for offline target installs
if [[ -d /build/live-build/config/includes.chroot/root/darksite ]]; then
    mkdir -p "${ROOTFS}/root/darksite"
    cp -r /build/live-build/config/includes.chroot/root/darksite/. "${ROOTFS}/root/darksite/"
    log "Darksite repo copied to rootfs: $(du -sh "${ROOTFS}/root/darksite" 2>/dev/null | cut -f1)"
fi

# Download ZFSBootMenu EFI binary into darksite for offline installs
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
    --no-hostonly --kver "$KVER" "/boot/initramfs-${KVER}.img" 2>&1 | tee -a "$LOG_FILE" || \
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
    linuxefi /images/pxeboot/vmlinuz root=live:CDLABEL=KLDLOAD rd.live.image
    initrdefi /images/pxeboot/initrd.img
}

menuentry "KLDload Live (troubleshooting)" {
    linuxefi /images/pxeboot/vmlinuz root=live:CDLABEL=KLDLOAD rd.live.image rd.shell
    initrdefi /images/pxeboot/initrd.img
}
GRUBCFG

# Create EFI boot image
dd if=/dev/zero of="${ISO_STAGING}/images/efiboot.img" bs=1M count=10
mkfs.vfat "${ISO_STAGING}/images/efiboot.img"
mkdir -p /tmp/efi-mount
mount "${ISO_STAGING}/images/efiboot.img" /tmp/efi-mount
mkdir -p /tmp/efi-mount/EFI/BOOT
cp "${ISO_STAGING}/EFI/BOOT/BOOTX64.EFI" /tmp/efi-mount/EFI/BOOT/ 2>/dev/null || true
cp "${ISO_STAGING}/EFI/BOOT/grubx64.efi" /tmp/efi-mount/EFI/BOOT/ 2>/dev/null || true
cp "${ISO_STAGING}/EFI/BOOT/grub.cfg" /tmp/efi-mount/EFI/BOOT/
umount /tmp/efi-mount

# Build ISO (EFI-only, no legacy BIOS)
xorriso -as mkisofs \
    -o "${OUTPUT_DIR}/${ISO_NAME}" \
    -R -J -joliet-long \
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
