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
            echo "openssh sudo curl ca-certificates vim less chrony wireguard-tools iproute2 tmux python python-websockets python-yaml htop net-tools ethtool nftables tcpdump fzf bat eza fd ripgrep zoxide podman fastfetch"
            ;;
        client)
            echo "openssh sudo curl ca-certificates vim less networkmanager wireguard-tools iproute2"
            ;;
        desktop)
            # kldload-webview deps (webkitgtk6.0 + gtk4 + python3-gobject):
            # without these on the target the per-launcher webview windows
            # die at import time and the dock launchers silently fail to
            # open. Caught on .139 b651 reinstall 2026-06-11: helm /
            # ansible / klab / vms / k8s / metrics all dead because the
            # live ISO had webkitgtk6.0 from kldload-live.ks but the
            # install-time package list didn't carry it onto disk.
            echo "openssh sudo curl ca-certificates vim less networkmanager \
          gnome-shell gnome-session gnome-control-center gnome-settings-daemon \
          gdm nautilus gnome-terminal eog \
          adwaita-icon-theme cantarell-fonts gvfs gvfs-mtp gvfs-smb \
          gnome-keyring \
          webkitgtk6.0 gtk4 python3-gobject \
          pulseaudio-utils \
          speech-dispatcher espeak-ng \
          tmux python python-websockets python-yaml htop net-tools wireguard-tools iproute2 fzf bat eza fd ripgrep zoxide podman fastfetch"
            ;;
        core)
            echo "openssh sudo curl ca-certificates vim less iproute2 chrony nftables wireguard-tools"
            ;;
        ai)
            echo "openssh sudo curl ca-certificates vim less iproute2 chrony nftables \
          wireguard-tools tmux python python-pip jq htopfzf bat eza fd ripgrep zoxide podman fastfetch \
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
        echo "openssh-server sudo curl ca-certificates vim less systemd-resolved chrony wireguard-tools iproute2 tmux eject sanoid python3 python3-websockets python3-yaml htop net-tools ethtool nftables tcpdump fzf bat eza fd-find ripgrep zoxide podman pciutils ${_fastfetch}"
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
        # Debian/Ubuntu: Chrome isn't in stock APT repos and Firefox is no
        # longer the kldload-preferred browser (Task #47 — workstation
        # standardizes on Chrome via google-chrome.repo on RPM). On Debian
        # we land chromium as the closest in-repo equivalent; an operator
        # who wants the same Chrome experience can add the Google APT
        # signing key + .list and `apt install google-chrome-stable`
        # post-install. Leaving _browser empty would result in a desktop
        # with NO browser at all, so chromium is the safer default.
        local _browser="chromium"
        # certutil lives in a DIFFERENTLY NAMED package per family:
        #   RPM (Fedora/RHEL/CentOS/Rocky) -> nss-tools
        #   Debian/Ubuntu                  -> libnss3-tools
        # kldload-trust-cert uses certutil to add the kldload CA to
        # ~/.pki/nssdb so the browser trusts the webui cert silently.
        # With the RPM name on Debian the package simply never installed,
        # certutil was absent, the CA never reached the browser store, and
        # every tile opened with a certificate warning.
        # HISTORY: 2026-08-14, fiend rc3 — "worked, just wasn't trusted".
        local _nsstools="libnss3-tools"
        local _viewer="loupe"
        local _terminal="gnome-terminal"
        local _nm="network-manager"
        # WiFi/NIC firmware must be INSTALLED ON TARGET, not just on the live
        # ISO. HISTORY: b682 laptop (2026-08-04) and the fresh 1.4.0-rc2
        # install (2026-08-05) both landed with ZERO iwlwifi firmware — the
        # AX201 never probed ("no suitable firmware found" / silent no-probe).
        # build-iso.sh ships the blobs on the LIVE image, but the target's
        # package transaction never included them, so every real laptop lost
        # wifi after install. CI can't catch this (VMs have no wifi NIC).
        # Debian: non-free-firmware component is already in bootstrap.sh's
        # sources. Per-distro names differ — see the branches below.
        local _fw="firmware-iwlwifi firmware-realtek firmware-atheros"
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
            # Ubuntu keeps the monolithic linux-firmware package (main).
            _fw="linux-firmware"
            # Ubuntu 24.04 LTS ships GDM 46, not affected by the GDM 48
            # systemd-integration bug we hit on Debian Trixie. Keep gdm3
            # there. (Switch to lightdm if/when Ubuntu lands GDM 48 with
            # the same bug.)
            _gdm="gdm3"
        elif [[ "$_distro" == "centos" || "$_distro" == "rocky" || "$_distro" == "rhel" || "$_distro" == "fedora" ]]; then
            # RPM branch — match package naming on those ecosystems.
            _nsstools="nss-tools"
            # Note: on RHEL 10+ and Fedora 41+, Red Hat dropped gnome-terminal
            # and eog from AppStream in favor of modern GNOME 47 replacements
            # (ptyxis + loupe). dnf without --skip-broken errors out if the
            # package list contains a name that's not in any enabled repo.
            # Ship BOTH the legacy and the modern names so dnf installs
            # whichever is available — gnome-terminal/eog on older releases,
            # ptyxis/loupe on RHEL 10 / Fedora 41+. Caught 2026-05-14 on .143
            # RHEL 10 desktop install: gnome-terminal silently dropped,
            # operator booted into a desktop with no terminal app.
            #
            # Chrome is the DEFAULT browser on the installed RPM desktop, not
            # the only one: firefox also ships, from the hardcoded _dnf_pkgs
            # array in bootstrap.sh. Task #47 removed firefox from the LIVE ISO
            # (build-iso.sh PKGS carries no firefox — Chrome alone renders the
            # installer via kldload-chrome-app), but deliberately left it on the
            # installed desktop as a second browser. Corrected 2026-08-07; this
            # comment previously claimed the opposite on both counts.
            #
            # Shipping both is safe because "default" is enforced, not assumed:
            # /etc/xdg/mimeapps.list below binds http(s)/html to Chrome, and a
            # Chrome managed policy suppresses the "make me default" prompt.
            # Without that pair, http(s) links opened firefox even with Chrome
            # pinned first in the dock (.137 install, 2026-06-06).
            #
            # kldload-firstboot has a belt-and-suspenders Chrome install if the
            # dnf transaction here didn't land it.
            _browser="google-chrome-stable"
            _viewer="eog loupe"
            _terminal="gnome-terminal ptyxis"
            _nm="NetworkManager NetworkManager-wifi NetworkManager-tui"
            # EL keeps monolithic linux-firmware; F43+ split the blobs into
            # per-vendor sub-packages and bare linux-firmware carries only
            # licenses — same list build-iso.sh ships on the live image.
            _fw="linux-firmware"
            if [[ "$_distro" == "fedora" ]]; then
                _fw="linux-firmware iwlwifi-dvm-firmware iwlwifi-mvm-firmware iwlwifi-mld-firmware iwlegacy-firmware realtek-firmware atheros-firmware"
            fi
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
        # kldload-webview deps for Debian/Ubuntu — gir1.2-webkit-6.0 +
        # libgtk-4-1 + python3-gi. Same role as webkitgtk6.0 on RHEL: the
        # GTK4 + WebKit 6.0 stack the per-launcher webview Python script
        # imports. Missing on .139 b651 reinstall 2026-06-11 broke every
        # dock launcher except sysdiag / k9s / Bob.
        echo "openssh-server sudo curl ca-certificates vim nano less ${_nm} ${_fw} \
        gnome-shell gnome-session ${_xsession_pkg} gnome-control-center gnome-settings-daemon \
        ${_gdm} nautilus ${_terminal} ${_viewer} \
        adwaita-icon-theme ${_fonts} gvfs ${_gvfs_extra} \
        gnome-keyring ${_pam_extras} ${_portal_extras} ${_dbus_extras} \
        gnome-tweaks \
        ${_xsrv} ${_netools_extra} \
        ${_browser} ${_nsstools} \
        gir1.2-webkit-6.0 libgtk-4-1 python3-gi \
        pulseaudio-utils \
        speech-dispatcher espeak-ng \
        tmux eject sanoid python3 python3-websockets python3-yaml htop iotop lm-sensors net-tools wireguard-tools iproute2 fzf bat eza fd-find ripgrep zoxide podman pciutils ${_fastfetch} \
        zenity chromium"
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
        wireguard-tools tmux python3 python3-websockets python3-yaml htop net-tools ethtool tcpdump \
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
        wireguard-tools tmux python3 python3-pip jq htopfzf bat eza fd-find ripgrep zoxide ${_fastfetch} \
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
            # libbpf-tools = the CO-RE/BTF rebuilds of the bcc tools; REQUIRED
            # on modern kernels (F44/7.0) where legacy bcc runtime-compile
            # fails. bpfcc-tools→bcc-tools is remapped in bootstrap.sh; both
            # ship so sysdiag prefers /usr/bin/bpf-* and falls back to legacy
            # on older substrates.
            out+=(bpftool bpfcc-tools libbpf-tools bpftrace linux-perf)
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
            # qemu-utils / cloud-image-utils / genisoimage are NOT optional here.
            # Debian splits the image tooling out of qemu-system-x86, and nothing
            # in this set pulls it back in — unlike Arch, where qemu-full carries
            # qemu-img, and RPM, where qemu-img is a hard dependency of qemu-kvm.
            # Debian is the only branch that loses it silently.
            #
            # WHY IT MATTERS: kube-cluster and klab both shell out to qemu-img
            # (3 call sites each) to import a cloud image into a ZFS zvol, and to
            # cloud-localds/genisoimage to build the cloud-init seed ISO.
            #
            # HISTORY: 2026-08-14, fiend. k8s bootstrap died with
            # "kube-cluster: line 969: qemu-img: command not found", and the klab
            # golden VM booted with no imported disk and no seed, so it never took
            # a DHCP lease — klab then broadcast-pinged for it until timeout,
            # which on screen looked like a hung installer ("no IP found").
            out+=(qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst
                bridge-utils ovmf dnsmasq-base sshpass
                qemu-utils cloud-image-utils genisoimage)
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
    vmware) out+=(open-vm-tools) ;;
    kvm | qemu) out+=(qemu-guest-agent) ;;
    xen) out+=(xe-guest-utilities) ;;
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
        >"${target}/etc/sudoers.d/kldload-path"
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
    [[ -f /etc/kldload-build-id ]] && cp /etc/kldload-build-id "${target}/etc/kldload-build-id"
    [[ -f /etc/kldload/edition ]] && cp /etc/kldload/edition "${target}/etc/kldload/edition"
    # Propagate VERSION from the live env so installed boxes can self-report
    # which kldload ISO built them — without this the target has no record
    # of its provenance, and tools (kst-summary, attestation, support
    # bug reports) fall back to a hardcoded placeholder string.
    [[ -f /etc/kldload/VERSION ]] && cp /etc/kldload/VERSION "${target}/etc/kldload/VERSION"
    # Which zxplore commit this image baked (see build-iso.sh) — traceability
    # for the tracks-upstream-main build model.
    [[ -f /etc/kldload/zxplore-commit ]] && cp /etc/kldload/zxplore-commit "${target}/etc/kldload/zxplore-commit"
    [[ -f /etc/kldload/wgxplore-commit ]] && cp /etc/kldload/wgxplore-commit "${target}/etc/kldload/wgxplore-commit"
    [[ -f /etc/kldload/vmxplore-commit ]] && cp /etc/kldload/vmxplore-commit "${target}/etc/kldload/vmxplore-commit"
    # process-exporter config — kldload-process-exporter.service
    # ConditionPathExists on this file, so without it the unit silently
    # skips and the per-process Grafana dashboards stay empty on the target.
    # Caught .113 2026-05-16 alongside the missing exporter binaries.
    [[ -f /etc/kldload/process-exporter.yml ]] &&
        cp /etc/kldload/process-exporter.yml "${target}/etc/kldload/process-exporter.yml"
    echo "${_profile}" >"${target}/etc/kldload/profile"
    printf '%s\n' "${root_ds}" >"${target}/etc/kldload/boot-environment"

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
                if [[ -x "/usr/local/sbin/${_sb}" ]] &&
                    [[ ! -x "${target}/usr/sbin/${_sb}" ]] &&
                    [[ ! -x "${target}/usr/local/sbin/${_sb}" ]] &&
                    [[ ! -x "${target}/usr/bin/${_sb}" ]]; then
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
        # Explicit list so adding a unit is a conscious decision. Lines 627-638
        # below `ln -sf` symlink the RAG units into multi-user.target.wants but
        # those symlinks point nowhere unless the unit files are copied here
        # first. The kldload-rag-* entries below were missing pre-build-#48 and
        # caused RAG to be completely dead on every installed system even though
        # smoke-build saw the files in the squashfs (caught on .101 / build #47).
        # kldload-rhel-composer.service added in build #50 -- runs at firstboot
        # when bootstrap.sh wrote /var/lib/klab/.rhel-composer-pending (RHEL
        # distro selected). Builds the 6th klab golden via osbuild-composer.
        mkdir -p "${target}/usr/lib/systemd/system"
        # zexplore-api.service added 2026-08-05 — the guest ZFS-transaction
        # daemon was enabled by build-iso.sh but never copied to target
        # (unit "not-found" on the fresh 1.4.0-rc2 install; the `enable ||
        # true` swallowed it).
        for f in kldload-srv-snapshot.service kldload-srv-snapshot.timer kldload-firstboot.service kldload-webui.service kldload-proxy.service kldload-export.service kldload-autodeploy.service ttyd-k9s.service kldload-tls-cert.service kldload-tls-cert.timer kldload-journal-flush.service klab-prom-targets.service klab-prom-targets.timer kldload-headlamp.service kldload-session@.service kldload-rag.service kldload-rag-firstboot.service kldload-rag-index.service kldload-rag-index.timer kldload-rhel-composer.service zexplore-api.service; do
            [[ -f "/usr/lib/systemd/system/${f}" ]] &&
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
        # Backup tools — pack the installed system to fiend, restore later.
        # Operator-only tools, shipped to /usr/local/sbin so they're in PATH
        # under sudo. ZFS send/recv-based, so they only make sense on a ZFS
        # root; no-op cleanly on btrfs/ext4 installs (they'll die on the
        # findmnt check).
        mkdir -p "${target}/usr/local/sbin"
        for _bk in kldload-backup-pack kldload-backup-restore; do
            if [[ -f "/usr/local/sbin/${_bk}" ]]; then
                cp "/usr/local/sbin/${_bk}" "${target}/usr/local/sbin/${_bk}" &&
                    chmod +x "${target}/usr/local/sbin/${_bk}" &&
                    k_log "installed /usr/local/sbin/${_bk}"
            fi
        done
        # Ship orchestrator + console scripts alongside the units. Ensure
        # /usr/sbin exists on the bootstrap — a minimal dnf install may not
        # create it before this function runs, and a silent cp failure here
        # was the 1.0.4 regression where kldload-autodeploy.service had a
        # symlink in multi-user.target.wants but no binary behind it.
        mkdir -p "${target}/usr/sbin"
        for bin in kldload-autodeploy; do
            if [[ -f "/usr/sbin/${bin}" ]]; then
                cp "/usr/sbin/${bin}" "${target}/usr/sbin/${bin}" &&
                    chmod +x "${target}/usr/sbin/${bin}" &&
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
            [[ -f "/usr/local/bin/${bin}" ]] &&
                cp "/usr/local/bin/${bin}" "${target}/usr/local/bin/${bin}" &&
                chmod +x "${target}/usr/local/bin/${bin}"
        done
        # sbin-level CLI tools:
        #   kspawn            — ZFS-native cluster spawner
        #   kldload-tls-cert  — self-signed TLS cert script for webui HTTPS
        mkdir -p "${target}/usr/local/sbin"
        for bin in kspawn kldload-ca kldload-tls-cert kldload-wait-for-ip kldload-bounce-tls-services kldload-session kldload-headlamp-install kldload-secure-boot kldload-debug-bundle kldload-rhel-composer-build; do
            [[ -f "/usr/local/sbin/${bin}" ]] &&
                cp "/usr/local/sbin/${bin}" "${target}/usr/local/sbin/${bin}" &&
                chmod +x "${target}/usr/local/sbin/${bin}" &&
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

        # /usr/local/lib/kldload-* — Python modules consumed by the k* CLIs.
        # Currently: kldload-rag/ (used by kldload-rag-index, kai-rag, and the
        # bob RAG bridge). Without these on target, `bob` falls back to no-RAG
        # mode silently and every kldload-specific question gets a generic
        # answer. Glob handles future additions. Caught 2026-05-23 on .101.
        if compgen -G '/usr/local/lib/kldload-*' >/dev/null 2>&1; then
            mkdir -p "${target}/usr/local/lib"
            for _libdir in /usr/local/lib/kldload-*/; do
                [[ -d "$_libdir" ]] || continue
                _libname=$(basename "$_libdir")
                mkdir -p "${target}/usr/local/lib/${_libname}"
                cp -r "${_libdir}." "${target}/usr/local/lib/${_libname}/"
                k_log "Copied /usr/local/lib/${_libname} ($(du -sh "${target}/usr/local/lib/${_libname}" 2>/dev/null | cut -f1))"
            done
        fi

        # (ChromaDB data dir created below alongside the symlink block.)

        # RAG python deps — chromadb (vector store) + beautifulsoup4 (HTML doc
        # extraction). No RPM ships either; dnf --installroot has no path to
        # pip-install into the target, so we do it explicitly here. Same
        # pattern as the websockets pip install below. --break-system-packages
        # is required on PEP 668 distros (Fedora 43+, RHEL 10+, Debian 13+).
        # Without this, `kldload-rag-index` crashes on import and Bob's RAG
        # bridge can't index anything.
        chroot "${target}" pip3 install --quiet --break-system-packages \
            chromadb beautifulsoup4 2>/dev/null ||
            k_log "WARNING: chromadb/bs4 pip install failed — RAG will not function"

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

        # ── kldload RAG service + indexer ───────────────────────────────────
        # The RAG service answers /query and /health on :8400. The first-boot
        # service runs the indexer once after install to populate ChromaDB.
        # The nightly timer keeps it fresh as kldload tools/docs change.
        if [[ -f /usr/lib/systemd/system/kldload-rag.service ]]; then
            ln -sf "/usr/lib/systemd/system/kldload-rag.service" \
                "${target}/etc/systemd/system/multi-user.target.wants/kldload-rag.service" || true
        fi
        if [[ -f /usr/lib/systemd/system/kldload-rag-firstboot.service ]]; then
            ln -sf "/usr/lib/systemd/system/kldload-rag-firstboot.service" \
                "${target}/etc/systemd/system/multi-user.target.wants/kldload-rag-firstboot.service" || true
        fi
        if [[ -f /usr/lib/systemd/system/kldload-rag-index.timer ]]; then
            ln -sf "/usr/lib/systemd/system/kldload-rag-index.timer" \
                "${target}/etc/systemd/system/timers.target.wants/kldload-rag-index.timer" || true
        fi
        # ChromaDB data dir
        install -d -m 0755 "${target}/var/lib/kldload-rag"

        # ── RHEL firstboot composer build ──────────────────────────────────
        # Wires kldload-rhel-composer.service into multi-user.target.wants/.
        # The unit's ConditionPathExists=/var/lib/klab/.rhel-composer-pending
        # makes it a no-op on non-RHEL installs (the marker file is only
        # written by bootstrap.sh when KLDLOAD_DISTRO=rhel). Safe to enable
        # universally. See kldload-rhel-composer-build header for the why
        # (RH's password-grant SSO API is dead; composer is the replacement).
        if [[ -f /usr/lib/systemd/system/kldload-rhel-composer.service ]]; then
            ln -sf "/usr/lib/systemd/system/kldload-rhel-composer.service" \
                "${target}/etc/systemd/system/multi-user.target.wants/kldload-rhel-composer.service" || true
        fi
        install -d -m 0755 "${target}/var/lib/klab/images"
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
            cp -r /etc/nginx/conf.d "${target}/etc/nginx/" 2>/dev/null || true
            cp -r /etc/nginx/kldload "${target}/etc/nginx/" 2>/dev/null || true
            cp /etc/nginx/nginx.conf "${target}/etc/nginx/nginx.conf" 2>/dev/null || true
            mkdir -p "${target}/etc/nginx/conf.d/kldload-dyn"
            # Nginx system user differs by distro: RHEL/Fedora ship `nginx`,
            # Debian/Ubuntu ship `www-data`. Our shipped nginx.conf uses
            # `user nginx;` which works on RPM but on Debian fails with
            # `getpwnam("nginx") failed`, nginx -t errors, service crash-loops.
            # Patch the user line to match the target's package.
            case "${KLDLOAD_DISTRO:-centos}" in
            debian | ubuntu)
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
        [[ -f "${target}/usr/lib/systemd/system/ttyd-k9s.service" ]] &&
            ln -sf "/usr/lib/systemd/system/ttyd-k9s.service" \
                "${target}/etc/systemd/system/multi-user.target.wants/ttyd-k9s.service" || true

        # ── Fix websockets version (CentOS 9 RPM is too old for websockets.http11) ──
        # The kldload-webui Python server requires websockets.http11 (v11+ API).
        # The CentOS 9 python3-websockets RPM ships v10 which lacks that module.
        # pip-install a newer version to overwrite the system package on RPM targets.
        # (Debian/Ubuntu ship a compatible version, but this is harmless there.)
        chroot "${target}" pip3 install --quiet "websockets>=11" 2>/dev/null || true

        # ── Web UI binary + static files ──────────────────────────────────────────
        [[ -x /usr/local/bin/kldload-webui ]] &&
            cp /usr/local/bin/kldload-webui "${target}/usr/local/bin/kldload-webui" &&
            chmod +x "${target}/usr/local/bin/kldload-webui"
        # The service WorkingDirectory is /usr/local/share/kldload-webui — copy static files
        if [[ -d /usr/local/share/kldload-webui/active ]]; then
            mkdir -p "${target}/usr/local/share/kldload-webui"
            cp -r /usr/local/share/kldload-webui/active/. "${target}/usr/local/share/kldload-webui/"
        fi

        # ── Platform assets under /usr/local/share/kldload* ───────────────────────
        # The installer copies named paths only — /usr/local/share/ does NOT
        # come along automatically. Build #45 moved demo assets into
        # /usr/local/share/kldload/ on the (wrong) assumption that the path
        # would travel. Multiple consumers broke on installed systems while
        # working fine in the live env:
        #
        #   /usr/local/share/kldload/demo/            chart + Argo Application
        #                                             — kube-demo javaapi
        #   /usr/local/share/kldload/tetragon-filter.jq F11 tracing cockpit
        #                                             (kldload-console)
        #   /usr/local/share/kldload/ktcp-format.awk  ktcp output formatter
        #   /usr/local/share/kldload/argocd-values.yaml autodeploy ArgoCD install
        #   /usr/local/share/kldload/tests/           smoke-*.sh test suite
        #   /usr/local/share/kldload-examples/        32-example library (build #41)
        #
        # Caught on .137 build #45 install: kube-demo javaapi missing chart,
        # F11 cockpit dying with "Could not open tetragon-filter.jq", smoke
        # tests not present, etc. All fixed by copying the whole tree.
        #
        # Five kldload-* top-level dirs exist in /usr/local/share — handle
        # each with an explicit cp -r so a new one needs an explicit line
        # (avoiding the "all of /usr/local/share/ copies blindly" footgun).
        for _share in kldload kldload-examples; do
            if [[ -d "/usr/local/share/${_share}" ]]; then
                mkdir -p "${target}/usr/local/share/${_share}"
                cp -r "/usr/local/share/${_share}/." "${target}/usr/local/share/${_share}/"
            fi
        done
        # kldload-ai and kldload-webui already handled above; kldload-ansible
        # may need its own block if its tree grows beyond what the autodeploy
        # symlinks reach.

        # ── Chrome autostart to dashboard — LAB profiles only ────────────────────
        # Workstation (desktop) and headless (server) installs should NOT have
        # the browser auto-open to the kldload dashboard at every login —
        # that's a daily driver, the user's homepage is theirs. Only lab
        # profiles (kvm/ai/zfslab) where the operator explicitly booted FOR
        # the UI get the auto-open. Firefox was the previous default here;
        # ripped 2026-06-06 after operator decided to standardize on Chrome
        # (see project rules / task #15 / task #47). Chrome is the only browser
        # in the desktop package list now; the live ISO's installer-GUI
        # rendering still uses Firefox (transient, not user-facing).
        case "${KLDLOAD_PROFILE:-server}" in
        kvm | ai | zfslab)
            mkdir -p "${target}/etc/xdg/autostart"
            cat >"${target}/etc/xdg/autostart/kldload-dashboard.desktop" <<'DASHSTART'
