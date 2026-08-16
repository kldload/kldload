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
    ARCH_EFI="x64"     # grub2-efi-x64, shim-x64, BOOTX64.EFI
    ARCH_DEB="amd64"   # helm linux-amd64.tar.gz, Debian arm64 vs amd64
    ARCH_DKMS="x86_64" # kernel DKMS ARCH= value
    ARCH_ALPINE="x86_64"
    ;;
aarch64 | arm64)
    ARCH="aarch64"  # canonical name inside the script
    ARCH_EFI="aa64" # grub2-efi-aa64, shim-aa64, BOOTAA64.EFI
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
VERSION="${KLDLOAD_VERSION:-1.4.0-rc9}"
ISO_NAME="${ISO_NAME_OVERRIDE:-kldload-${VERSION}-${ARCH}.iso}"
SQUASHFS_DIR="${ISO_STAGING}/LiveOS"

log() { printf '[%s] [build-iso] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() {
    printf '[%s] [build-iso] ERROR: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
    exit 1
}

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
        # pipefail is deliberately off in this script (SIGPIPE note at top),
        # so the tee masks the darksite's exit — its hard RPM-count gate was
        # silently defeated on 2026-07-23 and a mirror-less ISO kept building.
        # Judge the real status via PIPESTATUS, same as the bootstrap dnf.
        _darksite_rc=${PIPESTATUS[0]}
        if [[ "$_darksite_rc" != "0" ]]; then
            echo "FATAL: EL darksite build failed (rc=${_darksite_rc}) — refusing to ship an ISO with an empty EL mirror" >&2
            exit 1
        fi
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
    # kernel* intentionally absent — koji-pinned to the last zfs-compatible
    # NVR, see KOJI_KERNEL_URLS at the bootstrap dnf below
    dracut dracut-live dracut-squash
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
    # ZFS — DKMS build inside chroot against target kernel. zfs/zfs-dkms are
    # dropped from this list in ZFS-from-git mode (see KLDLOAD_ZFS_GIT below).
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
        # bcc-tools + bpftrace — every Alt+letter / F11-F12 / Shift-F binding
        # in kldload-console (the embedded terminal drawer) runs an eBPF
        # tracer (execsnoop / opensnoop / biosnoop / killsnoop / tcplife /
        # tcptop / tcpretrans / tcpconnect / etc.) and falls through to
        # "need-bcc-tools" if these aren't installed. They WERE only in the
        # darksite for installed targets — meaning every keybind in the
        # live ISO printed "need-bcc-tools" forever. Adding here so the
        # live env is usable as a diagnostic toolkit (which is one of the
        # documented use cases for booting kldload as a USB rescue stick).
        # ~80 MB; well below the ISO-size noise floor on a 16+ GB build.
        bcc-tools bpftrace
    )
fi

