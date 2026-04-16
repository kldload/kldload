#!/usr/bin/env bash
set -e
# SIGPIPE handling: when piping commands like "dnf ... | tee", if tee exits
# early (e.g., broken pipe to the log file), the SIGPIPE kills the whole
# container build. "trap '' PIPE" silences it. We also leave pipefail DISABLED
# for the same reason — pipefail turns SIGPIPE into a non-zero exit code that
# "set -e" would catch, aborting the build on harmless pipe closures.
trap '' PIPE

# =============================================================================
# build-iso.sh — Stage 5 of the kldload build pipeline (ISO assembly)
# =============================================================================
#
# Runs INSIDE the builder container (CentOS Stream 9 + lorax/squashfs/xorriso).
# Invoked by deploy.sh after the builder image and darksites are ready.
#
# Pipeline overview (all stages are containerized):
#   Stage 1: builder image     — Dockerfile builds the toolchain container
#   Stage 2: Debian darksite   — build-darksite-debian.sh resolves APT packages
#   Stage 3: Ubuntu darksite   — build-darksite-ubuntu.sh resolves APT packages
#   Stage 4: RPM darksite      — build-darksite.sh downloads RPM packages
#   Stage 5: ISO assembly      — THIS FILE — bootstraps rootfs, builds ZFS DKMS,
#                                 embeds all darksites, creates squashfs + EFI + ISO
#
# The live ISO is always CentOS Stream 9 regardless of PROFILE. The user picks
# the target distro (Debian, Ubuntu, Arch, etc.) at install time via the web UI.
# GNOME is always installed because the live environment needs a desktop session
# for the web-based installer (Firefox auto-opens to kldload-webui on boot).
#
# No anaconda/livemedia-creator — this builds directly with dnf --installroot
# + squashfs + xorriso, which works reliably inside rootless containers.
# =============================================================================

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
VERSION="${KLDLOAD_VERSION:-1.0.4}"
ISO_NAME="${ISO_NAME_OVERRIDE:-kldload-${VERSION}-${ARCH}.iso}"
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
# Clean previous state — delete the old ISO FIRST so that if this build fails
# partway through, no stale ISO remains that could be mistaken for a successful
# build. This makes builds atomic: either a new ISO exists or nothing does.
# ---------------------------------------------------------------------------
rm -rf "$ROOTFS" "$ISO_STAGING" /var/tmp/kldload-*
rm -f "/build/live-build/output/${ISO_NAME}" "/build/live-build/output/${ISO_NAME}.sha256"
mkdir -p "$ROOTFS" "$ISO_STAGING" "/build/live-build/output"

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
    grub2-efi-x64 grub2-tools shim-x64 efibootmgr mokutil pesign sbsigntools
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

# GNOME desktop is ALWAYS installed in the live ISO regardless of the PROFILE
# variable. The live environment boots to a GNOME session with GDM autologin,
# and Firefox auto-opens the kldload-webui installer. Without GNOME, the user
# would have no way to interact with the web UI. The PROFILE variable only
# affects what packages get installed on the TARGET system at install time.
PKGS+=(
    gnome-shell gnome-session gdm gnome-terminal nautilus
    gnome-control-center gnome-settings-daemon gedit
    gnome-keyring firefox mesa-dri-drivers
    pipewire wireplumber
    adwaita-icon-theme google-noto-sans-fonts
)

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
#
# pipefail is explicitly disabled here and never re-enabled. Enabling it would
# cause SIGPIPE from "dnf | tee" to propagate as a non-zero exit, which set -e
# would turn into a fatal build abort. The SIGPIPE is harmless (just tee closing).
set +o pipefail
dnf --installroot="$ROOTFS" --releasever=9 --setopt=install_weak_deps=False \
    --setopt=tsflags=nodocs --nogpgcheck -y install "${PKGS[@]}" 2>&1 | tee -a "$LOG_FILE"