[Desktop Entry]
Type=Application
Name=kldload Dashboard
Comment=Auto-open the kldload ops console at login (lab profile)
Exec=bash -c 'for i in $(seq 1 60); do (echo >/dev/tcp/localhost/8443) 2>/dev/null && break; sleep 1; done; sleep 3; google-chrome-stable --new-window https://localhost:8443'
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=8
DASHSTART
            ;;
        esac

        # App-menu launchers — every non-core GUI profile gets the FULL set of
        # kldload/bob launchers, not just the webui. The live ISO ships ~13 of them
        # (.desktop) at /usr/share/applications/; we copy ALL kldload-*/bob-* so the
        # 68 tools in /usr/local/bin are actually discoverable in the GNOME menu.
        # Regression caught 2026-05-31 on .137 RHEL desktop: only kldload-webui.desktop
        # was copied (explicit single-file whitelist) -> 68 tools present but only 3
        # menu entries, desktop looked empty. Glob copy fixes it for every distro.
        if [[ "${KLDLOAD_PROFILE:-server}" != "core" ]]; then
            mkdir -p "${target}/usr/share/applications"
            # Each launcher is a single .desktop whose StartupWMClass matches the
            # Wayland app_id kldload-chrome-app sets via `--class` — GNOME maps the
            # Chrome app window to its OWN icon directly, no hidden shadow entry
            # needed. (A prior build added com.kldload.*.desktop shadows for the
            # GTK4 kldload-webview path; that path was reverted to chrome-app
            # because WebKit fails to map a window on first boot before the NVIDIA
            # akmod loads — windowless processes pile up and "no icon opens".)
            # zxplore ships its own .desktop (not kldload-*/bob-*), so name it
            # explicitly or the installed target gets the binary with no launcher
            # (observed .139 2026-07-28).
            for _lnch in /usr/share/applications/kldload-*.desktop \
                /usr/share/applications/bob-*.desktop \
                /usr/share/applications/zxplore.desktop \
                /usr/share/applications/wgxplore.desktop \
                /usr/share/applications/vmxplore*.desktop; do
                [[ -f "$_lnch" ]] || continue
                # honor the ZFS Console opt-out (checkbox, default on)
                [[ "$(basename "$_lnch")" == zxplore* && "${KLDLOAD_ENABLE_ZXPLORE:-1}" != "1" ]] && continue
                install -m 0644 "$_lnch" \
                    "${target}/usr/share/applications/$(basename "$_lnch")"
            done
            chroot "${target}" update-desktop-database /usr/share/applications 2>/dev/null || true

            # Custom kldload app icons (gold-on-slate set) — copy the scalable theme
            # icons the launchers reference, else the menu shows generic fallbacks.
            local themedir="usr/share/icons/hicolor/scalable/apps"
            if [[ -d "/${themedir}" ]]; then
                mkdir -p "${target}/${themedir}"
                # WARN: this is a CURATED list, so a new icon is invisible here
                # until its name is added — the launcher then shows a generic
                # square and nothing logs a thing.
                # HISTORY: 2026-08-13. ollama.svg shipped on the ISO, passed
                # every check that looked at the ISO, and still did not reach
                # the installed system: bob-*.svg matched, ollama.svg matched
                # no pattern, and the Ollama tile rendered as a blank square.
                for _ic in /${themedir}/kldload-*.svg /${themedir}/bob-*.svg \
                    /${themedir}/kst*.svg /${themedir}/ksnap.svg /${themedir}/kexport.svg \
                    /${themedir}/zxplore*.svg /${themedir}/wgxplore.svg \
                    /${themedir}/vmxplore.svg /${themedir}/ollama.svg; do
                    [[ -f "$_ic" ]] || continue
                    # honor the ZFS Console opt-out (checkbox, default on)
                    [[ "$(basename "$_ic")" == zxplore* && "${KLDLOAD_ENABLE_ZXPLORE:-1}" != "1" ]] && continue
                    install -m 0644 "$_ic" \
                        "${target}/${themedir}/$(basename "$_ic")"
                done
            fi

            # ── polkit actions: carry them to the target ──────────────────────
            # The target is debootstrapped fresh, so NOTHING from the live
            # ISO's rootfs arrives unless it is copied explicitly. build-iso.sh
            # puts org.kldload.wgxplore.policy into the ISO (fixed 2026-08-03
            # after it reached neither ISO nor install), but that only ever got
            # it as far as the live environment — every INSTALL has shipped
            # without it since.
            #
            # allow_active=yes in that policy is what makes the estate console
            # refresh without a prompt. Its absence is currently masked by the
            # NOPASSWD sudoers entry, which the elevation ladder tries before
            # pkexec — so nobody saw a prompt. On any install that tightens
            # sudo, the ladder falls through to pkexec and the GUI starts
            # raising a dialog on every periodic refresh.
            # HISTORY: found 2026-08-10 while tracing the libvirt prompt on
            # .149; `ls /usr/share/polkit-1/actions` there matched nothing.
            if [[ -d /usr/share/polkit-1 ]]; then
                mkdir -p "${target}/usr/share/polkit-1"
                cp -r /usr/share/polkit-1/. "${target}/usr/share/polkit-1/" ||
                    k_log "WARN: polkit actions not copied — consoles may prompt on refresh"
            fi

            # Konsole's stock .desktop references Icon=utilities-terminal — a
            # name that exists in Breeze (KDE) but NOT in Adwaita/hicolor on
            # RHEL 10 / GNOME 50. Without a fallback in hicolor, the dock pin
            # for Konsole renders as the default-app triangle (operator
            # report .137 b628 2026-06-06). Konsole pulls in
            # breeze-icon-theme as a dep, so the Breeze SVG is on the target
            # — symlink it into hicolor's universal-fallback path. Cheap
            # against icon-theme updates because the symlink targets the
            # package-installed Breeze file rather than copying the bytes.
            local _btv=""
            for _bsz in 48 64 32 22 16; do
                if [[ -f "${target}/usr/share/icons/breeze/apps/${_bsz}/utilities-terminal.svg" ]]; then
                    _btv="${_bsz}"
                    break
                fi
            done
            if [[ -n "$_btv" ]] && [[ ! -e "${target}/usr/share/icons/hicolor/scalable/apps/utilities-terminal.svg" ]]; then
                ln -sf "/usr/share/icons/breeze/apps/${_btv}/utilities-terminal.svg" \
                    "${target}/usr/share/icons/hicolor/scalable/apps/utilities-terminal.svg"
                k_log "icons: utilities-terminal symlinked from breeze (${_btv}px) — Konsole dock pin now resolves"
            fi
            chroot "${target}" gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true

            # Curate stock launchers (package-owned, so patched on-target, idempotent):
            #   htop — a TUI; the Konsole/terminal tile covers it. Hide its GUI tile.
            #   vim  — the stock launcher ships Exec=gnome-terminal, which is absent on
            #          RHEL/konsole desktops, so its tile is a dead click. Repoint it at
            #          kldload-term (picks whatever terminal the box actually has). Its
            #          default text-editor icon is kept — no custom icon.
            local _appdir="${target}/usr/share/applications"
            if [[ -f "${_appdir}/htop.desktop" ]] && ! grep -q '^NoDisplay=true' "${_appdir}/htop.desktop"; then
                printf 'NoDisplay=true\n' >>"${_appdir}/htop.desktop"
            fi

            # ── One terminal in the grid, not four ───────────────────────────
            # The package set pulls konsole, ptyxis, gnome-console AND
            # gnome-terminal — konsole for its kldload colourschemes, ptyxis
            # and gnome-console as Fedora desktop defaults, gnome-terminal
            # because the dock pins it. Every one ships a launcher, so the
            # grid ends up with "Terminal", "Terminal", "Console" and
            # "Konsole" side by side and no way to tell which is which.
            #
            # HISTORY: reported by the operator 2026-08-13 on a fresh desktop
            # install — "a terminal and a console and printsettings and a
            # konsole .. idk where that came from but dont want it".
            #
            # Hidden, not uninstalled: konsole's colourschemes are still used
            # by kldload-term, ptyxis is a dependency of the Fedora desktop
            # group, and removing packages to tidy a menu invites a
            # dependency cascade. NoDisplay only affects the launcher.
            #
            # org.gnome.Terminal.desktop is deliberately NOT in this list —
            # it is the one 50-kldload-installed-favorites pins to the dock,
            # so it is the terminal the operator actually sees and uses.
            local _dupe
            for _dupe in org.gnome.Console.desktop org.gnome.Ptyxis.desktop \
                org.kde.konsole.desktop system-config-printer.desktop; do
                if [[ -f "${_appdir}/${_dupe}" ]] &&
                    ! grep -q '^NoDisplay=true' "${_appdir}/${_dupe}"; then
                    printf 'NoDisplay=true\n' >>"${_appdir}/${_dupe}"
                    k_log "hid duplicate launcher: ${_dupe}"
                fi
            done
            if [[ -f "${_appdir}/vim.desktop" ]] && grep -q '^Exec=gnome-terminal' "${_appdir}/vim.desktop"; then
                sed -i 's|^Exec=gnome-terminal[[:space:]]*--[[:space:]]*|Exec=kldload-term |' "${_appdir}/vim.desktop"
            fi
            # Launcher surface is profile-dependent — this is the Workstation /
            # server-class split:
            #   desktop (Workstation): every tool is a first-class app icon in
            #     the GNOME grid. The launchers ship NoDisplay=true (hidden on
            #     the live ISO and on server-class installs); strip it here so
            #     the operator gets point-and-shoot windows — VMs, K8s, ZFS,
            #     Metrics, Ansible, Helm, klab — each grouping under its own icon
            #     (kldload-chrome-app sets a matching Wayland app_id via --class).
            #   kvm / zfslab / klab / server / core: keep the single cohesive
            #     web GUI page (https://localhost:8443) as the only surface, the
            #     way it's always been. Those land on a server, not a desktop, so
            #     per-tool grid icons would be clutter — leave NoDisplay in place.
            # The live ISO keeps them hidden regardless (the web GUI is the live
            # surface). Operator on .145 b651 live 2026-06-11: "the live needs
            # all the rescue tools and the GUI, but nothing else is installed yet
            # so [the infra section] is useless."
            if [[ "${KLDLOAD_PROFILE:-server}" == "desktop" ]]; then
                # kldload-webui included so the web GUI is a point-and-click win+A
                # app (hexagon icon) on the workstation, not just a hidden window
                # matcher. Lab/server keep it NoDisplay (their surface is the
                # auto-opened kiosk page).
                # ZFS is now ONE console: kldload-zexplore (the zexplore TUI — browse /
                # snapshot / replicate / VM-fs explore, k9s-for-ZFS). The old
                # per-function ZFS tiles (kldload-zfs "ZFS Snapshots", kldload-zfs-
                # manager GTK dialogs, ksnap) are consolidated into it, so they are
                # NO LONGER stripped here and stay NoDisplay on the desktop grid —
                # their functions live inside zexplore. kldload-zfslab stays separate:
                # it's the OpenZFS VM test lab, a different job, not file/snapshot
                # management. (2026-07-26: operator "the other zfs tools should all
                # be in the 1 zfs tool".)
                # 2026-08-09, same consolidation as the ZFS tiles above: the
                # VM, klab and ZFS-lab launchers are NO LONGER stripped. Their
                # functions live inside vmxplore's kldload tab, which carries
                # 27 tools with descriptions and colour — so a loose grid icon
                # for each was the same toolset twice, once organised and once
                # as a wall. kexport goes with them (it is a vmxplore tile).
                # Kubernetes, k9s, Metrics, Ansible, Helm, the web GUI and
                # sysdiag stay: the console has no equivalent for them, so the
                # icon IS the interface. Operator: "you can remove everything
                # in the kldload folder — that's all the old tools."
                for _ldskt in kldload-k8s kldload-helm \
                    kldload-ansible kldload-metrics kldload-zexplore \
                    kldload-sysdiag \
                    bob-chat kldload-k9s bob-gaming kldload-webui; do
                    if [[ -f "${_appdir}/${_ldskt}.desktop" ]]; then
                        sed -i '/^NoDisplay=true$/d' "${_appdir}/${_ldskt}.desktop"
                    fi
                done
                # Workstation: the web GUI is launched on demand from win+A, NOT
                # flung open on every login. Drop the system autostart that
                # build-iso.sh ships (lab/server profiles keep it as their kiosk
                # surface). Operator request 2026-06-15.
                rm -f "${target}/etc/xdg/autostart/kldload-webui.desktop"
            fi
            chroot "${target}" update-desktop-database /usr/share/applications 2>/dev/null || true
        fi

        # ── Service auto-start gate ────────────────────────────────────────────────
        # Lab profiles (kvm / ai / zfslab / klab) and the desktop / Workstation
        # Developer Edition auto-start the webui + proxy + ttyd-k9s so the
        # operator lands on the UI at first boot. Workstation: the embedded
        # browser-terminal panel (TTYD → kldload-console F-key tmux cockpit)
        # is the headline UX next to gnome-terminal and the kldload-klab-console
        # dock launcher. Without ttyd-k9s enabled at boot, the "TERMINAL" panel
        # in the webui shows a connect-refused state. Operator on .140 b640:
        # "tmux commands and integration with bob ... works great as the server
        # console but doesn't exist in workstation" — that was this gate.
        # Server: opt-in. The installer's Platform Options panel has a "Web ops
        # console" card that sets KLDLOAD_ENABLE_WEBUI=1 when checked. Default
        # unchecked → binaries still copied (so the operator can flip it on
        # later) but the systemd units are disabled at boot to spare RAM/CPU on
        # headless boxes whose user may never open the UI. Manual enable:
        #     sudo systemctl enable --now kldload-proxy kldload-webui ttyd-k9s
        # core: always disabled — bare ZFS only, no UI of any kind.
        case "${KLDLOAD_PROFILE:-server}" in
        kvm | ai | zfslab | klab | desktop)
            : # keep defaults — enabled in each unit's [Install] WantedBy
            ;;
        server)
            if [[ "${KLDLOAD_ENABLE_WEBUI:-0}" == "1" ]]; then
                # Operator opted in via the Platform Options card. Leave the
                # default WantedBy enable intact.
                k_log "Web ops console: enabled at boot (opt-in via Platform Options)."
            else
                chroot "${target}" systemctl disable kldload-webui.service 2>/dev/null || true
                chroot "${target}" systemctl disable kldload-proxy.service 2>/dev/null || true
                chroot "${target}" systemctl disable ttyd-k9s.service 2>/dev/null || true
            fi
            ;;
        *)
            # core (and any unknown profile) — disable.
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
    [[ -f /etc/kldload-build-id ]] && cp /etc/kldload-build-id "${target}/etc/kldload-build-id"

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
    echo "${_profile}" >"${target}/etc/kldload/profile"

    # ── User tools: ZFS helpers + adduser.local hook (skip for core) ─────────────
    mkdir -p "${target}/usr/local/bin" "${target}/usr/local/sbin"
    if [[ "$_profile" != "core" ]]; then
        # eza not in EPEL — copy from live if target doesn't have it.
        # See sanoid loop above for why we test paths instead of `chroot
        # ... command -v` (the latter doesn't work; `command` is a bash
        # builtin, not in PATH).
        if [[ -x /usr/local/bin/eza ]] &&
            [[ ! -x "${target}/usr/bin/eza" ]] &&
            [[ ! -x "${target}/usr/local/bin/eza" ]]; then
            cp /usr/local/bin/eza "${target}/usr/local/bin/eza"
            chmod +x "${target}/usr/local/bin/eza"
        fi
        # Wholesale copy of kldload CLI tools — everything matching k* or _k*
        # in /usr/local/bin. The `_` prefix tools (_ktoggle-win, _kconsole-home)
        # are helpers called from kldload-console's tmux keybindings; missing
        # them makes every F-key return 127. Skip installer-only internals.
        # zexplore* is explicit: the ZFS console + its API/guest CLI break the k*
        # naming convention (branded "zexplore"), so the k*/_k* globs silently
        # dropped them — the installed system got kldload-zexplore.desktop but no
        # zexplore binary, and the app tile opened a terminal to "zexplore: command not
        # found" (.116 2026-07-26). Any future non-k tool needs adding here too.
        _skip_tools="kldload-install-target kldload-overview"
        shopt -s nullglob
        # wgx is explicit like zxplore: the WG networks console breaks the k*
        # naming convention, so the globs would silently drop it. vmxplore and
        # vmx are explicit for the same reason and cost a broken install to
        # learn: 1.4.0-rc2 shipped both launchers, the icon and the commit
        # stamp to the target and NOT the binaries, so a fresh .149 install had
        # two app tiles that opened onto "vmxplore: command not found". The
        # warning three lines above this one was already there. Read it.
        for _src in /usr/local/bin/k* /usr/local/bin/_k* /usr/local/bin/_s* \
            /usr/local/bin/zxplore* /usr/local/bin/zexplore* /usr/local/bin/bob* \
            /usr/local/bin/wgx /usr/local/bin/vmxplore /usr/local/bin/vmx; do
            [[ -x "$_src" ]] || continue
            _name="$(basename "$_src")"
            # ZFS Console is an installer checkbox (default on) — honor an
            # explicit opt-out. KLDLOAD_ENABLE_ZXPLORE from bootstrap.sh.
            [[ "$_name" == zxplore* && "${KLDLOAD_ENABLE_ZXPLORE:-1}" != "1" ]] && continue
            case " $_skip_tools kldload-webui " in *" $_name "*) continue ;; esac
            cp "$_src" "${target}/usr/local/bin/${_name}"
            chmod +x "${target}/usr/local/bin/${_name}"
        done
        shopt -u nullglob

        # ── Component DEFINITIONS ───────────────────────────────────────
        #
        # kldload-component itself rides the k* glob above, so the CLI has
        # always landed. Its definitions do not: they live in
        # /usr/lib/kldload/components/*.component, which is a data directory
        # no glob here touches. The result is a tool that installs perfectly
        # and manages nothing.
        #
        # HISTORY: 2026-08-15, .145. `kldload-component list` printed its
        # header row and not one component. /usr/lib/kldload did not exist on
        # the target at all. Every optional component — ai, k8s, klab, kvm,
        # zfslab — was therefore un-installable and un-removable on every
        # machine kldload has ever installed, with no error anywhere: the CLI
        # was present, it ran, it just had an empty catalogue. This is the
        # same shape as the vmxplore launcher-without-a-binary bug recorded
        # forty lines above, and the same lesson — shipping the entry point
        # is not shipping the feature.
        if [[ -d /usr/lib/kldload/components ]]; then
            mkdir -p "${target}/usr/lib/kldload/components"
            if cp -a /usr/lib/kldload/components/. \
                "${target}/usr/lib/kldload/components/" 2>/dev/null; then
                k_log "installed component definitions ($(find /usr/lib/kldload/components -name '*.component' | wc -l) components)"
            else
                k_log "WARNING: component definitions failed to copy — kldload-component will list nothing"
            fi
        else
            k_log "WARNING: /usr/lib/kldload/components missing from the live env — kldload-component will list nothing"
        fi

        # ── Install ansible-core NOW, at install time, not first boot. ──
        # Autodeploy + kube-cluster + klab all call ansible-playbook for
        # provisioning. If it's missing when autodeploy fires, the first-boot
        # orchestration dies. We install eagerly here so it's baked in.
        # Works offline via the darksite repo — the package is listed in
        # target-base.txt for every supported distro.
        case "${KLDLOAD_DISTRO:-centos}" in
        centos | rocky | rhel | fedora)
            chroot "${target}" dnf install -y ansible-core >/dev/null 2>&1 ||
                k_log "WARNING: ansible-core install failed — autodeploy may retry at first boot"
            ;;
        debian | ubuntu)
            chroot "${target}" apt-get install -y ansible-core >/dev/null 2>&1 ||
                k_log "WARNING: ansible-core install failed — autodeploy may retry at first boot"
            ;;
        esac
        # Verify — if this fails the install is broken and should not claim
        # success. Test paths directly (see eza/sanoid blocks above for why
        # `chroot ... command -v` doesn't work).
        if [[ -x "${target}/usr/bin/ansible-playbook" ]] ||
            [[ -x "${target}/usr/local/bin/ansible-playbook" ]]; then
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
            cp -r /usr/local/share/kldload-ansible/. "${target}/usr/local/share/kldload-ansible/"
            local _src _dst
            _src=$(find /usr/local/share/kldload-ansible/playbooks -maxdepth 1 -name '*.yml' 2>/dev/null | wc -l)
            _dst=$(find "${target}/usr/local/share/kldload-ansible/playbooks" -maxdepth 1 -name '*.yml' 2>/dev/null | wc -l)
            k_log "installed kldload-ansible (${_dst}/${_src} playbooks)"
            # .135 2026-06-05: install landed with 1/6 playbooks — kube-cluster
            # dies on the missing provision-golden.yml. The earlier code logged
            # the count but never verified, so the regression was invisible.
            if ((_src > 0)) && ((_dst < _src)); then
                k_die "ansible playbook copy dropped files: ${_dst}/${_src} landed. src=/usr/local/share/kldload-ansible/playbooks dst=${target}/usr/local/share/kldload-ansible/playbooks"
            fi
        else
            k_die "/usr/local/share/kldload-ansible missing in live root — kube-cluster + Ansible tab will fail"
        fi
        [[ -f /usr/local/sbin/adduser.local ]] &&
            cp /usr/local/sbin/adduser.local "${target}/usr/local/sbin/adduser.local" &&
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
    centos) _target_suite="stream9" ;;
    rocky) _target_suite="9" ;;
    rhel) _target_suite="10" ;;
    fedora) _target_suite="${KLDLOAD_FEDORA_RELEASE:-44}" ;;
    debian) _target_suite="${KLDLOAD_SUITE:-trixie}" ;;
    ubuntu) _target_suite="${KLDLOAD_SUITE:-noble}" ;;
    arch) _target_suite="rolling" ;;
    esac
    # VERSION_ID is REQUIRED by tools that key off distro identity:
    # osbuild-composer's weldr API refuses to start without it
    # ("failed to read host distro information"), dnf/yum plugins use it,
    # Ansible reads it as ansible_distribution_version. ID_LIKE lets
    # rhel-family / debian-family tools accept the derivative.
    local _id_like=""
    case "$_target_distro" in
    centos | rocky | rhel | fedora) _id_like='ID_LIKE="rhel fedora"' ;;
    debian | ubuntu) _id_like='ID_LIKE=debian' ;;
    esac
    cat >"${target}/etc/os-release" <<OSREL