# GNOME desktop is ALWAYS installed in the live ISO regardless of the PROFILE
# variable. The live environment boots to a GNOME session with GDM autologin,
# and Firefox auto-opens the kldload-webui installer. Without GNOME, the user
# would have no way to interact with the web UI. The PROFILE variable only
# affects what packages get installed on the TARGET system at install time.
PKGS+=(
    # firefox is NOT installed: Chrome is the only kldload browser (installed
    # from google-chrome.repo after the rootfs is built) and renders the webui
    # via kldload-chrome-app. Shipping firefox here left two browsers on the live
    # and a stale firefox dock pin. gnome-terminal ("Terminal") stays as the F44
    # terminal.
    gnome-shell gnome-session gdm gnome-terminal nautilus
    gnome-control-center gnome-settings-daemon gedit
    gnome-keyring mesa-dri-drivers
    pipewire wireplumber
    adwaita-icon-theme google-noto-sans-fonts
    # Color-emoji font — the installer SPA uses emoji as the distro/profile TILE
    # icons (🐧 🌀 ⛰ 🔴 🟠 🔵 😈 etc.). Without a color-emoji font the live
    # installer's browser renders them as nothing, so every tile shows blank
    # above its label (10.100.10.119, 2026-06-14: "icons on the tiles still
    # don't show up"). This font makes them render.
    google-noto-color-emoji-fonts
    # F44 branded wallpapers for the LIVE installer only. The installed
    # system uses /usr/share/backgrounds/kldload/default{,-dark}.png set by
    # 00-kldload-desktop dconf. The live ISO overrides those with the F44
    # default via 99-kldload-live-session below so the operator sees Fedora
    # branding during install, not kldload — clearer signal "you're booting
    # the installer, not the installed system."
    f44-backgrounds-gnome
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

cat >"${ROOTFS}/etc/yum.repos.d/fedora.repo" <<'FEDOREPO'
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

# ZFS source — OpenZFS 2.4 line from zfsonlinux.org (release builds), or a
# from-git build when KLDLOAD_ZFS_GIT is set (repo skipped — the built rpms
# are fed to the bootstrap dnf directly, see the ZFS-from-git block below).
#
# As of 2026-06-12 zfsonlinux.org publishes a native fc44 build; the 2.4 line
# serves OpenZFS 2.4.3 (supports Linux 4.18–7.0). $releasever expands to 44.
if [[ -z "${KLDLOAD_ZFS_GIT:-}" || "${KLDLOAD_ZFS_GIT}" == "0" ]]; then
    cat >"${ROOTFS}/etc/yum.repos.d/zfs.repo" <<'ZFSREPO'
[zfs]
name=OpenZFS 2.4 for Fedora $releasever
baseurl=http://download.zfsonlinux.org/2.4/fedora/$releasever/$basearch/
enabled=1
gpgcheck=0

ZFSREPO
fi

# Note: DKMS autoinstall will fail here (host kernel != target kernel).
# That's expected — we rebuild DKMS explicitly below with --kernelsourcedir.
# Don't let the scriptlet failure kill the build.
#
# pipefail is explicitly disabled here and never re-enabled. Enabling it would
# cause SIGPIPE from "dnf | tee" to propagate as a non-zero exit, which set -e
# would turn into a fatal build abort. The SIGPIPE is harmless (just tee closing).
set +o pipefail
# Kernel pin REINSTATED 2026-07-23: the predicted 7.1 window opened. F44
# updates now serves kernel 7.1.4-202 (and pruned 7.0.x entirely), while the
# OpenZFS 2.4 repo still serves zfs-dkms-2.4.3 with its
# `Conflicts: kernel-uname-r > 7.0.999` cap — unpinned, this transaction
# aborts on dep resolution (exactly as the previous comment here predicted).
#
# Pin choice: koji URLs for the newest 7.0.x NVR — the kernel line the
# shipping ISOs already boot-verified with zfs 2.4.3 — rather than falling
# back to GA 6.19.10 (an untested combo). Modules only build against RELEASE
# zfs; the kernel holds at the newest that release supports. kojipkgs keeps
# every built NVR forever (mirrors prune; updates-archive unreachable from
# the builder, probed 2026-07-23). All six subpackage URLs verified 200.
# The --exclude keeps any repo 7.1+ kernel out of the transaction; it does
# NOT match the 7.0.x URL packages.
# REMOVE this pin (restore kernel names in PKGS) when the 2.4 line ships a
# zfs-dkms whose cap covers the then-current F44 kernel —
# check: dnf repoquery --repoid=zfs zfs-dkms
KOJI_KERNEL_NVR="7.0.14-201.fc44"
KOJI_KERNEL_BASE="https://kojipkgs.fedoraproject.org/packages/kernel/${KOJI_KERNEL_NVR%%-*}/${KOJI_KERNEL_NVR#*-}/${ARCH}"
KOJI_KERNEL_URLS=()
# kernel-devel-matched must be pinned too: something in the closure requires
# it, and without a matching provider on the command line dnf pulls the
# repo's 6.19 one — which drags a SECOND kernel-core/devel into the
# transaction (kernels are installonly, so dnf stacks both; verified
# 2026-07-23).
# kernel-modules-extra included: it wasn't pinned in the first 7.0.14 build,
# so the resolver pulled the repo's 6.19.10 one — mixed-NVR modules-extra on
# a 7.0.14 kernel (uncommon drivers missing) — caught on the smoke VM's
# versionlock list 2026-07-23.
for _ksub in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-devel kernel-devel-matched; do
    KOJI_KERNEL_URLS+=("${KOJI_KERNEL_BASE}/${_ksub}-${KOJI_KERNEL_NVR}.${ARCH}.rpm")
done

# ─── ZFS-from-git test mode (KLDLOAD_ZFS_GIT) ────────────────────────────────
# OPT-IN escape hatch for the "zfs lags the kernel" window: build OpenZFS
# rpms from git (1 = master, anything else = branch/tag) and UNPIN the kernel
# so the rootfs rides newest F44 — the combination you'd be testing. The
# built rpms carry the same package names (zfs, zfs-dkms), so the rpm -q
# gate, the explicit DKMS rebuild below, and the firstboot versionlock all
# work unchanged. UNSUPPORTED test path — release builds stay on release
# zfs + the pinned kernel above. Default (flag unset) is byte-identical to
# the release path.
ZFS_GIT_RPMS=()
if [[ -n "${KLDLOAD_ZFS_GIT:-}" && "${KLDLOAD_ZFS_GIT}" != "0" ]]; then
    _zfs_ref="${KLDLOAD_ZFS_GIT}"
    [[ "$_zfs_ref" == "1" ]] && _zfs_ref="master"
    log "ZFS-FROM-GIT: building OpenZFS rpms from ref '${_zfs_ref}' (UNSUPPORTED test build; kernel unpinned)"
    # Explicit build-dep list (the documented OpenZFS Fedora set), NOT
    # `dnf builddep zfs`: Fedora's repos don't carry zfs at all and this
    # mode deliberately skips the zfsonlinux repo, so builddep has nothing
    # to resolve from — it died here invisibly on the first attempt
    # (2026-07-23; container stdout was lost, hence the tee below).
    # kernel-devel: zfs's default configure probes a kernel tree even though
    # we only ship the dkms + userland rpms. In git mode the builder gets the
    # NEWEST F44 kernel-devel (7.1.x) — deliberately: configure against it is
    # the first signal on whether the git ref supports that kernel at all.
    dnf -y install \
        git rpm-build kernel-rpm-macros gcc make autoconf automake libtool \
        kernel-devel \
        libtirpc-devel libblkid-devel libuuid-devel systemd-devel \
        openssl-devel zlib-ng-compat-devel libaio-devel libattr-devel \
        elfutils-libelf-devel python3-devel python3-setuptools python3-cffi \
        libffi-devel ncompress libcurl-devel 2>&1 | tail -3 | tee -a "$LOG_FILE"
    rpm -q rpm-build gcc libtool >/dev/null 2>&1 ||
        die "ZFS-FROM-GIT: build toolchain install failed — see $LOG_FILE"
    git clone --depth 1 --branch "${_zfs_ref}" https://github.com/openzfs/zfs.git /tmp/zfs-git 2>&1 | tee -a "$LOG_FILE" ||
        die "git clone of openzfs ref '${_zfs_ref}' failed (branch/tag only, not a SHA)"
    (cd /tmp/zfs-git && ./autogen.sh && ./configure && make -j"$(nproc)" rpm-utils rpm-dkms) >>"$LOG_FILE" 2>&1 ||
        die "zfs from-git rpm build failed — tail $LOG_FILE"
    mapfile -t ZFS_GIT_RPMS < <(find /tmp/zfs-git -maxdepth 1 -name '*.rpm' \
        ! -name '*.src.rpm' ! -name '*debug*')
    ((${#ZFS_GIT_RPMS[@]})) || die "zfs from-git build produced no installable rpms"
    log "ZFS-FROM-GIT: built ${#ZFS_GIT_RPMS[@]} rpms"
    # Drop the repo zfs packages from the bootstrap set — the built rpms
    # replace them (the zfs repo file was never written in this mode).
    _pkgs_no_zfs=()
    for _p in "${PKGS[@]}"; do
        [[ "$_p" == "zfs" || "$_p" == "zfs-dkms" ]] || _pkgs_no_zfs+=("$_p")
    done
    PKGS=("${_pkgs_no_zfs[@]}")
fi

# Kernel selection: pinned koji set (release path) vs unpinned newest F44
# (ZFS-from-git test path).
DNF_KERNEL_ARGS=()
if ((${#ZFS_GIT_RPMS[@]})); then
    DNF_KERNEL_ARGS=(kernel kernel-core kernel-modules kernel-devel)
else
    DNF_KERNEL_ARGS=(--exclude='kernel*-7.[1-9]*' "${KOJI_KERNEL_URLS[@]}")
fi
dnf --installroot="$ROOTFS" --releasever=44 --setopt=install_weak_deps=False \
    --setopt=tsflags=nodocs --nogpgcheck -y install \
    "${DNF_KERNEL_ARGS[@]}" "${PKGS[@]}" "${ZFS_GIT_RPMS[@]}" 2>&1 | tee -a "$LOG_FILE"
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
    curl -sL "https://github.com/jimsalterjrs/sanoid/archive/refs/tags/v${SANOID_VER}.tar.gz" |
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
    EZA_VER="$(curl -fsSL https://api.github.com/repos/eza-community/eza/releases/latest 2>/dev/null |
        grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')" || true
    if [[ -n "$EZA_VER" ]]; then
        curl -fsSL "https://github.com/eza-community/eza/releases/download/v${EZA_VER}/eza_${ARCH}-unknown-linux-gnu.tar.gz" |
            tar xz -C "${ROOTFS}/usr/local/bin/" 2>/dev/null ||
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
    x86_64) _ttyd_arch="x86_64" ;;
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
    K9S_VERSION="$(curl -fsSL https://api.github.com/repos/derailed/k9s/releases/latest 2>/dev/null |
        grep '"tag_name"' | head -1 | sed 's/.*"\([^"]*\)".*/\1/')" || true
    case "$ARCH" in
    x86_64) _k9s_arch="amd64" ;;
    aarch64) _k9s_arch="arm64" ;;
    esac
    if [[ -n "$K9S_VERSION" ]]; then
        curl -fsSL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${_k9s_arch}.tar.gz" \
            2>/dev/null | tar xz -C "${ROOTFS}/usr/local/bin/" k9s 2>/dev/null &&
            chmod +x "${ROOTFS}/usr/local/bin/k9s" && log "k9s ${K9S_VERSION} installed." ||
            log "WARNING: k9s extract failed"
    else
        log "WARNING: could not resolve k9s version — skipping"
    fi

    # ── zxplore — the ZFS console, built from its OWN repo (github.com/zxplore/
    # zxplore) and PART OF THE OS on every profile. The repo is separate only
    # because zxplore runs on any OpenZFS system — kldload is its first-party
    # distribution, not an optional consumer. Built HERE in the F44 builder
    # (glibc matches the Fedora rootfs):
    #   zxplore-tui — static (CGO_ENABLED=0), zero runtime deps → ALL profiles;
    #                 the ZFS console works over SSH on every kldload box.
    #   zxplore     — Fyne GUI, needs the GL/X/wayland stack → every
    #                 GUI-capable rootfs (desktop, kvm's GNOME shell, …),
    #                 with icon + launcher beside the other tool tiles.
    #                 Replaces the old bash zexplore TUI.
    # TRACKS UPSTREAM MAIN by operator decision (2026-08-02): kldload and
    # zxplore are co-developed and ship together, so a tag pin here goes stale
    # the week it lands. The trade is documented unreproducibility — every
    # build logs AND bakes the exact ingested commit into
    # /etc/kldload/zxplore-commit so any image traces to its source. Set
    # ZXPLORE_REF=<tag|branch> to pin a specific build (release ISOs should).
    #
    # DARKSITE / OFFLINE builds: the source is cached on the host at
    # live-build/zxplore-cache (inside the gitignored live-build/ area, mounted
    # rw at /build). Online builds refresh the cache and ship the newest
    # commit; when the refresh fails (air-gapped builder) the build ships the
    # CACHED source with a loud warning instead of dying. Only a first-ever
    # build with neither network nor cache refuses — it cannot include what
    # was never fetched.
    ZXPLORE_REF="${ZXPLORE_REF:-}"
    log "Building zxplore (${ZXPLORE_REF:-main HEAD}) from github.com/zxplore/zxplore ..."
    rm -rf /tmp/zxplore-src /tmp/go-cache /tmp/go
    _zx_cache="/build/live-build/zxplore-cache"
    _zx_fresh=0
    if [[ -d "${_zx_cache}/.git" ]]; then
        if (git -C "$_zx_cache" fetch --depth 1 origin "${ZXPLORE_REF:-main}" &&
            git -C "$_zx_cache" reset --hard FETCH_HEAD) >>"$LOG_FILE" 2>&1; then
            _zx_fresh=1
        fi
    else
        _zx_clone=(git clone --depth 1)
        [[ -n "$ZXPLORE_REF" ]] && _zx_clone+=(--branch "$ZXPLORE_REF")
        if "${_zx_clone[@]}" https://github.com/zxplore/zxplore.git "$_zx_cache" >>"$LOG_FILE" 2>&1; then
            _zx_fresh=1
        fi
    fi
    [[ -d "${_zx_cache}/.git" ]] ||
        die "FATAL: zxplore unavailable — no network AND no cached source at live-build/zxplore-cache. zxplore is part of the OS; refusing to ship without it. Run one online build to populate the cache for darksite builds."
    if ((!_zx_fresh)); then
        log "WARNING: zxplore refresh failed (offline/darksite builder?) — shipping CACHED commit $(git -C "$_zx_cache" rev-parse --short HEAD) from $(git -C "$_zx_cache" log -1 --format=%cd --date=short)"
    fi
    # Build from a throwaway copy so go outputs never dirty the cache.
    cp -a "$_zx_cache" /tmp/zxplore-src
    _zx_commit="$(git -C /tmp/zxplore-src rev-parse HEAD)"
    log "zxplore commit: ${_zx_commit}"
    install -d "${ROOTFS}/etc/kldload"
    printf '%s\n' "$_zx_commit" >"${ROOTFS}/etc/kldload/zxplore-commit"

    # ── wgxplore — the WireGuard estate console, built from THIS repo (wg/).
    # It is the one console that is NOT a separate product. It was folded in
    # on 2026-08-10 because the thing it needs — who owns WireGuard identity
    # — is decided here: hosts mint their own keypairs at install time, and a
    # console that also minted keys was a second, weaker identity system.
    # zxplore and vmxplore stay upstream because they ARE products people run
    # on non-kldload machines; building those from a vendored copy would ship
    # something that is not the released binary.
    #
    # So: no clone, no cache, no network fetch for the source. The commit
    # stamp is this repo's HEAD, which is also the ISO's own build identity —
    # one answer to "which wgxplore is this?" instead of two that can differ.
    #
    # NOTE: Go MODULE downloads still need the network here, same as the
    # other two consoles (there is no vendor/ and GOPATH is wiped each run).
    # Moving the source in-tree removes one network dependency, not all of
    # them. A truly offline builder needs a seeded module cache — untouched
    # by this change and still an open gap.
    _wgx_src="/build/wg"
    [[ -f "${_wgx_src}/main.go" ]] ||
        die "FATAL: wg/ missing from the repo — the WireGuard console lives in-tree now, not upstream."
    log "Building wgxplore from in-tree wg/ ..."
    rm -rf /tmp/wgx-src
    cp -a "$_wgx_src" /tmp/wgx-src
    # Build artefacts from a developer's working tree must never reach the
    # ISO: .gotmp is the exec-capable TMPDIR used when testing locally.
    rm -rf /tmp/wgx-src/.gotmp
    _wgx_commit="$(git -C /build rev-parse HEAD 2>/dev/null || echo unknown)"
    log "wgxplore commit (kldload HEAD): ${_wgx_commit}"
    printf '%s\n' "$_wgx_commit" >"${ROOTFS}/etc/kldload/wgxplore-commit"

    if [[ -e "${ROOTFS}/usr/lib64/libGL.so.1" && -e "${ROOTFS}/usr/lib64/libxkbcommon.so.0" ]]; then
        if (cd /tmp/wgx-src &&
            HOME=/tmp GOCACHE=/tmp/go-cache GOPATH=/tmp/go \
                CGO_ENABLED=1 go build -trimpath -tags gui -ldflags "-X main.buildNum=${_wgx_commit:0:8}" -o /tmp/wgx-bin .) >>"$LOG_FILE" 2>&1; then
            if ! readelf -d /tmp/wgx-bin 2>/dev/null |
                grep -qiE 'NEEDED.*(libGL|libX11|libwayland|libxkbcommon)'; then
                die "FATAL: wgxplore built WITHOUT the GUI (no GL/X11/wayland libs) — '-tags gui' produced the terminal variant."
            fi
            install -Dm0755 /tmp/wgx-bin "${ROOTFS}/usr/local/bin/wgx" ||
                die "FATAL: wgx (GUI) install failed."
            log "wgx installed (GUI + TUI, GL-capable rootfs)."
        else
            die "FATAL: wgxplore GUI build failed — refusing to ship a GUI ISO without the WG console."
        fi
    elif (cd /tmp/wgx-src &&
        HOME=/tmp GOCACHE=/tmp/go-cache GOPATH=/tmp/go \
            CGO_ENABLED=0 go build -trimpath -ldflags "-X main.buildNum=${_wgx_commit:0:8}" -o /tmp/wgx-bin .) >>"$LOG_FILE" 2>&1; then
        install -Dm0755 /tmp/wgx-bin "${ROOTFS}/usr/local/bin/wgx" ||
            die "FATAL: wgx install failed."
        log "wgx installed (static TUI, headless rootfs)."
    else
        die "FATAL: wgxplore build failed — refusing to ship an ISO without the WG networks tool."
    fi

    # Icon, launcher and manual come from wg/ too, for the same reason the
    # binary does: one source. HISTORY 2026-08-10 — the icon used to be a
    # hand-maintained copy under includes.chroot, and it went stale the day
    # the mark was redrawn: the ISO would have shipped the old teal tile
    # while the repo and upstream both carried the new one. Fail loud rather
    # than ship a console with a missing or wrong face.
    [[ -r /tmp/wgx-src/assets/wgxplore.svg ]] ||
        die "FATAL: wgxplore icon absent (wg/assets/wgxplore.svg)."
    install -Dm0644 /tmp/wgx-src/assets/wgxplore.svg \
        "${ROOTFS}/usr/share/icons/hicolor/scalable/apps/wgxplore.svg" ||
        die "FATAL: wgxplore icon install failed."
    [[ -r /tmp/wgx-src/contrib/wgxplore.desktop ]] ||
        die "FATAL: wgxplore launcher absent (wg/contrib/wgxplore.desktop)."
    install -Dm0644 /tmp/wgx-src/contrib/wgxplore.desktop \
        "${ROOTFS}/usr/share/applications/wgxplore.desktop" ||
        die "FATAL: wgxplore launcher install failed."
    if [[ -r /tmp/wgx-src/docs/wgx.1 ]]; then
        install -Dm0644 /tmp/wgx-src/docs/wgx.1 \
            "${ROOTFS}/usr/share/man/man1/wgx.1"
    fi

    rm -f /tmp/wgx-bin
    rm -rf /tmp/wgx-src

    # ── kldload-buildmon — build progress and install audit, from in-tree
    # buildmon/. In-tree for the same reason wg/ is: it reads
    # /var/lib/kldload/phases, drives kldload-component and parses
    # /var/log/installer, so it is meaningless off a kldload box and there is
    # no upstream that would want it.
    #
    # WHY IT SHIPS AT ALL: the post-install build runs for up to six hours
    # after the desktop appears, and the display that used to say so was a
    # bash script repainting a terminal in place. On 2026-08-15 a screenshot
    # from .145 showed one pane painted by TWO of them 23 minutes apart —
    # duplicated Phase/Elapsed/Progress blocks, half-overwritten words, a
    # banner smeared into itself. The second job is bigger: `buildmon audit`
    # answers "did this install actually work", which is the question nobody
    # could answer on the morning an install shipped with no kernel because
    # one `E: Unable to locate package` line sat in a 387 KB log.
    #
    # TWO binaries, like the sisters: the static one goes everywhere
    # (headless servers included, where `buildmon audit` is the point), the
    # GUI only where the rootfs can actually link GL.
    _bm_src="/build/buildmon"
    [[ -f "${_bm_src}/main.go" ]] ||
        die "FATAL: buildmon/ missing from the repo — the build monitor lives in-tree."
    log "Building kldload-buildmon from in-tree buildmon/ ..."
    rm -rf /tmp/bm-src
    cp -a "$_bm_src" /tmp/bm-src
    # A developer's working tree carries build output and an exec-capable
    # TMPDIR; neither may reach the ISO.
    rm -rf /tmp/bm-src/.testtmp /tmp/bm-src/kldload-buildmon /tmp/bm-src/kldload-buildmon-tui
    _bm_commit="$(git -C /build rev-parse HEAD 2>/dev/null || echo unknown)"
    log "buildmon commit (kldload HEAD): ${_bm_commit}"
    printf '%s\n' "$_bm_commit" >"${ROOTFS}/etc/kldload/buildmon-commit"

    # Static first: this one is not optional on any profile.
    if (cd /tmp/bm-src &&
        HOME=/tmp GOCACHE=/tmp/go-cache GOPATH=/tmp/go \
            CGO_ENABLED=0 go build -trimpath -ldflags "-X main.buildNum=${_bm_commit:0:8}" \
            -o /tmp/bm-tui .) >>"$LOG_FILE" 2>&1; then
        install -Dm0755 /tmp/bm-tui "${ROOTFS}/usr/local/bin/kldload-buildmon-tui" ||
            die "FATAL: kldload-buildmon-tui install failed."
        log "kldload-buildmon-tui installed (static)."
    else
        die "FATAL: buildmon static build failed — refusing to ship an ISO that cannot audit its own installs."
    fi

    # GUI only where the rootfs can link it. Same readelf guard as wgx: a
    # '-tags gui' build that silently produced the terminal binary would
    # install a 'GUI' that opens no window, and nobody would notice until an
    # operator double-clicked it.
    if [[ -e "${ROOTFS}/usr/lib64/libGL.so.1" && -e "${ROOTFS}/usr/lib64/libxkbcommon.so.0" ]]; then
        if (cd /tmp/bm-src &&
            HOME=/tmp GOCACHE=/tmp/go-cache GOPATH=/tmp/go \
                CGO_ENABLED=1 go build -trimpath -tags gui \
                -ldflags "-X main.buildNum=${_bm_commit:0:8}" -o /tmp/bm-bin .) >>"$LOG_FILE" 2>&1; then
            if ! readelf -d /tmp/bm-bin 2>/dev/null |
                grep -qiE 'NEEDED.*(libGL|libX11|libwayland|libxkbcommon)'; then
                die "FATAL: kldload-buildmon built WITHOUT the GUI (no GL/X11/wayland libs) — '-tags gui' produced the terminal binary."
            fi
            install -Dm0755 /tmp/bm-bin "${ROOTFS}/usr/local/bin/kldload-buildmon" ||
                die "FATAL: kldload-buildmon (GUI) install failed."
            log "kldload-buildmon installed (GUI, GL-capable rootfs)."
        else
            die "FATAL: buildmon GUI build failed on a GL-capable rootfs."
        fi
    else
        log "buildmon GUI skipped (headless rootfs) — the static binary covers it."
    fi

    rm -f /tmp/bm-bin /tmp/bm-tui
    rm -rf /tmp/bm-src

    # ── ztxplore — the OpenZFS test lab, from in-tree ztxplore/.
    #
    # In-tree for the same reason buildmon and wg are: it drives kzfs-test,
    # reads kzfs-test's results directory and classifies this kernel's ring
    # buffer, so it is only correct against the version of those shipped in
    # the same ISO.
    #
    # It is one application on purpose. The lab used to be a web console tab
    # for the matrix, Grafana for the metrics, a terminal for dmesg and a
    # different web tab for the eBPF tools — four surfaces a ZFS developer had
    # to correlate by wall-clock time while chasing one assertion.
    _ztx_src="/build/ztxplore"
    [[ -f "${_ztx_src}/main.go" ]] ||
        die "FATAL: ztxplore/ missing from the repo — the OpenZFS test lab lives in-tree."
    log "Building ztxplore from in-tree ztxplore/ ..."
    rm -rf /tmp/ztx-src
    cp -a "$_ztx_src" /tmp/ztx-src
    # A developer's working tree carries build output and an exec-capable
    # TMPDIR; neither may reach the ISO.
    rm -rf /tmp/ztx-src/.testtmp /tmp/ztx-src/ztx /tmp/ztx-src/ztx-tui
    _ztx_commit="$(git -C /build rev-parse HEAD 2>/dev/null || echo unknown)"
    printf '%s\n' "$_ztx_commit" >"${ROOTFS}/etc/kldload/ztxplore-commit"

    # Static first. The lab runs on hypervisors, which are headless, so the
    # terminal build is the one that must always exist.
    if (cd /tmp/ztx-src &&
        HOME=/tmp GOCACHE=/tmp/go-cache GOPATH=/tmp/go \
            CGO_ENABLED=0 go build -trimpath -ldflags "-X main.buildNum=${_ztx_commit:0:8}" \
            -o /tmp/ztx-tui .) >>"$LOG_FILE" 2>&1; then
        install -Dm0755 /tmp/ztx-tui "${ROOTFS}/usr/local/bin/ztx-tui" ||
            die "FATAL: ztx-tui install failed."
        log "ztx-tui installed (static)."
    else
        die "FATAL: ztxplore static build failed."
    fi

    # GUI only where the rootfs can link it, with the same readelf guard as
    # buildmon and wgx: a '-tags gui' build that silently produced the
    # terminal binary installs a "GUI" that opens no window.
    if [[ -e "${ROOTFS}/usr/lib64/libGL.so.1" && -e "${ROOTFS}/usr/lib64/libxkbcommon.so.0" ]]; then
        if (cd /tmp/ztx-src &&
            HOME=/tmp GOCACHE=/tmp/go-cache GOPATH=/tmp/go \
                CGO_ENABLED=1 go build -trimpath -tags gui \
                -ldflags "-X main.buildNum=${_ztx_commit:0:8}" -o /tmp/ztx-bin .) >>"$LOG_FILE" 2>&1; then
            if ! readelf -d /tmp/ztx-bin 2>/dev/null |
                grep -qiE 'NEEDED.*(libGL|libX11|libwayland|libxkbcommon)'; then
                die "FATAL: ztx built WITHOUT the GUI (no GL/X11/wayland libs) — '-tags gui' produced the terminal binary."
            fi
            install -Dm0755 /tmp/ztx-bin "${ROOTFS}/usr/local/bin/ztx" ||
                die "FATAL: ztx (GUI) install failed."
            log "ztx installed (GUI, GL-capable rootfs)."
        else
            die "FATAL: ztxplore GUI build failed on a GL-capable rootfs."
        fi
    else
        log "ztxplore GUI skipped (headless rootfs) — ztx-tui covers it."
    fi

    rm -f /tmp/ztx-bin /tmp/ztx-tui
    rm -rf /tmp/ztx-src

    # ── vmxplore — the KVM console, built from its OWN repo
    # (github.com/vmxplore/vmxplore, public). Third console in the family and
    # the same deal as zxplore and wgxplore: it runs on ANY libvirt host, and
    # kldload is simply its first-party distribution. Tracks main with a
    # cache fallback so an air-gapped builder still ships something and says
    # loudly that it is cached; the ingested commit is baked into
    # /etc/kldload/vmxplore-commit so an image traces to its source.
    #
    # TWO binaries, like the sisters: `vmx` is the static terminal build
    # (CGO_ENABLED=0, zero runtime deps) and goes on EVERY profile, including
    # headless servers where it is the only way to drive KVM from the box.
    # `vmxplore` is the Fyne GUI and needs the GL/X/wayland stack, so it is
    # gated on the rootfs actually having one — asserted with readelf rather
    # than assumed, because a '-tags gui' build that silently produced the
    # terminal variant is how a GUI ISO ships without its console.
    VMXPLORE_REF="${VMXPLORE_REF:-}"
    log "Building vmxplore (${VMXPLORE_REF:-main HEAD}) from github.com/vmxplore/vmxplore ..."
    rm -rf /tmp/vmx-src
    _vmx_cache="/build/live-build/vmxplore-cache"
    _vmx_fresh=0
    if [[ -d "${_vmx_cache}/.git" ]]; then
        if (git -C "$_vmx_cache" fetch --depth 1 origin "${VMXPLORE_REF:-main}" &&
            git -C "$_vmx_cache" reset --hard FETCH_HEAD) >>"$LOG_FILE" 2>&1; then
            _vmx_fresh=1
        fi
    else
        _vmx_clone=(git clone --depth 1)
        [[ -n "$VMXPLORE_REF" ]] && _vmx_clone+=(--branch "$VMXPLORE_REF")
        if "${_vmx_clone[@]}" https://github.com/vmxplore/vmxplore.git "$_vmx_cache" >>"$LOG_FILE" 2>&1; then
            _vmx_fresh=1
        fi
    fi
    [[ -d "${_vmx_cache}/.git" ]] ||
        die "FATAL: vmxplore unavailable — no network AND no cached source at live-build/vmxplore-cache. Run one online build to populate the cache for darksite builds."
    if ((!_vmx_fresh)); then
        log "WARNING: vmxplore refresh failed (offline/darksite builder?) — shipping CACHED commit $(git -C "$_vmx_cache" rev-parse --short HEAD)"
    fi
    cp -a "$_vmx_cache" /tmp/vmx-src
    _vmx_commit="$(git -C /tmp/vmx-src rev-parse HEAD)"
    log "vmxplore commit: ${_vmx_commit}"
    printf '%s\n' "$_vmx_commit" >"${ROOTFS}/etc/kldload/vmxplore-commit"

    # the static TUI first: it is the one every profile gets
    if (cd /tmp/vmx-src &&
        HOME=/tmp GOCACHE=/tmp/go-cache GOPATH=/tmp/go \
            CGO_ENABLED=0 go build -trimpath -ldflags "-X main.buildNum=${_vmx_commit:0:8}" -o /tmp/vmx-bin .) >>"$LOG_FILE" 2>&1; then
        install -Dm0755 /tmp/vmx-bin "${ROOTFS}/usr/local/bin/vmx" ||
            die "FATAL: vmx (static TUI) install failed."
        log "vmx installed (static TUI, all profiles)."
    else
        die "FATAL: vmxplore TUI build failed — refusing to ship an ISO without the KVM console."
    fi
    rm -f /tmp/vmx-bin

    # the man page travels with either build: a console on a stranger's box
    # must not be undocumented, and `man vmxplore` is the first thing an
    # operator tries.
    if [[ -r /tmp/vmx-src/docs/vmxplore.1 ]]; then
        install -Dm0644 /tmp/vmx-src/docs/vmxplore.1 \
            "${ROOTFS}/usr/share/man/man1/vmxplore.1" ||
            die "FATAL: vmxplore man page install failed."
    else
        die "FATAL: vmxplore man page absent (docs/vmxplore.1) — upstream moved it."
    fi

    # the GUI, only where the rootfs can actually run it
    if [[ -e "${ROOTFS}/usr/lib64/libGL.so.1" && -e "${ROOTFS}/usr/lib64/libxkbcommon.so.0" ]]; then
        if (cd /tmp/vmx-src &&
            HOME=/tmp GOCACHE=/tmp/go-cache GOPATH=/tmp/go \
                CGO_ENABLED=1 go build -trimpath -tags gui -ldflags "-X main.buildNum=${_vmx_commit:0:8}" -o /tmp/vmxplore-bin .) >>"$LOG_FILE" 2>&1; then
            if ! readelf -d /tmp/vmxplore-bin 2>/dev/null |
                grep -qiE 'NEEDED.*(libGL|libX11|libwayland|libxkbcommon)'; then
                die "FATAL: vmxplore built WITHOUT the GUI (no GL/X11/wayland libs) — '-tags gui' produced the terminal variant."
            fi
            install -Dm0755 /tmp/vmxplore-bin "${ROOTFS}/usr/local/bin/vmxplore" ||
                die "FATAL: vmxplore (GUI) install failed."
            # Launcher + icon are not optional on a desktop profile — a KVM
            # console with no app icon is a broken install. Both come from
            # the upstream repo, so an absent file is a build-time failure
            # rather than a silently icon-less tool (the zxplore lesson,
            # 2026-07-27).
            [[ -r /tmp/vmx-src/packaging/vmxplore.svg ]] ||
                die "FATAL: vmxplore icon absent (packaging/vmxplore.svg) — upstream moved it."
            install -Dm0644 /tmp/vmx-src/packaging/vmxplore.svg \
                "${ROOTFS}/usr/share/icons/hicolor/scalable/apps/vmxplore.svg" ||
                die "FATAL: vmxplore icon install failed."
            for _vmx_desk in vmxplore.desktop vmxplore-tui.desktop; do
                [[ -r "/tmp/vmx-src/packaging/${_vmx_desk}" ]] ||
                    die "FATAL: vmxplore launcher absent (packaging/${_vmx_desk}) — upstream moved it."
                install -Dm0644 "/tmp/vmx-src/packaging/${_vmx_desk}" \
                    "${ROOTFS}/usr/share/applications/${_vmx_desk}" ||
                    die "FATAL: vmxplore .desktop install failed (${_vmx_desk})."
            done
            log "vmxplore installed: GUI + icon + launchers (from repo)."
        else
            die "FATAL: vmxplore GUI build failed — refusing to ship a GUI ISO without the KVM console."
        fi
    else
        log "vmxplore: headless rootfs — static vmx only, no GUI."
    fi
    rm -f /tmp/vmxplore-bin
    rm -rf /tmp/vmx-src

    # Static TUI — every profile. No build tag = the terminal-only variant
    # (pure Go, no Fyne/GL); CGO_ENABLED=0 keeps it fully static.
    if (cd /tmp/zxplore-src &&
        HOME=/tmp GOCACHE=/tmp/go-cache GOPATH=/tmp/go \
            CGO_ENABLED=0 go build -trimpath -ldflags "-X main.buildNum=${_zx_commit:0:8}" -o zxplore-tui .) >>"$LOG_FILE" 2>&1; then
        install -Dm0755 /tmp/zxplore-src/zxplore-tui "${ROOTFS}/usr/local/bin/zxplore-tui" ||
            die "FATAL: zxplore-tui install failed."
        log "zxplore-tui installed (static, all profiles)."
    else
        die "FATAL: zxplore-tui build failed — refusing to ship an ISO without the ZFS console."
    fi

    # GUI gate — CAPABILITY, not profile name: any rootfs shipping the GL/
    # Wayland stack gets the GUI + launcher; headless rootfs skip it
    # automatically. HISTORY: 2026-08-02 the kvm profile ships gnome-shell +
    # full GL yet the old PROFILE==desktop gate left it TUI-only — the
    # operator expects the console's tile beside sysdiag in the tray.
    if [[ -e "${ROOTFS}/usr/lib64/libGL.so.1" && -e "${ROOTFS}/usr/lib64/libxkbcommon.so.0" ]]; then
        # `-tags gui` is MANDATORY: zxplore gates its Fyne GUI behind the `gui`
        # build tag (every gui*.go is `//go:build gui`; nogui.go is
        # `//go:build !gui`). Without the tag, `go build .` compiles the
        # terminal-only variant — a pure-Go binary with NO Fyne/GL/X11 — which
        # is exactly the CLI-only `zxplore-tui` target, not the desktop GUI.
        # HISTORY: 2026-07-27 the tagless build shipped a 6.8M non-GUI binary
        # (34.9M GUI expected); the desktop's headline ZFS console was broken.
        # This matches the upstream Makefile `gui:` target.
        # NB: redirect (not | tee) so the `if` sees go build's REAL exit — a
        # piped `... | tee` returns tee's 0 and silently ships a broken build.
        if (cd /tmp/zxplore-src &&
            HOME=/tmp GOCACHE=/tmp/go-cache GOPATH=/tmp/go \
                CGO_ENABLED=1 go build -trimpath -tags gui -ldflags "-X main.buildNum=${_zx_commit:0:8}" -o zxplore .) >>"$LOG_FILE" 2>&1; then
            # Assert we actually built the GUI, not the tagless CLI fallback. A
            # Fyne cgo build dynamically links the GL/X11/wayland stack; the CLI
            # variant links only libc. If the GUI libs are absent the build tag
            # silently didn't take (renamed tag, toolchain change) — fail LOUD
            # rather than ship a launcher that opens a console-less binary.
            if ! readelf -d /tmp/zxplore-src/zxplore 2>/dev/null |
                grep -qiE 'NEEDED.*(libGL|libX11|libwayland|libxkbcommon)'; then
                die "FATAL: zxplore built WITHOUT the GUI (no GL/X11/wayland libs) — the '-tags gui' build produced the CLI variant. Refusing to ship a GUI-capable ISO with a headless zxplore."
            fi
            install -Dm0755 /tmp/zxplore-src/zxplore "${ROOTFS}/usr/local/bin/zxplore" ||
                die "FATAL: zxplore binary install failed."
            # Launcher + icon are NOT optional on the desktop profile: a ZFS
            # console with no app icon is a broken install. These come from the
            # UPSTREAM zxplore repo, which is a separate project that can move
            # files — so fail LOUD if they're absent instead of shipping a
            # launcher-less tool. HISTORY: 2026-07-27 an ISO cloned a zxplore
            # commit that predated assets/zxplore.svg + contrib/zxplore.desktop;
            # because `set -e` is relaxed in this section the two installs
            # failed SILENTLY and .129 shipped the binary with no icon/.desktop
            # while the log still said "installed". Existence-gate + `|| die`
            # turns that into a build-time failure the operator sees.
            # Ship BOTH upstream SVGs. As of 2026-08-10 the launcher's face is
            # Icon=zxplore — the borderless line-art mark that matches vmxplore
            # and wgxplore in the dock; zxplore-tui.svg is the terminal
            # edition's dark tile and still ships because that launcher points
            # at it. Install both regardless of which one the .desktop names:
            # HISTORY 2026-08-02, the build shipped only zxplore.svg while the
            # launcher referenced zxplore-tui → dangling Icon= → generic
            # fallback icon on every install. A kldload-branded replacement
            # icon was tried and reverted the same day: upstream's own art is
            # the right face, and upstream is where the family look is kept in
            # step across all three tools.
            _zx_desktop="/tmp/zxplore-src/contrib/zxplore.desktop"
            for _zx_svg in zxplore.svg zxplore-tui.svg; do
                [[ -r "/tmp/zxplore-src/assets/${_zx_svg}" ]] ||
                    die "FATAL: zxplore icon absent (assets/${_zx_svg}) — upstream repo moved it; GUI ISO needs its icons."
                install -Dm0644 "/tmp/zxplore-src/assets/${_zx_svg}" \
                    "${ROOTFS}/usr/share/icons/hicolor/scalable/apps/${_zx_svg}" ||
                    die "FATAL: zxplore icon install failed (${_zx_svg})."
            done
            [[ -r "$_zx_desktop" ]] ||
                die "FATAL: zxplore launcher absent ($_zx_desktop) — upstream repo moved it; GUI ISO needs a .desktop."
            # Icons live in /usr/share/icons/hicolor (NOT /usr/local/share):
            # that is where the installer's icon-copy glob in profiles.sh
            # looks. HISTORY: 2026-07-28 the icon sat in /usr/local/share and
            # installed targets got the binary but no icon/launcher.
            install -Dm0644 "$_zx_desktop" \
                "${ROOTFS}/usr/share/applications/zxplore.desktop" ||
                die "FATAL: zxplore .desktop install failed."
            rm -rf /tmp/zxplore-src /tmp/go-cache /tmp/go
            log "zxplore installed: binary + icon + launcher (from repo)."
        else
            die "FATAL: zxplore go build failed — refusing to ship a GUI-capable ISO without it."
        fi
    fi

    # Download helper: retry up to 3 times on failure, then FAIL the build.
    # Silent warnings here used to ship ISOs with missing exporter binaries
    # (observed on .133 2026-05-16: libvirt-exporter + process-exporter both
    # missing, observability dashboards empty). If GitHub is unreachable at
    # build time the operator needs to know — not discover it post-install.
    _fetch_with_retry() {
        local _url="$1" _out="$2" _what="$3"
        local _i
        for _i in 1 2 3; do
            if curl -fsSL --connect-timeout 15 --max-time 120 "$_url" -o "$_out"; then
                return 0
            fi
            log "  ${_what} download attempt $_i/3 failed (curl rc=$?), retrying in 5s..."
            sleep 5
        done
        return 1
    }

    # helm — same silent-warning class of bug previously hit k9s/exporters.
    # Until .135 2026-06-05 the helm download had `2>/dev/null` + a WARNING
    # log line on failure, so builds shipped without helm and "Helm tab
    # shows not installed" was a recurring report. Now uses the retry
    # helper and DIES if helm can't be fetched after 3 tries (just like
    # node_exporter/process-exporter below).
    log "Installing helm (live host) from get.helm.sh..."
    HELM_VERSION="${HELM_VERSION:-v3.16.2}"
    if _fetch_with_retry \
        "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH_DEB}.tar.gz" \
        /tmp/helm.tar.gz "helm"; then
        tar -xzf /tmp/helm.tar.gz -C /tmp/
        install -m 755 "/tmp/linux-${ARCH_DEB}/helm" "${ROOTFS}/usr/local/bin/helm"
        rm -rf /tmp/helm.tar.gz "/tmp/linux-${ARCH_DEB}"
        log "helm ${HELM_VERSION} installed on live host (${ARCH_DEB})."
    else
        log "FATAL: helm download failed after 3 retries — refusing to ship an ISO without helm."
        exit 1
    fi

    # process-exporter — per-process CPU/RSS/IO grouped by binary name.
    # node_exporter only exposes aggregate process counts; process-exporter
    # gives "which specific process is hogging" — essential for finding the
    # rogue qemu-kvm, the stuck zfs send, the misbehaving kubelet, etc.
    # Static Go binary from ncabatoff/process-exporter releases.
    log "Installing process-exporter from GitHub..."
    PROCESS_EXPORTER_VERSION="${PROCESS_EXPORTER_VERSION:-0.8.7}"
    case "$ARCH" in
    x86_64) _pe_arch="amd64" ;;
    aarch64) _pe_arch="arm64" ;;
    esac
    if _fetch_with_retry \
        "https://github.com/ncabatoff/process-exporter/releases/download/v${PROCESS_EXPORTER_VERSION}/process-exporter-${PROCESS_EXPORTER_VERSION}.linux-${_pe_arch}.tar.gz" \
        /tmp/process-exporter.tar.gz "process-exporter"; then
        tar -xzf /tmp/process-exporter.tar.gz -C /tmp/
        install -m 755 /tmp/process-exporter-*/process-exporter "${ROOTFS}/usr/local/bin/process-exporter" ||
            die "process-exporter extract failed — tarball layout changed?"
        rm -rf /tmp/process-exporter.tar.gz /tmp/process-exporter-*
        log "process-exporter ${PROCESS_EXPORTER_VERSION} installed."
    else
        die "process-exporter download failed after 3 retries — check network or GitHub status. Observability stack would ship broken."
    fi

    # libvirt-exporter — Prometheus exporter for libvirt-managed VMs.
    # Agentless: queries libvirt API on the host, emits per-VM (per-domain)
    # CPU/RAM/disk/network metrics without needing anything inside guests.
    # Powers the klab-vm-estate Grafana dashboard's "every VM is a virtual
    # host" view. Critical for ZFS test forensics — operators can see which
    # test VM is CPU-starved or disk-thrashed without SSH'ing into each one.
    # Static Go binary from inovex/prometheus-libvirt-exporter releases.
    log "Installing libvirt-exporter from GitHub..."
    LIBVIRT_EXPORTER_VERSION="${LIBVIRT_EXPORTER_VERSION:-2.3.1}"
    case "$ARCH" in
    x86_64) _lvexp_arch="amd64" ;;
    aarch64) _lvexp_arch="arm64" ;;
    esac
    if _fetch_with_retry \
        "https://github.com/inovex/prometheus-libvirt-exporter/releases/download/v${LIBVIRT_EXPORTER_VERSION}/prometheus-libvirt-exporter-${LIBVIRT_EXPORTER_VERSION}.linux-${_lvexp_arch}.tar.gz" \
        /tmp/libvirt-exporter.tar.gz "libvirt-exporter"; then
        tar -xzf /tmp/libvirt-exporter.tar.gz -C /tmp/
        # Tarball ships the binary as `prometheus-libvirt-exporter` at top-level.
        install -m 755 /tmp/prometheus-libvirt-exporter "${ROOTFS}/usr/local/bin/libvirt-exporter" 2>/dev/null ||
            install -m 755 /tmp/prometheus-libvirt-exporter-*/prometheus-libvirt-exporter "${ROOTFS}/usr/local/bin/libvirt-exporter" 2>/dev/null ||
            die "libvirt-exporter extract layout unexpected — release tarball may have changed"
        rm -rf /tmp/libvirt-exporter.tar.gz /tmp/prometheus-libvirt-exporter*
        log "libvirt-exporter ${LIBVIRT_EXPORTER_VERSION} installed."
    else
        die "libvirt-exporter download failed after 3 retries — check network or GitHub status. Per-VM metrics would be missing."
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
        2>&1 | tee -a "$LOG_FILE" ||
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
            "$SIGN_FILE" sha256 "${MOK_DIR}/mok.key" "${MOK_DIR}/mok.pub" "$_ko" 2>/dev/null &&
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
        printf 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch\n' >"${ROOTFS}/etc/pacman.d/mirrorlist"
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
    _apk_ver="$(curl -sfL "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/${ARCH_ALPINE}/" |
        grep -oP 'apk-tools-static-\K[0-9][^"]*(?=\.apk)' | head -1)" || true
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
echo "kldload" >"${ROOTFS}/etc/hostname"