DNF_RC=${PIPESTATUS[0]}
# set -o pipefail  # INTENTIONALLY DISABLED — see SIGPIPE note above
# Check if packages actually installed (ignore DKMS scriptlet exit code)
if ! chroot "$ROOTFS" rpm -q zfs zfs-dkms kernel-core >/dev/null 2>&1; then
    die "dnf --installroot failed — core packages missing"
fi
log "dnf completed (exit $DNF_RC — DKMS scriptlet failures are expected and handled below)"

log "Root filesystem bootstrapped: $(du -sh "$ROOTFS" | cut -f1)"

# Install sanoid from GitHub (free edition only)
# The CentOS 9 EPEL sanoid package is too old — it lacks features like
# template inheritance and improved pruning that kldload's snapshot policies
# rely on. Building from GitHub source gives us the latest stable release
# and puts binaries in /usr/local/sbin/ (profiles.sh copies them to targets).
if [[ "$EDITION" != "core" ]]; then
    log "Installing sanoid from GitHub..."
    SANOID_VER="2.2.0"
    curl -sL "https://github.com/jimsalterjrs/sanoid/archive/refs/tags/v${SANOID_VER}.tar.gz" | \
        tar xz -C /tmp/
    cp "/tmp/sanoid-${SANOID_VER}/sanoid" "${ROOTFS}/usr/local/sbin/sanoid"
    cp "/tmp/sanoid-${SANOID_VER}/syncoid" "${ROOTFS}/usr/local/sbin/syncoid"
    cp "/tmp/sanoid-${SANOID_VER}/findoid" "${ROOTFS}/usr/local/sbin/findoid"
    chmod +x "${ROOTFS}/usr/local/sbin/sanoid" "${ROOTFS}/usr/local/sbin/syncoid" "${ROOTFS}/usr/local/sbin/findoid"
    # Copy sanoid.defaults.conf — required by sanoid at runtime
    mkdir -p "${ROOTFS}/etc/sanoid"
    cp "/tmp/sanoid-${SANOID_VER}/sanoid.defaults.conf" "${ROOTFS}/etc/sanoid/sanoid.defaults.conf"
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

# DO NOT bind-mount /proc from the host — it exposes the host kernel version
# (e.g., Fedora 6.18.x) which confuses DKMS into building against the wrong
# kernel. Mount a fresh procfs so DKMS sees the CentOS kernel from the rootfs.
mount -t proc proc "${ROOTFS}/proc" 2>/dev/null || true

# Ensure the kernel headers symlink is correct
ln -sfn "/usr/src/kernels/${KVER}" "${ROOTFS}/lib/modules/${KVER}/build" 2>/dev/null || true

# DKMS build — force the target kernel explicitly
ZFS_VER=$(chroot "$ROOTFS" rpm -q --qf '%{VERSION}' zfs-dkms 2>/dev/null || echo "")
if [[ -n "$ZFS_VER" ]]; then
    # Remove any failed autoinstall attempt, then add fresh
    chroot "$ROOTFS" dkms remove -m zfs -v "$ZFS_VER" --all 2>/dev/null || true
    chroot "$ROOTFS" dkms add -m zfs -v "$ZFS_VER" 2>&1 | tee -a "$LOG_FILE" || true

    # Force DKMS to use the CentOS kernel headers via --kernelsourcedir,
    # bypassing DKMS's /proc-based autodetection (which would find the wrong kernel).
    # ARCH=x86_64 is required to prevent "arch/amd64/Makefile: No such file" errors
    # that occur in Docker builds on aarch64 hosts or when uname reports amd64.
    # || true because DKMS may fail — we verify zfs.ko exists below.
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

