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
# Runs INSIDE the builder container (Fedora 44 + lorax/squashfs/xorriso).
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
# The live ISO is always Fedora 44 regardless of PROFILE. The user picks
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

# Derive arch-specific names used by different upstream projects. EFI, Debian,
# Helm, Go releases, Alpine repos all spell "aarch64" differently — centralise
# the translation so the rest of the script stays readable.
case "$ARCH" in
    x86_64)
        ARCH_EFI="x64"         # grub2-efi-x64, shim-x64, BOOTX64.EFI
        ARCH_DEB="amd64"       # helm linux-amd64.tar.gz, Debian arm64 vs amd64
        ARCH_DKMS="x86_64"     # kernel DKMS ARCH= value
        ARCH_ALPINE="x86_64"
        ;;
    aarch64|arm64)
        ARCH="aarch64"         # canonical name inside the script
        ARCH_EFI="aa64"        # grub2-efi-aa64, shim-aa64, BOOTAA64.EFI
        ARCH_DEB="arm64"
        ARCH_DKMS="arm64"
        ARCH_ALPINE="aarch64"
        ;;
    *)
        echo "ERROR: unsupported ARCH=$ARCH (x86_64 or aarch64 only)" >&2
        exit 1
        ;;
esac
OUTPUT_DIR="${OUTPUT_DIR:-/build/live-build/output}"
LOG_DIR="${LOG_DIR:-/build/live-build/logs}"
BUILD_ROOT="/build"
BUILD_DATE="$(date +%Y%m%d)"

ROOTFS="/var/tmp/kldload-rootfs"
ISO_STAGING="/var/tmp/kldload-iso"
DISTRO_TAG="${DISTRO:-fedora}"
VERSION="${KLDLOAD_VERSION:-1.1.0}"
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
log "Bootstrapping Fedora 44 root filesystem..."

# Install base + profile packages
# Core packages: minimal OS + ZFS on root (both editions)
PKGS=(
    basesystem filesystem setup
    dnf rpm coreutils bash glibc glibc-langpack-en
    systemd systemd-pam systemd-udev dbus-broker
    kernel kernel-core kernel-modules kernel-devel dracut dracut-live dracut-squash
    grub2-efi-${ARCH_EFI} grub2-tools shim-${ARCH_EFI} efibootmgr mokutil pesign sbsigntools
    NetworkManager NetworkManager-wifi wpa_supplicant openssh-server openssh-clients sudo
    vim-enhanced tmux curl wget rsync jq less tar gzip
    iproute iputils net-tools nftables chrony
    # Hardware support — WiFi firmware, storage controllers, USB, etc.
    # F43+ split linux-firmware: bare `linux-firmware` carries only licenses,
    # actual blobs live in per-vendor sub-packages. `iwl*-firmware` glob
    # catches iwlwifi-{dvm,mvm,mld}-firmware + iwlegacy-firmware on F44, but
    # we also need realtek/atheros explicitly (don't start with `iwl`).
    # Without these, modern Intel AX/BE wifi cards and any Realtek/Atheros
    # chipset boot the live env with no wifi device — `nmcli device` is empty
    # even though the card is in lspci. See feedback_fedora_firmware_split.md.
    linux-firmware
    iwlwifi-dvm-firmware iwlwifi-mvm-firmware iwlwifi-mld-firmware
    iwlegacy-firmware
    realtek-firmware atheros-firmware
    passwd shadow-utils util-linux procps-ng findutils grep sed gawk
    rootfiles parted gdisk dosfstools
    # nginx — single TLS reverse proxy on :8443 for every browser-facing
    # service. Needed on the LIVE ISO too, not just the target, so the
    # installer webui is reachable at https://<host>:8443/ from first boot
    # without waiting for a dnf install. Replaces the 1.0.5 Python
    # kldload-proxy; HTTP/2 eliminates the cert-trust flicker class.
    nginx
    # Live environment disk & diagnostic tools
    hdparm smartmontools nvme-cli
    lshw dmidecode pciutils usbutils
    nmap-ncat tcpdump iperf3 ethtool
    blktrace iotop sysstat strace
    xfsprogs e2fsprogs btrfs-progs mdadm lvm2 cryptsetup
    fio bonnie++ stress-ng memtest86+
    # Rescue / repair toolset — for fixing kldload boxes that won't boot
    # (broken initramfs, corrupted GPT, dead BE, accidentally-wiped ESP).
    # Without these, a user has to boot a separate rescue USB to recover.
    # ~30MB total, fits the use case where the kldload USB IS the rescue
    # USB. gparted brings the GTK partition GUI; testdisk includes
    # photorec for data recovery; ddrescue is the canonical bad-block
    # cloner; fsarchiver does compressed filesystem snapshots.
    gparted testdisk ddrescue fsarchiver
    # File restoration helpers (exfat/ntfs read-write for cross-OS rescue,
    # 7zip/p7zip for extracting Windows recovery images).
    exfatprogs ntfsprogs p7zip p7zip-plugins
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
        # Ansible — replaces cloud-init runcmd for golden VM provisioning
        # and powers the web UI's Ansible tab
        ansible-core
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
    # Monospace fonts — without these, fc-match monospace falls back to
    # NotoSans (proportional), and the GNOME Terminal renders with
    # variable-width glyphs. F44 + GNOME 50 doesn't pull these as weak
    # deps when --setopt=install_weak_deps=False is set.
    dejavu-sans-mono-fonts liberation-mono-fonts google-noto-sans-mono-fonts
    # Bob's voice/audio stack (from bob-ai). pipewire is already above;
    # these add pulseaudio shims for apps that speak PA, sox for audio
    # pipeline helpers, espeak-ng as a fallback TTS, alsa-utils for
    # arecord (which bob-voice uses), and cmake + gcc-c++ to compile
    # whisper.cpp below. wl-clipboard for Wayland clipboard access.
    pipewire-pulseaudio pulseaudio-utils
    alsa-utils espeak-ng sox wl-clipboard
    cmake gcc-c++
)

# Set up repos inside the installroot
mkdir -p "${ROOTFS}/etc/yum.repos.d" "${ROOTFS}/etc/pki/rpm-gpg"

cat > "${ROOTFS}/etc/yum.repos.d/fedora.repo" << 'FEDOREPO'
[fedora]
name=Fedora 44 - $basearch
metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-$releasever&arch=$basearch
gpgcheck=0
enabled=1

[updates]
name=Fedora 44 - $basearch - Updates
metalink=https://mirrors.fedoraproject.org/metalink?repo=updates-released-f$releasever&arch=$basearch
gpgcheck=0
enabled=1
FEDOREPO