# Live user
chroot "$ROOTFS" useradd -m -G wheel -s /bin/bash live 2>/dev/null || true
echo "live:live" | chroot "$ROOTFS" chpasswd
echo "root:kldload" | chroot "$ROOTFS" chpasswd

# Passwordless sudo for wheel
echo "%wheel ALL=(ALL) NOPASSWD: ALL" >"${ROOTFS}/etc/sudoers.d/wheel-nopasswd"
chmod 440 "${ROOTFS}/etc/sudoers.d/wheel-nopasswd"

# Enable SSH password auth on the live ISO (CentOS 9 disables it by default)
mkdir -p "${ROOTFS}/etc/ssh/sshd_config.d"
cat >"${ROOTFS}/etc/ssh/sshd_config.d/50-kldload-live.conf" <<'SSHEOF'
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
cat >"${ROOTFS}/etc/gdm/custom.conf" <<'GDMCONF'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=live

[security]

[xdmcp]

[chooser]

[debug]
GDMCONF

# Auto-launch Chrome to webui on live session login (free edition only, not Bob).
#
# Browser choice — Chrome, not Firefox. Per task #15/#47, kldload defaults to
# google-chrome-stable as the only shipped browser. Firefox is uninstalled
# at install time by kldload-firstboot. Operator on .142 b644 caught this
# block still hard-coding `firefox` after the Chrome migration, leaving the
# autostart silently broken on every fresh boot.
#
# Cert trust — no per-browser NSS DB cert import is needed here. The
# kldload-trust-cert service-mode (called via kldload-tls-cert.service's
# ExecStartPost) seeds /etc/skel/.pki/nssdb plus every existing user's
# NSS DB with the kldload-webui cert at trust flag CT,C,T before any user
# session opens. Chrome reads ~/.pki/nssdb on launch; the cert is already
# trusted by the time this autostart fires.
#
# --app= launches in app-mode (no address bar, no tabs) so the UI feels
# like a kiosk app instead of a browser tab — matches the "disguised
# desktop, push-button UI behind familiar chrome" positioning.
if [[ "$EDITION" != "core" && "${BOB_LIVE:-}" != "1" ]]; then
    mkdir -p "${ROOTFS}/etc/xdg/autostart"

    # Carry kldload's own autostart entries from includes.chroot.
    #
    # Only the build monitor by name, deliberately. includes.chroot also holds
    # kldload-zfs-bookmarks.desktop, which is referenced by NOTHING in this
    # build script or the installer — a dead file, and a glob here would
    # silently switch it on for every user. It stays dead until someone
    # decides otherwise on purpose.
    #
    # The installer glob-copies /etc/xdg/autostart/kldload-*.desktop from the
    # live system to the target (profiles.sh), so getting the file onto the
    # LIVE rootfs here is what makes it reach an installed machine too.
    if [[ -f /build/live-build/config/includes.chroot/etc/xdg/autostart/kldload-build-monitor.desktop ]]; then
        install -m0644 \
            /build/live-build/config/includes.chroot/etc/xdg/autostart/kldload-build-monitor.desktop \
            "${ROOTFS}/etc/xdg/autostart/kldload-build-monitor.desktop"
        log "Build-progress monitor autostart installed."
    else
        log "WARNING: kldload-build-monitor.desktop missing — an install will give no on-screen build progress."
    fi

    cat >"${ROOTFS}/etc/xdg/autostart/kldload-webui.desktop" <<'AUTOSTART'