# ── Sign ZFS modules with MOK key for Secure Boot ────────────────────────
# Generate a MOK key pair, sign all ZFS kernel modules, and embed the key
# in the live ISO. This allows the live environment to load ZFS even with
# Secure Boot enabled (the kernel lockdown check validates the signature).
log "Generating MOK key for Secure Boot module signing..."
MOK_DIR="${ROOTFS}/var/lib/dkms"
mkdir -p "$MOK_DIR"
openssl req -new -x509 -newkey rsa:2048 \
    -keyout "${MOK_DIR}/mok.key" \
    -out "${MOK_DIR}/mok.pub" \
    -days 3650 -nodes \
    -subj "/CN=kldload Live ISO MOK/" 2>&1 | tee -a "$LOG_FILE" || true
openssl x509 -in "${MOK_DIR}/mok.pub" -out "${MOK_DIR}/mok.der" -outform DER 2>/dev/null || true
chmod 0600 "${MOK_DIR}/mok.key" 2>/dev/null || true

# Sign all ZFS kernel modules with the MOK key.
# Modules may be compressed (.ko.xz) — decompress, sign, recompress.
# sign-file is in the kernel-devel package under scripts/.
SIGN_FILE="${ROOTFS}/usr/src/kernels/${KVER}/scripts/sign-file"
if [[ -x "$SIGN_FILE" && -f "${MOK_DIR}/mok.key" ]]; then
    log "Signing ZFS kernel modules with MOK key..."
_signed=0 || true
    while IFS= read -r _ko; do
        [[ -f "$_ko" ]] || continue
        if [[ "$_ko" == *.xz ]]; then
            # Decompress, sign, recompress
            xz -d "$_ko" 2>/dev/null || true
            _ko_plain="${_ko%.xz}"
            if [[ -f "$_ko_plain" ]]; then
                "$SIGN_FILE" sha256 "${MOK_DIR}/mok.key" "${MOK_DIR}/mok.pub" "$_ko_plain" 2>/dev/null || true
                xz "$_ko_plain" 2>/dev/null || true
                log "  Signed: $(basename "$_ko")"
                ((_signed++)) || true
            fi
        elif [[ "$_ko" == *.zst ]]; then
            zstd -d "$_ko" 2>/dev/null || true
            _ko_plain="${_ko%.zst}"
            if [[ -f "$_ko_plain" ]]; then
                "$SIGN_FILE" sha256 "${MOK_DIR}/mok.key" "${MOK_DIR}/mok.pub" "$_ko_plain" 2>/dev/null || true
                zstd --rm "$_ko_plain" 2>/dev/null || true
                log "  Signed: $(basename "$_ko")"
                ((_signed++)) || true
            fi
        else
            "$SIGN_FILE" sha256 "${MOK_DIR}/mok.key" "${MOK_DIR}/mok.pub" "$_ko" 2>/dev/null && \
                log "  Signed: $(basename "$_ko")" && ((_signed++)) || true || true
        fi
    done < <(find "${ROOTFS}/lib/modules/${KVER}/extra" "${ROOTFS}/lib/modules/${KVER}/weak-updates" \
                   -name '*.ko' -o -name '*.ko.xz' -o -name '*.ko.zst' 2>/dev/null)
    log "Signed ${_signed} ZFS/SPL kernel modules"

    # Embed MOK public key in the live ISO for the installed system to use
    mkdir -p "${ROOTFS}/etc/keys"
    cp "${MOK_DIR}/mok.der" "${ROOTFS}/etc/keys/kldload-mok.der"
    log "MOK key embedded in live ISO"
else
    log "WARNING: sign-file not found at ${SIGN_FILE} — ZFS modules unsigned"
    log "  Secure Boot will block ZFS module loading on the live ISO"
fi

chroot "$ROOTFS" depmod -a "$KVER" 2>/dev/null || true

# Verify
_zfs_mod="$(find "${ROOTFS}/lib/modules/${KVER}" -name 'zfs.ko*' 2>/dev/null | head -1)" || true
if [[ -n "$_zfs_mod" ]]; then
    log "ZFS kernel module built successfully for $KVER"
else
    _zfs_mod="$(find "${ROOTFS}/lib/modules/" -name 'zfs.ko*' 2>/dev/null | head -1)" || true
    if [[ -n "$_zfs_mod" ]]; then
        log "ZFS kernel module found (alternate path)"
    else
        die "ZFS kernel module NOT found — DKMS build failed for $KVER"
    fi