PRETTY_NAME="kldload (${_target_distro} ${_target_suite})"
NAME="kldload"
ID=${_target_distro}
VERSION="${_target_suite}"
VERSION_ID="${_target_suite}"
${_id_like}
OSREL

    # ── GNOME dconf system settings (dock, theme, terminal defaults) ──────────────
    mkdir -p "${target}/etc/dconf/db/local.d" "${target}/etc/dconf/profile"
    for _f in 00-kldload-desktop 01-kldload-terminal-default; do
        [[ -f "/etc/dconf/db/local.d/${_f}" ]] &&
            cp "/etc/dconf/db/local.d/${_f}" "${target}/etc/dconf/db/local.d/${_f}"
    done
    [[ -f /etc/dconf/profile/user ]] && cp /etc/dconf/profile/user "${target}/etc/dconf/profile/user"

    # ── /etc files that live in includes.chroot but profiles.sh has to
    #    explicitly carry through to /target (build-iso.sh puts them in the
    #    LIVE rootfs; the install-time chroot dnf doesn't copy /etc/* from
    #    live to target — only package-owned files arrive that way). Each
    #    miss caused a real .137/.121 install regression:
    #
    #      gtk-3.0/settings.ini + gtk-4.0/settings.ini  → GTK3/4 apps without
    #        these render with light theme even on a dark-mode session
    #        (.137 b628 audit 2026-06-06).
    #      yum.repos.d/google-chrome.repo              → without it on the
    #        target at chroot-dnf time, dnf install -y google-chrome-stable
    #        silently fails to resolve, falls back to firefox staying pinned
    #        (.121 b637 audit: firefox installed, chrome missing).
    #
    #    Loop the live → target carry-over so any future /etc file we drop
    #    into includes.chroot lands on the installed system too.
    for _p in etc/gtk-3.0/settings.ini etc/gtk-4.0/settings.ini etc/yum.repos.d/google-chrome.repo; do
        if [[ -f "/${_p}" ]]; then
            install -D -m 0644 "/${_p}" "${target}/${_p}"
            k_log "carried /${_p} → target"
        fi
    done
    unset _p

    # ── Installed-system dock favorites — minimum viable ─────────────────────
    # 00-kldload-desktop ships with empty favorites for the live ISO. This
    # overlay pins the BARE MINIMUM for the installed workstation:
    #   Nautilus      — Files
    #   Chrome        — browser (also the entry point to the webui at
    #                   localhost:8443 — see Chrome managed policy below
    #                   which sets that as homepage + startup page)
    #   Konsole       — terminal (everything kldload is CLI-discoverable
    #                   from here: `klab`, `kldload-console`, `bob`,
    #                   `kldload-doctor`, `kst`, `ksnap`, etc.)
    # All custom kldload-*/bob-* dock launchers were ripped 2026-06-06
    # per operator: "yeah so its literally 2 folders .. terminal konsole
    # chrome and files ... the cleanest possible install". Pure-Unix
    # posture: the OS does NOT advertise itself in the dock. Power users
    # find the tools via $PATH; the webui is just a website Chrome opens.
    # GNOME silently drops favorites whose .desktop is missing, so on a
    # build without Chrome the dock still renders Files + Konsole.
    # 3-pin (no Konsole). Operator on .142 b647 2026-06-08: "the dock should
    # The dock's contents live in ONE place — the shipped file under
    # live-build/config/includes.chroot/etc/dconf/db/local.d/. This block
    # only places it on the target.
    # COPY the shipped file; do not restate the pins here. This heredoc used
    # to carry its own copy of the list "kept in sync by hand", and it drifted
    # exactly as that always does: by 2026-08-10 the shipped file had nine
    # pins and this one still wrote six, and because this runs at install time
    # it WON. Every install got the stale dock while the repo looked correct.
    # One source of truth, and the assertion below still catches a failed copy.
    # SOURCE ORDER MATTERS. Read from target-files/ FIRST, because the live
    # session's own /etc/dconf/db/local.d/ deliberately does NOT contain this
    # file — build-iso.sh:1244 excludes it on purpose so the LIVE desktop does
    # not get install-only dock pins.
    #
    # HISTORY: 2026-08-13, fiend. This block read only the live path, found
    # nothing (by design), skipped the copy, and the assertion below then
    # fired k_die — which is `k_log ERROR; exit 1`. That exit happened inside
    # k_install_system_files, which runs from k_apply_profile at
    # install-target:2048, LONG BEFORE k_install_bootloader at :2113. So the
    # installer aborted before writing any bootloader and left a machine that
    # dropped to firmware with Secure Boot on or off. Every desktop install
    # from an ISO built after that exclusion was unbootable, and the symptom
    # looked like a Secure Boot or USB problem.
    local _pins_src=""
    for _c in \
        /usr/lib/kldload-installer/target-files/etc/dconf/db/local.d/50-kldload-installed-favorites \
        /etc/dconf/db/local.d/50-kldload-installed-favorites; do
        [[ -s "$_c" ]] && {
            _pins_src="$_c"
            break
        }
    done
    if [[ -n "$_pins_src" ]]; then
        cp "$_pins_src" \
            "${target}/etc/dconf/db/local.d/50-kldload-installed-favorites"
    fi
    # .135 + onyx both shipped without this file in the installed system —
    # dock came up empty for fresh users. So the check stays; what changed is
    # the CONSEQUENCE. A missing dock pin is a cosmetically incomplete
    # desktop. k_die here costs a bootloader, which is an unbootable machine.
    # Those are not the same severity and must not share an exit path.
    [[ -s "${target}/etc/dconf/db/local.d/50-kldload-installed-favorites" ]] ||
        k_log "WARN: dock pins not installed (looked in target-files/ and /etc/dconf/db/local.d/) — the desktop will come up without kldload's pinned apps. NOT fatal: a bare dock is not worth an unbootable system."

    # ── Lock the visual-identity keys so re-login doesn't drift ───────────────
    # Operator on .137 b628 logged out, logged back in, and the carefully-set
    # folder-children + favorites + wallpaper reset to GNOME 47 schema defaults
    # — which on RHEL 10 are leftovers from upstream contributions
    # ('System','Utilities','YaST','Pardus') intermixed with our intended
    # 'system','apps' folders. Result: icons scattered, ghost folders, no
    # kldload wallpaper. /etc/dconf/db/local.d/locks/ entries make these keys
    # read-only at the user-session layer; gsettings set is rejected with
    # "The key is not writable." Installed system gets the locked-in look
    # every login.
    mkdir -p "${target}/etc/dconf/db/local.d/locks"
    # Locks list: ONLY the brand/structural keys. Anything an operator should
    # be able to flip from Settings (color-scheme, gtk-theme, font-name, etc.)
    # is set as a DEFAULT in 00-kldload-desktop but NOT locked. The .140 b640
    # operator hit the inverse — color-scheme was locked, so the GNOME quick
    # dark/light toggle silently no-op'd. Rule of thumb:
    #   LOCK:   identity (wallpaper, dock pins, app-folder layout, brand)
    #   DEFAULT: preference (theme variant, fonts, animations, idle delay)
    # Operator on .142 b647 2026-06-08: "still can't make the background
    # change using gnome?" The wallpaper IS identity territory by the rule
    # above, but locking it actively prevents the operator from picking a
    # different one via Settings → Appearance — a basic ergonomic loss.
    # Demote wallpaper from LOCK to DEFAULT: the kldload picture-uri stays
    # the install-time default (set in 00-kldload-desktop), but GNOME
    # Settings can override it for the session. Locks now stick to
    # structural-only (app folders + dock pins).
    # favorite-apps is a DEFAULT, not a lock. Locked, GNOME hides the
    # Pin/Unpin item entirely and `gsettings set` answers "The key is not
    # writable" — so an operator who wants their own editor on the dock has
    # no way to do it and nothing telling them why. Reported 2026-08-10:
    # "i dont see a way to pin/unpin from the dock .. I feel like i missed
    # something?" They had not; the system was refusing them.
    #
    # This is the same call already made for the wallpaper on .142 b647,
    # where locking identity beat ergonomics and was reverted. The shipped
    # pin list stays the install-time default; the operator owns it after.
    #
    # folder-children STAYS locked. That one has an incident behind it
    # rather than a preference: on RHEL 10 leftover upstream app-folders
    # ('System', 'Utilities', 'YaST', 'Pardus') intermix with ours and
    # scatter the grid.
    cat >"${target}/etc/dconf/db/local.d/locks/kldload-desktop" <<'LOCKS'