[Desktop Entry]
Type=Application
Name=kldload Web UI
Exec=/usr/local/bin/kldload-webui-launch
Icon=kldload-webui
StartupWMClass=com.kldload.webui
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=8
AUTOSTART

    # Relaunch path — the autostart above opens the installer UI ONCE, but
    # xdg-autostart entries never appear in the app grid. Operator on the
    # 1.4.0-rc2 live ISO (2026-08-04): closed the installer window and had
    # NO way back — no Win+A icon, and stock Chrome's default page isn't
    # the UI. Two live-only artifacts fix it; BOTH carry the `-live` suffix
    # and are removed by profiles.sh at install time (installed systems get
    # their surface from the profile, never from live leftovers):
    #   1. a VISIBLE grid launcher, so closing the window is recoverable;
    #   2. a Chrome managed policy so even a stock Chrome launch lands on
    #      the UI instead of a blank new-tab page.
    mkdir -p "${ROOTFS}/usr/share/applications"
    cat >"${ROOTFS}/usr/share/applications/kldload-installer-live.desktop" <<'LIVEDESKTOP'
[Desktop Entry]
Type=Application
Name=Install kldload
GenericName=System installer
Comment=Reopen the kldload installer UI
Exec=/usr/local/bin/kldload-webui-launch
Icon=kldload-console
StartupWMClass=com.kldload.webui
Terminal=false
Categories=System;
StartupNotify=true
LIVEDESKTOP
    mkdir -p "${ROOTFS}/etc/opt/chrome/policies/managed"
    cat >"${ROOTFS}/etc/opt/chrome/policies/managed/kldload-live.json" <<'LIVECHROME'
{
  "RestoreOnStartup": 4,
  "RestoreOnStartupURLs": ["https://localhost:8443"],
  "HomepageLocation": "https://localhost:8443",
  "HomepageIsNewTabPage": false,
  "ShowHomeButton": true
}
LIVECHROME

    # Disable screensaver / screen blank / auto-lock on live session
    # Method 1: dconf system database (GNOME settings)
    #
    # Two-layer config:
    #   00-kldload-desktop          → full desktop dconf from source
    #                                 (theme, fonts, terminal profile, idle policy)
    #   01-kldload-terminal-default → terminal profile + default font/colors
    #                                 (font = "Monospace 12" — explicit so dconf
    #                                 doesn't fall back to GNOME's variable-pitch
    #                                 "Adwaita Mono" which renders weird in a
    #                                 terminal; bug seen on .107 XPS 2026-05-16)
    #   99-kldload-live-session     → live-ISO-only overrides (idle=0, etc.)
    #
    # Previous revision had a single inline heredoc here that wrote a STRIPPED
    # 00-kldload-desktop with no font / terminal settings — clobbering the
    # source file in includes.chroot AND never shipping 01-kldload-terminal-default
    # at all. Result: every install on F44+ inherited "Adwaita Mono 11" from
    # the GNOME system default. Fixed by copying from source and writing the
    # live-session quirks as a separate file with a higher numeric prefix.
    mkdir -p "${ROOTFS}/etc/dconf/db/local.d" "${ROOTFS}/etc/dconf/profile"
    cat >"${ROOTFS}/etc/dconf/profile/user" <<'DCONFPROFILE'