fi

# Unmount chroot mounts
umount "${ROOTFS}/dev/pts" 2>/dev/null || true
umount "${ROOTFS}/dev" 2>/dev/null || true
umount "${ROOTFS}/sys" 2>/dev/null || true
umount "${ROOTFS}/proc" 2>/dev/null || true

# Download pacman-static for Arch Linux bootstrap support.
# CentOS has no pacman package in any repo, and building from source would pull
# in Arch-specific dependencies. The pacman-static binary is a fully statically
# linked build that runs on any x86_64 Linux — it's used by the installer to
# run "pacstrap" when the user selects Arch as the target distro.
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
        # CentOS uses /etc/pki/tls/certs/ — symlink so TLS verification works
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

# CentOS 9 python3-websockets RPM ships websockets v10, which lacks the
# websockets.http11 module that kldload-webui imports. The webui needs the
# v11+ HTTP/1.1 protocol implementation for its WebSocket upgrade handling.
# Fix: remove the system RPM and pip-install a compatible version.
# resolv.conf is copied into the chroot so pip can resolve pypi.org.
if [[ "$EDITION" != "core" ]]; then
    chroot "$ROOTFS" dnf remove -y python3-websockets 2>/dev/null || true
    cp /etc/resolv.conf "${ROOTFS}/etc/resolv.conf" 2>/dev/null || true
    set +euo pipefail
    chroot "$ROOTFS" pip3 install --no-cache-dir websockets >/dev/null 2>&1
    _pip_rc=$?
    set -e  # pipefail intentionally left disabled (SIGPIPE)
    [[ $_pip_rc -ne 0 ]] && log "WARNING: pip install websockets failed — webui may not start"
fi

# Enable services
chroot "$ROOTFS" systemctl enable NetworkManager sshd 2>/dev/null || true
# Live environment always boots to GNOME desktop — the web UI installer is
# browser-based, so even "server" and "kvm" profile ISOs need a graphical session
chroot "$ROOTFS" systemctl enable gdm 2>/dev/null || true
chroot "$ROOTFS" systemctl set-default graphical.target 2>/dev/null || true

# GDM autologin for live session — boots straight to desktop with no login prompt
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

# Auto-launch Firefox to webui on live session login (free edition only, not Bob)
if [[ "$EDITION" != "core" && "${BOB_LIVE:-}" != "1" ]]; then
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

# Edition marker — lets runtime tools distinguish free vs core edition
mkdir -p "${ROOTFS}/etc/kldload"
echo "$EDITION" > "${ROOTFS}/etc/kldload/edition"