/org/gnome/desktop/app-folders/folder-children
LOCKS

    # ── Per-user xdg autostart + systemd tmpfiles glob copy ──────────────────
    # The wholesale kldload-* glob in /usr/local/bin handles tools but the
    # installer historically didn't reach into /etc/xdg/autostart/ or
    # /usr/lib/tmpfiles.d/ for kldload's own entries. Operator on .142
    # b642 install: kldload-trust-cert.desktop autostart MISSED →
    # Chrome warning banner came back; tmpfiles.d/kldload-runtime.conf
    # MISSED → /run/kldload not created → F5/F11 _kgroup bcc bpftrace
    # writes failed for non-root with "permission denied". Glob-copy both
    # paths for any kldload-*.* under them.
    shopt -s nullglob
    if [[ -d /etc/xdg/autostart ]]; then
        mkdir -p "${target}/etc/xdg/autostart"
        for _au in /etc/xdg/autostart/kldload-*.desktop /etc/xdg/autostart/bob-*.desktop; do
            [[ -f "$_au" ]] || continue
            install -m 0644 "$_au" "${target}${_au}"
            k_log "carried xdg-autostart: $_au"
        done
    fi

    # ── Live-only artifacts never ship installed ──────────────────────────────
    # build-iso.sh stamps the live rootfs with `-live`-suffixed surface bits:
    # the "Install kldload" grid launcher (relaunch path after the operator
    # closes the autostarted installer window — 1.4.0-rc2 live bug, 2026-08-04)
    # and a Chrome managed policy that points a stock Chrome launch at the UI.
    # Neither makes sense on an installed system — an "Install" icon on the
    # installed grid reads as broken, and the Chrome policy would hijack every
    # browser launch. Applies to ALL profiles, so it lives here in the common
    # path, not the desktop-only branch.
    rm -f "${target}/usr/share/applications/kldload-installer-live.desktop" \
        "${target}/etc/opt/chrome/policies/managed/kldload-live.json"
    if [[ -d /usr/lib/tmpfiles.d ]]; then
        mkdir -p "${target}/usr/lib/tmpfiles.d"
        for _tf in /usr/lib/tmpfiles.d/kldload-*.conf; do
            [[ -f "$_tf" ]] || continue
            install -m 0644 "$_tf" "${target}${_tf}"
            k_log "carried tmpfiles.d: $_tf"
        done
    fi
    # /etc/xdg/konsolerc — KDE/Konsole shortcut overrides (F11 fullscreen
    # toggle disable so it reaches tmux). Lives outside autostart pattern.
    if [[ -f /etc/xdg/konsolerc ]]; then
        mkdir -p "${target}/etc/xdg"
        install -m 0644 /etc/xdg/konsolerc "${target}/etc/xdg/konsolerc"
        k_log "carried /etc/xdg/konsolerc"
    fi
    # /usr/share/konsole/kldload* — custom color schemes (light + dark) +
    # profile with AutoCopySelectedText. Without these on the install
    # target, sysdiag's `-p ColorScheme=kldload-dark` silently no-ops and
    # Konsole falls back to its hardcoded grey-on-black scheme, ignoring
    # the GNOME light/dark preference. Operator on .142 b646 2026-06-08:
    # "the sysdiag is opening in bright mode when the desktop is in dark
    # mode" — that was these files missing.
    mkdir -p "${target}/usr/share/konsole"
    for _kf in /usr/share/konsole/kldload*; do
        [[ -f "$_kf" ]] || continue
        install -m 0644 "$_kf" "${target}/usr/share/konsole/$(basename "$_kf")"
        k_log "carried $(basename "$_kf")"
    done
    # systemd drop-ins kldload ships (ollama keep-alive, future services).
    for _dropdir in /etc/systemd/system/*.d; do
        [[ -d "$_dropdir" ]] || continue
        _svc=$(basename "$_dropdir")
        mkdir -p "${target}/etc/systemd/system/${_svc}"
        for _conf in "$_dropdir"/*.conf; do
            [[ -f "$_conf" ]] || continue
            install -m 0644 "$_conf" \
                "${target}/etc/systemd/system/${_svc}/$(basename "$_conf")"
            k_log "carried drop-in: ${_svc}/$(basename "$_conf")"
        done
    done
    # /etc/dnf/automatic.conf — security-only nightly upgrade config.
    if [[ -f /etc/dnf/automatic.conf ]]; then
        mkdir -p "${target}/etc/dnf"
        install -m 0644 /etc/dnf/automatic.conf "${target}/etc/dnf/automatic.conf"
        k_log "carried /etc/dnf/automatic.conf"
    fi
    shopt -u nullglob

    # ── Default browser → Chrome (RPM-family desktop only) ───────────────────────
    # /etc/xdg/mimeapps.list sets system-wide defaults that apply unless the
    # user override them in ~/.config/mimeapps.list. Operator feedback
    # 2026-06-06 (.137 install): when Chrome lands alongside firefox, http(s)
    # links still launched firefox until manually changed — confusing because
    # Chrome was already pinned as the FIRST dock app. Bind protocol handlers
    # AND html mime types so xdg-open + GNOME's "open with" both pick Chrome.
    if [[ "${KLDLOAD_DISTRO:-centos}" =~ ^(centos|rocky|rhel|fedora)$ ]]; then
        mkdir -p "${target}/etc/xdg"
        cat >"${target}/etc/xdg/mimeapps.list" <<'MIMES'
[Default Applications]
x-scheme-handler/http=google-chrome.desktop
x-scheme-handler/https=google-chrome.desktop
x-scheme-handler/about=google-chrome.desktop
x-scheme-handler/unknown=google-chrome.desktop
text/html=google-chrome.desktop
application/xhtml+xml=google-chrome.desktop
MIMES

        # Chrome enterprise policy — suppress the "Make Chrome the default
        # browser?" prompt that fires every launch until the user agrees.
        # On .137 b628 the kldload-webui dock launcher triggered this on
        # first open because Chrome's default-check still runs even when the
        # system mimeapps.list already routes http(s) to Chrome (the policy
        # check is separate from the OS default). DefaultBrowserSettingEnabled
        # = false also removes the "Make default" option from chrome://settings
        # so the user can't accidentally enable the prompt back. The other two
        # keys silence the welcome-tour promo tabs + opt out of usage metrics
        # (kldload ships offline-first; metrics make no sense here).
        mkdir -p "${target}/etc/opt/chrome/policies/managed"
        cat >"${target}/etc/opt/chrome/policies/managed/kldload-defaults.json" <<'CHROMEPOLICY'
{
  "DefaultBrowserSettingEnabled": false,
  "PromotionalTabsEnabled": false,
  "MetricsReportingEnabled": false,
  "HomepageLocation": "https://localhost:8443/",
  "HomepageIsNewTabPage": false,
  "ShowHomeButton": true,
  "RestoreOnStartup": 4,
  "RestoreOnStartupURLs": ["https://localhost:8443/"],
  "BookmarkBarEnabled": true,
  "ManagedBookmarks": [
    {"toplevel_name": "kldload"},
    {"name": "kldload Web UI",  "url": "https://localhost:8443/"},
    {"name": "Grafana",         "url": "https://localhost:8443/grafana/"},
    {"name": "kldload Docs",    "url": "https://kldload.com/"}
  ]
}
CHROMEPOLICY
    fi

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
        cat >"${target}/etc/${_gdm_dir}/${_gdm_conf}" <<EOGDM
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=${_install_user}

[security]

[xdmcp]

[chooser]

[debug]
EOGDM
    done

    # ── lightdm autologin, AT INSTALL TIME ───────────────────────────────────
    # Debian deliberately runs lightdm rather than GDM (GDM 48 has a systemd
    # integration bug on Trixie — see the _gdm selection near the top of this
    # file), so everything written above lands in files lightdm never reads.
    #
    # WHY HERE AND NOT ONLY IN FIRSTBOOT: kldload-firstboot also re-asserts
    # this, but it runs AFTER the display manager has already started, so the
    # very first boot still shows a greeter and autologin only takes effect on
    # the second. Writing it now — before the target has ever booted — is what
    # makes the FIRST boot go straight to the desktop.
    # HISTORY: 2026-08-14, fiend — "on first boot the gdm or whatever is
    # prompting me to log in, it should autoboot directly in right?"
    # Gate on the DISTRO, not on _gdm and not on the directory existing.
    #   * _gdm is `local` to the package-set function above — reading it here
    #     is an unbound-variable abort under `set -u`.
    #   * `[[ -d ${target}/etc/lightdm ]]` looks tempting but repeats the exact
    #     ordering bug that broke the wallpaper: if this runs before lightdm is
    #     unpacked, the test is false and the config is silently never written.
    # The distro is known before any package is installed, so it cannot race.
    # Mirrors the _gdm selection above: ubuntu→gdm3, RPM family→gdm, rest→lightdm.
    case "${KLDLOAD_DISTRO:-centos}" in
    ubuntu | centos | rocky | rhel | fedora) _want_lightdm=0 ;;
    *) _want_lightdm=1 ;;
    esac
    if [[ "$_want_lightdm" == "1" ]]; then
        mkdir -p "${target}/etc/lightdm/lightdm.conf.d"
        cat >"${target}/etc/lightdm/lightdm.conf.d/50-kldload-autologin.conf" <<EOLDM
# Written by the kldload installer. A drop-in rather than an edit to
# lightdm.conf so a package upgrade cannot silently revert it.
[Seat:*]
autologin-user=${_install_user}
autologin-user-timeout=0
EOLDM
        # Debian gates autologin on this group: without it lightdm ignores
        # autologin-user and still shows the greeter.
        chroot "${target}" sh -c 'getent group autologin >/dev/null 2>&1 || groupadd -r autologin' 2>/dev/null || true
        chroot "${target}" usermod -aG autologin "${_install_user}" 2>/dev/null || true
        k_log "lightdm autologin configured for ${_install_user} (install-time)"
    fi

    # Wayland is the default — xserver-xorg is installed as fallback so GDM
    # can fall back to X11 if Wayland fails (older virtual GPUs, etc.)

    # ── Disable screen blanking / power saving (desktop profiles) ────────────────
    mkdir -p "${target}/etc/dconf/db/local.d"
    cat >"${target}/etc/dconf/db/local.d/00-kldload-power" <<'DCONF'
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
    echo -e "user-db:user\nsystem-db:local" >"${target}/etc/dconf/profile/user"
    # Compile the dconf database INTO the install, and verify it landed.
    #
    # This was `dconf update 2>/dev/null || true`. When it failed there was no
    # /etc/dconf/db/local, GNOME fell back to its own defaults, and nothing said
    # so — the operator got a LIGHT desktop with stock favourites and no app
    # folders on a build that reported success (.131, 2026-08-15).
    #
    # It must work at INSTALL time, not just in firstboot's healing net: the
    # database is what the very first login reads, so a firstboot-only fix still
    # shows the user a light, unorganised desktop the first time they see the
    # machine. Failure is reported and left to firstboot to heal rather than
    # aborting the install — a wrong-looking desktop is not worth failing an
    # otherwise good install over, but it is absolutely worth logging.
    if chroot "${target}" dconf update &&
        [[ -s "${target}/etc/dconf/db/local" ]]; then
        k_log "desktop: dconf database compiled into target ($(stat -c %s "${target}/etc/dconf/db/local") bytes)"
    else
        k_log "WARNING: dconf update failed on target — first login will show GNOME defaults (light theme, stock favourites); kldload-firstboot will retry"
    fi

    # ── Custom .desktop launchers ───────────────────────────────────────────────
    # kst-dashboard.desktop removed 2026-06-05 — operator feedback was that the
    # launcher confused users (read as "btop-equivalent dashboard" and looked
    # redundant against Bob + Grafana). The kst-dashboard binary stays under
    # /usr/local/bin/ for terminal users; just no app-grid tile.
    mkdir -p "${target}/usr/share/applications"
    # ksnap.desktop retired 2026-08-04 (FOSSY pass): snapshot management is
    # zxplore's job now; the ksnap CLI itself still ships for terminal users.
    for _dt in kexport.desktop; do
        [[ -f "/usr/share/applications/${_dt}" ]] &&
            cp "/usr/share/applications/${_dt}" "${target}/usr/share/applications/${_dt}"
    done

    # ── Wallpaper — set the distro's default background ───────────────────────
    # k_install_tree fails the install if the wallpaper dir came up short.
    # Previously a silent cp -r dropped /usr/share/backgrounds/kldload entirely
    # on .135 — dconf still pointed at file:///usr/share/backgrounds/kldload/...
    # and GNOME fell back to no-wallpaper. Operator never knew.
    if [[ -d /usr/share/backgrounds/kldload ]]; then
        k_install_tree /usr/share/backgrounds/kldload \
            "${target}/usr/share/backgrounds/kldload" \
            "wallpapers"
    else
        k_die "wallpapers: /usr/share/backgrounds/kldload missing on live ISO — build dropped them"
    fi
    # ── Per-distro NATIVE default wallpaper ──────────────────────────────────
    # Each distro install wears ITS OWN stock GNOME wallpaper, NOT the kldload
    # nebula baked into 00-kldload-desktop (operator 2026-06-13: "each profile
    # should use its respected distro default wallpaper — F44 install → F44
    # default"). This is the per-distro-native identity stance now that F44 is
    # the primary substrate: an F44 box should look like Fedora, a RHEL box
    # like RHEL — see [[disguise-as-rhel]] (evolved from always-RHEL to
    # per-distro-native).
    #
    # HISTORY: until .143 the fedora case mapped to /usr/share/backgrounds/
    # default.png (the RHEL/CentOS path). That file doesn't exist on Fedora, so
    # the [[ -e ]] guard skipped the override and 00-kldload-desktop's kldload
    # nebula won — that's the "RHEL 10 wallpaper on F44" the operator saw on the
    # 10.100.10.113 install. Fedora's actual default ships in f44-backgrounds-
    # gnome with DISTINCT day/night art, so we carry separate light/dark URIs.
    local _wp_day="" _wp_dark=""
    case "${KLDLOAD_DISTRO:-centos}" in
    ubuntu)
        _wp_day="/usr/share/backgrounds/warty-final-ubuntu.png"
        _wp_dark="$_wp_day"
        ;;
    debian)
        _wp_day="/usr/share/desktop-base/active-theme/wallpaper/contents/images/1920x1080.svg"
        _wp_dark="$_wp_day"
        ;;
    fedora)
        _wp_day="/usr/share/backgrounds/f44/default/f44-01-day.jxl"
        _wp_dark="/usr/share/backgrounds/f44/default/f44-01-night.jxl"
        ;;
    centos | rocky | rhel)
        _wp_day="/usr/share/backgrounds/default.png"
        _wp_dark="$_wp_day"
        ;;
    esac
    # 01-kldload-wallpaper has a higher numeric prefix than 00-kldload-desktop,
    # so dconf merges its [background] block ON TOP of the 00- nebula. The
    # distro-default backgrounds package is a hard member of every desktop set
    # AND is enforced by the darksite completeness gate, so on a correct build
    # the file is always present. If it is somehow missing we DON'T silently
    # fall back to the wrong-distro nebula (operator 2026-06-13: "no silent
    # failures") — we log a loud, greppable WARN naming the file so the
    # darksite gap gets fixed, and leave the wallpaper unset rather than lying
    # about which distro this is. Cosmetic, so WARN not k_die: a bad wallpaper
    # must not brick an otherwise-good install.
    if [[ -n "$_wp_day" ]] && [[ -e "${target}${_wp_day}" ]]; then
        [[ -e "${target}${_wp_dark}" ]] || _wp_dark="$_wp_day"
        mkdir -p "${target}/etc/dconf/db/local.d"
        cat >"${target}/etc/dconf/db/local.d/01-kldload-wallpaper" <<WPEOF
[org/gnome/desktop/background]
picture-uri='file://${_wp_day}'
picture-uri-dark='file://${_wp_dark}'
picture-options='zoom'
WPEOF
        if ! chroot "${target}" dconf update; then
            k_die "01-kldload-wallpaper: dconf update failed on target — wallpaper override will not apply"
        fi
        k_log "wallpaper: ${KLDLOAD_DISTRO:-centos} native default set (${_wp_day})"
    elif [[ -n "$_wp_day" ]]; then
        k_log "WARN: wallpaper: ${KLDLOAD_DISTRO:-centos} default ${_wp_day} MISSING on target — darksite gap, fix the package set; leaving wallpaper unset (refusing to fall back to wrong-distro nebula)"
    fi

    # ── Shell dotfiles (.bashrc, .tmux.conf, .vimrc) — non-core profiles only
    # Core profile gets the stock distro dotfiles untouched.
    if [[ "$_profile" != "core" ]]; then
        local _user="${KLDLOAD_USERNAME:-admin}"
        local _user_home="${target}/home/${_user}"
        # .bash_profile is REQUIRED: kldload-term opens a login shell (bash -l)
        # which sources .bash_profile, NOT .bashrc directly. Without it the
        # terminal skips the kldload .bashrc and comes up plain (10.100.10.119).
        for _f in .bashrc .bash_profile .tmux.conf .vimrc; do
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
        [[ -n "$_uid" && -n "$_gid" ]] &&
            chown -R "${_uid}:${_gid}" "${_user_home}/" 2>/dev/null || true
    fi

    # ── Performance tuning (sysctl, ZFS ARC, I/O scheduler) ─────────────────────
    [[ -f /etc/sysctl.d/99-kldload.conf ]] &&
        {
            mkdir -p "${target}/etc/sysctl.d"
            cp /etc/sysctl.d/99-kldload.conf "${target}/etc/sysctl.d/99-kldload.conf"
        }
    [[ -f /etc/modprobe.d/zfs.conf ]] &&
        {
            mkdir -p "${target}/etc/modprobe.d"
            cp /etc/modprobe.d/zfs.conf "${target}/etc/modprobe.d/zfs.conf"
        }
    [[ -f /etc/udev/rules.d/60-kldload-scheduler.rules ]] &&
        {
            mkdir -p "${target}/etc/udev/rules.d"
            cp /etc/udev/rules.d/60-kldload-scheduler.rules "${target}/etc/udev/rules.d/60-kldload-scheduler.rules"
        }

    # ── Backend runtime tools (kbe, krecovery, kupgrade) — skip for core ──────────
    if [[ "$_profile" != "core" && -d /usr/lib/kldload-installer/backend ]]; then
        mkdir -p "${target}/usr/lib/kldload-installer/backend/bin"
        cp -r /usr/lib/kldload-installer/backend/. "${target}/usr/lib/kldload-installer/backend/"
        chmod +x "${target}/usr/lib/kldload-installer/backend/bin/"* 2>/dev/null || true
        # Expose backend tools in PATH with short names
        mkdir -p "${target}/usr/local/bin"
        for _bt in kbe krecovery kupgrade; do
            [[ -f "${target}/usr/lib/kldload-installer/backend/bin/${_bt}" ]] &&
                ln -sf "/usr/lib/kldload-installer/backend/bin/${_bt}" "${target}/usr/local/bin/${_bt}"
        done
        # kexport lives in the main tools directory
        [[ -x "/usr/local/bin/kexport" ]] &&
            cp "/usr/local/bin/kexport" "${target}/usr/local/bin/kexport" &&
            chmod +x "${target}/usr/local/bin/kexport"
    fi

    # ── Boot environment marker — tells kldload-be which dataset is active ─────────
    mkdir -p "${target}/etc/kldload"
    printf '%s\n' "${root_ds}" >"${target}/etc/kldload/boot-environment"

    # ── Darksite — copy ONLY the matching distro's darksite to target ──────────
    # Core profile and RHEL skip darksites (RHEL uses Red Hat CDN)
    local _distro="${KLDLOAD_DISTRO:-centos}"
    if [[ "$_profile" != "core" && "$_distro" != "rhel" ]]; then
        local darksite_tgt="${target}/root/darksite"
        mkdir -p "$darksite_tgt"

        case "$_distro" in
        debian | ubuntu)
            # Copy only the APT darksite
            if [[ -d /root/darksite/debian ]]; then
                rsync -a --exclude='*.lock' /root/darksite/debian/ "${darksite_tgt}/debian/"
                k_log "Debian APT darksite installed to target"
            fi
            ;;
        centos | rocky)
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
    if [[ -d "${tgt_files}" && ("$_distro" == "debian" || "$_distro" == "ubuntu") ]]; then
        mkdir -p "${target}/etc/apt/apt.conf.d"
        # WHY the name matters and why this is not swallowed: this file is the
        # APT::NeverAutoRemove list that keeps linux-headers-* and zfs-dkms
        # installed. Without it `apt autoremove` — which apt itself suggests
        # after an upgrade — can take the DKMS build environment away, and the
        # NEXT kernel upgrade then produces a kernel with no ZFS module. On ZFS
        # root that is an unbootable machine.
        #
        # HISTORY: this copied "60-kldload-kernel", but the file shipped in
        # target-files is named "60-debz-kernel". cp failed, 2>/dev/null || true
        # hid it, and every Debian/Ubuntu install went out with no protection
        # at all. Found 2026-08-12 while answering a user asking exactly this:
        # "will apt upgrade blow out the kernel?"
        if ! cp "${tgt_files}/etc/apt/apt.conf.d/60-debz-kernel" \
            "${target}/etc/apt/apt.conf.d/60-debz-kernel"; then
            k_log "FATAL: could not install 60-debz-kernel — apt autoremove" \
                "would be free to strip the DKMS build environment"
            return 1
        fi
        mkdir -p "${target}/etc/kernel/postinst.d"
        cp "${tgt_files}/etc/kernel/postinst.d/kldload-dkms-verify" \
            "${target}/etc/kernel/postinst.d/kldload-dkms-verify" 2>/dev/null || true
        chmod +x "${target}/etc/kernel/postinst.d/kldload-dkms-verify" 2>/dev/null || true
        # Second failsafe (the b653 pattern): apt-mark hold on the kernel, the
        # headers and the ZFS packages. The unit shipped but nothing ever
        # enabled it, so BOTH layers of this protection were inert.
        if ! chroot "${target}" systemctl enable kldload-package-holds.service \
            >/dev/null 2>&1; then
            k_log "WARN: kldload-package-holds.service not enabled — kernel" \
                "and zfs-dkms are unheld; apt upgrade may replace the kernel"
        fi
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
        # lz4: free space savings on thin zvols (children inherit).
        # WHY no primarycache=metadata: guests attach with cache=none, so ARC
        # is the ONLY host-side read cache — metadata-only sent every guest
        # read miss to physical disk (measured 2026-07-31 on NVMe: -15%
        # random IOPS, -30% sequential; worse on contended/spinning pools).
        # swallow: dataset may already exist on installer re-run — harmless
        # recordsize applies to filesystem children (e.g. rpool/vms/isos);
        # zvol children use volblocksize instead. 64K here so the firstboot
        # "64K recordsize" status line matches what installs actually get.
        zfs create -o canmount=off \
            -o mountpoint=none \
            -o compression=lz4 \
            -o recordsize=64K \
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
        local _arc_max=$((_total_ram_bytes / 2))
        [[ "$_arc_max" -gt 0 ]] || _arc_max=8589934592 # fallback 8GB

        mkdir -p "${target}/etc/modprobe.d"
        cat >"${target}/etc/modprobe.d/zfs.conf" <<ZFSMOD
# kldload KVM host — ZFS tuning
# ARC capped at 50% of RAM to leave memory for KVM guests
options zfs zfs_arc_max=${_arc_max}
options zfs zfs_txg_timeout=10
options zfs zfs_vdev_scheduler=none
options zfs l2arc_noprefetch=0
ZFSMOD

        # Kernel VM tuning for ZFS on root + KVM
        mkdir -p "${target}/etc/sysctl.d"
        cat >"${target}/etc/sysctl.d/99-zfs-kvm.conf" <<SYSCTL
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
        cat >"${target}/usr/local/sbin/kvm-replicate" <<'REPL'
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
                continue # driven by its timer, don't enable .service directly
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
        # Heal-pending retry hook — firstboot's missed packages auto-retry on
        # network-up instead of staying missing forever (steam, 2026-08-05).
        if [[ -f /etc/NetworkManager/dispatcher.d/98-kldload-heal-pending ]]; then
            mkdir -p "${target}/etc/NetworkManager/dispatcher.d"
            install -m 0755 /etc/NetworkManager/dispatcher.d/98-kldload-heal-pending \
                "${target}/etc/NetworkManager/dispatcher.d/98-kldload-heal-pending"
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
        # libvirt-exporter + process-exporter — downloaded at ISO build time by
        # builder/build-iso.sh into /usr/local/bin/. Without copying these into
        # the target, kldload-libvirt-exporter.service and kldload-process-
        # exporter.service both ConditionPathExists-fail at first boot and the
        # per-VM + per-process Grafana dashboards stay empty forever. Bug
        # caught on .113 2026-05-16 — install of build #20 had loud download
        # of binaries into the live ISO, but install-target never copied them
        # to /target so the installed system had no exporters.
        for _exp in libvirt-exporter process-exporter; do
            if [[ -x "/usr/local/bin/${_exp}" ]]; then
                cp "/usr/local/bin/${_exp}" "${target}/usr/local/bin/${_exp}"
                chmod +x "${target}/usr/local/bin/${_exp}"
            else
                k_log "WARNING: /usr/local/bin/${_exp} missing from live env — ${_exp} dashboards will be empty on target"
            fi
        done
        # textfile collector dir
        mkdir -p "${target}/var/lib/node_exporter/textfile_collector"
        # configs
        mkdir -p "${target}/etc/loki" "${target}/etc/promtail" \
            "${target}/etc/systemd/journald.conf.d" \
            "${target}/var/lib/loki" "${target}/var/lib/promtail" \
            "${target}/var/log/journal"
        [[ -f /etc/loki/loki.yaml ]] &&
            cp /etc/loki/loki.yaml "${target}/etc/loki/loki.yaml"
        [[ -f /etc/promtail/promtail.yaml ]] &&
            cp /etc/promtail/promtail.yaml "${target}/etc/promtail/promtail.yaml"
        [[ -f /etc/systemd/journald.conf.d/persistent.conf ]] &&
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
            # Recursive copy so subfolder dashboards (host/, storage/,
            # kubernetes/, zfs-test-lab/, virtual-machines/, estate/) land
            # too — the kldload.yaml provisioner has 7 per-folder providers
            # that expect subdir-based grouping. Previous flat `*.json` copy
            # only caught 6 top-level files (~6 dashboards), losing all 16
            # in subfolders. Caught .142 2026-05-17.
            cp -r /var/lib/grafana/dashboards/. \
                "${target}/var/lib/grafana/dashboards/" 2>/dev/null || true
        fi
        # Provisioner config — kldload.yaml has the per-folder provider
        # mapping; without it Grafana falls back to a stub klab.yaml (or
        # nothing) and the folder structure breaks.
        if [[ -d /etc/grafana/provisioning ]]; then
            mkdir -p "${target}/etc/grafana/provisioning/dashboards" \
                "${target}/etc/grafana/provisioning/datasources"
            cp -r /etc/grafana/provisioning/dashboards/. \
                "${target}/etc/grafana/provisioning/dashboards/" 2>/dev/null || true
            cp -r /etc/grafana/provisioning/datasources/. \
                "${target}/etc/grafana/provisioning/datasources/" 2>/dev/null || true
        fi

        # Hourly VM snapshot timer
        mkdir -p "${target}/etc/systemd/system"
        cat >"${target}/etc/systemd/system/kvm-snapshot.service" <<'SNAPSVC'
[Unit]
Description=ZFS snapshot all VM datasets
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'TS=$(date -u +%%Y%%m%%dT%%H%%M%%SZ); for ds in $(zfs list -H -o name -r rpool/vms | tail -n+2); do zfs snapshot ${ds}@auto-${TS}; done; for ds in $(zfs list -H -o name -r rpool/vms | tail -n+2); do zfs list -H -t snapshot -o name ${ds} 2>/dev/null | grep @auto- | head -n -48 | xargs -r -n1 zfs destroy; done'
SNAPSVC
        cat >"${target}/etc/systemd/system/kvm-snapshot.timer" <<'SNAPTMR'
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
            cat >>"${target}/etc/sanoid/sanoid.conf" <<'KVMSANOID'

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
        cat >"${target}/etc/containers/storage.conf" <<'STORAGE'
[storage]
driver = "zfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options.zfs]
fsname = "rpool/var/lib/containers/storage/zfs"
STORAGE

        # Create the container storage dataset
        chroot "${target}" bash -c 'zfs create -p -o mountpoint=/var/lib/containers/storage/zfs rpool/var/lib/containers/storage/zfs' 2>/dev/null || true

        # ── Docker, on the same terms as podman ──────────────────────
        #
        # apt distros get Docker because that is what their users reach for;
        # the RPM side keeps podman, which is what RHEL ships. Both engines
        # coexist (they do not conflict), and both put their layers on ZFS.
        #
        # WHY THIS MATTERS BEYOND TIDINESS: with the zfs storage driver every
        # image layer becomes a real dataset, so a pull is a clone, layers
        # inherit compression, and the whole container estate — layers, the
        # engine's database and the volumes — can be snapshotted and sent as
        # one recursive stream. On overlay2 a layer is a directory inside one
        # filesystem with no handle to snapshot or send.
        #
        # The dataset MUST exist before dockerd first starts: Docker picks a
        # storage driver on first run and records it, and one that came up on
        # overlay2 will not move to zfs afterwards without discarding its
        # images.
        if chroot "${target}" sh -c 'command -v dockerd >/dev/null 2>&1'; then
            k_log_to "$log" "Configuring Docker for the ZFS storage driver"
            chroot "${target}" bash -c \
                'zfs create -p -o mountpoint=/var/lib/docker rpool/var/lib/docker' \
                >>"$log" 2>&1 ||
                k_log_to "$log" "WARNING: could not create rpool/var/lib/docker — Docker will fall back to overlay2"
            mkdir -p "${target}/etc/docker"
            cat >"${target}/etc/docker/daemon.json" <<'DOCKERJSON'
{
  "storage-driver": "zfs",
  "data-root": "/var/lib/docker"
}
DOCKERJSON
            chroot "${target}" systemctl enable docker 2>/dev/null || true

            # ── Who may talk to the daemon ───────────────────────────
            #
            # Membership of the docker group is equivalent to root: anyone in
            # it can ask dockerd to run a container that mounts / and writes
            # anywhere. That is not a reason to refuse it — it is a reason to
            # decide it per profile rather than everywhere.
            #
            # DESKTOP: the installed user is added. This is a workstation with
            # one human on it who already has sudo, so the group grants them
            # nothing they did not already have, and withholding it means the
            # first command a container developer types fails with a
            # permission error and no explanation.
            #
            # SERVER and everything else: NOT added. A server's accounts are
            # not all the administrator, sudo there is deliberate and audited,
            # and silently making an account root-equivalent because a package
            # got installed is exactly the kind of thing nobody notices until
            # it matters. The message names the one command that grants it.
            if [[ "${KLDLOAD_PROFILE:-server}" == "desktop" ]]; then
                local _docker_user="${KLDLOAD_USERNAME:-admin}"
                if chroot "${target}" usermod -aG docker "${_docker_user}" 2>/dev/null; then
                    k_log_to "$log" "Added ${_docker_user} to the docker group (desktop profile)"
                else
                    k_log_to "$log" "WARNING: could not add ${_docker_user} to the docker group — " \
                        "docker will need sudo"
                fi
            else
                k_log_to "$log" "Docker installed; no account added to the docker group " \
                    "(that group is root-equivalent). Grant it with: usermod -aG docker <user>"
            fi
        fi

        # Enable libvirtd + default network (virbr0)
        chroot "${target}" systemctl enable libvirtd 2>/dev/null || true
        # virsh can't run in a chroot (no running libvirtd to connect to). At
        # firstboot, libvirtd takes variable time to register drivers and create
        # the default network; a plain After=libvirtd.service races.
        #
        # Previous design used a 30s timer + a 10-iteration shell loop with
        # `net-autostart && net-start && exit 0`. That had two latent bugs:
        #   1. net-autostart returns 0 even when the net is unconfigured (it only
        #      flips the autostart flag), so the && chain depended entirely on
        #      net-start. When net-start failed (stale `default` definition, missing
        #      bridge module, etc.) the loop fell through, then the trailing `echo`
        #      returned 0 -> systemd reported success even though virbr0 was DOWN.
        #      Result: kldload-doctor green, every VM creation fails to attach.
        #   2. No `set -e`, no explicit `exit 1`; only an echo for diagnosis.
        #
        # New design: a small helper script with explicit state checks and a real
        # exit code. Retries via Restart=on-failure / RestartSec= rather than an
        # in-shell loop, so each attempt is a separate journald entry and the
        # final failure is visible to systemd, kldload-doctor, and Prometheus.
        install -d -m 0755 "${target}/usr/local/sbin"
        cat >"${target}/usr/local/sbin/kldload-virbr0-up" <<'VIRBR0SH'
#!/usr/bin/env bash
set -Eeuo pipefail
# Bring up the libvirt 'default' network (virbr0) reliably at firstboot.
# Exits 0 only when the network is both Active and Persistent.

readonly _net="default"
_log() { logger -t kldload-virbr0 -- "$*"; printf '%s\n' "$*"; }
trap '_log "FAIL at line $LINENO: $BASH_COMMAND"' ERR

# _net_ready — can this connection actually serve NETWORK calls?
#
# Returns: 0 when the libvirt network driver answers, 1 otherwise.
#
# WHY this and not `virsh list`: they are different daemons. Fedora's modular
# libvirt splits domains (virtqemud) from networks (virtnetworkd), each with
# its own socket, each socket-activated independently. `virsh list` succeeds
# the moment virtqemud is up and says NOTHING about whether networks can be
# defined.
#
# HISTORY: 2026-08-13, fiend (.121) first boot after the Secure Boot install.
# The old gate polled `virsh list`, saw virtqemud, and declared libvirt ready
# — then net-define died instantly with:
#
#     error: this function is not supported by the connection driver:
#            virNetworkDefineXML
#
# which is what libvirt says when you ask the domain driver about networks.
# All six retries burned in 90s against a driver that was never going to
# answer, the unit latched failed, and libvirt's own config-network package
# defined the net correctly moments later. Net result: a HEALTHY host with a
# permanently red unit — a false alarm on the CI runner, and the worst kind,
# because the thing it claims is broken is demonstrably working.
_net_ready() { virsh -c qemu:///system net-list --all >/dev/null 2>&1; }

for _ in $(seq 1 60); do
    _net_ready && break
    sleep 1
done
if ! _net_ready; then
    # Second failsafe (the boot-critical-dep rule): the network driver may
    # simply not be running rather than not-yet-started. Ask for it by name
    # and give it a final window. Both units are absent on a monolithic
    # libvirtd host, where the first poll would already have succeeded.
    _log "libvirt network driver not answering — starting virtnetworkd"
    systemctl start virtnetworkd.socket virtnetworkd.service 2>/dev/null || true
    for _ in $(seq 1 30); do
        _net_ready && break
        sleep 1
    done
fi
_net_ready || {
    _log "libvirt network driver unavailable after 90s"
    exit 1
}

# Reconcile stale state. A failed prior boot can leave the network defined
# with an inactive bridge that won't restart cleanly; destroy+undefine and
# re-create from the libvirt-shipped default net XML.
if virsh -c qemu:///system net-info "$_net" >/dev/null 2>&1; then
    _active=$(virsh -c qemu:///system net-info "$_net" | awk '/^Active:/ {print $2}')
    if [[ "$_active" != "yes" ]]; then
        _log "net '$_net' present but inactive — recreating"
        virsh -c qemu:///system net-destroy "$_net" 2>/dev/null || true
        virsh -c qemu:///system net-undefine "$_net" 2>/dev/null || true
    fi
fi
if ! virsh -c qemu:///system net-info "$_net" >/dev/null 2>&1; then
    # Define the default net. Prefer the libvirt-shipped default.xml — but do
    # NOT hard-depend on it. On a darksite/offline first boot the
    # libvirt-daemon-config-network payload can land mid-convergence, so the
    # file is absent for the first ~45s. The old `exit 1` here turned that
    # transient into 3 failed-unit entries + a red service in the GUI before
    # the 30s retry timer happened to fire after the file appeared. Fall back
    # to an inline definition (the canonical 192.168.122.0/24 NAT net every
    # kldload tool assumes, identical to kube-cluster's) so this service is
    # self-contained and never races a package file.
    # HISTORY: virbr0 3x-fail on kldload-node firstboot, 2026-07-27 (.129).
    _xml="/usr/share/libvirt/networks/default.xml"
    if [[ -r "$_xml" ]]; then
        _log "defining default net from $_xml"
        virsh -c qemu:///system net-define "$_xml"
    else
        _log "default.xml absent — defining default net inline"
        virsh -c qemu:///system net-define /dev/stdin <<'NETXML'
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
NETXML
    fi
fi
virsh -c qemu:///system net-autostart "$_net" >/dev/null
virsh -c qemu:///system net-start "$_net" 2>/dev/null || true

# Final verification: must be Active AND Persistent. Anything else is a fail.
_status=$(virsh -c qemu:///system net-info "$_net" 2>/dev/null | awk '/^(Active|Persistent):/ {print $1$2}' | sort | xargs)
if [[ "$_status" != "Active:yes Persistent:yes" ]]; then
    _log "net '$_net' final state: ${_status:-unknown} — FAIL"
    exit 1
fi
# Disable our retry trigger now that we've succeeded — one-shot semantics.
systemctl disable kldload-virbr0.timer kldload-virbr0.service 2>/dev/null || true
_log "virbr0 up (default network Active + Persistent)"
VIRBR0SH
        chmod +x "${target}/usr/local/sbin/kldload-virbr0-up"

        cat >"${target}/etc/systemd/system/kldload-virbr0.service" <<'VIRBR0SVC'
[Unit]
Description=Enable libvirt default network (virbr0) autostart
# virtnetworkd.socket is listed because the NETWORK driver is what this unit
# needs; libvirtd alone is the monolithic case, where the socket unit simply
# does not exist and the dependency is inert. Ordering alone is not enough —
# see the readiness poll in the script, which is the real gate.
After=libvirtd.service virtnetworkd.socket virtnetworkd.service network-online.target
Wants=libvirtd.service virtnetworkd.socket network-online.target
# Stop retrying after ~10 minutes (6 attempts * (90s + 15s)); failed state
# is now visible to kldload-doctor instead of being papered over.
# These keys MUST live in [Unit], not [Service]. On .137 b628 systemd
# warned every boot: "Unknown key 'StartLimitIntervalSec' in section
# [Service], ignoring" — the rate limit was silently disabled.
StartLimitIntervalSec=600
StartLimitBurst=6

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kldload-virbr0-up
RemainAfterExit=yes
# Per-attempt timeout; total wall-time bounded by StartLimitBurst (in [Unit]).
TimeoutStartSec=90
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
VIRBR0SVC
        cat >"${target}/etc/systemd/system/kldload-virbr0.timer" <<'VIRBR0TMR'
[Unit]
Description=Delayed virbr0 setup (30s after boot)

[Timer]
OnBootSec=30s
Unit=kldload-virbr0.service

[Install]
WantedBy=timers.target
VIRBR0TMR
        chroot "${target}" systemctl enable kldload-virbr0.service kldload-virbr0.timer 2>/dev/null || true

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
        cat >"${target}/etc/modules-load.d/k8s.conf" <<'K8SMOD'
overlay
br_netfilter
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
K8SMOD

        # sysctl for K8s
        cat >"${target}/etc/sysctl.d/99-kubernetes.conf" <<'K8SSYS'
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
        cat >"${target}/etc/crictl.yaml" <<'CRICTLCFG'
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
        cat >"${target}/etc/profile.d/kube-banner.sh" <<'KUBEBANNER'
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
    if [[ "${KLDLOAD_ENABLE_DEVOPS:-0}" == "1" || "${KLDLOAD_BUILD_IMAGES:-0}" == "1" ]]; then
        k_log "Enabling klab first-boot deployment..."
        cat >"${target}/etc/systemd/system/klab-firstboot.service" <<'KLABFB'
[Unit]
Description=klab — build golden images for all distros
After=network-online.target libvirtd.service kldload-firstboot.service
Wants=network-online.target
ConditionPathExists=!/var/lib/kldload/klab-firstboot-done

[Service]
Type=oneshot
ExecStartPre=/bin/bash -c 'for i in $(seq 1 30); do curl -sf --connect-timeout 5 https://cloud.debian.org >/dev/null 2>&1 && exit 0; echo "Waiting for internet ($i/30)..."; sleep 10; done'
# Build #49+: webui no longer stores RHEL creds (no Dashboard panel).
# Creds are entered once in the install form, used to (a) register the
# host, (b) fetch the RHEL Cloud Image, (c) build the 6th klab golden
# (rpool/vms/klab-golden-rhel@golden), then shredded. So this service
# does NOT need to bridge creds — the RHEL golden is already on disk
# before first boot, and `klab golden rhel` below will see the existing
# @golden snapshot and skip naturally.
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
# RHEL 10 golden: pre-built during install (rpool/vms/klab-golden-rhel
# @golden). klab's build_golden_single checks for the existing snapshot
# and returns 0 cleanly. Left in the list as a safety net -- if the
# install-time build didn't run (e.g. activation-key auth flow where
# the RH API path isn't available), this gives the operator a chance
# to drop a qcow2 at /var/lib/klab/images/rhel-10-cloud.qcow2 and let
# firstboot finish what install couldn't.
ExecStart=-/usr/local/bin/klab golden rhel
# ── Blue/green playground spawn (the "spit clones" demo) ─────────────────
# After all 6 goldens land (above), klab deploy blue + deploy green clone
# each @golden into a live VM via ZFS instant-clone (~75ms per clone) +
# virt-install --import. Result: 12 small VMs running side-by-side
# (klab-blue-<distro> + klab-green-<distro>) on static IPs:
#   blue:  192.168.122.101-106
#   green: 192.168.122.201-206
# Operator on .121 b640: "spawn 1 test vm for each distro .. one blue and
# 1 green .. so people can 'see' how easy this is now". The cattle pattern
# was previously aspirational ("blue-green ready" was logged but no clones
# spawned); now they actually fire.
#
# RAM/CPU override: klab's defaults are RAM=4096 CPUS=2 — sized for a
# beefy ZFS-lab host, not a workstation. The first spawn on .121 b640
# pushed 10 VMs × 4GB = 40GB on top of K8s + ollama + GNOME and OOM-killed
# the entire GNOME session (gsd-*, gjs/shell, evolution, gnome-session-binary
# all SIGKILL'd by the kernel; user got booted to GDM). For the cattle DEMO,
# blue/green VMs only need enough RAM to boot the cloud image and respond to
# `virsh` — 384MB per VM keeps total blue/green footprint ~3.8GB and leaves
# room for K8s + ollama + the desktop. Wrap in bash so the env override
# applies only to this call (goldens above still build at the full 4GB they
# need for package install + cloud-init).
ExecStart=-/bin/bash -c 'RAM=384 CPUS=1 exec /usr/local/bin/klab deploy blue'
ExecStart=-/bin/bash -c 'RAM=384 CPUS=1 exec /usr/local/bin/klab deploy green'
# K8s bootstrap is OWNED BY kldload-autodeploy (single orchestrator).
# Previously had a duplicate `kube-cluster bootstrap --workers 3` here
# which raced autodeploy's K8s phase — both tried to bootstrap, second
# one hit "cluster already exists" and was no-op'd, plus the half-built
# state confused the operator. Removed 2026-05-17. autodeploy's K8S_WORKERS
# default is now 3 for klab template (was 0), so the cluster lands with
# workers without this duplicate ExecStart.
ExecStartPost=/bin/mkdir -p /var/lib/kldload
ExecStartPost=/bin/touch /var/lib/kldload/klab-firstboot-done
ExecStartPost=/bin/touch /var/lib/kldload/bluegreen-ready
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