user-db:user
system-db:local
DCONFPROFILE
    # Copy the real desktop + terminal-default files from source.
    if [[ -f /build/live-build/config/includes.chroot/etc/dconf/db/local.d/00-kldload-desktop ]]; then
        cp /build/live-build/config/includes.chroot/etc/dconf/db/local.d/00-kldload-desktop \
            "${ROOTFS}/etc/dconf/db/local.d/00-kldload-desktop"
    else
        die "FATAL: includes.chroot/etc/dconf/db/local.d/00-kldload-desktop missing — build dropped it"
    fi
    if [[ -f /build/live-build/config/includes.chroot/etc/dconf/db/local.d/01-kldload-terminal-default ]]; then
        cp /build/live-build/config/includes.chroot/etc/dconf/db/local.d/01-kldload-terminal-default \
            "${ROOTFS}/etc/dconf/db/local.d/01-kldload-terminal-default"
    fi
    # Wildcard copy ANY dconf override that operator added to source — avoids
    # the "I added a file but the build doesn't ship it" footgun that bit us
    # on b646 (konsole assets, terminal-default, etc.). Operator on .142 b646
    # 2026-06-08: dock still had konsole pinned because the 3-pin favorites
    # file was untracked AND build-iso.sh had no wildcard copy.
    #
    # EXPLICIT EXCLUSION: 50-kldload-installed-favorites is intentionally NOT
    # shipped into the live rootfs — profiles.sh writes it onto the install
    # TARGET at install-time. Shipping it into the live ISO (b649 regression)
    # makes the live dconf pin Files/Chrome/sysdiag instead of the installer
    # browser, breaking the live install-popup UX. The file lives in source
    # under live-build/config/includes.chroot/etc/dconf/db/local.d/ as a
    # reference + so editors can find it; do not also ship it.
    for _dconf in /build/live-build/config/includes.chroot/etc/dconf/db/local.d/*-kldload-*; do
        [[ -f "$_dconf" ]] || continue
        case "$(basename "$_dconf")" in
        50-kldload-installed-favorites) continue ;;
        esac
        cp "$_dconf" "${ROOTFS}/etc/dconf/db/local.d/$(basename "$_dconf")"
    done

    # ── Konsole assets — wildcard copy custom kldload schemes + profile ───────
    # Operator on .142 b646 2026-06-08: sysdiag was opening in bright Konsole
    # default scheme even with desktop in dark mode, because the kldload-dark/
    # kldload-light colorschemes never made it into the ISO — Konsole's -p
    # ColorScheme=kldload-dark silently no-op'd without the .colorscheme files.
    mkdir -p "${ROOTFS}/usr/share/konsole"
    for _kf in /build/live-build/config/includes.chroot/usr/share/konsole/kldload*; do
        [[ -f "$_kf" ]] || continue
        cp "$_kf" "${ROOTFS}/usr/share/konsole/$(basename "$_kf")"
    done
    if [[ -f /build/live-build/config/includes.chroot/etc/xdg/konsolerc ]]; then
        mkdir -p "${ROOTFS}/etc/xdg"
        cp /build/live-build/config/includes.chroot/etc/xdg/konsolerc \
            "${ROOTFS}/etc/xdg/konsolerc"
    fi

    # ── systemd drop-ins kldload ships (ollama keep-alive, etc.) ──────────────
    for _dropdir in /build/live-build/config/includes.chroot/etc/systemd/system/*.d; do
        [[ -d "$_dropdir" ]] || continue
        _svc=$(basename "$_dropdir")
        mkdir -p "${ROOTFS}/etc/systemd/system/${_svc}"
        for _conf in "$_dropdir"/*.conf; do
            [[ -f "$_conf" ]] || continue
            cp "$_conf" "${ROOTFS}/etc/systemd/system/${_svc}/$(basename "$_conf")"
        done
    done

    # ── GTK 3 / GTK 4 dark-theme defaults ─────────────────────────────────────
    # Plain GTK3/GTK4 apps don't read GNOME's color-scheme dconf key; they
    # only honour gtk-3.0/settings.ini + gtk-4.0/settings.ini. Without these
    # files in the rootfs, random app windows render against a white canvas
    # on a kldload-dark desktop. .137 1.3.0-b625 shipped without them
    # because nothing in this script copied that path. Hard-fail loudly if
    # the source files are missing — they ARE in includes.chroot, so a miss
    # means the bind mount or copy step is broken.
    for _gtkdir in gtk-3.0 gtk-4.0; do
        _src="/build/live-build/config/includes.chroot/etc/${_gtkdir}/settings.ini"
        if [[ -f "$_src" ]]; then
            mkdir -p "${ROOTFS}/etc/${_gtkdir}"
            cp "$_src" "${ROOTFS}/etc/${_gtkdir}/settings.ini"
        else
            die "FATAL: $_src missing — GTK ${_gtkdir} dark theme defaults not shipped"
        fi
    done
    unset _src

    # ── Third-party RPM repos shipped in /etc/yum.repos.d/ ────────────────────
    # google-chrome.repo lets dnf resolve google-chrome-stable at install
    # time; without it, profiles.sh added Chrome to the dnf install list but
    # dnf couldn't find the package and silently dropped it (1.3.0-b625
    # shipped with .repo missing -> Chrome not installed -> firefox-esr
    # still default in the dock).
    if [[ -d /build/live-build/config/includes.chroot/etc/yum.repos.d ]]; then
        mkdir -p "${ROOTFS}/etc/yum.repos.d"
        for _r in /build/live-build/config/includes.chroot/etc/yum.repos.d/*.repo; do
            [[ -f "$_r" ]] || continue
            cp "$_r" "${ROOTFS}/etc/yum.repos.d/$(basename "$_r")"
        done
        unset _r
    fi

    # Install Chrome INTO the live rootfs now that google-chrome.repo is present.
    # The webui autostart renders the dashboard via kldload-chrome-app (Chrome —
    # its Web Speech API powers Bob's mic). The repo alone only lets the INSTALLED
    # system pull Chrome via profiles.sh; the LIVE ISO never installed it, so the
    # live session had the repo + firefox but no Chrome → the app window silently
    # never opened (F44 live 2026-06-13: GNOME up, webui :8443 HTTP 200, but
    # CHROME MISSING). Hard-fail — the live env has no firstboot heal net, so a
    # browserless live ISO is a defect, not a degrade.
    if [[ -f "${ROOTFS}/etc/yum.repos.d/google-chrome.repo" ]]; then
        dnf --installroot="$ROOTFS" --releasever=44 --setopt=install_weak_deps=False \
            --setopt=tsflags=nodocs --nogpgcheck -y install google-chrome-stable 2>&1 | tee -a "$LOG_FILE"
        chroot "$ROOTFS" rpm -q google-chrome-stable >/dev/null 2>&1 ||
            die "FATAL: google-chrome-stable not installed into live rootfs — webui app window will not open"
        log "google-chrome-stable installed into live rootfs"
    fi

    # ── Hide stock TUI launchers on the LIVE grid ─────────────────────────────
    # htop is a terminal app and ships its own GUI tile; on the live grid it's
    # clutter (the operator opens it from a terminal). Mirror what profiles.sh
    # does on the installed target. vim correctly ships no tile — htop should
    # match. NoDisplay hides the tile without removing the tool.
    for _hide in htop; do
        _hd="${ROOTFS}/usr/share/applications/${_hide}.desktop"
        if [[ -f "$_hd" ]] && ! grep -q '^NoDisplay=true' "$_hd"; then
            printf 'NoDisplay=true\n' >>"$_hd"
            log "live grid: hid ${_hide}.desktop (TUI tool, no GUI tile needed)"
        fi
    done

    # ── kldload-branded wallpapers ────────────────────────────────────────────
    # /usr/share/backgrounds/kldload/{default,default-dark}.png — referenced by
    # both 00-kldload-desktop dconf (picture-uri / picture-uri-dark) AND
    # /etc/dconf/db/local.d/01-kldload-wallpaper that profiles.sh writes at
    # install time. Without these PNGs in the rootfs, the new install asserted
    # via k_install_tree "wallpapers: source dir missing" on .137-class boots
    # (1.3.0-b631 / 14:06:58 install run). Hard-fail the build if the source
    # dir is empty — these are load-bearing for the desktop visual identity.
    if [[ -d /build/live-build/config/includes.chroot/usr/share/backgrounds/kldload ]]; then
        mkdir -p "${ROOTFS}/usr/share/backgrounds/kldload"
        cp /build/live-build/config/includes.chroot/usr/share/backgrounds/kldload/*.png \
            "${ROOTFS}/usr/share/backgrounds/kldload/"
        _wp_count=$(find "${ROOTFS}/usr/share/backgrounds/kldload" -maxdepth 1 -name '*.png' | wc -l)
        ((_wp_count > 0)) || die "FATAL: wallpaper copy dropped all files in ${ROOTFS}/usr/share/backgrounds/kldload"
        log "kldload wallpapers installed: ${_wp_count} png(s)"
        unset _wp_count
    else
        die "FATAL: includes.chroot/usr/share/backgrounds/kldload missing — desktop has no branded wallpaper"
    fi
    # Live-ISO-only overrides — idle=0 to keep the session up indefinitely
    # during install, no auto-lock, suppress GNOME welcome dialog. These
    # ride alongside (not on top of) the source files thanks to the 99-
    # prefix; dconf merges them at db build time.
    cat >"${ROOTFS}/etc/dconf/db/local.d/99-kldload-live-session" <<'DCONFLIVE'
# kldload — live-ISO-only quirks. Suppresses idle, lock, welcome dialog
# so the operator can leave the live session open while watching a long
# install. Installed-system overrides live in 00-kldload-desktop.
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

# Wallpaper — show F44 branding on the LIVE installer (clear "you're in
# the installer, not the installed system" signal) instead of inheriting
# 00-kldload-desktop's kldload-branded background. Installed-system
# wallpaper is unaffected — 00-kldload-desktop applies post-install.
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/f44/default/f44-01-day.jxl'
picture-uri-dark='file:///usr/share/backgrounds/f44/default/f44-01-night.jxl'
picture-options='zoom'
primary-color='#241f31'
secondary-color='#241f31'
DCONFLIVE
    # Lock these settings so the user can't accidentally re-enable
    mkdir -p "${ROOTFS}/etc/dconf/db/local.d/locks"
    cat >"${ROOTFS}/etc/dconf/db/local.d/locks/kldload-live" <<'LOCKS'
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
    cat >"${ROOTFS}/etc/X11/xinit/xinitrc.d/99-no-blank.sh" <<'XSET'
#!/bin/sh
xset s off s noblank 2>/dev/null || true
xset -dpms 2>/dev/null || true
XSET
    chmod +x "${ROOTFS}/etc/X11/xinit/xinitrc.d/99-no-blank.sh"

    # Method 4: kernel — disable console blanking
    mkdir -p "${ROOTFS}/etc/sysctl.d"
    echo "kernel.consoleblank=0" >"${ROOTFS}/etc/sysctl.d/99-no-blank.conf"
fi

# Edition marker — lets runtime tools distinguish free vs core edition
mkdir -p "${ROOTFS}/etc/kldload"
echo "$EDITION" >"${ROOTFS}/etc/kldload/edition"

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
echo "$GIT_SHA" >"${ROOTFS}/etc/kldload-build-sha"
echo "${VERSION}-b${BUILD_NUM}" >"${ROOTFS}/etc/kldload-build-id"
log "Build ID: ${VERSION}-b${BUILD_NUM} (${GIT_SHA})"

# OS branding
cat >"${ROOTFS}/etc/os-release" <<OSREL
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
    # Wholesale-copy /usr/local/bin/ from includes.chroot — the includes
    # tree is the curated source of truth, so anything that lands there
    # should reach the rootfs without an allow-list maintenance burden.
    # Previous opt-in list silently dropped new tools (caught build #33
    # 2026-05-18: kldload-follow was added for F3 but never copied →
    # operator hit F3 and got "command not found"). chmod +x preserves
    # the +x bit; cp -p keeps mtimes for debug correlation.
    for src in /build/live-build/config/includes.chroot/usr/local/bin/*; do
        [[ -f "$src" ]] || continue
        cp -p "$src" "${ROOTFS}/usr/local/bin/"
        chmod +x "${ROOTFS}/usr/local/bin/$(basename "$src")"
    done

    # Component registry for kldload-component. Globbed, not listed, for the
    # same reason the loop above is: an opt-in list silently drops new entries.
    # This bit us immediately — rc4 shipped /usr/local/bin/kldload-component
    # (picked up by the glob above) with NO registry, so `list` printed a bare
    # header and every `install` answered "unknown component". A tool without
    # its data is a broken tool, not a missing feature.
    if compgen -G "/build/live-build/config/includes.chroot/usr/lib/kldload/components/*.component" >/dev/null; then
        mkdir -p "${ROOTFS}/usr/lib/kldload/components"
        cp -p /build/live-build/config/includes.chroot/usr/lib/kldload/components/*.component \
            "${ROOTFS}/usr/lib/kldload/components/"
        log "component registry: $(find "${ROOTFS}/usr/lib/kldload/components" -name '*.component' | wc -l) components"
    else
        log "WARN: no component definitions found — kldload-component will have an empty registry"
    fi

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
        "${_whisper_tmp}/whisper.cpp" >>"$LOG_FILE" 2>&1; then
        cp -a "${_whisper_tmp}/whisper.cpp" "${ROOTFS}/opt/whisper.cpp"
        mount --bind /proc "${ROOTFS}/proc" 2>/dev/null || true
        mount --bind /sys "${ROOTFS}/sys" 2>/dev/null || true
        mount --bind /dev "${ROOTFS}/dev" 2>/dev/null || true
        if chroot "${ROOTFS}" bash -c \
            "cd /opt/whisper.cpp && cmake -B build && cmake --build build --config Release -j\$(nproc)" \
            >>"$LOG_FILE" 2>&1; then
            log "Bob: whisper.cpp built"
        else
            log "Bob: WARNING — whisper.cpp build failed (voice input disabled)"
        fi
        umount "${ROOTFS}/proc" 2>/dev/null || true
        umount "${ROOTFS}/sys" 2>/dev/null || true
        umount "${ROOTFS}/dev" 2>/dev/null || true
        # Download base.en model (~150 MB)
        mkdir -p "${ROOTFS}/opt/whisper.cpp/models"
        curl -fsSL -o "${ROOTFS}/opt/whisper.cpp/models/ggml-base.en.bin" \
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin" \
            >>"$LOG_FILE" 2>&1 &&
            log "Bob: whisper model downloaded" ||
            log "Bob: WARNING — whisper model download failed"
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
        mount --bind /sys "${ROOTFS}/sys" 2>/dev/null || true
        mount --bind /dev "${ROOTFS}/dev" 2>/dev/null || true
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
        " >>"$LOG_FILE" 2>&1; then
            log "  lh installed: $(stat -c '%s bytes' "${ROOTFS}/usr/local/bin/lh" 2>/dev/null)"
        else
            log "  WARNING: lh build failed — F5 will fall back to journalctl"
        fi
        umount "${ROOTFS}/proc" 2>/dev/null || true
        umount "${ROOTFS}/sys" 2>/dev/null || true
        umount "${ROOTFS}/dev" 2>/dev/null || true
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
        >>"$LOG_FILE" 2>&1; then
        tar xzf "${_obs_tmp}/zfs_exporter.tgz" -C "${_obs_tmp}" >>"$LOG_FILE" 2>&1
        install -m 0755 "${_obs_tmp}"/zfs_exporter-*/zfs_exporter "${ROOTFS}/usr/local/bin/zfs_exporter"
    else
        log "  WARNING zfs_exporter download failed"
        _obs_ok=0
    fi
    # smartctl_exporter
    if curl -fsSL -o "${_obs_tmp}/smartctl_exporter.tgz" \
        "https://github.com/prometheus-community/smartctl_exporter/releases/download/v0.14.0/smartctl_exporter-0.14.0.linux-amd64.tar.gz" \
        >>"$LOG_FILE" 2>&1; then
        tar xzf "${_obs_tmp}/smartctl_exporter.tgz" -C "${_obs_tmp}" >>"$LOG_FILE" 2>&1
        install -m 0755 "${_obs_tmp}"/smartctl_exporter-*/smartctl_exporter "${ROOTFS}/usr/local/bin/smartctl_exporter"
    else
        log "  WARNING smartctl_exporter download failed"
        _obs_ok=0
    fi
    # loki (single binary, zip archive)
    if curl -fsSL -o "${_obs_tmp}/loki.zip" \
        "https://github.com/grafana/loki/releases/download/v3.3.2/loki-linux-amd64.zip" \
        >>"$LOG_FILE" 2>&1; then
        (cd "${_obs_tmp}" && unzip -o loki.zip >>"$LOG_FILE" 2>&1)
        install -m 0755 "${_obs_tmp}/loki-linux-amd64" "${ROOTFS}/usr/local/bin/loki"
    else
        log "  WARNING loki download failed"
        _obs_ok=0
    fi
    # promtail (same release)
    if curl -fsSL -o "${_obs_tmp}/promtail.zip" \
        "https://github.com/grafana/loki/releases/download/v3.3.2/promtail-linux-amd64.zip" \
        >>"$LOG_FILE" 2>&1; then
        (cd "${_obs_tmp}" && unzip -o promtail.zip >>"$LOG_FILE" 2>&1)
        install -m 0755 "${_obs_tmp}/promtail-linux-amd64" "${ROOTFS}/usr/local/bin/promtail"
    else
        log "  WARNING promtail download failed"
        _obs_ok=0
    fi
    rm -rf "${_obs_tmp}"
    # Enable the 4 services in the live ISO rootfs so they start at first
    # boot on the installed target too (profiles.sh copies these). Persistent
    # journal is enabled via includes.chroot/etc/systemd/journald.conf.d.
    for _svc in zfs_exporter smartctl_exporter loki promtail; do
        if [[ -f "${ROOTFS}/usr/lib/systemd/system/${_svc}.service" ]]; then
            chroot "${ROOTFS}" systemctl enable "${_svc}.service" >>"$LOG_FILE" 2>&1 || true
        fi
    done
    # Pre-create Loki + promtail state dirs so services come up clean.
    mkdir -p "${ROOTFS}/var/lib/loki" "${ROOTFS}/var/lib/promtail" "${ROOTFS}/var/log/journal"

    # ── Helm charts for the K8s stack (offline install) ─────────────────
    #
    # Every chart kldload deploys is staged here, because the alternative is
    # what actually shipped: an "air-gapped" install that logged "chart not in
    # darksite — trying online helm repo" and pulled Cilium, MetalLB, ArgoCD
    # and Tetragon — plus ~138 container images — straight off quay.io and
    # registry.k8s.io at first boot (fiend, 2026-08-16).
    #
    # Only Tetragon was ever fetched before, and pinned at 1.4.1 while the
    # cluster actually deployed 1.7.0 from the network — so even the single
    # vendored chart was the wrong version.
    #
    # NEWEST-at-build-time, by design: `helm pull` with no --version resolves
    # whatever the upstream repo currently publishes. That is the intent —
    # the ISO is the version boundary, not a hardcoded list that silently
    # rots. Every resolved version is written to a manifest in the darksite,
    # so an ISO is still exactly auditable after the fact ("what did this
    # build actually bake in?") without the pins needing hand-maintenance.
    #
    # This directory is also the operator's drop-in point: any *.tgz placed in
    # /root/darksite/helm-charts/workloads is installed at first boot, which is
    # how you run your own charts on a machine that has never had a network.
    mkdir -p "${ROOTFS}/root/darksite/helm-charts/workloads"
    _helm_tmp="$(mktemp -d)"
    _helm_bin=""
    if curl -fsSL --retry 3 -o "${_helm_tmp}/helm.tgz" \
        "https://get.helm.sh/helm-v3.16.4-linux-amd64.tar.gz" >>"$LOG_FILE" 2>&1 &&
        tar xzf "${_helm_tmp}/helm.tgz" -C "${_helm_tmp}" >>"$LOG_FILE" 2>&1; then
        _helm_bin="$(find "${_helm_tmp}" -type f -name helm | head -1)"
    fi

    _chart_ok=0
    _chart_fail=0
    _chart_manifest="${ROOTFS}/root/darksite/helm-charts/MANIFEST.txt"
    : >"$_chart_manifest"
    if [[ -n "$_helm_bin" ]]; then
        export HELM_CACHE_HOME="${_helm_tmp}/cache" HELM_CONFIG_HOME="${_helm_tmp}/config" \
            HELM_DATA_HOME="${_helm_tmp}/data"
        while IFS='|' read -r _rname _rurl _cname; do
            [[ -n "$_rname" ]] || continue
            "$_helm_bin" repo add "$_rname" "$_rurl" >>"$LOG_FILE" 2>&1 || true
        done <<'HELMREPOS'