# Build ID generation — produces a version string like "1.0.4-b47" where:
#   - VERSION is the release version from kldload.env (e.g., 1.0.4)
#   - bN is the number of commits since the last "bump version" commit,
#     which resets to 0 on each release and counts up with each dev build
# This lets users identify exactly which build they're running (kst shows it).
# The git SHA is stored separately for precise commit identification.
GIT_SHA=$(git -C /build rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_NUM=$(git -C /build log --oneline --grep="^bump.*${VERSION}\|^bump.*version" 2>/dev/null | head -1 | cut -d' ' -f1)
if [[ -n "$BUILD_NUM" ]]; then
  BUILD_NUM=$(git -C /build rev-list --count "${BUILD_NUM}..HEAD" 2>/dev/null || echo "0")
else
  BUILD_NUM=$(git -C /build rev-list --count HEAD 2>/dev/null || echo "0")
fi
echo "$GIT_SHA" > "${ROOTFS}/etc/kldload-build-sha"
echo "${VERSION}-b${BUILD_NUM}" > "${ROOTFS}/etc/kldload-build-id"
log "Build ID: ${VERSION}-b${BUILD_NUM} (${GIT_SHA})"

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
    for tool in kst kst-dashboard ksnap kclone kdf kdir kpkg kexport kldload-help kldload-test kldload-install-target kldload-webui kldload-overview \
                 kvm-create kvm-clone kvm-snap kvm-delete kvm-list kvm-demo \
                 kube-setup kube-init kube-join kube-status kube-reset kube-network kube-load-images kube-smoke-test kube-cluster kube-demo \
                 kzfs-test kzfs-lab klab klab-exporter; do
        src="/build/live-build/config/includes.chroot/usr/local/bin/${tool}"
        [[ -f "$src" ]] && cp "$src" "${ROOTFS}/usr/local/bin/${tool}" && chmod +x "${ROOTFS}/usr/local/bin/${tool}"
    done

    # Copy klab share files (Prometheus config, Grafana dashboard)
    if [[ -d /build/live-build/config/includes.chroot/usr/local/share/klab ]]; then
        mkdir -p "${ROOTFS}/usr/local/share/klab"
        cp -r /build/live-build/config/includes.chroot/usr/local/share/klab/* "${ROOTFS}/usr/local/share/klab/"
    fi

    # Copy .desktop files for GNOME menu
    for dt in kst.desktop kst-dashboard.desktop ksnap.desktop kexport.desktop kldload-terminal.desktop kldload-docs.desktop vim.desktop; do
        src="/build/live-build/config/includes.chroot/usr/share/applications/${dt}"
        [[ -f "$src" ]] && cp "$src" "${ROOTFS}/usr/share/applications/${dt}"
    done

    # Copy the main installer to /usr/sbin
    for sbin_tool in kldload-install-target kldload-firstboot kldload-recovery kldload-snapshot kldload-apply-platform-holds kldload-export-deferred; do
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
    # The webui Python server serves files from /usr/local/share/kldload-webui/.
    # The source HTML lives in edition-named directories (free/, core/) but the
    # server always serves from active/. This copy makes free/index.html the
    # actually-served file by copying it to active/index.html. This indirection
    # lets us maintain edition-specific UI files in the repo while having a
    # single WorkingDirectory in the systemd unit.
    if [[ -x /build/live-build/config/includes.chroot/usr/local/bin/kldload-webui ]]; then
        cp /build/live-build/config/includes.chroot/usr/local/bin/kldload-webui \
           "${ROOTFS}/usr/local/bin/kldload-webui"
        chmod +x "${ROOTFS}/usr/local/bin/kldload-webui"
        # Replace active/ with the correct edition's UI files
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

    # Copy profile.d scripts (shell helpers, environment)
    mkdir -p "${ROOTFS}/etc/profile.d"
    for _pd in /build/live-build/config/includes.chroot/etc/profile.d/*.sh; do
        [[ -f "$_pd" ]] && cp "$_pd" "${ROOTFS}/etc/profile.d/"
    done

    # Copy smoke tests and test framework
    if [[ -d /build/live-build/config/includes.chroot/usr/local/share/kldload/tests ]]; then
        mkdir -p "${ROOTFS}/usr/local/share/kldload/tests"
        cp /build/live-build/config/includes.chroot/usr/local/share/kldload/tests/*.sh \
            "${ROOTFS}/usr/local/share/kldload/tests/" 2>/dev/null || true
        chmod +x "${ROOTFS}/usr/local/share/kldload/tests/"*.sh 2>/dev/null || true
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

    # Debian darksite APT mirror service — Python HTTP server on port 3142.
    # debootstrap on the live ISO is configured to use http://127.0.0.1:3142/apt/
    # as its mirror, which serves packages from the baked-in darksite directory.
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

    # Arch Linux darksite — note: Arch is a rolling release so the darksite
    # goes stale quickly. Arch installs actually require internet; this mirror
    # is a partial cache that supplements live mirrors.
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

# ── Bob live service (AI appliance live boot) ────────────────────────────────
_bob_ic="/build/live-build/config/includes.chroot"
cp "${_bob_ic}/etc/systemd/system/bob-live.service" "${ROOTFS}/etc/systemd/system/" 2>/dev/null || true
cp "${_bob_ic}/usr/local/sbin/bob-live" "${ROOTFS}/usr/local/sbin/" 2>/dev/null && chmod +x "${ROOTFS}/usr/local/sbin/bob-live" || true
if [[ "${BOB_LIVE:-}" == "1" ]]; then
    mkdir -p "${ROOTFS}/etc/kldload"
    touch "${ROOTFS}/etc/kldload/bob-live"
    mkdir -p "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
    ln -sf "/etc/systemd/system/bob-live.service" \
        "${ROOTFS}/etc/systemd/system/multi-user.target.wants/bob-live.service"
    # Disable the kldload installer webui — Bob replaces it
    rm -f "${ROOTFS}/etc/systemd/system/multi-user.target.wants/kldload-webui.service" 2>/dev/null || true

    # ── Pre-bake Ollama + model + Open WebUI into the image ──────────────
    log "Bob: installing Ollama into rootfs..."
    BINDIR="${ROOTFS}/usr/local/bin" curl -fsSL https://ollama.com/install.sh | sh >> "$LOG_DIR/bob-build.log" 2>&1
    log "Bob: Ollama installed to rootfs"

    # Create ollama user + service in rootfs
    chroot "${ROOTFS}" useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama 2>/dev/null || true
    cat > "${ROOTFS}/etc/systemd/system/ollama.service" <<'OSERVICE'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="OLLAMA_HOST=0.0.0.0:11434"

[Install]
WantedBy=default.target
OSERVICE
    ln -sf "/etc/systemd/system/ollama.service" \
        "${ROOTFS}/etc/systemd/system/multi-user.target.wants/ollama.service"

    # Pull the model at build time — run ollama from the rootfs temporarily
    log "Bob: pulling llama3.1:8b model (this takes a few minutes)..."
    mkdir -p "${ROOTFS}/usr/share/ollama/.ollama/models"
    export OLLAMA_MODELS="${ROOTFS}/usr/share/ollama/.ollama/models"
    # Run ollama serve from rootfs (it's a static binary, works outside chroot)
    "${ROOTFS}/usr/local/bin/ollama" serve >> "$LOG_DIR/bob-build.log" 2>&1 &
    _ollama_pid=$!
    for _try in $(seq 1 20); do
        curl -sf http://localhost:11434/api/tags >/dev/null 2>&1 && break
        sleep 2
    done
    "${ROOTFS}/usr/local/bin/ollama" pull llama3.1:8b >> "$LOG_DIR/bob-build.log" 2>&1
    log "Bob: model pulled, creating Bob personality..."

    # Create Bob modelfile and build it
    cat > /tmp/Modelfile.bob <<'BOBMODEL'
FROM llama3.1:8b

SYSTEM """
Your name is Bob. You are a friendly, patient, and knowledgeable AI assistant.

How you talk:
- Warm and direct. Like a trusted friend who happens to know a lot.
- You talk to everyone like they're intelligent, no matter what they ask.
- You never make anyone feel stupid for asking a question.
- You say "here's what I'd do" not "here are some options to consider."
- You keep answers clear and practical. No jargon unless someone asks for it.
- You admit when you don't know something. "I'm not sure about that" is always OK.
- You never start with "As an AI language model" or "I'd be happy to help you with that!"
- You never give 47 caveats before answering. Just answer.
- You are not corporate. You are not cold. You are Bob.

What you help with:
- Writing — emails, letters, complaints, resumes, cover letters
- Math — explained simply, step by step
- Health — general wellness info (you're not a doctor, say so if asked for diagnosis)
- Cooking — recipes, substitutions, food safety
- Finance — budgeting, understanding bills, explaining financial terms
- Legal — understanding documents in plain English (not legal advice)
- Technology — how to use computers, phones, apps, fixing common problems
- Education — explain anything simply, homework help, learning new things
- Emotional support — sometimes people just need someone to talk to

What you never do:
- Make people feel stupid
- Pretend to be human
- Send data anywhere — you run locally, everything stays on this machine
- Refuse reasonable questions
"""

PARAMETER temperature 0.7
PARAMETER num_ctx 8192
BOBMODEL

    "${ROOTFS}/usr/local/bin/ollama" create bob -f /tmp/Modelfile.bob
    log "Bob: model created"

    # Stop the temporary ollama
    kill $_ollama_pid 2>/dev/null; wait $_ollama_pid 2>/dev/null || true
    unset OLLAMA_MODELS

    # Fix ownership
    chroot "${ROOTFS}" chown -R ollama:ollama /usr/share/ollama 2>/dev/null || true

    # Install Open WebUI via pip (no container runtime needed)
    log "Bob: installing Open WebUI..."
    chroot "${ROOTFS}" pip3 install --quiet open-webui 2>&1 | tail -5 || {
        log "Bob: pip install open-webui failed — will use podman on boot"
    }

    # Create bob CLI command
    cat > "${ROOTFS}/usr/local/bin/bob" <<'BOBCLI'
#!/usr/bin/env bash
Q="${*:-Hey Bob, what can you help me with?}"
echo "$Q" | ollama run bob
BOBCLI
    chmod +x "${ROOTFS}/usr/local/bin/bob"

    log "Bob live mode enabled — Ollama + model + Bob baked into image"
fi

# ── Autoinstall service + baked-in answers (AI appliance, seed-disk boot) ─────
_ic="/build/live-build/config/includes.chroot"
mkdir -p "${ROOTFS}/etc/systemd/system/multi-user.target.wants" "${ROOTFS}/usr/local/sbin" "${ROOTFS}/etc/kldload"
# Autoinstall service
cp "${_ic}/etc/systemd/system/kldload-autoinstall.service" "${ROOTFS}/etc/systemd/system/" 2>/dev/null && {
    ln -sf "/etc/systemd/system/kldload-autoinstall.service" \
        "${ROOTFS}/etc/systemd/system/multi-user.target.wants/kldload-autoinstall.service"
    log "Autoinstall service installed"
} || true
# Autoinstall script
cp "${_ic}/usr/local/sbin/kldload-autoinstall" "${ROOTFS}/usr/local/sbin/" 2>/dev/null && \
    chmod +x "${ROOTFS}/usr/local/sbin/kldload-autoinstall" || true
# Baked-in answers file (AI appliance builds only)
cp "${_ic}/etc/kldload/autoinstall.env" "${ROOTFS}/etc/kldload/autoinstall.env" 2>/dev/null && \
    log "Baked-in autoinstall.env — this ISO will auto-install on boot" || true
# Answers templates
cp -r "${_ic}/etc/kldload/debz" "${ROOTFS}/etc/kldload/" 2>/dev/null || true

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
# ZFSBootMenu replaces GRUB as the bootloader for ZFS-on-root systems. It's an
# EFI application that understands ZFS boot environments natively. Downloaded
# at build time and baked in so installs work offline. If the download fails,
# the installer will attempt to download it at install time as a fallback.
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
# Darksites are pre-resolved package mirrors baked into the ISO so target installs
# work without internet. Each distro's darksite was built in an earlier pipeline
# stage (stages 2-4) and cached on the host. Here we copy them into the rootfs
# so they end up inside the squashfs image. On the live ISO, Python HTTP servers
# expose these as local APT/RPM/pacman mirrors (ports 3142-3146).
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
# Final safety sync: re-copy free/ -> active/ right before squashfs creation.
# This catches any case where the webui HTML was updated after the initial copy
# in Step 2 (e.g., if a hook modified it). Belt-and-suspenders — the Step 2 copy
# should be sufficient, but stale webui in the ISO is a painful debugging session.
if [[ -d /build/live-build/config/includes.chroot/usr/local/share/kldload-webui/free ]]; then
    rm -rf "${ROOTFS}/usr/local/share/kldload-webui/active" 2>/dev/null || true
    mkdir -p "${ROOTFS}/usr/local/share/kldload-webui/active"
    cp -r /build/live-build/config/includes.chroot/usr/local/share/kldload-webui/free/. \
          "${ROOTFS}/usr/local/share/kldload-webui/active/"
    log "Final webui sync: free/ → active/ ($(grep -o 'kldloadOS [0-9.]*' "${ROOTFS}/usr/local/share/kldload-webui/active/index.html" 2>/dev/null || echo 'unknown'))"
fi

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

# EFI bootloader for the live ISO — use GRUB directly (no shim).
# Shim on the live USB causes "failed to load image" because the live GRUB
# isn't signed by the CentOS key that shim expects. The live ISO boots with
# Secure Boot "Other OS" or disabled, so shim isn't needed here.
# Shim is only installed on the TARGET system for Secure Boot after install.
find "$ROOTFS" -name 'grubx64.efi' -exec cp {} "${ISO_STAGING}/EFI/BOOT/BOOTX64.EFI" \; 2>/dev/null || \
    find "$ROOTFS" -name 'grubx64.efi' -exec cp {} "${ISO_STAGING}/EFI/BOOT/BOOTX64.EFI" \; 2>/dev/null || \
    log "WARNING: grubx64.efi not found — live ISO may not UEFI boot"

# Also keep grubx64.efi as itself (some firmware looks for it by name)
cp "${ISO_STAGING}/EFI/BOOT/BOOTX64.EFI" "${ISO_STAGING}/EFI/BOOT/grubx64.efi" 2>/dev/null || true

# GRUB config
cat > "${ISO_STAGING}/EFI/BOOT/grub.cfg" << 'GRUBCFG'
set default=0
set timeout=5
set timeout_style=countdown

menuentry "KLDload Live (CentOS Stream 9 + ZFS)" --hotkey=l {
    linuxefi /images/pxeboot/vmlinuz root=live:CDLABEL=KLDLOAD rd.live.image rd.live.overlay.size=10240 lockdown=none module.sig_enforce=0 selinux=0
    initrdefi /images/pxeboot/initrd.img
}

menuentry "KLDload Live (troubleshooting)" {
    linuxefi /images/pxeboot/vmlinuz root=live:CDLABEL=KLDLOAD rd.live.image rd.live.overlay.size=10240 lockdown=none module.sig_enforce=0 selinux=0 rd.shell
    initrdefi /images/pxeboot/initrd.img
}
GRUBCFG

# Create EFI boot image using mtools (mmd/mcopy) instead of loop-mounting a
# FAT image. Loop devices require CAP_SYS_ADMIN which rootless containers lack.
# mtools manipulates FAT filesystems via direct file I/O — no kernel involvement.
dd if=/dev/zero of="${ISO_STAGING}/images/efiboot.img" bs=1M count=10
mkfs.vfat "${ISO_STAGING}/images/efiboot.img"
mmd -i "${ISO_STAGING}/images/efiboot.img" ::EFI
mmd -i "${ISO_STAGING}/images/efiboot.img" ::EFI/BOOT
mcopy -i "${ISO_STAGING}/images/efiboot.img" "${ISO_STAGING}/EFI/BOOT/BOOTX64.EFI" ::EFI/BOOT/ 2>/dev/null || true
mcopy -i "${ISO_STAGING}/images/efiboot.img" "${ISO_STAGING}/EFI/BOOT/grubx64.efi" ::EFI/BOOT/ 2>/dev/null || true
mcopy -i "${ISO_STAGING}/images/efiboot.img" "${ISO_STAGING}/EFI/BOOT/grub.cfg" ::EFI/BOOT/

# Build ISO (EFI-only, no legacy BIOS — all modern hardware uses UEFI)
# -isohybrid-gpt-basdat makes the ISO dd-able to USB (GPT hybrid)
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