# ZFS source — OpenZFS 2.4 from zfsonlinux.org.
#
# zfsonlinux.org publishes fc41/fc42/fc43 but not fc44 yet (Fedora 44
# GA was 2026-04-28). zfs-dkms is a noarch source package that DKMS
# rebuilds against the running kernel — so the fc43 tag is purely
# cosmetic for it. The userspace libs (libzfs7/libnvpair3/libzpool7)
# are fc43-built but glibc forward-compat means they run fine on fc44.
#
# The hardcoded `fedora/43/` path is intentional and stays until
# zfsonlinux publishes fc44 binaries — at which point flip to
# `fedora/$releasever/`.
cat > "${ROOTFS}/etc/yum.repos.d/zfs.repo" << 'ZFSREPO'
[zfs]
name=OpenZFS 2.4 for Fedora (using fc43 packages — fc44 not yet published)
baseurl=http://download.zfsonlinux.org/2.4/fedora/43/$basearch/
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
# IMPORTANT: --exclude='kernel-*-7.*' pins the F44 live env to kernel 6.19.x.
# Fedora 44 updates pushed kernel-core-7.0.4 around 2026-05-07 (the day matrix
# #4 went 0/15 from 3/15 — exactly the regression session handoff predicted).
# The fc43 zfs-dkms-2.4.1 carries `Conflicts: kernel-uname-r > 6.19.999`, so
# pulling kernel 7.0 alongside zfs-dkms fails dependency resolution and aborts
# the whole build. We pin updates kernels at 6.19.x until either:
#   (a) zfsonlinux.org publishes an fc44 build for OpenZFS 2.4 or 2.5, OR
#   (b) we ship our own zfs-dkms rebuild that drops the kernel-uname-r cap.
# When that happens, remove the --exclude flags here. Until then, 6.19.x is
# the highest kernel the live ISO can carry.
dnf --installroot="$ROOTFS" --releasever=44 --setopt=install_weak_deps=False \
    --exclude='kernel-7.*' --exclude='kernel-core-7.*' \
    --exclude='kernel-modules-7.*' --exclude='kernel-modules-core-7.*' \
    --exclude='kernel-devel-7.*' --exclude='kernel-devel-matched-7.*' \
    --exclude='kernel-headers-7.*' --exclude='kernel-tools-7.*' \
    --exclude='kernel-tools-libs-7.*' \
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

    # Install eza from GitHub (not in EPEL). Eza publishes both x86_64 and
    # aarch64 "unknown-linux-gnu" release tarballs — naming matches rustc
    # targets exactly, so $ARCH works as-is.
    log "Installing eza from GitHub..."
    EZA_VER="$(curl -fsSL https://api.github.com/repos/eza-community/eza/releases/latest 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')" || true
    if [[ -n "$EZA_VER" ]]; then
        curl -fsSL "https://github.com/eza-community/eza/releases/download/v${EZA_VER}/eza_${ARCH}-unknown-linux-gnu.tar.gz" \
            | tar xz -C "${ROOTFS}/usr/local/bin/" 2>/dev/null || \
            log "WARNING: eza ${EZA_VER} download failed for ${ARCH} — skipping"
        chmod +x "${ROOTFS}/usr/local/bin/eza" 2>/dev/null || true
        log "eza ${EZA_VER} installed."
    else
        log "WARNING: could not fetch eza version — skipping"
    fi

    # Install helm on the live host so the Helm tab + kube-cluster can
    # manage the bootstrapped cluster from the installer environment.
    # Helm publishes linux-amd64 and linux-arm64 tarballs (their naming,
    # not ours). Goldens still install their own copy via kube-setup.
    # ttyd — browser terminal daemon, drives the k9s console iframe on :7681.
    # Tiny static binary from upstream releases. Non-fatal if download fails
    # (console tab just won't work).
    log "Installing ttyd (browser terminal) from GitHub..."
    case "$ARCH" in
        x86_64)  _ttyd_arch="x86_64" ;;
        aarch64) _ttyd_arch="aarch64" ;;
    esac
    if curl -fsSL "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.${_ttyd_arch}" \
        -o "${ROOTFS}/usr/local/bin/ttyd" 2>/dev/null; then
        chmod +x "${ROOTFS}/usr/local/bin/ttyd"
        log "ttyd installed."
    else
        log "WARNING: ttyd download failed — k9s console tab will not work"
    fi

    # k9s — terminal-based k8s UI, runs inside ttyd's tmux session. Same
    # lazy fallback: console page shows a shell if k9s is missing.
    log "Installing k9s from GitHub..."
    K9S_VERSION="$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')" || true
    case "$ARCH" in
        x86_64)  _k9s_arch="amd64" ;;
        aarch64) _k9s_arch="arm64" ;;
    esac
    if [[ -n "$K9S_VERSION" ]]; then
        curl -fsSL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${_k9s_arch}.tar.gz" \
            2>/dev/null | tar xz -C "${ROOTFS}/usr/local/bin/" k9s 2>/dev/null && \
            chmod +x "${ROOTFS}/usr/local/bin/k9s" && log "k9s ${K9S_VERSION} installed." || \
            log "WARNING: k9s extract failed"
    else
        log "WARNING: could not resolve k9s version — skipping"
    fi

    log "Installing helm (live host) from get.helm.sh..."
    HELM_VERSION="${HELM_VERSION:-v3.16.2}"
    if curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH_DEB}.tar.gz" \
        -o /tmp/helm.tar.gz 2>/dev/null; then
        tar -xzf /tmp/helm.tar.gz -C /tmp/
        install -m 755 "/tmp/linux-${ARCH_DEB}/helm" "${ROOTFS}/usr/local/bin/helm"
        rm -rf /tmp/helm.tar.gz "/tmp/linux-${ARCH_DEB}"
        log "helm ${HELM_VERSION} installed on live host (${ARCH_DEB})."
    else
        log "WARNING: helm download failed — Helm tab will show 'not installed'"
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
    # ARCH= is required to prevent "arch/amd64/Makefile: No such file" errors
    # that occur in Docker builds where uname reports a different arch than
    # what we're building for. Kernel Makefile expects x86_64 or arm64 (the
    # kernel's short name for aarch64), NOT the canonical aarch64 string.
    # || true because DKMS may fail — we verify zfs.ko exists below.
    chroot "$ROOTFS" env ARCH=${ARCH_DKMS} dkms build -m zfs -v "$ZFS_VER" -k "$KVER" \
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
            # Decompress, sign, recompress.
            # --check=crc32 is REQUIRED: the kernel module decompressor
            # only accepts CRC32-checksummed xz streams. Default xz uses
            # CRC64, which produces files the kernel rejects with
            # "decompression failed with status 6" / modprobe "Invalid
            # argument" — silently breaking ZFS load on boot.
            xz -d "$_ko" 2>/dev/null || true
            _ko_plain="${_ko%.xz}"
            if [[ -f "$_ko_plain" ]]; then
                "$SIGN_FILE" sha256 "${MOK_DIR}/mok.key" "${MOK_DIR}/mok.pub" "$_ko_plain" 2>/dev/null || true
                xz --check=crc32 "$_ko_plain" 2>/dev/null || true
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
#
# Arch Linux ARM (aarch64) is unofficial and not shipped by archlinux.org, so
# we skip pacman on aarch64 builds. The Arch install target is x86_64-only;
# users on aarch64 can still install any other distro.
if [[ "$EDITION" != "core" && "$ARCH" == "x86_64" ]]; then
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
elif [[ "$ARCH" != "x86_64" ]]; then
    log "Skipping pacman-static (Arch Linux target not available for ${ARCH})"
fi

# Download apk-tools-static for Alpine Linux bootstrap support.
# CentOS has no apk package — we need a static binary. Alpine publishes for
# both x86_64 and aarch64 in the same repo layout, so the only change across
# arches is the URL path component.
if [[ "$EDITION" != "core" ]]; then
    log "Downloading apk-tools-static for Alpine support (${ARCH_ALPINE})..."
    _apk_ver=""
    _apk_ver="$(curl -sfL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/${ARCH_ALPINE}/" \
        | grep -oP 'apk-tools-static-\K[0-9][^"]*(?=\.apk)' | head -1)" || true
    if [[ -n "$_apk_ver" ]]; then
        curl -sfL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/${ARCH_ALPINE}/apk-tools-static-${_apk_ver}.apk" \
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
    # webui runs on HTTPS :8443 (self-signed cert via kldload-tls-cert).
    # Port 8080 was Bob's Open WebUI — not the installer. Pre-import the
    # cert into Firefox's NSS DB (via certutil from nss-tools) so the
    # installer page loads without a "Warning: Potential Security Risk"
    # prompt. Falls back silently if certutil or cert are missing.
    cat > "${ROOTFS}/etc/xdg/autostart/kldload-webui.desktop" << 'AUTOSTART'