cilium|https://helm.cilium.io/|tetragon
argo|https://argoproj.github.io/argo-helm|argo-cd
metallb|https://metallb.github.io/metallb|metallb
HELMREPOS
        "$_helm_bin" repo update >>"$LOG_FILE" 2>&1 || true

        while IFS='|' read -r _rname _rurl _cname; do
            [[ -n "$_cname" ]] || continue
            if "$_helm_bin" pull "${_rname}/${_cname}" \
                -d "${ROOTFS}/root/darksite/helm-charts" >>"$LOG_FILE" 2>&1; then
                # helm names the file <chart>-<version>.tgz; autodeploy looks
                # for the bare <chart>.tgz, so record the version and rename.
                _got="$(find "${ROOTFS}/root/darksite/helm-charts" -maxdepth 1 \
                    -name "${_cname}-*.tgz" -printf '%f\n' | sort -V | tail -1)"
                if [[ -n "$_got" ]]; then
                    mv -f "${ROOTFS}/root/darksite/helm-charts/${_got}" \
                        "${ROOTFS}/root/darksite/helm-charts/${_cname}.tgz"
                    echo "${_cname} ${_got}" >>"$_chart_manifest"
                    log "  helm chart staged: ${_got}"
                    _chart_ok=$((_chart_ok + 1))
                    continue
                fi
            fi
            log "  WARNING helm chart download failed: ${_cname} — install will fall back to the online repo"
            _chart_fail=$((_chart_fail + 1))
        done <<'HELMCHARTS'
cilium|https://helm.cilium.io/|tetragon
cilium|https://helm.cilium.io/|cilium
argo|https://argoproj.github.io/argo-helm|argo-cd
metallb|https://metallb.github.io/metallb|metallb
HELMCHARTS
        unset HELM_CACHE_HOME HELM_CONFIG_HOME HELM_DATA_HOME
    else
        log "  WARNING helm binary unavailable at build time — no charts staged"
        _chart_fail=4
    fi
    rm -rf "${_helm_tmp}"
    log "Helm charts staged for offline install: ${_chart_ok} ok, ${_chart_fail} failed"
    # smartmontools (smartctl CLI) — required at runtime by smartctl_exporter
    chroot "${ROOTFS}" dnf install -y smartmontools >>"$LOG_FILE" 2>&1 ||
        log "  WARNING smartmontools install failed"

    # ebpf_exporter (Cloudflare) — per-device block I/O latency histograms.
    # BPF programs + yaml configs ship via includes.chroot/etc/ebpf_exporter.
    _ebpf_tmp="$(mktemp -d)"
    if curl -fsSL -o "${_ebpf_tmp}/ebpf.tgz" \
        "https://github.com/cloudflare/ebpf_exporter/releases/download/v2.5.1/ebpf_exporter_with_examples.x86_64.tar.gz" \
        >>"$LOG_FILE" 2>&1; then
        tar xzf "${_ebpf_tmp}/ebpf.tgz" -C "${_ebpf_tmp}" --strip-components=1 >>"$LOG_FILE" 2>&1
        install -m 0755 "${_ebpf_tmp}/ebpf_exporter" "${ROOTFS}/usr/local/bin/ebpf_exporter"
        log "Observability: ebpf_exporter installed"
    else
        log "  WARNING ebpf_exporter download failed"
    fi
    rm -rf "${_ebpf_tmp}"
    # Enable ebpf_exporter at boot
    if [[ -f "${ROOTFS}/usr/lib/systemd/system/ebpf_exporter.service" ]]; then
        chroot "${ROOTFS}" systemctl enable ebpf_exporter.service >>"$LOG_FILE" 2>&1 || true
    fi
    # Enable zpool-scrub-exporter timer (scrub state textfile collector)
    if [[ -f "${ROOTFS}/usr/lib/systemd/system/zpool-scrub-exporter.timer" ]]; then
        chroot "${ROOTFS}" systemctl enable zpool-scrub-exporter.timer >>"$LOG_FILE" 2>&1 || true
    fi
    # Enable arcstats-exporter timer
    if [[ -f "${ROOTFS}/usr/lib/systemd/system/arcstats-exporter.timer" ]]; then
        chroot "${ROOTFS}" systemctl enable arcstats-exporter.timer >>"$LOG_FILE" 2>&1 || true
    fi
    [[ $_obs_ok -eq 1 ]] && log "Observability: stack installed (4 exporters + smartctl)" ||
        log "Observability: PARTIAL — some downloads failed, check log"

    # Copy Grafana dashboards + datasource + provisioner configs from
    # includes.chroot explicitly (whitelist-copy, same pattern as Bob
    # configs above). These would otherwise not land because the build
    # uses explicit copies, not a full includes.chroot mirror.
    #
    # WHY recursive (cp -r .../. .../) rather than flat *.json glob: the
    # repo ships 7 dashboard folders (host/, storage/, kubernetes/,
    # estate/, klab-ops/, virtual-machines/, zfs-test-lab/), one per
    # Grafana category. A flat *.json glob silently dropped all of them
    # — build #28 landed with 6 empty top-level files instead of the 16
    # folder-organised dashboards. Fixed 2026-05-17 after .148 install.
    if [[ -d /build/live-build/config/includes.chroot/var/lib/grafana/dashboards ]]; then
        mkdir -p "${ROOTFS}/var/lib/grafana/dashboards"
        cp -r /build/live-build/config/includes.chroot/var/lib/grafana/dashboards/. \
            "${ROOTFS}/var/lib/grafana/dashboards/" 2>>"$LOG_FILE" || true
        log "Observability: $(find "${ROOTFS}/var/lib/grafana/dashboards/" -name '*.json' | wc -l) dashboards provisioned across $(find "${ROOTFS}/var/lib/grafana/dashboards/" -mindepth 1 -maxdepth 1 -type d | wc -l) folders"
    fi
    if [[ -f /build/live-build/config/includes.chroot/etc/grafana/provisioning/datasources/loki.yaml ]]; then
        mkdir -p "${ROOTFS}/etc/grafana/provisioning/datasources"
        cp /build/live-build/config/includes.chroot/etc/grafana/provisioning/datasources/loki.yaml \
            "${ROOTFS}/etc/grafana/provisioning/datasources/loki.yaml"
    fi
    # Grafana dashboard provisioner — kldload.yaml registers the 7
    # folder-providers above so Grafana groups dashboards in the left-nav.
    # Without this file the JSONs sit on disk and Grafana never loads
    # them (kldload-firstboot deletes any stale klab.yaml stub that would
    # have re-pointed at the flat layout). Whole reason build #28 landed
    # with empty dashboard folders even when the files were there.
    if [[ -d /build/live-build/config/includes.chroot/etc/grafana/provisioning/dashboards ]]; then
        mkdir -p "${ROOTFS}/etc/grafana/provisioning/dashboards"
        cp /build/live-build/config/includes.chroot/etc/grafana/provisioning/dashboards/*.yaml \
            "${ROOTFS}/etc/grafana/provisioning/dashboards/" 2>>"$LOG_FILE" || true
    fi
    # process-exporter config — without this the unit's
    # ConditionPathExists=/etc/kldload/process-exporter.yml fails and the
    # service stays inactive, leaving the Prometheus scrape on :9256 dead
    # and per-process panels blank. Caught on .148 build #28.
    if [[ -f /build/live-build/config/includes.chroot/etc/kldload/process-exporter.yml ]]; then
        mkdir -p "${ROOTFS}/etc/kldload"
        cp /build/live-build/config/includes.chroot/etc/kldload/process-exporter.yml \
            "${ROOTFS}/etc/kldload/process-exporter.yml"
    fi
    # Default authorized_keys for the installer's k_create_users. Read on
    # the LIVE env during install, copied to ~admin/.ssh/authorized_keys
    # on the target. Without this on the live env the SSH key bake
    # silently no-ops (the file-check in bootstrap.sh sees no file and
    # falls through). Caught in build #48 verification.
    if [[ -f /build/live-build/config/includes.chroot/etc/kldload/default-authorized-keys ]]; then
        mkdir -p "${ROOTFS}/etc/kldload"
        cp /build/live-build/config/includes.chroot/etc/kldload/default-authorized-keys \
            "${ROOTFS}/etc/kldload/default-authorized-keys"
        chmod 0644 "${ROOTFS}/etc/kldload/default-authorized-keys"
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
        /build/live-build/config/includes.chroot/usr/lib/systemd/system/kldload-*.service \
        /build/live-build/config/includes.chroot/usr/lib/systemd/system/kldload-*.timer \
        /build/live-build/config/includes.chroot/usr/lib/systemd/system/zexplore-api.service \
        /build/live-build/config/includes.chroot/usr/lib/systemd/system/kldload-session@.service; do
        [[ -f "$_unit_path" ]] && cp "$_unit_path" "${ROOTFS}/usr/lib/systemd/system/$(basename "$_unit_path")"
    done

    # Wholesale-copy /usr/local/lib/kldload-rag/ (RAG service code +
    # indexer + unit-file sources). Same root-cause fix as the unit-file
    # glob above: previous hardcoded approach missed the lib dir entirely,
    # so RAG silently shipped without its python code. Catch-all glob.
    if [[ -d /build/live-build/config/includes.chroot/usr/local/lib ]]; then
        mkdir -p "${ROOTFS}/usr/local/lib"
        for _libdir in /build/live-build/config/includes.chroot/usr/local/lib/*/; do
            [[ -d "$_libdir" ]] || continue
            _libname=$(basename "$_libdir")
            mkdir -p "${ROOTFS}/usr/local/lib/${_libname}"
            cp -r "${_libdir}/." "${ROOTFS}/usr/local/lib/${_libname}/"
        done
        log "Copied /usr/local/lib/* dirs from includes.chroot to ROOTFS"
    fi

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
    chroot "${ROOTFS}" systemctl enable nginx.service >>"$LOG_FILE" 2>&1 || true
    chroot "${ROOTFS}" systemctl disable kldload-proxy.service >>"$LOG_FILE" 2>&1 || true

    # ── DEBUG MODE (opt-in, NEVER in a release build) ──────────────────────
    # The :8443 management surface is IP-restricted to localhost by default
    # (nginx kldload.conf) because the webui dispatch isn't authenticated yet.
    # For remote testing, pass KLDLOAD_DEBUG_ALLOW=<ip> at build time (e.g. the
    # onyx box). The IP is a BUILD VARIABLE — never hardcoded in the tree. It
    # drops a central debug marker (/etc/kldload/debug.conf) that other tooling
    # can source to relax behaviour for the trusted host, plus the nginx allow
    # rule for :8443. Unset (a production build) → no marker, no drop-in,
    # loopback-only. The release smoke-check should assert this file is absent.
    if [[ -n "${KLDLOAD_DEBUG_ALLOW:-}" ]]; then
        log "DEBUG MODE: allow ${KLDLOAD_DEBUG_ALLOW} → :8443 (and debug marker) — NOT FOR RELEASE"
        mkdir -p "${ROOTFS}/etc/kldload" "${ROOTFS}/etc/nginx/conf.d"
        {
            echo "# kldload DEBUG MODE — generated at build from KLDLOAD_DEBUG_ALLOW."
            echo "# The presence of this file MEANS this is a debug build (NOT a release)."
            echo "# Tools may source it to relax behaviour for the trusted debug host."
            echo "KLDLOAD_DEBUG=1"
            echo "KLDLOAD_DEBUG_ALLOW_IP=${KLDLOAD_DEBUG_ALLOW}"
        } >"${ROOTFS}/etc/kldload/debug.conf"
        printf '# DEBUG (KLDLOAD_DEBUG_ALLOW) — remote test access to :8443; strip for release.\nallow %s;\n' \
            "${KLDLOAD_DEBUG_ALLOW}" >"${ROOTFS}/etc/nginx/conf.d/kldload-access-debug.conf"
    fi
    # Disable kldload-headlamp.service at boot — caught 2026-05-17 on .148:
    # the pinned upstream URL (v0.26.0 with headlamp-server-linux-amd64.tar.gz
    # filename pattern) returns 404. The Headlamp project stopped publishing
    # standalone server binaries; v0.42+ tarballs are the 160MB Electron app.
    # Until kldload-headlamp-install is rewritten (likely to extract the
    # server out of the Electron tarball, or to deploy as a helm chart),
    # leave the unit disabled by default so fresh installs don't have a
    # failing unit + 502 on /k8s/ in the webui. /k9s/ still works (ttyd-k9s).
    chroot "${ROOTFS}" systemctl disable kldload-headlamp.service >>"$LOG_FILE" 2>&1 || true
    # Enable kldload-tls-cert.timer at boot (fires cert-drift check hourly)
    if [[ -f "${ROOTFS}/usr/lib/systemd/system/kldload-tls-cert.timer" ]]; then
        chroot "${ROOTFS}" systemctl enable kldload-tls-cert.timer >>"$LOG_FILE" 2>&1 || true
    fi
    # Enable kldload-tls-cert.service at boot (regenerates cert once
    # network is up — handles the DHCP race)
    if [[ -f "${ROOTFS}/usr/lib/systemd/system/kldload-tls-cert.service" ]]; then
        chroot "${ROOTFS}" systemctl enable kldload-tls-cert.service >>"$LOG_FILE" 2>&1 || true
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
        chroot "${ROOTFS}" systemctl enable kldload-journal-flush.service >>"$LOG_FILE" 2>&1 || true
    fi

    # NetworkManager dispatcher hook — fires on IP change events so the
    # TLS cert gets regen'd without waiting for next reboot/timer.
    if [[ -f /build/live-build/config/includes.chroot/etc/NetworkManager/dispatcher.d/99-kldload-tls-cert ]]; then
        mkdir -p "${ROOTFS}/etc/NetworkManager/dispatcher.d"
        install -m 0755 \
            /build/live-build/config/includes.chroot/etc/NetworkManager/dispatcher.d/99-kldload-tls-cert \
            "${ROOTFS}/etc/NetworkManager/dispatcher.d/99-kldload-tls-cert"
    fi
    # Heal-pending retry hook — re-attempts firstboot's missed desktop
    # packages (steam et al) whenever a network comes up. See the hook's
    # banner for the why.
    if [[ -f /build/live-build/config/includes.chroot/etc/NetworkManager/dispatcher.d/98-kldload-heal-pending ]]; then
        mkdir -p "${ROOTFS}/etc/NetworkManager/dispatcher.d"
        install -m 0755 \
            /build/live-build/config/includes.chroot/etc/NetworkManager/dispatcher.d/98-kldload-heal-pending \
            "${ROOTFS}/etc/NetworkManager/dispatcher.d/98-kldload-heal-pending"
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
        >>"$LOG_FILE" 2>&1; then
        tar xf "${_piper_tmp}/piper.tar.gz" -C "${ROOTFS}/opt/" >>"$LOG_FILE" 2>&1
        mkdir -p "${ROOTFS}/opt/piper/models"
        curl -fsSL -o "${ROOTFS}/opt/piper/models/en_US-lessac-medium.onnx" \
            "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx" \
            >>"$LOG_FILE" 2>&1 || log "Bob: WARNING piper voice onnx download failed"
        curl -fsSL -o "${ROOTFS}/opt/piper/models/en_US-lessac-medium.onnx.json" \
            "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json" \
            >>"$LOG_FILE" 2>&1 || true
        [[ -x "${ROOTFS}/opt/piper/piper" ]] &&
            log "Bob: piper TTS installed" ||
            log "Bob: WARNING piper binary not found after extract"
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
        _src_count=$(find /build/live-build/config/includes.chroot/usr/local/share/kldload-ansible/playbooks \
            -maxdepth 1 -name '*.yml' 2>/dev/null | wc -l)
        _dst_count=$(find "${ROOTFS}/usr/local/share/kldload-ansible/playbooks" \
            -maxdepth 1 -name '*.yml' 2>/dev/null | wc -l)
        log "Ansible playbook library installed: ${_dst_count}/${_src_count} playbooks"
        # If the build context has playbooks but the rootfs doesn't, the copy
        # dropped files (.135 2026-06-05: 1/6 landed → kube-cluster died with
        # 'playbook not found' on provision-golden.yml). Fail loudly instead
        # of silently shipping a non-functional ansible tree.
        if ((_src_count > 0)) && ((_dst_count < _src_count)); then
            log "FATAL: ansible playbook copy dropped files (${_dst_count}/${_src_count})."
            log "  src: /build/live-build/config/includes.chroot/usr/local/share/kldload-ansible/playbooks"
            log "  dst: ${ROOTFS}/usr/local/share/kldload-ansible/playbooks"
            ls -la "${ROOTFS}/usr/local/share/kldload-ansible/playbooks/" >&2 || true
            exit 1
        fi
    else
        log "FATAL: /build/live-build/config/includes.chroot/usr/local/share/kldload-ansible missing — bind mount broken."
        exit 1
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

    # Copy ALL .desktop files for the GNOME menu (wildcard — new launchers such
    # as bob-chat / bob-gaming / kldload-zfs / kldload-dashboard ship
    # automatically instead of being silently dropped by a hardcoded list).
    if [[ -d /build/live-build/config/includes.chroot/usr/share/applications ]]; then
        mkdir -p "${ROOTFS}/usr/share/applications"
        cp /build/live-build/config/includes.chroot/usr/share/applications/*.desktop \
            "${ROOTFS}/usr/share/applications/" 2>/dev/null || true
    fi

    # Copy the custom kldload app-icon theme (the scalable SVGs the launchers
    # above reference). Same wildcard rationale as the .desktop block: without
    # this the live GNOME menu shows generic fallback icons — and because
    # profiles.sh copies icons to the install target *from the live rootfs*,
    # a missing theme here means the installed system loses them too.
    if [[ -d /build/live-build/config/includes.chroot/usr/share/icons/hicolor/scalable/apps ]]; then
        mkdir -p "${ROOTFS}/usr/share/icons/hicolor/scalable/apps"
        cp /build/live-build/config/includes.chroot/usr/share/icons/hicolor/scalable/apps/*.svg \
            "${ROOTFS}/usr/share/icons/hicolor/scalable/apps/" 2>/dev/null || true
        chroot "${ROOTFS}" gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
    fi

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
    for _lsbin in kspawn kldload-debug-bundle kldload-rhel-composer-build kldload-backup-pack kldload-backup-restore; do
        _src="/build/live-build/config/includes.chroot/usr/local/sbin/${_lsbin}"
        [[ -f "$_src" ]] && cp "$_src" "${ROOTFS}/usr/local/sbin/${_lsbin}" && chmod +x "${ROOTFS}/usr/local/sbin/${_lsbin}"
    done
    # kldload-rhel-composer-build added in build #51 -- caught on .103
    # (build #50): the script was in includes.chroot/ but neither this
    # ROOTFS copy block nor profiles.sh's target-copy block included
    # it, so the systemd unit kldload-rhel-composer.service failed at
    # boot with "No such file or directory" -- no RHEL golden built.

    # Copy installer library files
    if [[ -d /build/live-build/config/includes.chroot/usr/lib/kldload-installer ]]; then
        cp -r /build/live-build/config/includes.chroot/usr/lib/kldload-installer "${ROOTFS}/usr/lib/"
        chmod +x "${ROOTFS}/usr/lib/kldload-installer/backend/bin/"* 2>/dev/null || true
        # Symlink backend tools to PATH
        for be_tool in kbe krecovery kupgrade; do
            [[ -f "${ROOTFS}/usr/lib/kldload-installer/backend/bin/${be_tool}" ]] &&
                ln -sf "/usr/lib/kldload-installer/backend/bin/${be_tool}" "${ROOTFS}/usr/local/bin/${be_tool}"
        done
    fi

    # Copy sanoid config
    mkdir -p "${ROOTFS}/etc/sanoid"
    [[ -f /build/live-build/config/includes.chroot/etc/sanoid/sanoid.conf ]] &&
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
    [[ -f /build/live-build/config/includes.chroot/etc/skel/.tmux.conf ]] &&
        cp /build/live-build/config/includes.chroot/etc/skel/.tmux.conf "${ROOTFS}/etc/skel/.tmux.conf" &&
        cp /build/live-build/config/includes.chroot/etc/skel/.tmux.conf "${ROOTFS}/home/live/.tmux.conf" 2>/dev/null || true
    [[ -f /build/live-build/config/includes.chroot/etc/skel/.vimrc ]] &&
        cp /build/live-build/config/includes.chroot/etc/skel/.vimrc "${ROOTFS}/etc/skel/.vimrc"
    # vim colorscheme
    if [[ -d /build/live-build/config/includes.chroot/etc/skel/.vim ]]; then
        cp -r /build/live-build/config/includes.chroot/etc/skel/.vim "${ROOTFS}/etc/skel/.vim"
        cp -r /build/live-build/config/includes.chroot/etc/skel/.vim "${ROOTFS}/root/.vim"
        cp -r /build/live-build/config/includes.chroot/etc/skel/.vim "${ROOTFS}/home/live/.vim" 2>/dev/null || true
    fi

    # skel/.config — the whole tree, recursively, fanned out to skel + root +
    # live like .bashrc/.vim above. WHY recursive: the per-file skel copies
    # grew stale the moment includes.chroot gained .config/k9s/ (family skin
    # + logoless config) — same shape as the build-#48 narrow-copy bug below.
    # root gets it because ttyd-k9s.service runs k9s as root.
    if [[ -d /build/live-build/config/includes.chroot/etc/skel/.config ]]; then
        for _dest in "${ROOTFS}/etc/skel" "${ROOTFS}/root" "${ROOTFS}/home/live"; do
            [[ -d "$_dest" ]] || continue
            mkdir -p "${_dest}/.config"
            cp -r /build/live-build/config/includes.chroot/etc/skel/.config/. \
                "${_dest}/.config/"
        done
    fi

    # polkit policies/rules — wgxplore's GUI depends on
    # org.kldload.wgxplore.policy for prompt-free read-only estate refreshes
    # (estate.go documents it as shipped). It sat in includes.chroot with NO
    # copy block, so it reached neither the live ISO nor installs — caught on
    # the 1.4.0-rc2 fresh-install verify (2026-08-03, host .119). Recursive
    # so future rules.d/ additions just work.
    if [[ -d /build/live-build/config/includes.chroot/usr/share/polkit-1 ]]; then
        mkdir -p "${ROOTFS}/usr/share/polkit-1"
        cp -r /build/live-build/config/includes.chroot/usr/share/polkit-1/. \
            "${ROOTFS}/usr/share/polkit-1/"
    fi

    # Copy profile.d scripts (shell helpers, environment)
    mkdir -p "${ROOTFS}/etc/profile.d"
    for _pd in /build/live-build/config/includes.chroot/etc/profile.d/*.sh; do
        [[ -f "$_pd" ]] && cp "$_pd" "${ROOTFS}/etc/profile.d/"
    done

    # Copy /usr/local/share/kldload/ — the whole tree, not just tests/.
    # Build #48 only copied tests/ which dropped ktcp-format.awk,
    # tetragon-filter.jq, demo/, argocd-values.yaml on the floor.
    # Result: F12 (kernel-tcp cockpit) died with "awk: cannot open
    # source file /usr/local/share/kldload/ktcp-format.awk"; F11
    # tracing cockpit died with "Could not open tetragon-filter.jq";
    # kube-demo javaapi had no chart; autodeploy had no ArgoCD values.
    # Same shape as the RAG-files bug we fixed in build #48 -- explicit
    # narrow copy that grew stale as the includes.chroot tree gained
    # files. Use cp -r so future additions just work.
    if [[ -d /build/live-build/config/includes.chroot/usr/local/share/kldload ]]; then
        mkdir -p "${ROOTFS}/usr/local/share/kldload"
        cp -r /build/live-build/config/includes.chroot/usr/local/share/kldload/. \
            "${ROOTFS}/usr/local/share/kldload/"
        # Tests subdir needs execute bit; everything else (awk, jq,
        # yaml) is read-only data and stays mode-from-source.
        [[ -d "${ROOTFS}/usr/local/share/kldload/tests" ]] &&
            chmod +x "${ROOTFS}/usr/local/share/kldload/tests/"*.sh 2>/dev/null || true
    fi

    # Create kldload-webui systemd service
    cat >"${ROOTFS}/usr/lib/systemd/system/kldload-webui.service" <<'SVCEOF'
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

    # ttyd-k9s enable moved down to AFTER the unit file is copied into the
    # rootfs (the `for _svc in ... ttyd-k9s.service ...` loop ~100 lines
    # below). Enabling it here would hit a non-existent unit and silently
    # no-op. Caught build #33 on .133 2026-05-18: ttyd-k9s.service file
    # shipped fine but no multi-user.target.wants symlink, so the live
    # ISO booted with the console disabled and /k9s/ returned 502.

    # Debian darksite APT mirror service — Python HTTP server on port 3142.
    # debootstrap on the live ISO is configured to use http://127.0.0.1:3142/apt/
    # as its mirror, which serves packages from the baked-in darksite directory.
    cat >"${ROOTFS}/usr/lib/systemd/system/kldload-apt-mirror.service" <<'APTEOF'
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
    cat >"${ROOTFS}/usr/lib/systemd/system/kldload-apt-mirror-ubuntu.service" <<'UAPTEOF'
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
    cat >"${ROOTFS}/usr/lib/systemd/system/kldload-pacman-mirror.service" <<'PACEOF'
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
    cat >"${ROOTFS}/usr/lib/systemd/system/kldload-fedora-mirror.service" <<'FEDEOF'
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
    cat >"${ROOTFS}/usr/lib/systemd/system/kldload-apk-mirror.service" <<'ALPEOF'
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
        ttyd-k9s.service zexplore-api.service \
        klab-prom-targets.service klab-prom-targets.timer; do
        _src="/build/live-build/config/includes.chroot/usr/lib/systemd/system/${_svc}"
        [[ -f "$_src" ]] && cp "$_src" "${ROOTFS}/usr/lib/systemd/system/${_svc}"
    done

    # NOW enable ttyd-k9s — the unit file just got copied into the rootfs
    # by the loop above, so `systemctl enable` finds it and creates the
    # /etc/systemd/system/multi-user.target.wants/ttyd-k9s.service symlink.
    # The earlier attempt at line ~1472 ran before this copy and silently
    # no-op'd, leaving the live ISO booting with the embedded console
    # disabled. See the comment block where that earlier enable used to be.
    chroot "$ROOTFS" systemctl enable ttyd-k9s.service 2>/dev/null || true
    # zexplore-api: the guest ZFS-transaction daemon ("instant rollback as a
    # function"). Harmless where unused — it only listens (unix socket + vsock
    # 9455); on a KVM host it lets guest VMs snapshot/roll back their own zvols,
    # scoped per-VM. Not a boot dependency, so a bind failure never blocks boot.
    chroot "$ROOTFS" systemctl enable zexplore-api.service 2>/dev/null || true

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
    BINDIR="${ROOTFS}/usr/local/bin" curl -fsSL https://ollama.com/install.sh | sh >>"$LOG_DIR/bob-build.log" 2>&1
    log "Bob: Ollama installed to rootfs"

    # Create ollama user + service in rootfs
    chroot "${ROOTFS}" useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama 2>/dev/null || true
    cat >"${ROOTFS}/etc/systemd/system/ollama.service" <<'OSERVICE'
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
    "${ROOTFS}/usr/local/bin/ollama" serve >>"$LOG_DIR/bob-build.log" 2>&1 &
    _ollama_pid=$!
    for _try in $(seq 1 20); do
        curl -sf http://localhost:11434/api/tags >/dev/null 2>&1 && break
        sleep 2
    done
    "${ROOTFS}/usr/local/bin/ollama" pull llama3.1:8b >>"$LOG_DIR/bob-build.log" 2>&1
    log "Bob: model pulled, creating Bob personality..."

    # Create Bob modelfile and build it
    cat >/tmp/Modelfile.bob <<'BOBMODEL'
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
    kill $_ollama_pid 2>/dev/null
    wait $_ollama_pid 2>/dev/null || true
    unset OLLAMA_MODELS

    # Fix ownership
    chroot "${ROOTFS}" chown -R ollama:ollama /usr/share/ollama 2>/dev/null || true

    # Install Open WebUI via pip (no container runtime needed)
    log "Bob: installing Open WebUI..."
    chroot "${ROOTFS}" pip3 install --quiet open-webui 2>&1 | tail -5 || {
        log "Bob: pip install open-webui failed — will use podman on boot"
    }

    # Install kldload-rag Python deps (chromadb + beautifulsoup4) so the
    # RAG service at /usr/local/lib/kldload-rag/kldload_rag.py can start.
    # Without these, imports fail and the RAG silently never works -- which
    # is exactly what shipped in earlier builds.
    log "Bob: installing kldload-rag Python deps (chromadb, beautifulsoup4)..."
    chroot "${ROOTFS}" pip3 install --quiet --break-system-packages chromadb beautifulsoup4 2>&1 | tail -5 || {
        log "Bob: pip install chromadb/bs4 failed -- RAG will fall back to direct Ollama"
    }

    # Bob CLI: always pull from the source-of-truth in includes.chroot,
    # don't rely on ROOTFS state (it races with the wholesale copy below
    # the BOB_LIVE block in some build sequences). If the source is
    # missing, write a minimal stub as a defensive fallback.
    INCLUDES_BOB="/build/live-build/config/includes.chroot/usr/local/bin/bob"
    if [[ -s "$INCLUDES_BOB" ]] && grep -q 'BOB_RAG\b' "$INCLUDES_BOB"; then
        install -m 0755 "$INCLUDES_BOB" "${ROOTFS}/usr/local/bin/bob"
        log "Bob: copied full CLI from includes.chroot (RAG bridge present)"
    else
        log "Bob: WARN -- includes.chroot bob CLI missing or stub; writing minimal stub"
        cat >"${ROOTFS}/usr/local/bin/bob" <<'BOBCLI'
#!/usr/bin/env bash
Q="${*:-Hey Bob, what can you help me with?}"
echo "$Q" | ollama run bob
BOBCLI
        chmod +x "${ROOTFS}/usr/local/bin/bob"
    fi

    log "Bob live mode enabled -- Ollama + model + Bob + RAG baked into image"
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
cp "${_ic}/usr/local/sbin/kldload-autoinstall" "${ROOTFS}/usr/local/sbin/" 2>/dev/null &&
    chmod +x "${ROOTFS}/usr/local/sbin/kldload-autoinstall" || true
# Baked-in answers file (AI appliance builds only)
cp "${_ic}/etc/kldload/autoinstall.env" "${ROOTFS}/etc/kldload/autoinstall.env" 2>/dev/null &&
    log "Baked-in autoinstall.env — this ISO will auto-install on boot" || true
# Answers templates
cp -r "${_ic}/etc/kldload/debz" "${ROOTFS}/etc/kldload/" 2>/dev/null || true

# Copy ALL modules-load.d configs (virtio for VM guests, uinput for Steam
# controllers, wireguard, etc.) — wildcard so additions ship instead of
# being dropped by a per-file list.
mkdir -p "${ROOTFS}/etc/modules-load.d"
cp /build/live-build/config/includes.chroot/etc/modules-load.d/*.conf \
    "${ROOTFS}/etc/modules-load.d/" 2>/dev/null || true

# Copy udev rules from includes.chroot (uinput perms for Steam controllers,
# the kldload I/O scheduler rule, etc.) — was previously not copied at all.
if [[ -d /build/live-build/config/includes.chroot/etc/udev/rules.d ]]; then
    mkdir -p "${ROOTFS}/etc/udev/rules.d"
    cp /build/live-build/config/includes.chroot/etc/udev/rules.d/*.rules \
        "${ROOTFS}/etc/udev/rules.d/" 2>/dev/null || true
fi

# Ensure ZFS module loads at boot
cat >"${ROOTFS}/etc/modules-load.d/zfs.conf" <<'ZFSMOD'
zfs
ZFSMOD

# ZFS modprobe tuning
mkdir -p "${ROOTFS}/etc/modprobe.d"
cat >"${ROOTFS}/etc/modprobe.d/zfs.conf" <<'ZFSTUNE'
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
    # Gate on the SWITCH as well as the directory: deploy.sh retired the
    # Ubuntu darksite on 2026-08-14, but a stale cache left on disk from an
    # earlier build would otherwise still be baked in — costing the 2.6 GB
    # the retirement was meant to save, silently.
    if [[ "${KLDLOAD_INCLUDE_UBUNTU_DARKSITE:-0}" == "1" &&
        -d /build/live-build/darksite-ubuntu-cache/apt ]]; then
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
        # The runtime travels with the weights or neither is any use: a model
        # tree on a machine that cannot install ollama offline is 2 GB of
        # nothing. Absent runtime is FATAL rather than a warning, because the
        # failure would only surface at first boot on the operator's hardware.
        if [[ -f /build/live-build/darksite-ollama-cache/runtime/ollama-linux-amd64.tar.zst ]]; then
            mkdir -p "${ROOTFS}/root/darksite/ollama/runtime"
            cp /build/live-build/darksite-ollama-cache/runtime/ollama-linux-amd64.tar.zst \
                "${ROOTFS}/root/darksite/ollama/runtime/"
        else
            die "Ollama darksite requested but the runtime tarball is missing — weights without a runtime cannot come up offline"
        fi
        # The interface travels with the engine, for the same reason the
        # runtime travels with the weights. An engine and 2 GB of weights
        # with nothing to talk to them is a machine where "local AI" means
        # a command line, which is not what the desktop tile promises.
        # WARN, not die: the engine alone is still usable from the CLI, and
        # an ISO built before the webui cache existed should not be blocked
        # from building — but the log has to say so plainly.
        if [[ -s /build/live-build/darksite-ollama-cache/webui/open-webui.oci.tar ]]; then
            mkdir -p "${ROOTFS}/root/darksite/ollama/webui"
            cp -r /build/live-build/darksite-ollama-cache/webui/. \
                "${ROOTFS}/root/darksite/ollama/webui/"
            log "Open WebUI image + Whisper weights copied: $(du -sh "${ROOTFS}/root/darksite/ollama/webui" 2>/dev/null | cut -f1)"
        else
            log "WARNING: no Open WebUI image in the darksite cache — the target gets the Ollama engine and CLI only, and the desktop tile will have no interface. Re-run deploy.sh build-ollama-darksite."
        fi
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
        [[ -f /build/live-build/darksite-alpine-cache/alpine-version ]] &&
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

# dracut-108 regression (F44): its systemd module ships initrd-parse-etc.service
# (ExecStart=/usr/lib/systemd/systemd-sysroot-fstab-check) but FAILS to pack the
# helper binary itself into the initramfs -> the service dies 203/EXEC -> switch
# root never completes -> dracut emergency shell. We force-install the helpers
# the module dropped. Guard each so the build still works once dracut fixes this.
DRACUT_INSTALL=()
for _b in /usr/lib/systemd/systemd-sysroot-fstab-check \
    /usr/lib/systemd/system-generators/systemd-fstab-generator; do
    [[ -x "${ROOTFS}${_b}" ]] && DRACUT_INSTALL+=(--install "$_b")
done
[[ ${#DRACUT_INSTALL[@]} -gt 0 ]] &&
    log "Force-installing dracut-108-dropped helpers: ${DRACUT_INSTALL[*]}"

chroot "$ROOTFS" dracut --force --add "dmsquash-live" \
    --no-hostonly \
    "${DRACUT_INSTALL[@]}" \
    --force-drivers "xhci_pci xhci_hcd ehci_pci ehci_hcd ohci_pci ohci_hcd uhci_hcd usb_storage uas usbhid hid_generic cdc_ether usbnet r8152 ax88179_178a thunderbolt typec_ucsi ucsi_acpi nvme nvme_core ahci virtio_blk virtio_scsi virtio_net virtio_pci sdhci sdhci_pci mmc_block" \
    --kver "$KVER" "/boot/initramfs-${KVER}.img" 2>&1 | tee -a "$LOG_FILE" ||
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
x64)
    GRUB_EFI="grubx64.efi"
    BOOT_EFI="BOOTX64.EFI"
    ;;
aa64)
    GRUB_EFI="grubaa64.efi"
    BOOT_EFI="BOOTAA64.EFI"
    ;;
esac
find "$ROOTFS" -name "$GRUB_EFI" -exec cp {} "${ISO_STAGING}/EFI/BOOT/${BOOT_EFI}" \; 2>/dev/null ||
    log "WARNING: ${GRUB_EFI} not found — live ISO may not UEFI boot"

# Also keep the arch-named copy as itself (some firmware looks for it by name)
cp "${ISO_STAGING}/EFI/BOOT/${BOOT_EFI}" "${ISO_STAGING}/EFI/BOOT/${GRUB_EFI}" 2>/dev/null || true

# GRUB config
cat >"${ISO_STAGING}/EFI/BOOT/grub.cfg" <<'GRUBCFG'
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
printf '%s\n' "${_iso_label}" >"${ISO_STAGING}/.disk/info"
cat >"${ISO_STAGING}/VERSION" <<VERSIONEOF
kldload_version = ${VERSION}
iso_name        = ${ISO_NAME}
built_at        = ${_iso_built_at}
edition         = ${EDITION:-free}
profile         = ${PROFILE:-desktop}
arch            = ${ARCH:-x86_64}
release         = ${RELEASE:-10}
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
    "$ISO_STAGING" 2>&1 | tee -a "$LOG_FILE" ||
    die "xorriso failed"

# ---------------------------------------------------------------------------
# Checksum
# ---------------------------------------------------------------------------
log "Generating SHA256 checksum..."
# 1.3.0-b623 shipped with a 0-byte .sha256 because nothing verified the file
# after writing it. Compute → verify non-empty → die loudly if the write
# silently failed. Distribution artifacts MUST be verifiable; an empty checksum
# is worse than no checksum (operators trust the file exists).
(cd "$OUTPUT_DIR" && sha256sum "$ISO_NAME" >"${ISO_NAME}.sha256") ||
    die "sha256sum failed for $ISO_NAME"
[[ -s "${OUTPUT_DIR}/${ISO_NAME}.sha256" ]] ||
    die "sha256 file is empty: ${OUTPUT_DIR}/${ISO_NAME}.sha256"

ISO_DEST="${OUTPUT_DIR}/${ISO_NAME}"
ISO_SIZE="$(du -sh "$ISO_DEST" | cut -f1)"
log "Build complete."
log "  ISO:      $ISO_DEST"
log "  Size:     $ISO_SIZE"
log "  Checksum: ${ISO_DEST}.sha256"
log "  Log:      $LOG_FILE"

echo "$ISO_DEST"