[Desktop Entry]
Type=Application
Name=kldload Web UI
Exec=bash -c 'for i in $(seq 1 60); do curl -sk -o /dev/null https://localhost:8443/ 2>/dev/null && break; sleep 1; done; PROF="$HOME/.mozilla/firefox/kldload.default"; mkdir -p "$PROF"; if command -v certutil >/dev/null 2>&1 && [[ -f /var/lib/kldload/tls/webui.crt ]]; then [[ -f "$PROF/cert9.db" ]] || timeout 5 firefox --headless --profile "$PROF" about:blank >/dev/null 2>&1; certutil -A -n kldload-webui-selfsigned -t "CT,," -i /var/lib/kldload/tls/webui.crt -d sql:"$PROF" 2>/dev/null; fi; sleep 2; firefox --no-remote --profile "$PROF" https://localhost:8443'
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
    "PasswordManagerEnabled": false,
    "OfferToSaveLogins": false,
    "DisableFormHistory": true,
    "DisableTelemetry": true,
    "DisableFirefoxAccounts": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "Homepage": {
      "URL": "https://localhost:8443",
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
PRETTY_NAME="kldload (Fedora 44)"
NAME="kldload"
VERSION_ID="44"
VERSION="44 (fedora)"
ID=fedora
ID_LIKE=fedora
HOME_URL="https://kldload.com"
SUPPORT_URL="https://kldload.com"
OSREL

# ---------------------------------------------------------------------------
# Free edition: copy kldload tools, webui, installer, darksites, sanoid config
# Core edition: skip all of this — just ZFS on root with stock tools
# ---------------------------------------------------------------------------
if [[ "$EDITION" != "core" ]]; then
    # Copy kldload tools (short names). Added for pass-12:
    #   kldload-lh — LogHog cluster-wide wrapper (F5 in tmux console)
    for tool in kst kst-dashboard ksnap kclone kdf kdir kpkg kexport kldload-help kldload-test kldload-install-target kldload-webui kldload-overview kldload-doctor kldload-db kldload-inventory kldload-console kldload-dash kldload-lh \
                 kinspect kztest-tail _ktoggle-win _kconsole-home \
                 kvm-create kvm-clone kvm-snap kvm-delete kvm-list kvm-demo \
                 kube-setup kube-init kube-join kube-status kube-reset kube-network kube-load-images kube-smoke-test kube-cluster kube-demo \
                 kzfs-test kzfs-lab klab klab-exporter klab-prom-targets klab-vm-debug-bundle \
                 kldload-obs-check arcstats-exporter zpool-scrub-exporter \
                 bob bob-agent bob-bash bob-desktop bob-do bob-home bob-model bob-remote bob-sys bob-voice; do
        src="/build/live-build/config/includes.chroot/usr/local/bin/${tool}"
        [[ -f "$src" ]] && cp "$src" "${ROOTFS}/usr/local/bin/${tool}" && chmod +x "${ROOTFS}/usr/local/bin/${tool}"
    done

    # Bob's sbin tools — boot splash (hardware detect + progress + quotes)
    # and the appliance UI launcher. These live at /usr/local/sbin.
    # kldload-tls-cert added for pass-12 — self-signed TLS for webui HTTPS.
    # kldload-proxy is the :8443 reverse proxy that fronts webui, grafana,
    # ttyd-k9s and Bob behind a single cert — without it, nothing answers
    # on :8443 because the webui binds loopback :8444 now.
    for _sb_bob in bob-splash bob-ui kldload-ca kldload-tls-cert kldload-wait-for-ip kldload-bounce-tls-services kldload-proxy kldload-session kldload-headlamp-install kldload-secure-boot; do
        src="/build/live-build/config/includes.chroot/usr/local/sbin/${_sb_bob}"
        [[ -f "$src" ]] && cp "$src" "${ROOTFS}/usr/local/sbin/${_sb_bob}" && chmod +x "${ROOTFS}/usr/local/sbin/${_sb_bob}"
    done

    # /usr/libexec/ helpers — kldload-session@.service calls
    # kldload-session-run, an argv-safe wrapper that sources the
    # session env file and execs ttyd. Without this copy the
    # session unit starts but ttyd never binds (no wrapper found).
    mkdir -p "${ROOTFS}/usr/libexec"
    shopt -s nullglob
    for _libex in /build/live-build/config/includes.chroot/usr/libexec/*; do
        cp "$_libex" "${ROOTFS}/usr/libexec/$(basename "$_libex")"
        chmod +x "${ROOTFS}/usr/libexec/$(basename "$_libex")"
    done
    shopt -u nullglob

    # Bob config files — personas (64 greetings × N personas) + Modelfiles.
    # bob-ui reads /etc/bob/personas.json on startup; the rotating greeting
    # system depends on this existing.
    if [[ -d /build/live-build/config/includes.chroot/etc/bob ]]; then
        mkdir -p "${ROOTFS}/etc/bob"
        cp -r /build/live-build/config/includes.chroot/etc/bob/. "${ROOTFS}/etc/bob/"
        log "Bob configs installed: $(ls "${ROOTFS}/etc/bob" | tr '\n' ' ')"
    fi

    # ── whisper.cpp — speech-to-text for bob-voice ──────────────────────
    # Ported from bob-ai/builder/bob-build-iso.sh. Clones upstream,
    # builds inside the ROOTFS chroot (needs cmake + gcc-c++ from PKGS),
    # downloads the ~150 MB base.en model. Non-fatal if network fails —
    # bob-voice will just be absent, rest of Bob still works.
    log "Bob: building whisper.cpp (voice input)..."
    _whisper_tmp="$(mktemp -d)"
    if git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git \
            "${_whisper_tmp}/whisper.cpp" >> "$LOG_FILE" 2>&1; then
        cp -a "${_whisper_tmp}/whisper.cpp" "${ROOTFS}/opt/whisper.cpp"
        mount --bind /proc "${ROOTFS}/proc" 2>/dev/null || true
        mount --bind /sys  "${ROOTFS}/sys"  2>/dev/null || true
        mount --bind /dev  "${ROOTFS}/dev"  2>/dev/null || true
        if chroot "${ROOTFS}" bash -c \
            "cd /opt/whisper.cpp && cmake -B build && cmake --build build --config Release -j\$(nproc)" \
            >> "$LOG_FILE" 2>&1; then
            log "Bob: whisper.cpp built"
        else
            log "Bob: WARNING — whisper.cpp build failed (voice input disabled)"
        fi
        umount "${ROOTFS}/proc" 2>/dev/null || true
        umount "${ROOTFS}/sys"  2>/dev/null || true
        umount "${ROOTFS}/dev"  2>/dev/null || true
        # Download base.en model (~150 MB)
        mkdir -p "${ROOTFS}/opt/whisper.cpp/models"
        curl -fsSL -o "${ROOTFS}/opt/whisper.cpp/models/ggml-base.en.bin" \
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin" \
            >> "$LOG_FILE" 2>&1 \
            && log "Bob: whisper model downloaded" \
            || log "Bob: WARNING — whisper model download failed"
    else
        log "Bob: WARNING — whisper.cpp clone failed (offline build?)"
    fi
    rm -rf "${_whisper_tmp}"

    # ── LogHog (lh) — multi-source log stitcher, wired to F5 ────────────
    # Source tree is shipped at /opt/lh/src via includes.chroot. We compile
    # it inside the rootfs chroot so the binary links against the target
    # system's json-c / readline / ncurses (not the builder container's),
    # then strip and install to /usr/local/bin/lh. kldload-lh wraps it for
    # cluster-wide SSHFS mounts.
    # build-iso.sh uses a whitelist-copy (not a wholesale includes.chroot
    # mirror), so the /opt/lh/src tree has to be copied in explicitly
    # before the compile-guard below can find it.
    if [[ -d /build/live-build/config/includes.chroot/opt/lh/src ]]; then
        mkdir -p "${ROOTFS}/opt/lh"
        cp -r /build/live-build/config/includes.chroot/opt/lh/src \
              "${ROOTFS}/opt/lh/src"
    fi
    if [[ -d "${ROOTFS}/opt/lh/src" ]]; then
        log "Building LogHog (lh)..."
        mount --bind /proc "${ROOTFS}/proc" 2>/dev/null || true
        mount --bind /sys  "${ROOTFS}/sys"  2>/dev/null || true
        mount --bind /dev  "${ROOTFS}/dev"  2>/dev/null || true
        if chroot "${ROOTFS}" bash -c "
            set -e
            # json-c-devel + readline-devel + ncurses-devel are in the
            # ISO's base package set. gcc/make come from the toolchain
            # group installed by the rootfs bootstrap step above.
            dnf install -y json-c-devel readline-devel ncurses-devel gcc make >/dev/null 2>&1 || true
            cd /opt/lh/src
            make clean >/dev/null 2>&1 || true
            make >/dev/null
            install -m 0755 lh /usr/local/bin/lh
            strip /usr/local/bin/lh 2>/dev/null || true
        " >> "$LOG_FILE" 2>&1; then
            log "  lh installed: $(stat -c '%s bytes' "${ROOTFS}/usr/local/bin/lh" 2>/dev/null)"
        else
            log "  WARNING: lh build failed — F5 will fall back to journalctl"
        fi
        umount "${ROOTFS}/proc" 2>/dev/null || true
        umount "${ROOTFS}/sys"  2>/dev/null || true
        umount "${ROOTFS}/dev"  2>/dev/null || true
    fi

    # ── Observability stack — zfs_exporter, smartctl_exporter, loki, promtail ─
    # These are Go binaries downloaded from GitHub releases and installed to
    # /usr/local/bin in the rootfs. Systemd units + configs come in via
    # includes.chroot, so everything is wired up at first boot automatically.
    # Dashboards (Grafana provisioning) also ship via includes.chroot under
    # /var/lib/grafana/dashboards and are picked up by the klab.yaml
    # provisioning config that's already there.
    log "Observability: downloading exporters (zfs, smartctl, loki, promtail)..."
    _obs_tmp="$(mktemp -d)"
    _obs_ok=1
    # zfs_exporter
    if curl -fsSL -o "${_obs_tmp}/zfs_exporter.tgz" \
        "https://github.com/pdf/zfs_exporter/releases/download/v2.3.8/zfs_exporter-2.3.8.linux-amd64.tar.gz" \
        >> "$LOG_FILE" 2>&1; then
        tar xzf "${_obs_tmp}/zfs_exporter.tgz" -C "${_obs_tmp}" >> "$LOG_FILE" 2>&1
        install -m 0755 "${_obs_tmp}"/zfs_exporter-*/zfs_exporter "${ROOTFS}/usr/local/bin/zfs_exporter"
    else
        log "  WARNING zfs_exporter download failed"; _obs_ok=0
    fi
    # smartctl_exporter
    if curl -fsSL -o "${_obs_tmp}/smartctl_exporter.tgz" \
        "https://github.com/prometheus-community/smartctl_exporter/releases/download/v0.14.0/smartctl_exporter-0.14.0.linux-amd64.tar.gz" \
        >> "$LOG_FILE" 2>&1; then
        tar xzf "${_obs_tmp}/smartctl_exporter.tgz" -C "${_obs_tmp}" >> "$LOG_FILE" 2>&1
        install -m 0755 "${_obs_tmp}"/smartctl_exporter-*/smartctl_exporter "${ROOTFS}/usr/local/bin/smartctl_exporter"
    else
        log "  WARNING smartctl_exporter download failed"; _obs_ok=0
    fi
    # loki (single binary, zip archive)
    if curl -fsSL -o "${_obs_tmp}/loki.zip" \
        "https://github.com/grafana/loki/releases/download/v3.3.2/loki-linux-amd64.zip" \
        >> "$LOG_FILE" 2>&1; then
        (cd "${_obs_tmp}" && unzip -o loki.zip >> "$LOG_FILE" 2>&1)
        install -m 0755 "${_obs_tmp}/loki-linux-amd64" "${ROOTFS}/usr/local/bin/loki"
    else
        log "  WARNING loki download failed"; _obs_ok=0
    fi
    # promtail (same release)
    if curl -fsSL -o "${_obs_tmp}/promtail.zip" \
        "https://github.com/grafana/loki/releases/download/v3.3.2/promtail-linux-amd64.zip" \
        >> "$LOG_FILE" 2>&1; then
        (cd "${_obs_tmp}" && unzip -o promtail.zip >> "$LOG_FILE" 2>&1)
        install -m 0755 "${_obs_tmp}/promtail-linux-amd64" "${ROOTFS}/usr/local/bin/promtail"
    else
        log "  WARNING promtail download failed"; _obs_ok=0
    fi
    rm -rf "${_obs_tmp}"
    # Enable the 4 services in the live ISO rootfs so they start at first
    # boot on the installed target too (profiles.sh copies these). Persistent
    # journal is enabled via includes.chroot/etc/systemd/journald.conf.d.
    for _svc in zfs_exporter smartctl_exporter loki promtail; do
        if [[ -f "${ROOTFS}/usr/lib/systemd/system/${_svc}.service" ]]; then
            chroot "${ROOTFS}" systemctl enable "${_svc}.service" >> "$LOG_FILE" 2>&1 || true
        fi
    done
    # Pre-create Loki + promtail state dirs so services come up clean.
    mkdir -p "${ROOTFS}/var/lib/loki" "${ROOTFS}/var/lib/promtail" "${ROOTFS}/var/log/journal"

    # ── Tetragon helm chart (for eBPF syscall policies in K8s) ──────────
    # autodeploy looks for /root/darksite/helm-charts/tetragon.tgz. Without
    # this, pass-20 install said "Tetragon chart not in darksite —
    # trying online helm repo" and skipped because cluster had no internet
    # during bootstrap. Download once into the rootfs so every installed
    # target has it ready.
    mkdir -p "${ROOTFS}/root/darksite/helm-charts"
    _helm_tmp="$(mktemp -d)"
    if curl -fsSL -o "${_helm_tmp}/helm.tgz" \
        "https://get.helm.sh/helm-v3.16.4-linux-amd64.tar.gz" >> "$LOG_FILE" 2>&1; then
        tar xzf "${_helm_tmp}/helm.tgz" -C "${_helm_tmp}" >> "$LOG_FILE" 2>&1 || true
    fi
    # Pull tetragon chart directly from the cilium oci registry via HTTPS
    if curl -fsSL -o "${ROOTFS}/root/darksite/helm-charts/tetragon.tgz" \
        "https://helm.cilium.io/tetragon-1.4.1.tgz" >> "$LOG_FILE" 2>&1; then
        log "Observability: tetragon chart downloaded to darksite"
    else
        # Fallback: try the latest release
        if curl -fsSL -o "${ROOTFS}/root/darksite/helm-charts/tetragon.tgz" \
            "https://github.com/cilium/tetragon/releases/download/tetragon-1.4.1/tetragon-1.4.1.tgz" \
            >> "$LOG_FILE" 2>&1; then
            log "Observability: tetragon chart (from github) downloaded"
        else
            log "  WARNING tetragon chart download failed — will skip during install"
        fi
    fi
    rm -rf "${_helm_tmp}"
    # smartmontools (smartctl CLI) — required at runtime by smartctl_exporter
    chroot "${ROOTFS}" dnf install -y smartmontools >> "$LOG_FILE" 2>&1 || \
        log "  WARNING smartmontools install failed"

    # ebpf_exporter (Cloudflare) — per-device block I/O latency histograms.
    # BPF programs + yaml configs ship via includes.chroot/etc/ebpf_exporter.
    _ebpf_tmp="$(mktemp -d)"
    if curl -fsSL -o "${_ebpf_tmp}/ebpf.tgz" \
        "https://github.com/cloudflare/ebpf_exporter/releases/download/v2.5.1/ebpf_exporter_with_examples.x86_64.tar.gz" \
        >> "$LOG_FILE" 2>&1; then
        tar xzf "${_ebpf_tmp}/ebpf.tgz" -C "${_ebpf_tmp}" --strip-components=1 >> "$LOG_FILE" 2>&1
        install -m 0755 "${_ebpf_tmp}/ebpf_exporter" "${ROOTFS}/usr/local/bin/ebpf_exporter"
        log "Observability: ebpf_exporter installed"
    else
        log "  WARNING ebpf_exporter download failed"
    fi
    rm -rf "${_ebpf_tmp}"
    # Enable ebpf_exporter at boot
    if [[ -f "${ROOTFS}/usr/lib/systemd/system/ebpf_exporter.service" ]]; then
        chroot "${ROOTFS}" systemctl enable ebpf_exporter.service >> "$LOG_FILE" 2>&1 || true
    fi
    # Enable zpool-scrub-exporter timer (scrub state textfile collector)
    if [[ -f "${ROOTFS}/usr/lib/systemd/system/zpool-scrub-exporter.timer" ]]; then
        chroot "${ROOTFS}" systemctl enable zpool-scrub-exporter.timer >> "$LOG_FILE" 2>&1 || true
    fi
    # Enable arcstats-exporter timer
    if [[ -f "${ROOTFS}/usr/lib/systemd/system/arcstats-exporter.timer" ]]; then
        chroot "${ROOTFS}" systemctl enable arcstats-exporter.timer >> "$LOG_FILE" 2>&1 || true
    fi
    [[ $_obs_ok -eq 1 ]] && log "Observability: stack installed (4 exporters + smartctl)" \
        || log "Observability: PARTIAL — some downloads failed, check log"

    # Copy Grafana dashboards + datasource + other observability configs
    # from includes.chroot explicitly (whitelist-copy, same pattern as
    # Bob configs above). These would otherwise not land because the
    # build uses explicit copies, not a full includes.chroot mirror.
    if [[ -d /build/live-build/config/includes.chroot/var/lib/grafana/dashboards ]]; then
        mkdir -p "${ROOTFS}/var/lib/grafana/dashboards"
        cp /build/live-build/config/includes.chroot/var/lib/grafana/dashboards/*.json \
           "${ROOTFS}/var/lib/grafana/dashboards/" 2>>"$LOG_FILE" || true
        log "Observability: $(ls "${ROOTFS}/var/lib/grafana/dashboards/" | wc -l) dashboards provisioned"
    fi
    if [[ -f /build/live-build/config/includes.chroot/etc/grafana/provisioning/datasources/loki.yaml ]]; then
        mkdir -p "${ROOTFS}/etc/grafana/provisioning/datasources"
        cp /build/live-build/config/includes.chroot/etc/grafana/provisioning/datasources/loki.yaml \
           "${ROOTFS}/etc/grafana/provisioning/datasources/loki.yaml"
    fi
    if [[ -d /build/live-build/config/includes.chroot/etc/loki ]]; then
        mkdir -p "${ROOTFS}/etc/loki"
        cp /build/live-build/config/includes.chroot/etc/loki/*.yaml "${ROOTFS}/etc/loki/" 2>/dev/null || true
    fi
    if [[ -d /build/live-build/config/includes.chroot/etc/promtail ]]; then
        mkdir -p "${ROOTFS}/etc/promtail"
        cp /build/live-build/config/includes.chroot/etc/promtail/*.yaml "${ROOTFS}/etc/promtail/" 2>/dev/null || true
    fi
    if [[ -d /build/live-build/config/includes.chroot/etc/ebpf_exporter ]]; then
        mkdir -p "${ROOTFS}/etc/ebpf_exporter"
        cp /build/live-build/config/includes.chroot/etc/ebpf_exporter/* "${ROOTFS}/etc/ebpf_exporter/" 2>/dev/null || true
    fi
    if [[ -f /build/live-build/config/includes.chroot/etc/zfs/zed.d/all-loki.sh ]]; then
        mkdir -p "${ROOTFS}/etc/zfs/zed.d"
        install -m 0755 /build/live-build/config/includes.chroot/etc/zfs/zed.d/all-loki.sh \
            "${ROOTFS}/etc/zfs/zed.d/all-loki.sh"
    fi
    if [[ -d /build/live-build/config/includes.chroot/etc/systemd/journald.conf.d ]]; then
        mkdir -p "${ROOTFS}/etc/systemd/journald.conf.d"
        cp /build/live-build/config/includes.chroot/etc/systemd/journald.conf.d/*.conf \
           "${ROOTFS}/etc/systemd/journald.conf.d/" 2>/dev/null || true
    fi
    if [[ -d /build/live-build/config/includes.chroot/etc/systemd/system/node_exporter.service.d ]]; then
        mkdir -p "${ROOTFS}/etc/systemd/system/node_exporter.service.d"
        cp /build/live-build/config/includes.chroot/etc/systemd/system/node_exporter.service.d/*.conf \
           "${ROOTFS}/etc/systemd/system/node_exporter.service.d/" 2>/dev/null || true
    fi
    # Copy systemd units from the live-build tree — glob pattern so new
    # units added to includes.chroot/usr/lib/systemd/system/ get picked
    # up automatically. Previous hardcoded list repeatedly missed units
    # (kldload-tls-cert.service, kldload-tls-cert.timer most recently).
    shopt -s nullglob
    for _unit_path in \
        /build/live-build/config/includes.chroot/usr/lib/systemd/system/*_exporter.service \
        /build/live-build/config/includes.chroot/usr/lib/systemd/system/*-exporter.service \
        /build/live-build/config/includes.chroot/usr/lib/systemd/system/*_exporter.timer \
        /build/live-build/config/includes.chroot/usr/lib/systemd/system/*-exporter.timer \
        /build/live-build/config/includes.chroot/usr/lib/systemd/system/loki.service \
        /build/live-build/config/includes.chroot/usr/lib/systemd/system/promtail.service \
        /build/live-build/config/includes.chroot/usr/lib/systemd/system/kldload-tls-cert.service \
        /build/live-build/config/includes.chroot/usr/lib/systemd/system/kldload-tls-cert.timer \
        /build/live-build/config/includes.chroot/usr/lib/systemd/system/kldload-proxy.service \
        /build/live-build/config/includes.chroot/usr/lib/systemd/system/kldload-headlamp.service \
        /build/live-build/config/includes.chroot/usr/lib/systemd/system/kldload-session@.service; do
        [[ -f "$_unit_path" ]] && cp "$_unit_path" "${ROOTFS}/usr/lib/systemd/system/$(basename "$_unit_path")"
    done
    shopt -u nullglob
    # ── 1.0.6 TLS-terminator swap: nginx replaces kldload-proxy ────────
    # nginx on :8443 with HTTP/2 + ALPN + drop-in dir pattern. Graceful
    # SIGHUP reload means cert rotations + session adds don't drop any
    # in-flight WebSockets. kldload-proxy is kept on-disk for one release
    # as a rollback path but is NOT enabled at boot.
    #
    # Copy nginx config tree into rootfs. /etc/nginx/ is created by the
    # nginx RPM install; our files overlay onto it. conf.d/kldload.conf,
    # kldload/proxy-common.conf + ws-upgrade.conf, conf.d/kldload-dyn/
    # (empty drop-in dir).
    if [[ -d /build/live-build/config/includes.chroot/etc/nginx ]]; then
        mkdir -p "${ROOTFS}/etc/nginx"
        cp -r /build/live-build/config/includes.chroot/etc/nginx/. "${ROOTFS}/etc/nginx/"
        log "nginx config tree installed from includes.chroot"
    fi
    # Drop-in dir needs to exist even when empty — nginx `include` on an
    # empty glob is fine, but the directory itself must be present.
    mkdir -p "${ROOTFS}/etc/nginx/conf.d/kldload-dyn"

    # systemd drop-in for nginx.service (ExecStartPre cert ensure).
    if [[ -d /build/live-build/config/includes.chroot/etc/systemd/system/nginx.service.d ]]; then
        mkdir -p "${ROOTFS}/etc/systemd/system/nginx.service.d"
        cp /build/live-build/config/includes.chroot/etc/systemd/system/nginx.service.d/*.conf \
           "${ROOTFS}/etc/systemd/system/nginx.service.d/" 2>/dev/null || true
    fi

    # Session session-dir scaffold (owned by root, readable).
    mkdir -p "${ROOTFS}/var/lib/kldload/sessions"

    # Enable nginx at boot — the new :8443 TLS terminator. Disable
    # kldload-proxy explicitly so only one thing binds :8443.
    chroot "${ROOTFS}" systemctl enable  nginx.service          >> "$LOG_FILE" 2>&1 || true
    chroot "${ROOTFS}" systemctl disable kldload-proxy.service  >> "$LOG_FILE" 2>&1 || true
    # Enable kldload-tls-cert.timer at boot (fires cert-drift check hourly)
    if [[ -f "${ROOTFS}/usr/lib/systemd/system/kldload-tls-cert.timer" ]]; then
        chroot "${ROOTFS}" systemctl enable kldload-tls-cert.timer >> "$LOG_FILE" 2>&1 || true
    fi
    # Enable kldload-tls-cert.service at boot (regenerates cert once
    # network is up — handles the DHCP race)
    if [[ -f "${ROOTFS}/usr/lib/systemd/system/kldload-tls-cert.service" ]]; then
        chroot "${ROOTFS}" systemctl enable kldload-tls-cert.service >> "$LOG_FILE" 2>&1 || true
    fi
    # Enable kldload-journal-flush on first boot — ensures persistent
    # journal actually gets populated so promtail can scrape kernel logs
    if [[ -f "${ROOTFS}/usr/lib/systemd/system/kldload-journal-flush.service" ]]; then
        # Copy the unit in first (wasn't caught by the exporter glob)
        :
    fi
    # Explicitly copy kldload-journal-flush.service (doesn't match the
    # *-exporter glob)
    if [[ -f /build/live-build/config/includes.chroot/usr/lib/systemd/system/kldload-journal-flush.service ]]; then
        cp /build/live-build/config/includes.chroot/usr/lib/systemd/system/kldload-journal-flush.service \
           "${ROOTFS}/usr/lib/systemd/system/kldload-journal-flush.service"
        chroot "${ROOTFS}" systemctl enable kldload-journal-flush.service >> "$LOG_FILE" 2>&1 || true
    fi

    # NetworkManager dispatcher hook — fires on IP change events so the
    # TLS cert gets regen'd without waiting for next reboot/timer.
    if [[ -f /build/live-build/config/includes.chroot/etc/NetworkManager/dispatcher.d/99-kldload-tls-cert ]]; then
        mkdir -p "${ROOTFS}/etc/NetworkManager/dispatcher.d"
        install -m 0755 \
            /build/live-build/config/includes.chroot/etc/NetworkManager/dispatcher.d/99-kldload-tls-cert \
            "${ROOTFS}/etc/NetworkManager/dispatcher.d/99-kldload-tls-cert"
    fi

    # /etc/kldload — admin-editable config dir (tls-extra-sans.txt etc.)
    if [[ -d /build/live-build/config/includes.chroot/etc/kldload ]]; then
        mkdir -p "${ROOTFS}/etc/kldload"
        cp /build/live-build/config/includes.chroot/etc/kldload/*.txt \
           "${ROOTFS}/etc/kldload/" 2>/dev/null || true
    fi
    # tetragon zfs tracing policy
    if [[ -f /build/live-build/config/includes.chroot/usr/local/share/klab/tetragon-zfs-policy.yaml ]]; then
        mkdir -p "${ROOTFS}/usr/local/share/klab"
        cp /build/live-build/config/includes.chroot/usr/local/share/klab/tetragon-zfs-policy.yaml \
           "${ROOTFS}/usr/local/share/klab/tetragon-zfs-policy.yaml"
    fi

    # ── piper — text-to-speech for Bob's voice output ────────────────────
    log "Bob: installing piper TTS..."
    _piper_tmp="$(mktemp -d)"
    if curl -fsSL -o "${_piper_tmp}/piper.tar.gz" \
         "https://github.com/rhasspy/piper/releases/latest/download/piper_linux_x86_64.tar.gz" \
         >> "$LOG_FILE" 2>&1; then
        tar xf "${_piper_tmp}/piper.tar.gz" -C "${ROOTFS}/opt/" >> "$LOG_FILE" 2>&1
        mkdir -p "${ROOTFS}/opt/piper/models"
        curl -fsSL -o "${ROOTFS}/opt/piper/models/en_US-lessac-medium.onnx" \
            "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx" \
            >> "$LOG_FILE" 2>&1 || log "Bob: WARNING piper voice onnx download failed"
        curl -fsSL -o "${ROOTFS}/opt/piper/models/en_US-lessac-medium.onnx.json" \
            "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json" \
            >> "$LOG_FILE" 2>&1 || true
        [[ -x "${ROOTFS}/opt/piper/piper" ]] \
            && log "Bob: piper TTS installed" \
            || log "Bob: WARNING piper binary not found after extract"
    else
        log "Bob: WARNING — piper download failed (offline build?)"
    fi
    rm -rf "${_piper_tmp}"

    # Copy klab share files (Prometheus config, Grafana dashboard)
    # Ansible playbook library — consumed by kube-cluster, klab, and
    # the Ansible tab in the web UI. profiles.sh expects it at
    # /usr/local/share/kldload-ansible/ in the live root; build-iso.sh
    # has to put it there explicitly because the rootfs is assembled
    # from a whitelist, not a wholesale copy of includes.chroot.
    if [[ -d /build/live-build/config/includes.chroot/usr/local/share/kldload-ansible ]]; then
        mkdir -p "${ROOTFS}/usr/local/share/kldload-ansible"
        cp -r /build/live-build/config/includes.chroot/usr/local/share/kldload-ansible/. \
              "${ROOTFS}/usr/local/share/kldload-ansible/"
        log "Ansible playbook library installed: $(find "${ROOTFS}/usr/local/share/kldload-ansible/playbooks" -name '*.yml' 2>/dev/null | wc -l) playbooks"
    fi

    # Bob's docs corpus — scraped kldload.com HTML-to-text + OCR'd PDF
    # manual. The web UI's docs_search tool greps this at query time
    # to give Bob actual kldload knowledge (the base llama3.1 model has
    # none). ~3.3 MB total.
    if [[ -d /build/live-build/config/includes.chroot/usr/local/share/kldload-ai ]]; then
        mkdir -p "${ROOTFS}/usr/local/share/kldload-ai"
        cp /build/live-build/config/includes.chroot/usr/local/share/kldload-ai/*.txt \
              "${ROOTFS}/usr/local/share/kldload-ai/" 2>/dev/null || true
        log "Bob docs corpus installed: $(du -sh "${ROOTFS}/usr/local/share/kldload-ai" 2>/dev/null | cut -f1)"
    fi

    if [[ -d /build/live-build/config/includes.chroot/usr/local/share/klab ]]; then
        mkdir -p "${ROOTFS}/usr/local/share/klab"
        cp -r /build/live-build/config/includes.chroot/usr/local/share/klab/* "${ROOTFS}/usr/local/share/klab/"
    fi

    # Copy .desktop files for GNOME menu
    for dt in kst.desktop kst-dashboard.desktop ksnap.desktop kexport.desktop kldload-terminal.desktop kldload-docs.desktop vim.desktop; do
        src="/build/live-build/config/includes.chroot/usr/share/applications/${dt}"
        [[ -f "$src" ]] && cp "$src" "${ROOTFS}/usr/share/applications/${dt}"
    done

    # Copy the main installer + orchestrator scripts to /usr/sbin.
    # kldload-autodeploy is the post-install orchestrator (K8s + AI + klab
    # goldens). Without it on the live ISO the installer's cp to target is
    # a silent no-op, which is the 1.0.4/1.0.5 root cause for installs
    # finishing but never building goldens, K8s, or AI.
    for sbin_tool in kldload-install-target kldload-firstboot kldload-autodeploy kldload-recovery kldload-snapshot kldload-apply-platform-holds kldload-export-deferred; do
        src="/build/live-build/config/includes.chroot/usr/sbin/${sbin_tool}"
        [[ -f "$src" ]] && cp "$src" "${ROOTFS}/usr/sbin/${sbin_tool}" && chmod +x "${ROOTFS}/usr/sbin/${sbin_tool}"
    done

    # Copy the sbin-level CLI tools users invoke directly.
    #   kspawn               — ZFS-native cluster spawner (new in 1.0.5)
    #   kldload-debug-bundle — post-mortem state collector — needs to ship
    #     in the LIVE ISO so the lifecycle smoke harness + manual repro on
    #     a stuck install can capture state from the live env, AND so
    #     profiles.sh's per-binary copy list can find it as a source when
    #     installing onto the target.
    for _lsbin in kspawn kldload-debug-bundle; do
        _src="/build/live-build/config/includes.chroot/usr/local/sbin/${_lsbin}"
        [[ -f "$_src" ]] && cp "$_src" "${ROOTFS}/usr/local/sbin/${_lsbin}" && chmod +x "${ROOTFS}/usr/local/sbin/${_lsbin}"
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
ExecStart=/usr/local/bin/kldload-webui --port 8443 --no-browser
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

    # Copy systemd service units from includes.chroot. Every unit the
    # installer's profiles.sh tries to symlink needs to live here first
    # (otherwise the `[[ -f ... ]] && cp` in profiles.sh silently skips).
    for _svc in kldload-firstboot.service kldload-autodeploy.service kldload-webui.service \
                kldload-srv-snapshot.service kldload-srv-snapshot.timer \
                kldload-snapshot.service kldload-snapshot.timer kldload-export.service \
                ttyd-k9s.service \
                klab-prom-targets.service klab-prom-targets.timer; do
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

    # Copy Ollama model darksite (llama3.1:8b + Bob personality) into rootfs.
    # Ollama darksite is OPT-IN — the ISO defaults to no baked-in model,
    # which keeps it at ~8 GB instead of ~17 GB. First boot with Bob
    # enabled pulls from ollama.com (internet required). Users who want
    # offline AI set KLDLOAD_INCLUDE_OLLAMA_DARKSITE=1 on deploy.sh and
    # the ~9 GB model tree gets baked in. Users who want BYOM drop the
    # tree into /root/darksite/ollama/models/ on the target before first
    # boot — kldload-firstboot honours it either way.
    if [[ "${KLDLOAD_INCLUDE_OLLAMA_DARKSITE:-0}" == "1" ]] && [[ -d /build/live-build/darksite-ollama-cache/models ]]; then
        mkdir -p "${ROOTFS}/root/darksite/ollama"
        cp -r /build/live-build/darksite-ollama-cache/models "${ROOTFS}/root/darksite/ollama/"
        log "Ollama darksite copied to rootfs: $(du -sh "${ROOTFS}/root/darksite/ollama" 2>/dev/null | cut -f1)"
    else
        log "Ollama darksite NOT baked in (opt-in via KLDLOAD_INCLUDE_OLLAMA_DARKSITE=1). Bob pulls model at firstboot (internet required)."
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
# x86-specific BCJ filter boosts compression on x86 binaries ~5-10%; on
# aarch64 it doesn't apply, so use arm filter there (or leave it off).
SQFS_BCJ=(-Xbcj x86)
[[ "$ARCH" == "aarch64" ]] && SQFS_BCJ=(-Xbcj arm)
mksquashfs "$ROOTFS" "${SQUASHFS_DIR}/squashfs.img" \
    -comp xz "${SQFS_BCJ[@]}" -b 1M -noappend 2>&1 | tail -5

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
#
# UEFI bootloader names are arch-specific:
#   x86_64 → grubx64.efi + BOOTX64.EFI (default per EFI spec)
#   aarch64 → grubaa64.efi + BOOTAA64.EFI
case "$ARCH_EFI" in
    x64)  GRUB_EFI="grubx64.efi";  BOOT_EFI="BOOTX64.EFI"  ;;
    aa64) GRUB_EFI="grubaa64.efi"; BOOT_EFI="BOOTAA64.EFI" ;;
esac
find "$ROOTFS" -name "$GRUB_EFI" -exec cp {} "${ISO_STAGING}/EFI/BOOT/${BOOT_EFI}" \; 2>/dev/null || \
    log "WARNING: ${GRUB_EFI} not found — live ISO may not UEFI boot"

# Also keep the arch-named copy as itself (some firmware looks for it by name)
cp "${ISO_STAGING}/EFI/BOOT/${BOOT_EFI}" "${ISO_STAGING}/EFI/BOOT/${GRUB_EFI}" 2>/dev/null || true

# GRUB config
cat > "${ISO_STAGING}/EFI/BOOT/grub.cfg" << 'GRUBCFG'
set default=0
set timeout=5
set timeout_style=countdown

# When booting from a USB stick with the new GPT+ESP hybrid layout, GRUB
# starts with $root set to the EFI System Partition — which does NOT
# contain the kernel. The kernel lives in the ISO9660 filesystem on the
# appended partition (labelled "KLDLOAD"). Without this search line, GRUB
# looks for /images/pxeboot/vmlinuz in the ESP, doesn't find it, and the
# boot aborts with "file not found". The CD-ROM boot path happens to
# work without this because emulated-CD firmware sets $root to the
# ISO9660 volume naturally.
search --no-floppy --set=root --label 'KLDLOAD'

# Default entry uses the broadly-compatible cmdline that was previously a
# fallback "Compatibility" entry. Trade is ~5 seconds of extra boot time
# on healthy hardware in exchange for booting reliably on HP minis, AMD
# Ryzen mini-PCs (Beelink/Minisforum/GMKtec/etc), and any USB stick whose
# controller has UAS quirks. The headline failure mode this avoids is
# "dracut-initqueue: timeout, still waiting for /dev/disk/by-label/KLDLOAD".
menuentry "kldloadOS Live (Fedora 44 + ZFS)" --hotkey=l {
    linuxefi /images/pxeboot/vmlinuz root=live:CDLABEL=KLDLOAD rd.live.image rd.live.overlay.size=10240 lockdown=none module.sig_enforce=0 selinux=0 rootdelay=30 rd.retry=120 modprobe.blacklist=uas usbcore.autosuspend=-1
    initrdefi /images/pxeboot/initrd.img
}

# Safe graphics — generic nomodeset. For any GPU init issue (Nvidia black
# screen, Intel/AMD garbled output) where the user just needs the EFI
# framebuffer to come up. Inherits the default USB compat settings.
menuentry "kldloadOS Live (safe graphics — nomodeset)" --hotkey=g {
    linuxefi /images/pxeboot/vmlinuz root=live:CDLABEL=KLDLOAD rd.live.image rd.live.overlay.size=10240 lockdown=none module.sig_enforce=0 selinux=0 rootdelay=30 rd.retry=120 modprobe.blacklist=uas usbcore.autosuspend=-1 nomodeset
    initrdefi /images/pxeboot/initrd.img
}

# AMD mini-PC compatibility — for Beelink SER5/SER6/SER8, Minisforum UM
# series, GMKtec, ACEMagic, NiPoGi and other AMD Phoenix / Hawk Point /
# Cezanne mini PCs where the 5.14 kernel's amdgpu driver stalls on Radeon
# 780M / Vega init and the dracut initqueue times out behind it.
# Blacklists amdgpu+radeon, forces efifb, longer device-wait windows.
menuentry "kldloadOS Live (AMD mini-PC — Beelink/Minisforum/GMKtec)" --hotkey=a {
    linuxefi /images/pxeboot/vmlinuz root=live:CDLABEL=KLDLOAD rd.live.image rd.live.overlay.size=10240 lockdown=none module.sig_enforce=0 selinux=0 rootdelay=60 rd.retry=120 modprobe.blacklist=amdgpu,radeon,uas usbcore.autosuspend=-1 nomodeset video=efifb:on
    initrdefi /images/pxeboot/initrd.img
}

# Maximum compatibility — last-resort kitchen sink. Use only when every
# other entry has timed out. Blacklists all GPU drivers and unreliable USB
# layers, pre-loads usb-storage early, delays storage probe, sets IOMMU
# passthrough, stretches all dracut waits to ~3 minutes. Slow boot, but
# if the hardware can boot Linux at all, this entry should get there.
menuentry "kldloadOS Live (maximum compatibility — last resort)" --hotkey=m {
    linuxefi /images/pxeboot/vmlinuz root=live:CDLABEL=KLDLOAD rd.live.image rd.live.overlay.size=10240 lockdown=none module.sig_enforce=0 selinux=0 rootdelay=120 rd.retry=180 modprobe.blacklist=amdgpu,radeon,nouveau,uas usbcore.autosuspend=-1 nomodeset video=efifb:on iommu=pt usb-storage.delay_use=15 rd.driver.pre=usb-storage,sd_mod,vfat,iso9660
    initrdefi /images/pxeboot/initrd.img
}

# Troubleshooting — drops to a dracut emergency shell after device-waits
# expire. Use to inspect why the live label isn't appearing: lsblk,
# ls /dev/disk/by-label/, dmesg | grep -i usb. Inherits compat USB delays.
menuentry "kldloadOS Live (troubleshooting — dracut shell)" --hotkey=t {
    linuxefi /images/pxeboot/vmlinuz root=live:CDLABEL=KLDLOAD rd.live.image rd.live.overlay.size=10240 lockdown=none module.sig_enforce=0 selinux=0 rootdelay=30 rd.retry=120 modprobe.blacklist=uas usbcore.autosuspend=-1 rd.shell
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
mcopy -i "${ISO_STAGING}/images/efiboot.img" "${ISO_STAGING}/EFI/BOOT/${BOOT_EFI}" ::EFI/BOOT/ 2>/dev/null || true
mcopy -i "${ISO_STAGING}/images/efiboot.img" "${ISO_STAGING}/EFI/BOOT/${GRUB_EFI}" ::EFI/BOOT/ 2>/dev/null || true
mcopy -i "${ISO_STAGING}/images/efiboot.img" "${ISO_STAGING}/EFI/BOOT/grub.cfg" ::EFI/BOOT/

# Write version metadata into the ISO so installers / diagnostics can
# identify which build a running system came from. Three locations:
#   .disk/info      — Debian-live convention (single-line "Name Version")
#   /VERSION        — top-level, trivially `cat`-able
#   /etc/kldload/VERSION — lives inside the eventual rootfs path too
# The installer prefers .disk/info but falls back to /VERSION.
_iso_label="kldload ${VERSION} x86_64"
_iso_built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "${ISO_STAGING}/.disk" "${ISO_STAGING}/etc/kldload"
printf '%s\n' "${_iso_label}" > "${ISO_STAGING}/.disk/info"
cat > "${ISO_STAGING}/VERSION" <<VERSIONEOF
kldload_version = ${VERSION}
iso_name        = ${ISO_NAME}
built_at        = ${_iso_built_at}
edition         = ${EDITION:-free}
profile         = ${PROFILE:-desktop}
arch            = ${ARCH:-x86_64}
release         = ${RELEASE:-9}
VERSIONEOF
cp "${ISO_STAGING}/VERSION" "${ISO_STAGING}/etc/kldload/VERSION"
# CRITICAL: also write VERSION into the ROOTFS so the running live
# system (kldload-install-target reads /etc/kldload/VERSION) can pick
# it up. Without this, files under ISO_STAGING only exist on the
# ISO medium, not inside the squashfs'd rootfs that boots.
mkdir -p "${ROOTFS}/etc/kldload"
cp "${ISO_STAGING}/VERSION" "${ROOTFS}/etc/kldload/VERSION"

# Build ISO with UEFI boot that works from USB *and* CD-ROM emulation.
#
# Two boot paths need to coexist:
#   1. CD-ROM / emulated-CD (KVM, Proxmox, libvirt) — firmware reads El
#      Torito catalog and loads the EFI image pointed to by -e.
#   2. Bare-metal USB UEFI — firmware scans the device for GPT with an
#      EFI System Partition. El Torito alone is NOT enough; most UEFI
#      firmware will not list the USB as bootable without a real GPT.
#
# -isohybrid-gpt-basdat only TAGS the EFI image as a GPT basic-data
# partition entry — it does not synthesize the protective MBR or GPT
# header, so the first 32 KiB of the ISO stays empty and USB UEFI
# firmware sees no partition table (issue that broke 1.0.4 downloads).
#
# The -append_partition + -appended_part_as_gpt combination appends the
# efiboot.img as GPT partition 2 with the EFI System Partition GUID
# (C12A7328-F81F-11D2-BA4B-00A0C93EC93B). xorriso then writes a real
# protective MBR + GPT so UEFI firmware on any modern machine detects
# the USB and boots /EFI/BOOT/BOOTX64.EFI. Same pattern as the
# Fedora/Debian/Arch installer ISOs.
xorriso -as mkisofs \
    -o "${OUTPUT_DIR}/${ISO_NAME}" \
    -R -J -joliet-long \
    -iso-level 3 \
    -V "KLDLOAD" \
    -e images/efiboot.img \
    -no-emul-boot \
    -appended_part_as_gpt \
    -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B \
        "${ISO_STAGING}/images/efiboot.img" \
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
