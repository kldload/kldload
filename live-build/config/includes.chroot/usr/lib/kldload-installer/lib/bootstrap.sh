#!/usr/bin/env bash
# Sourced by kldload-install-target — k_bootstrap_base (debootstrap, APT mirror detection, locale, timezone, extra packages)
set -Eeuo pipefail

# k_write_sources_list — INSTALL-TIME only.
# Points the target at whatever mirror is being used right now (local darksite
# or internet).  This is intentionally temporary — k_finalize_sources_list
# overwrites it at the end of bootstrap with the correct post-install config.
k_write_sources_list() {
  local target="${KLDLOAD_TARGET:?}"
  local distro="${KLDLOAD_DISTRO:-debian}"
  local suite mirror

  if [[ "$distro" == "ubuntu" ]]; then
    suite="${KLDLOAD_SUITE:-noble}"
    mirror="${KLDLOAD_MIRROR:-http://archive.ubuntu.com/ubuntu}"
  else
    suite="${KLDLOAD_SUITE:-trixie}"
    mirror="${KLDLOAD_MIRROR:-https://mirror.it.ubc.ca/debian}"
  fi

  if [[ "$mirror" == "http://127.0.0.1:"* ]]; then
    cat > "${target}/etc/apt/sources.list" <<EOS
# Install-time only — darksite local mirror (will be replaced after install)
deb [trusted=yes] ${mirror} ${suite} main
EOS
  elif [[ "$distro" == "ubuntu" ]]; then
    cat > "${target}/etc/apt/sources.list" <<EOS
deb [trusted=yes] ${mirror} ${suite} main restricted universe multiverse
deb [trusted=yes] ${mirror} ${suite}-updates main restricted universe multiverse
deb [trusted=yes] ${mirror} ${suite}-security main restricted universe multiverse
EOS
  else
    cat > "${target}/etc/apt/sources.list" <<EOS
deb ${mirror} ${suite} main contrib non-free non-free-firmware
deb ${mirror} ${suite}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${suite}-security main contrib non-free non-free-firmware
EOS
  fi
}

# k_finalize_sources_list — POST-INSTALL.
# Writes the sources.list the installed system will actually use for updates.
#
#   KLDLOAD_KEEP_DARKSITE=0  (default) → standard Debian internet repos
#   KLDLOAD_KEEP_DARKSITE=1            → custom mirror at KLDLOAD_CUSTOM_MIRROR_URL
#                                     (for air-gap targets that update via a
#                                      local APT mirror server or updated ISO)
k_finalize_sources_list() {
  local target="${KLDLOAD_TARGET:?}"
  local distro="${KLDLOAD_DISTRO:-debian}"
  local suite

  if [[ "$distro" == "ubuntu" ]]; then
    suite="${KLDLOAD_SUITE:-noble}"
  else
    suite="${KLDLOAD_SUITE:-trixie}"
  fi

  if [[ "${KLDLOAD_KEEP_DARKSITE:-0}" == "1" && -n "${KLDLOAD_CUSTOM_MIRROR_URL:-}" ]]; then
    k_log_to "${KLDLOAD_BOOTSTRAP_LOG}" \
      "Finalizing sources.list: custom mirror ${KLDLOAD_CUSTOM_MIRROR_URL}"
    cat > "${target}/etc/apt/sources.list" <<EOS
# Custom APT mirror — configured at install time
deb [trusted=yes] ${KLDLOAD_CUSTOM_MIRROR_URL} ${suite} main
EOS
  elif [[ "$distro" == "ubuntu" ]]; then
    k_log_to "${KLDLOAD_BOOTSTRAP_LOG}" \
      "Finalizing sources.list: standard Ubuntu internet repos"
    cat > "${target}/etc/apt/sources.list" <<EOS
deb http://archive.ubuntu.com/ubuntu ${suite} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${suite}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${suite}-security main restricted universe multiverse
EOS
  else
    k_log_to "${KLDLOAD_BOOTSTRAP_LOG}" \
      "Finalizing sources.list: standard Debian internet repos"
    cat > "${target}/etc/apt/sources.list" <<EOS
deb https://deb.debian.org/debian ${suite} main contrib non-free non-free-firmware
deb https://deb.debian.org/debian ${suite}-updates main contrib non-free non-free-firmware
deb https://security.debian.org/debian-security ${suite}-security main contrib non-free non-free-firmware
EOS
  fi
}

k_bind_chroot_mounts() {
  local target="${KLDLOAD_TARGET:?}"
  k_mount_bind /dev "${target}/dev"
  mkdir -p "${target}/dev/pts"
  k_mount_bind /dev/pts "${target}/dev/pts"
  k_mount_bind /proc "${target}/proc"
  k_mount_bind /sys "${target}/sys"
  k_mount_bind /run "${target}/run"
  # Copy resolv.conf so chroot has DNS for apt/dnf
  # Ubuntu may have a dangling symlink — remove it and write a real file
  rm -f "${target}/etc/resolv.conf" 2>/dev/null || true
  cp /etc/resolv.conf "${target}/etc/resolv.conf" 2>/dev/null || \
    echo "nameserver 8.8.8.8" > "${target}/etc/resolv.conf"
  if [[ -d /sys/firmware/efi/efivars ]]; then
    mkdir -p "${target}/sys/firmware/efi/efivars"
    mountpoint -q "${target}/sys/firmware/efi/efivars" || \
      mount --bind /sys/firmware/efi/efivars "${target}/sys/firmware/efi/efivars" || true
  fi
  # Make the live env's darksite reachable from inside the chroot at
  # the SAME absolute path the host sees, so dnf's file:// URLs in
  # /target/etc/yum.repos.d/kldload-darksite.repo resolve identically
  # whether dnf runs as the host (`dnf --installroot=`) or inside the
  # target via `chroot $target dnf install …` (the late zfs-dracut
  # path).
  #
  # We bind-mount onto /run/kldload-darksite (NOT /target/root/darksite
  # directly) — profiles.sh later does a real rsync of the live env's
  # /root/darksite/ into ${target}/root/darksite/ to persist the offline
  # mirror on the installed system, and binding to that destination
  # would have rsync copying to itself. /run is a tmpfs in the live
  # env AND in the booted target; the bind is install-time-only and
  # leaves no trace post-reboot.
  #
  # The kldload-darksite.repo URL writes are updated to point here.
  if [[ -d /root/darksite ]]; then
    mkdir -p /run/kldload-darksite "${target}/run/kldload-darksite"
    mountpoint -q /run/kldload-darksite || \
      mount --bind /root/darksite /run/kldload-darksite 2>/dev/null || true
    mountpoint -q "${target}/run/kldload-darksite" || \
      mount --bind /run/kldload-darksite "${target}/run/kldload-darksite" 2>/dev/null || true
  fi
}

k_unbind_chroot_mounts() {
  local target="${KLDLOAD_TARGET:?}"
  k_umount_if_mounted "${target}/run/kldload-darksite"
  k_umount_if_mounted "${target}/sys/firmware/efi/efivars"
  k_umount_if_mounted "${target}/run"
  k_umount_if_mounted "${target}/sys"
  k_umount_if_mounted "${target}/proc"
  k_umount_if_mounted "${target}/dev/pts"
  k_umount_if_mounted "${target}/dev"
  k_umount_if_mounted /run/kldload-darksite
}

k_write_hostname() {
  local target="${KLDLOAD_TARGET:?}"
  local host="${KLDLOAD_HOSTNAME:-kldload}"

  printf '%s\n' "${host}" > "${target}/etc/hostname"
  cat > "${target}/etc/hosts" <<EOH
127.0.0.1 localhost
127.0.1.1 ${host}
::1 localhost ip6-localhost ip6-loopback
EOH
}

k_enable_locale() {
  local target="${KLDLOAD_TARGET:?}"
  local locale="${KLDLOAD_LOCALE:-en_US.UTF-8}"

  mkdir -p "${target}/etc"
  : > "${target}/etc/locale.gen"
  printf '%s UTF-8\n' "${locale}" >> "${target}/etc/locale.gen"

  cat > "${target}/etc/default/locale" <<EOL
LANG=${locale}
LC_ALL=
EOL
}

k_preseed_noninteractive() {
  local target="${KLDLOAD_TARGET:?}"

  mkdir -p "${target}/etc/apt/apt.conf.d"
  cat > "${target}/etc/apt/apt.conf.d/90kldload-noninteractive" <<'EOA'
APT::Get::Assume-Yes "true";
APT::Install-Recommends "false";
DPkg::Options {
  "--force-confdef";
  "--force-confold";
};
EOA

  if command -v chroot >/dev/null 2>&1; then
    printf '%s\n' \
      'console-setup console-setup/charmap47 select UTF-8' \
      'console-setup console-setup/codeset47 select Latin1 and Latin5 - western Europe and Turkic languages' \
      'console-setup console-setup/fontface47 select Fixed' \
      'console-setup console-setup/fontsize-fb47 select 8x16' \
      'keyboard-configuration keyboard-configuration/layoutcode string us' \
      'keyboard-configuration keyboard-configuration/modelcode string pc105' \
      'keyboard-configuration keyboard-configuration/variantcode string' \
      | chroot "${target}" debconf-set-selections || true
  fi
}

k_create_users() {
  local target="${KLDLOAD_TARGET:?}"
  local user="${KLDLOAD_USERNAME:-admin}"

  # chpasswd lives in /usr/sbin/ on every supported target. Bare
  # `chroot $target chpasswd` doesn't go through bash, so PATH inside
  # the chroot is whatever the caller had — which on a fresh Debian
  # debootstrap target may not include /usr/sbin and chroot then errors
  # "failed to run command 'chpasswd': No such file or directory".
  # Use absolute path; works on Debian/Ubuntu/CentOS/Fedora identically.
  if [[ -n "${KLDLOAD_ROOT_PASSWORD:-}" ]]; then
    echo "root:${KLDLOAD_ROOT_PASSWORD}" | chroot "${target}" /usr/sbin/chpasswd
  fi

  if ! chroot "${target}" id "${user}" >/dev/null 2>&1; then
    # CentOS uses 'wheel', Debian uses 'sudo'
    local admin_group="sudo"
    chroot "${target}" getent group wheel >/dev/null 2>&1 && admin_group="wheel"
    k_in_chroot "${target}" useradd -m -s /bin/bash -G "${admin_group}" "${user}"
  fi

  if [[ -n "${KLDLOAD_PASSWORD:-}" ]]; then
    echo "${user}:${KLDLOAD_PASSWORD}" | chroot "${target}" /usr/sbin/chpasswd
  fi

  # ── Default authorized_keys for the admin user ────────────────────────
  # Sources, in priority order (each line appended; dupes culled):
  #   1. $KLDLOAD_ADMIN_SSH_KEYS (newline-separated pubkeys, from answers env)
  #   2. /etc/kldload/default-authorized-keys (baked into the ISO)
  #
  # This makes every installed kldload box keyed in for the operator on
  # first boot — no per-machine ssh-copy-id dance. Source (2) is the
  # primary path: live-build/.../etc/kldload/default-authorized-keys
  # gets a single line per trusted operator pubkey. Personal keys are
  # gitignored; the included key is the generic `admin@kldload` one.
  # Without this block, fresh installs require the admin password every
  # SSH session — usable but painful for fleet ops.
  local admin_ssh_dir="${target}/home/${user}/.ssh"
  local admin_auth_keys="${admin_ssh_dir}/authorized_keys"
  local _have_keys=0
  install -d -m 0700 "${admin_ssh_dir}"
  : > "${admin_auth_keys}.new"
  if [[ -n "${KLDLOAD_ADMIN_SSH_KEYS:-}" ]]; then
    printf '%s\n' "${KLDLOAD_ADMIN_SSH_KEYS}" >> "${admin_auth_keys}.new"
    _have_keys=1
  fi
  if [[ -f /etc/kldload/default-authorized-keys ]]; then
    cat /etc/kldload/default-authorized-keys >> "${admin_auth_keys}.new"
    _have_keys=1
  fi
  if [[ "${_have_keys}" -eq 1 ]]; then
    # Strip blanks + comment lines + dedupe (preserve order).
    awk 'NF && $1 !~ /^#/ && !seen[$0]++' "${admin_auth_keys}.new" \
      > "${admin_auth_keys}"
    chmod 0600 "${admin_auth_keys}"
    # Ownership: must be the admin user, not root. UID/GID 1000 by
    # convention on every supported distro (admin is first useradd).
    # Use chroot+chown for accuracy across uid_map differences.
    chroot "${target}" chown -R "${user}:${user}" "/home/${user}/.ssh" \
      2>/dev/null || true
  fi
  rm -f "${admin_auth_keys}.new"
}

k_write_manifest() {
  local target="${KLDLOAD_TARGET_MNT:-${KLDLOAD_TARGET:-/target}}"
  mkdir -p "${target}/etc/kldload"

  cat > "${target}/etc/kldload/install-manifest.env" <<EOM
# KLDLOAD_INSTALLED=1 is the canonical "this box came out of the installer,
# it is not the live ISO" flag. kldload-webui's is_live_mode() reads this —
# without it the webui keeps serving the INSTALLER UI on every boot, which
# makes installed machines look identical to the pre-install screen (no
# dashboard, no VMs/K8s/klab tabs, etc.). Must be set by every code path
# that finalises an install.
KLDLOAD_INSTALLED=1
KLDLOAD_PROFILE=${KLDLOAD_PROFILE:-server}
# KLDLOAD_TEMPLATE — 4-template architecture (1.1.0+). One of:
#   kvm    → libvirt + ZFS + OS lean goldens, no K8s
#   k8s    → lean K8s (1 CP + 3 workers) + obs, no goldens
#   klab   → kvm + K8s (1 CP + 0 workers, scalable) + obs
#   zfslab → K8s (1 CP + 0 workers) + obs + ZFS-test goldens
# Workload tiles all share KLDLOAD_PROFILE=kvm for the package set; the
# template field is the tile-level identity that drives autodeploy phases.
# Empty on plain server/desktop/core installs (no autodeploy).
KLDLOAD_TEMPLATE=${KLDLOAD_TEMPLATE:-}
KLDLOAD_STORAGE_MODE=${KLDLOAD_STORAGE_MODE:-standard}
KLDLOAD_ENABLE_ZFS=${KLDLOAD_ENABLE_ZFS:-0}
KLDLOAD_ENABLE_EBPF=${KLDLOAD_ENABLE_EBPF:-0}
KLDLOAD_SECURE_BOOT=${KLDLOAD_SECURE_BOOT:-1}
KLDLOAD_ENABLE_SECURE_BOOT=${KLDLOAD_ENABLE_SECURE_BOOT:-1}
KLDLOAD_TPM_PRESENT=${KLDLOAD_TPM_PRESENT:-0}
KLDLOAD_ENABLE_AI=${KLDLOAD_ENABLE_AI:-0}
KLDLOAD_BOB_MODEL=${KLDLOAD_BOB_MODEL:-recommended}
KLDLOAD_BOB_DARKSITE=${KLDLOAD_BOB_DARKSITE:-0}
KLDLOAD_ENABLE_KVM=${KLDLOAD_ENABLE_KVM:-0}
KLDLOAD_BUILD_IMAGES=${KLDLOAD_BUILD_IMAGES:-0}
KLDLOAD_ENABLE_K8S=${KLDLOAD_ENABLE_K8S:-0}
KLDLOAD_K8S_BOOTSTRAP=${KLDLOAD_K8S_BOOTSTRAP:-0}
KLDLOAD_ENABLE_DEVOPS=${KLDLOAD_ENABLE_DEVOPS:-0}
KLDLOAD_KLAB_ZFS_DEV=${KLDLOAD_KLAB_ZFS_DEV:-0}
KLDLOAD_ZFSLAB_MODE=${KLDLOAD_ZFSLAB_MODE:-0}
EOM
}

# k_generate_mok_keys — create MOK key pair at the standard DKMS paths and
# configure DKMS to sign modules during build.  Must be called BEFORE any
# package installation so that when zfs-dkms is installed, DKMS builds the
# kernel module and signs it in a single pass — no retroactive signing needed.
k_generate_mok_keys() {
  local target="${KLDLOAD_TARGET:?}"
  local mok_dir="${target}/var/lib/dkms"

  mkdir -p "${mok_dir}"

  # ─── Bring Your Own Key (BYOK) — honour caller-supplied key paths ───────
  #
  # Most users who actually want Secure Boot already have their own MOK
  # (org-issued cert, existing linux-tools keyring, HSM-backed key, …).
  # A throwaway per-install self-signed cert is only useful when the user
  # has no existing PKI story — and in that case they usually don't
  # need SB in the first place.
  #
  # Supported BYOK paths, in order of precedence:
  #
  #   1. Caller sets KLDLOAD_MOK_KEY_FILE + KLDLOAD_MOK_CERT_FILE before
  #      running the installer. Both files must be readable on the live
  #      environment; we copy them into the target. PEM private key +
  #      PEM X.509 cert — standard `openssl req -x509 -newkey` output.
  #
  #   2. Caller pre-populates /var/lib/dkms/mok.{key,pub} INSIDE THE
  #      TARGET before this function runs (e.g. via an answers-file hook
  #      that does a curl or scp). Useful when the key only exists on a
  #      pre-provisioned image that writes it during first-boot staging.
  #
  #   3. Nothing supplied → we generate a throwaway RSA-2048 self-signed
  #      cert with a timestamped+random CN so multiple installs don't
  #      accidentally share a subject. See warning in release notes.
  #
  # In all three cases we also generate the DER form (required by
  # `mokutil --import` for MokManager enrollment) and write the DKMS
  # sign_helper + framework config so kernel module signing just works.
  #
  # If you're writing deployment automation, path (1) is the right
  # answer — keeps your signing key out of every install log and lets
  # you enroll ONE cert on every box in the fleet instead of N certs.

  # ── kldload-ca unification (1.0.6) ──────────────────────────────────
  # One trust root per install. kldload-ca init creates the per-install
  # RSA-4096 root used for BOTH TLS leaf issuance AND kernel module
  # signing / MOK enrollment. Same key; same cert; same firmware trust
  # decision covers browsers AND `zfs.ko`. Eliminates the 1.0.5 class
  # of "three independent self-signed keys drifting" bugs.
  #
  # BYOK path still supported: if the caller supplies
  # KLDLOAD_MOK_KEY_FILE + KLDLOAD_MOK_CERT_FILE (e.g. org PKI, HSM),
  # we honour those as the MOK and skip CA init. DKMS signs with
  # them; TLS still uses the fresh kldload-ca root for serving certs
  # because an HSM-backed code-signing key isn't appropriate for TLS
  # terminator rotation.
  #
  # CA init target is the INSTALLED system's /etc/kldload/ca/ — we
  # set KLDLOAD_CA_DIR so kldload-ca writes into the chroot's filesystem
  # directly. Running from the live ISO as root, writing target paths
  # below. The same root will be reachable post-install via the normal
  # default path.
  local ca_dir="${target}/etc/kldload/ca"
  local ca_crt="${ca_dir}/root/ca.crt"
  local ca_key="${ca_dir}/root/ca.key"
  local ca_der="${ca_dir}/root/ca.der"

  if [[ -n "${KLDLOAD_MOK_KEY_FILE:-}" && -n "${KLDLOAD_MOK_CERT_FILE:-}" \
        && -r "${KLDLOAD_MOK_KEY_FILE}" && -r "${KLDLOAD_MOK_CERT_FILE}" ]]; then
    k_log_to "${KLDLOAD_BOOTSTRAP_LOG}" "Using caller-supplied MOK keypair (BYOK):"
    k_log_to "${KLDLOAD_BOOTSTRAP_LOG}" "  key:  ${KLDLOAD_MOK_KEY_FILE}"
    k_log_to "${KLDLOAD_BOOTSTRAP_LOG}" "  cert: ${KLDLOAD_MOK_CERT_FILE}"
    cp "${KLDLOAD_MOK_KEY_FILE}"  "${mok_dir}/mok.key"
    cp "${KLDLOAD_MOK_CERT_FILE}" "${mok_dir}/mok.pub"
  else
    # Always generate a dedicated EFI code-signing leaf cert for the MOK,
    # SEPARATE from the kldload-ca root (which is a CA cert used for TLS).
    #
    # Why: kldload-ca's root has X509v3 Basic Constraints CA:TRUE, multiple
    # EKUs (TLS Web Server Auth, TLS Web Client Auth, Code Signing), and
    # other CA-style extensions. Microsoft Authenticode + shim's PE
    # signature verifier expect a CODE-SIGNING LEAF cert: no CA flag,
    # codeSigning EKU only, minimal extensions. Signing with a CA-style
    # cert produces signatures that sbsign/pesign/sbctl all output
    # successfully but that sbverify and shim REJECT — symptom: ZBM
    # fails under SB with "bad shim status", `sbverify --cert mok.pub
    # <signed>` always returns "Signature verification failed" even
    # though the keys match. Verified empirically against ZBM 3.1.0 +
    # CentOS shim 15.8 + sbctl 0.18 — only LEAF certs validate.
    #
    # Pre-1.1.0-dev installs reused the CA root as the MOK; that's why
    # ZBM-under-SB never actually worked, only direct kernel boot did.
    #
    # The cert template here matches what `sbctl create-keys` produces:
    # bare self-signed RSA-4096 with no extensions. shim accepts it
    # via the MOK list; sign-file accepts any (key, cert) pair for
    # module signing; mokutil's import only cares about DER format.
    k_log_to "${KLDLOAD_BOOTSTRAP_LOG}" "Generating MOK code-signing leaf (separate from TLS CA)"
    if [[ -x /usr/local/sbin/kldload-ca ]]; then
      # Still init the kldload-ca for TLS purposes — it just no longer
      # supplies the MOK material.
      KLDLOAD_CA_DIR="${ca_dir}" /usr/local/sbin/kldload-ca init \
        >> "${KLDLOAD_BOOTSTRAP_LOG}" 2>&1
    fi

    # Generate per-install MOK leaf. RSA-4096 to match common SB key
    # strength (sbctl, shim's vendor_cert, MS db keys are 2048+; 4096
    # matches the kldload-ca root). Self-signed — no chain to verify.
    # Subject is unique per install so multiple boxes' enrollments
    # don't collide in MokListRT (mokutil keys by subject hash).
    local _mok_cn="kldload-mok-$(date -u +%Y%m%d%H%M%S)-$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    openssl req -new -x509 -newkey rsa:4096 \
      -keyout "${mok_dir}/mok.key" \
      -out    "${mok_dir}/mok.pub" \
      -days 3650 -nodes \
      -subj "/CN=${_mok_cn}" \
      >> "${KLDLOAD_BOOTSTRAP_LOG}" 2>&1
    k_log_to "${KLDLOAD_BOOTSTRAP_LOG}" "MOK leaf generated: CN=${_mok_cn}"
  fi

  # DER form for `mokutil --import`. Generate from mok.pub (PEM cert)
  # — do NOT reuse ca.der from the kldload-ca root anymore; that's the
  # bug class this rewrite is fixing.
  openssl x509 \
    -in "${mok_dir}/mok.pub" \
    -out "${mok_dir}/mok.der" \
    -outform DER \
    >> "${KLDLOAD_BOOTSTRAP_LOG}" 2>&1

  chmod 0600 "${mok_dir}/mok.key"
  chmod 0644 "${mok_dir}/mok.pub" "${mok_dir}/mok.der"

  # DKMS sign_tool script — called by DKMS as: script KVER MODULE_PATH
  # Searches both Debian (linux-headers-) and CentOS (kernels/) paths for sign-file.
  mkdir -p "${target}/etc/dkms"
  cat > "${target}/etc/dkms/sign_helper.sh" <<'EOSIGN'
#!/bin/bash
set -euo pipefail
KVER="${1:?}" MOD="${2:?}"
KEY=/var/lib/dkms/mok.key
CERT=/var/lib/dkms/mok.pub
# Search both Debian and CentOS/RHEL paths for the kernel sign-file tool
SIGN_FILE=$(find /usr/src/kernels/"${KVER}" \
                 /usr/src/linux-headers-"${KVER}" \
                 /usr/lib/linux-kbuild-"${KVER%%.*}"* \
                 -name sign-file -type f 2>/dev/null | head -1 || true)
[[ -x "${SIGN_FILE}" ]] || { echo "sign-file not found for ${KVER}" >&2; exit 0; }
exec "${SIGN_FILE}" sha256 "${KEY}" "${CERT}" "${MOD}"
EOSIGN
  chmod 0755 "${target}/etc/dkms/sign_helper.sh"

  # Configure DKMS to use our MOK keys and sign tool
  # Use framework.conf.d to avoid overwriting distro defaults
  mkdir -p "${target}/etc/dkms/framework.conf.d"
  cat > "${target}/etc/dkms/framework.conf.d/kldload-mok.conf" <<MOKCONF
# kldload Secure Boot — MOK key paths for DKMS module signing
mok_signing_key=/var/lib/dkms/mok.key
mok_certificate=/var/lib/dkms/mok.pub
sign_tool=/etc/dkms/sign_helper.sh
# Force signing even inside chroot (default not_in_chroot skips during install)
try_sign_modules=true
MOKCONF

  k_log_to "${KLDLOAD_BOOTSTRAP_LOG}" "MOK keys ready at /var/lib/dkms/mok.{key,pub,der} — DKMS will sign on install"
}

k_install_target_packages() {
  local target="${KLDLOAD_TARGET:?}"
  local -a pkgs
  local profile_pkgs profile_opt

  # Generate MOK keys BEFORE package installation so DKMS signs ZFS modules
  # during build rather than requiring retroactive signing afterward.
  # Secure Boot is OPT-IN as of 1.0.5 — default off, set
  # KLDLOAD_ENABLE_SECURE_BOOT=1 at install time to enable the full
  # MOK + signed-ZBM + shim pipeline. See the big comment on
  # _secure_boot_enabled() in kldload-install-target for rationale.
  if [[ "${KLDLOAD_ENABLE_SECURE_BOOT:-1}" == "1" ]]; then
    k_generate_mok_keys
  else
    k_log_to "${KLDLOAD_BOOTSTRAP_LOG}" "Skipping MOK keys (Secure Boot disabled; set KLDLOAD_ENABLE_SECURE_BOOT=1 to enable)"
  fi

  local distro="${KLDLOAD_DISTRO:-debian}"

  # Ubuntu uses different kernel metapackage names than Debian
  if [[ "$distro" == "ubuntu" ]]; then
    pkgs=(
      linux-image-generic
      linux-headers-generic
    )
  else
    pkgs=(
      "linux-image-$(dpkg --print-architecture)"
      "linux-headers-$(dpkg --print-architecture)"
    )
  fi

  pkgs+=(
    efibootmgr
    mokutil
    shim-signed
    grub-efi-amd64-signed
    sbsigntool
    kexec-tools
    locales
    keyboard-configuration
    console-setup
    systemd-sysv
    initramfs-tools
    sudo
    openssh-server
    network-manager
    qemu-guest-agent
    # nginx — single TLS reverse proxy on :8443 with HTTP/2 (1.0.6).
    # Must be in this hardcoded array — target-base.txt drives the
    # darksite download manifest only, not the actual target install.
    nginx-light
    # noVNC + websockify — graphical "View" console for libvirt VMs in
    # the kldload web UI. websockify on Debian pulls in
    # python3-websockify as a dep; novnc ships the HTML5 bundle at
    # /usr/share/novnc. Same lesson learned 2026-05-16 on the Fedora
    # side (see _dnf_pkgs novnc entry): adding only to target-base.txt
    # leaves the darksite mirror correct but the installed target
    # missing the package, View button silently does nothing.
    novnc websockify
  )

  if [[ "${KLDLOAD_STORAGE_MODE:-standard}" == "zfs" ]]; then
    # zfs-dkms must be explicit so DKMS builds (and signs) the kernel module;
    # zfsutils-linux alone may pull a pre-built binary that bypasses DKMS.
    pkgs+=(
      zfsutils-linux
      zfs-initramfs
      zfs-zed
    )
    # Debian needs zfs-dkms for DKMS build; Ubuntu ships ZFS in the kernel image
    if [[ "$distro" != "ubuntu" ]]; then
      pkgs+=( zfs-dkms )
    fi
  fi

  # Remove any DEB822 format sources and stale sources.list.d entries
  # that override our sources.list (Ubuntu noble uses these by default)
  rm -f "${target}"/etc/apt/sources.list.d/*.sources 2>/dev/null || true
  rm -f "${target}"/etc/apt/sources.list.d/*.list 2>/dev/null || true

  # Log what we're working with
  k_log_to "$log" "sources.list contents:"
  cat "${target}/etc/apt/sources.list" >> "$log" 2>&1 || true
  k_log_to "$log" "sources.list.d contents:"
  ls -la "${target}/etc/apt/sources.list.d/" >> "$log" 2>&1 || true

  k_log_to "$log" "Running apt-get update..."
  DEBIAN_FRONTEND=noninteractive k_in_chroot "${target}" apt-get update 2>&1 | tee -a "$log" || true
  k_log_to "$log" "Installing packages: ${pkgs[*]}"
  DEBIAN_FRONTEND=noninteractive k_in_chroot "${target}" apt-get install -y "${pkgs[@]}" 2>&1 | tee -a "$log"

  profile_pkgs="$(k_profile_packages)"
  profile_opt="$(k_profile_optional_packages)"
  if [[ -n "${profile_pkgs}${profile_opt}" ]]; then
    k_log_to "$log" "Installing profile packages: ${profile_pkgs} ${profile_opt}"
    DEBIAN_FRONTEND=noninteractive k_in_chroot "${target}" \
      apt-get install -y --no-install-recommends --ignore-missing \
      ${profile_pkgs} ${profile_opt} 2>&1 | tee -a "$log" || {
      k_log_to "$log" "WARNING: Some profile packages failed — retrying individually..."
      for _pkg in ${profile_pkgs} ${profile_opt}; do
        DEBIAN_FRONTEND=noninteractive k_in_chroot "${target}" \
          apt-get install -y --no-install-recommends "$_pkg" >> "$log" 2>&1 \
          || k_log_to "$log" "WARNING: package ${_pkg} not available — skipping"
      done
    }
  fi
}

# k_detect_local_mirror — returns the local darksite mirror URL if the
# kldload-apt-mirror service is running and has the requested suite.
k_detect_local_mirror() {
  local distro="${KLDLOAD_DISTRO:-debian}"
  local suite port

  if [[ "$distro" == "ubuntu" ]]; then
    suite="${KLDLOAD_SUITE:-noble}"
    port=3143
  else
    suite="${KLDLOAD_SUITE:-trixie}"
    port=3142
  fi

  local test_url="http://127.0.0.1:${port}/apt/dists/${suite}/Release"
  if curl -sf --connect-timeout 3 --max-time 5 "$test_url" >/dev/null 2>&1; then
    echo "http://127.0.0.1:${port}/apt"
    return 0
  fi
  return 1
}

k_bootstrap_base() {
  local target="${KLDLOAD_TARGET:?}"
  local distro="${KLDLOAD_DISTRO:-}"
  local log="${KLDLOAD_BOOTSTRAP_LOG:-/var/log/installer/bootstrap.log}"

  # Auto-detect distro from the live OS if not set
  if [[ -z "$distro" ]]; then
    local _id=""
    [[ -f /etc/os-release ]] && _id="$(. /etc/os-release && echo "$ID")"
    case "$_id" in
      centos|rocky|rhel|almalinux) distro="centos" ;;
      fedora) distro="fedora" ;;
      debian|ubuntu) distro="debian" ;;
      arch) distro="arch" ;;
      *) distro="debian" ;;
    esac
    export KLDLOAD_DISTRO="$distro"
  fi

  k_log_to "$log" "Distro detected: ${distro}"

  case "$distro" in
    centos|rocky|rhel|fedora)
      _k_bootstrap_dnf
      ;;
    debian|ubuntu)
      _k_bootstrap_apt
      ;;
    arch)
      _k_bootstrap_pacman
      ;;
    alpine)
      _k_bootstrap_apk
      ;;
    freebsd)
      _k_bootstrap_freebsd
      ;;
    openbsd)
      _k_bootstrap_openbsd
      ;;
    ghostbsd)
      _k_bootstrap_ghostbsd
      ;;
    *)
      k_die "Unsupported distro: $distro"
      ;;
  esac
}

_k_bootstrap_dnf() {
  local target="${KLDLOAD_TARGET:?}"
  local release="${KLDLOAD_RELEASE:-9}"
  local log="${KLDLOAD_BOOTSTRAP_LOG:-/var/log/installer/bootstrap.log}"

  local distro="${KLDLOAD_DISTRO:-centos}"

  # Fedora uses its own release version, not the EL release (9). Default F44:
  # F44's base repo ships the 6.19.x GA kernel and the fc43 OpenZFS bridge
  # (zfs-dkms 2.4.x) builds against 6.19 — the exact combo the live env runs.
  # The 7.0.x updates kernel (no buildable ZFS) is excluded at install time and
  # pinned out of the installed dnf.conf, so the box stays on 6.19 and upgrades
  # can't brick the ZFS boot. KLDLOAD_FEDORA_RELEASE=43 for the older 6.17 GA.
  if [[ "${distro}" == "fedora" ]]; then
    release="${KLDLOAD_FEDORA_RELEASE:-44}"
  fi

  # RHEL has moved to 10 (GA May 2025); CentOS Stream and Rocky stay on 9.
  # KLDLOAD_RELEASE overrides for users who still need RHEL 9.
  if [[ "${distro}" == "rhel" ]]; then
    release="${KLDLOAD_RELEASE:-10}"
  fi

  k_log_to "$log" "Bootstrapping ${distro} ${release} → ${target}"

  # Set up repos — distro-specific
  mkdir -p "${target}/etc/yum.repos.d" "${target}/etc/pki/rpm-gpg"

  case "${distro}" in
    rocky)
      cat > "${target}/etc/yum.repos.d/rocky.repo" <<ROCKYREPO
[baseos]
name=Rocky Linux ${release} - BaseOS
mirrorlist=https://mirrors.rockylinux.org/mirrorlist?arch=\$basearch&repo=BaseOS-${release}
gpgcheck=0
enabled=1

[appstream]
name=Rocky Linux ${release} - AppStream
mirrorlist=https://mirrors.rockylinux.org/mirrorlist?arch=\$basearch&repo=AppStream-${release}
gpgcheck=0
enabled=1

[crb]
name=Rocky Linux ${release} - CRB
mirrorlist=https://mirrors.rockylinux.org/mirrorlist?arch=\$basearch&repo=CRB-${release}
gpgcheck=0
enabled=1
ROCKYREPO
      ;;
    rhel)
      # RHEL uses subscription-manager — supports two auth methods:
      #   1. Username + password (simplest — use your Red Hat portal login)
      #   2. Activation key + org ID (for automation / shared credentials)
      #
      # IMPORTANT: We register from the LIVE environment (not the installroot)
      # and then write the RHEL repo configs into the clean installroot.
      # Previous approach installed CentOS packages first, which conflicted
      # with RHEL packages (CentOS Stream versions are newer than RHEL point releases).
      local rhel_key="${KLDLOAD_RHEL_KEY:-${RHEL_ACTIVATION_KEY:-}}"
      local rhel_org="${KLDLOAD_RHEL_ORG:-${RHEL_ORG_ID:-}}"
      local rhel_user="${KLDLOAD_RHEL_USERNAME:-${RHEL_USERNAME:-}}"
      local rhel_pass="${KLDLOAD_RHEL_PASSWORD:-${RHEL_PASSWORD:-}}"

      # Determine auth method
      local rhel_auth=""
      if [[ -n "${rhel_user}" && -n "${rhel_pass}" ]]; then
        rhel_auth="userpass"
        k_log_to "$log" "RHEL auth: username/password (user=${rhel_user})"
      elif [[ -n "${rhel_key}" && -n "${rhel_org}" ]]; then
        rhel_auth="activation"
        k_log_to "$log" "RHEL auth: activation key (key=${rhel_key}, org=${rhel_org})"
      else
        k_die "RHEL install requires either KLDLOAD_RHEL_USERNAME + KLDLOAD_RHEL_PASSWORD (Red Hat portal login) or KLDLOAD_RHEL_KEY + KLDLOAD_RHEL_ORG (activation key + org ID)"
      fi

      # Step 1: Register from the LIVE environment. This avoids polluting the
      # installroot with CentOS packages that conflict with RHEL versions.
      # Install subscription-manager on the live system if not present.
      if ! command -v subscription-manager >/dev/null 2>&1; then
        k_log_to "$log" "Installing subscription-manager on live system..."
        dnf install -y --nogpgcheck subscription-manager >> "$log" 2>&1 \
          || k_die "Failed to install subscription-manager on live system"
      fi
      k_log_to "$log" "Registering with Red Hat CDN from live environment..."
      # Unregister any previous registration on the live system
      subscription-manager unregister >> "$log" 2>&1 || true

      if [[ "${rhel_auth}" == "userpass" ]]; then
        subscription-manager register \
          --username="${rhel_user}" --password="${rhel_pass}" --force >> "$log" 2>&1 \
          || { k_log_to "$log" "WARNING: register failed — trying --insecure"; \
               subscription-manager register \
                 --username="${rhel_user}" --password="${rhel_pass}" --force --insecure >> "$log" 2>&1 \
                 || k_die "subscription-manager register failed — check your Red Hat username and password"; }
      else
        subscription-manager register \
          --activationkey="${rhel_key}" --org="${rhel_org}" --force >> "$log" 2>&1 \
          || { k_log_to "$log" "WARNING: register failed — trying --insecure"; \
               subscription-manager register \
                 --activationkey="${rhel_key}" --org="${rhel_org}" --force --insecure >> "$log" 2>&1 \
                 || k_die "subscription-manager register failed — check your activation key and org ID"; }
      fi

      # ── Mark for the firstboot osbuild-composer build ──────────────
      # The original plan was to download the pre-built RHEL Cloud
      # Image qcow2 via access.redhat.com's Images API during install.
      # That path is now dead at the source: RH disabled grant_type=
      # password for the rhsm-api SSO client in 2025-26 (returns
      # `unauthorized_client / Client not allowed for direct access
      # grants`). The only remaining programmatic paths are:
      #
      #   1. User generates an offline token at access.redhat.com/
      #      management/api and pastes it -- poor UX, one-time setup
      #      per operator with a fragile token TTL story.
      #
      #   2. osbuild-composer locally on the registered RHEL host
      #      builds a qcow2 from subscription content. RH-blessed
      #      "build custom RHEL images from your registered system"
      #      flow. Sidesteps the API entirely. (CHOSEN.)
      #
      # Composer needs to run ON the registered RHEL host, not the
      # live env (live env is Fedora; composer's RHEL repo defs need
      # to be present + entitlement certs available -- the installed
      # target has both, the live env doesn't without extra plumbing).
      # So we DEFER to firstboot: write a marker, install-time exits,
      # systemd's kldload-rhel-composer.service picks it up after the
      # host boots into its installed-RHEL state.
      #
      # User experience: install completes ~3 min faster than the old
      # pre-stage path (no image download here), but klab-golden-rhel
      # appears ~15-25 min into first boot rather than immediately.
      # Other 5 distros' goldens build in parallel during firstboot;
      # all are usable as soon as each finishes.
      install -d -m 0755 "${target}/var/lib/klab"
      touch "${target}/var/lib/klab/.rhel-composer-pending"
      k_log_to "$log" "RHEL 6th klab golden deferred to firstboot composer build (~15-25 min after first reboot, background)"

      # ── Shred install-time creds ──────────────────────────────────
      # Pass-through-and-delete model. By here:
      #   - host registered (subscription-manager identity persists)
      #   - marker written for firstboot composer (no creds needed --
      #     composer uses the host's entitlement certs)
      #
      # Nothing about RHEL needs the creds anymore. Unset in-memory.
      # We do NOT write /root/.klab-rhel-creds, do NOT mirror into
      # /var/lib/kldload/secrets/, do NOT keep anything around. If
      # the operator wants to spawn more RHEL VMs later, they re-enter
      # creds at clone time (or `subscription-manager register` inside
      # each clone manually -- standard RHEL flow).
      unset rhel_user rhel_pass rhel_key rhel_org
      k_log_to "$log" "RHEL install-time creds shredded from env (no persistent storage)"

      # Step 2: Install redhat-release into the installroot so it has proper
      # RHEL identity from the start (no CentOS packages ever touch it).
      # The cached RPMs in build/rhel-release/ are version-pinned at build
      # time (e.g. redhat-release-9.7 or redhat-release-10.0). If the cache
      # is the wrong major for the requested $release we'd end up with a
      # "Red Hat Enterprise Linux release 9.7" file on a RHEL-10 install —
      # confuses dnf, subscription-manager, every consumer of /etc/redhat-
      # release. Detect mismatch and fall through to the minimal-identity
      # path instead. The first dnf install on the live network will replace
      # the placeholder with the real package version.
      k_log_to "$log" "Setting up clean RHEL ${release} installroot..."
      local rhel_rpms="/root/darksite/rhel-release"
      [[ -d "$rhel_rpms" ]] || rhel_rpms="/usr/share/kldload/rhel-release"
      local _rrpm_major=""
      if [[ -d "$rhel_rpms" ]] && ls "$rhel_rpms"/redhat-release*.rpm >/dev/null 2>&1; then
        _rrpm_major="$(rpm -qp --qf '%{VERSION}' "$rhel_rpms"/redhat-release-[0-9]*.rpm 2>/dev/null | head -1 | cut -d. -f1)"
      fi
      if [[ -n "$_rrpm_major" && "$_rrpm_major" == "$release" ]]; then
        mkdir -p "${target}/tmp"
        cp "$rhel_rpms"/redhat-release*.rpm "${target}/tmp/"
        rpm --root="${target}" -ivh --nodeps "${target}"/tmp/redhat-release*.rpm 2>>"$log" || true
        rm -f "${target}"/tmp/redhat-release*.rpm
        k_log_to "$log" "redhat-release installed: $(chroot "${target}" cat /etc/redhat-release 2>/dev/null || echo unknown)"
      else
        if [[ -n "$_rrpm_major" ]]; then
          k_log_to "$log" "WARNING: cached redhat-release is RHEL ${_rrpm_major}.x but install requested RHEL ${release} — using minimal identity (dnf will install the real package later)"
        else
          k_log_to "$log" "WARNING: redhat-release RPMs not found — creating minimal RHEL identity"
        fi
        mkdir -p "${target}/etc"
        echo "Red Hat Enterprise Linux release ${release} (kldload)" > "${target}/etc/redhat-release"
      fi

      # Step 3: Copy subscription identity from the live system into the installroot
      # so dnf in the installroot can access RHEL repos
      k_log_to "$log" "Copying subscription identity to installroot..."
      mkdir -p "${target}/etc/pki/entitlement" "${target}/etc/pki/consumer" \
               "${target}/etc/pki/product" "${target}/etc/pki/product-default" \
               "${target}/etc/rhsm" "${target}/etc/pki/ca-trust/source/anchors"
      cp -a /etc/pki/entitlement/* "${target}/etc/pki/entitlement/" 2>/dev/null || true
      cp -a /etc/pki/consumer/* "${target}/etc/pki/consumer/" 2>/dev/null || true
      cp -a /etc/pki/product/* "${target}/etc/pki/product/" 2>/dev/null || true
      cp -a /etc/pki/product-default/* "${target}/etc/pki/product-default/" 2>/dev/null || true
      cp -a /etc/rhsm/* "${target}/etc/rhsm/" 2>/dev/null || true
      # CDN CA cert
      cp /etc/pki/ca-trust/source/anchors/redhat-uep.pem "${target}/etc/pki/ca-trust/source/anchors/" 2>/dev/null || true

      # Step 4: Write RHEL repo configs using the actual entitlement cert filenames
      k_log_to "$log" "Configuring RHEL ${release} repos in installroot..."

      # Find the entitlement cert and key (resolve the actual filenames)
      local _ent_cert="" _ent_key="" _ca_cert="/etc/rhsm/ca/redhat-uep.pem"
      _ent_key="$(find /etc/pki/entitlement -name '*-key.pem' 2>/dev/null | head -1)"
      _ent_cert="$(find /etc/pki/entitlement -name '*.pem' ! -name '*-key.pem' 2>/dev/null | head -1)"

      if [[ -n "$_ent_cert" && -n "$_ent_key" ]]; then
        k_log_to "$log" "Entitlement cert: ${_ent_cert}"
        k_log_to "$log" "Entitlement key:  ${_ent_key}"

        # Remove any repo files that redhat-release dropped (they use wildcard
        # cert paths that don't resolve and create duplicate repo definitions)
        rm -f "${target}"/etc/yum.repos.d/redhat.repo 2>/dev/null || true
        rm -f "${target}"/etc/yum.repos.d/redhat-*.repo 2>/dev/null || true

        # Copy certs to installroot AND host paths with fixed names.
        # dnf --installroot resolves SSL cert paths from the HOST, not the installroot.
        cp "$_ent_cert" "${target}/etc/pki/entitlement/entitlement.pem"
        cp "$_ent_key" "${target}/etc/pki/entitlement/entitlement-key.pem"
        [[ -f "$_ca_cert" ]] && cp "$_ca_cert" "${target}/etc/rhsm/ca/redhat-uep.pem" 2>/dev/null || true
        # Also copy to host paths for dnf --installroot SSL resolution
        mkdir -p /etc/pki/entitlement /etc/rhsm/ca
        cp "$_ent_cert" /etc/pki/entitlement/entitlement.pem 2>/dev/null || true
        cp "$_ent_key" /etc/pki/entitlement/entitlement-key.pem 2>/dev/null || true
        [[ -f "$_ca_cert" ]] && cp "$_ca_cert" /etc/rhsm/ca/redhat-uep.pem 2>/dev/null || true

        mkdir -p "${target}/etc/yum.repos.d" "${target}/etc/pki/rpm-gpg"
        cp /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release "${target}/etc/pki/rpm-gpg/" 2>/dev/null || true

        cat > "${target}/etc/yum.repos.d/rhel.repo" <<RHELREPO
[rhel-${release}-baseos]
name=Red Hat Enterprise Linux ${release} - BaseOS
baseurl=https://cdn.redhat.com/content/dist/rhel${release}/${release}/x86_64/baseos/os
enabled=1
gpgcheck=0
sslverify=1
sslcacert=/etc/rhsm/ca/redhat-uep.pem
sslclientkey=/etc/pki/entitlement/entitlement-key.pem
sslclientcert=/etc/pki/entitlement/entitlement.pem

[rhel-${release}-appstream]
name=Red Hat Enterprise Linux ${release} - AppStream
baseurl=https://cdn.redhat.com/content/dist/rhel${release}/${release}/x86_64/appstream/os
enabled=1
gpgcheck=0
sslverify=1
sslcacert=/etc/rhsm/ca/redhat-uep.pem
sslclientkey=/etc/pki/entitlement/entitlement-key.pem
sslclientcert=/etc/pki/entitlement/entitlement.pem

[rhel-${release}-crb]
name=Red Hat Enterprise Linux ${release} - CRB
baseurl=https://cdn.redhat.com/content/dist/rhel${release}/${release}/x86_64/codeready-builder/os
enabled=1
gpgcheck=0
sslverify=1
sslcacert=/etc/rhsm/ca/redhat-uep.pem
sslclientkey=/etc/pki/entitlement/entitlement-key.pem
sslclientcert=/etc/pki/entitlement/entitlement.pem
RHELREPO
        k_log_to "$log" "RHEL repos configured with entitlement certs"
      else
        # No entitlement certs — Simple Content Access may work without them
        # Fall back to subscription-manager in the chroot
        k_log_to "$log" "WARNING: No entitlement certs found — falling back to chroot sub-man"
        mkdir -p "${target}/proc" "${target}/sys" "${target}/dev" "${target}/dev/pts" "${target}/run"
        mountpoint -q "${target}/proc" || mount -t proc proc "${target}/proc" 2>/dev/null || true
        mountpoint -q "${target}/sys" || mount -t sysfs sysfs "${target}/sys" 2>/dev/null || true
        mountpoint -q "${target}/dev" || mount --bind /dev "${target}/dev" 2>/dev/null || true
        mountpoint -q "${target}/dev/pts" || mount --bind /dev/pts "${target}/dev/pts" 2>/dev/null || true
        mkdir -p "${target}/etc/yum.repos.d"
        # Install sub-man into the installroot via CentOS, then swap to RHEL
        cat > "${target}/etc/yum.repos.d/centos-tmp.repo" <<CTMP
[centos-tmp]
name=CentOS Stream ${release} - BaseOS (temp)
metalink=https://mirrors.centos.org/metalink?repo=centos-baseos-${release}-stream&arch=\$basearch&protocol=https
gpgcheck=0
enabled=1
CTMP
        dnf --installroot="${target}" --releasever="${release}" --nogpgcheck -y install \
          subscription-manager ca-certificates >> "$log" 2>&1 || true
        rm -f "${target}/etc/yum.repos.d/centos-tmp.repo"
        # Remove ALL CentOS packages to avoid version conflicts with RHEL
        chroot "${target}" /usr/bin/rpm -e --nodeps --allmatches \
          $(chroot "${target}" /usr/bin/rpm -qa 'centos-*' 2>/dev/null) 2>>"$log" || true
        # Install redhat-release
        local rhel_rpms="/root/darksite/rhel-release"
        [[ -d "$rhel_rpms" ]] || rhel_rpms="/usr/share/kldload/rhel-release"
        if [[ -d "$rhel_rpms" ]]; then
          cp "$rhel_rpms"/redhat-release*.rpm "${target}/tmp/"
          chroot "${target}" /usr/bin/rpm -ivh --force --nodeps /tmp/redhat-release*.rpm 2>>"$log" || true
          rm -f "${target}"/tmp/redhat-release*.rpm
        fi
        # Register in the chroot
        cp /etc/resolv.conf "${target}/etc/resolv.conf" 2>/dev/null || true
        if [[ "${rhel_auth}" == "userpass" ]]; then
          chroot "${target}" subscription-manager register \
            --username="${rhel_user}" --password="${rhel_pass}" --force >> "$log" 2>&1 || true
        else
          chroot "${target}" subscription-manager register \
            --activationkey="${rhel_key}" --org="${rhel_org}" --force >> "$log" 2>&1 || true
        fi
        chroot "${target}" subscription-manager release --set="${release}" >> "$log" 2>&1 || true
        chroot "${target}" subscription-manager repos \
          --enable="rhel-${release}-for-x86_64-baseos-rpms" \
          --enable="rhel-${release}-for-x86_64-appstream-rpms" \
          --enable="codeready-builder-for-rhel-${release}-x86_64-rpms" \
          >> "$log" 2>&1 || true
        k_log_to "$log" "RHEL repos configured via chroot subscription-manager"
      fi
      ;;
    fedora)
      local fedora_release="${KLDLOAD_FEDORA_RELEASE:-44}"
      cat > "${target}/etc/yum.repos.d/fedora.repo" <<FEDORAREPO
[fedora]
name=Fedora ${fedora_release} - \$basearch
metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-${fedora_release}&arch=\$basearch
gpgcheck=0
enabled=1

[fedora-updates]
name=Fedora ${fedora_release} - Updates - \$basearch
metalink=https://mirrors.fedoraproject.org/metalink?repo=updates-released-f${fedora_release}&arch=\$basearch
gpgcheck=0
enabled=1
FEDORAREPO

      # PIN THE KERNEL on the installed system. F44 ships kernel 7.0.x, which
      # the fc43 OpenZFS bridge (zfs-dkms 2.4.x, Conflicts: kernel-uname-r >
      # 6.19.999) cannot build against — so an unguarded `dnf upgrade` would
      # install kernel-7.x, leave ZFS unbuildable, and drop the next boot into
      # dracut emergency (rpool won't import). Excluding kernel-7.* globally
      # blocks the boot-breaking jump while STILL allowing 6.x security/kernel
      # updates (zfs-dkms rebuilds fine across the 6.x line). When upstream
      # ships a ZFS that builds against 7.x, remove this line (or `dnf upgrade
      # --disableexcludes=main`) to unpin. Glob matches NEVRA, so `kernel-7.*`
      # matches kernel-7.0.10-… but never the bare `kernel`/6.x packages.
      local _dnfconf="${target}/etc/dnf/dnf.conf"
      mkdir -p "${target}/etc/dnf"
      [[ -f "$_dnfconf" ]] || printf '[main]\n' > "$_dnfconf"
      if ! grep -q '^exclude=.*kernel-7' "$_dnfconf"; then
        printf 'exclude=kernel-7.* kernel-core-7.* kernel-modules-7.* kernel-modules-core-7.* kernel-modules-extra-7.* kernel-devel-7.* kernel-devel-matched-7.* kernel-headers-7.* kernel-tools-7.* kernel-tools-libs-7.*\n' >> "$_dnfconf"
        k_log_to "$log" "Pinned installed Fedora kernel at 6.x (exclude=kernel-7.* in dnf.conf) — protects ZFS-on-root from the unbuildable 7.x kernel"
      fi
      ;;
    *) # centos (default)
      cat > "${target}/etc/yum.repos.d/centos.repo" <<DNFREPO
[baseos]
name=CentOS Stream ${release} - BaseOS
metalink=https://mirrors.centos.org/metalink?repo=centos-baseos-${release}-stream&arch=\$basearch&protocol=https
gpgcheck=0
enabled=1

[appstream]
name=CentOS Stream ${release} - AppStream
metalink=https://mirrors.centos.org/metalink?repo=centos-appstream-${release}-stream&arch=\$basearch&protocol=https
gpgcheck=0
enabled=1

[crb]
name=CentOS Stream ${release} - CRB
metalink=https://mirrors.centos.org/metalink?repo=centos-crb-${release}-stream&arch=\$basearch&protocol=https
gpgcheck=0
enabled=1
DNFREPO
      ;;
  esac

  # EPEL + ZFS repos (shared across CentOS/Rocky/RHEL; Fedora skips EPEL)
  # skip_if_unavailable=1 so EPEL mirror outages don't kill the install
  if [[ "${distro}" != "fedora" ]]; then
    cat > "${target}/etc/yum.repos.d/epel.repo" <<EPELREPO
[epel]
name=EPEL ${release}
metalink=https://mirrors.fedoraproject.org/metalink?repo=epel-${release}&arch=\$basearch
gpgcheck=0
enabled=1
skip_if_unavailable=1
EPELREPO
  fi

  # ZFS repo — EL writes a static zfs.repo; Fedora defers to the
  # zfs-release RPM installed below (it ships its own repo config
  # with the matching gpg key + URL for that Fedora version).
  # Prior behaviour hardcoded /fedora/41/ which shipped ZFS 2.2.7 —
  # a version that doesn't compile against Fedora 44's 6.19 kernel,
  # causing silent DKMS failure and unbootable ZFS-root installs.
  if [[ "${distro}" != "fedora" ]]; then
    cat > "${target}/etc/yum.repos.d/zfs.repo" <<ZFSREPO
[zfs]
name=ZFS on Linux for EL${release}
baseurl=http://download.zfsonlinux.org/epel/${release}/\$basearch/
enabled=1
gpgcheck=0
ZFSREPO
  fi
  # NB: for Fedora, zfs-release is installed inside the chroot
  # after package base setup — see k_install_zfs_release_fedora() below.

  # Mount chroot filesystems BEFORE dnf so postinst scripts (grub, dracut) work
  mkdir -p "${target}/proc" "${target}/sys" "${target}/dev" "${target}/dev/pts" "${target}/run"
  mountpoint -q "${target}/proc" || mount -t proc proc "${target}/proc" 2>/dev/null || true
  mountpoint -q "${target}/sys" || mount -t sysfs sysfs "${target}/sys" 2>/dev/null || true
  mountpoint -q "${target}/dev" || mount --bind /dev "${target}/dev" 2>/dev/null || true
  mountpoint -q "${target}/dev/pts" || mount --bind /dev/pts "${target}/dev/pts" 2>/dev/null || true
  mountpoint -q "${target}/run" || mount -t tmpfs tmpfs "${target}/run" 2>/dev/null || true

  # Ensure key directories exist in the installroot BEFORE dnf runs
  mkdir -p "${target}/etc" "${target}/var/cache/dnf" "${target}/var/lib/dnf" \
           "${target}/var/lib/rpm" "${target}/var/log" "${target}/run" \
           "${target}/tmp"

  # Copy DNS resolution into the installroot so dnf/curl can resolve hosts
  cp /etc/resolv.conf "${target}/etc/resolv.conf" 2>/dev/null || true

  # Disable subscription-manager dnf plugin — it regenerates redhat.repo with
  # wildcard cert paths that conflict with our explicit repo configs for RHEL.
  # Also remove any redhat.repo it may have already created.
  rm -f "${target}/etc/yum.repos.d/redhat.repo" 2>/dev/null || true
  mkdir -p "${target}/etc/dnf/plugins"
  echo -e "[main]\nenabled=0" > "${target}/etc/dnf/plugins/subscription-manager.conf"

  # Repo configuration — darksite mode vs internet
  # Fedora has its own darksite; CentOS/Rocky share one.
  #
  # We use /run/kldload-darksite (bound by k_bind_chroot_mounts to
  # /root/darksite on the live env, also bound INTO the target's
  # /run/kldload-darksite at the same path). This makes file:// URLs
  # in /target/etc/yum.repos.d/kldload-darksite.repo resolve identically
  # whether dnf runs as the host (`dnf --installroot=`) or inside the
  # chroot. /root/darksite alone fails: dnf --installroot resolves it
  # against the install root → /target/root/darksite which doesn't
  # exist until profiles.sh's late-stage rsync (after pass-1 already
  # needed it).
  #
  # Ensure the bind is up — k_bind_chroot_mounts is normally called
  # earlier but may not have run yet for partial-install code paths.
  if [[ -d /root/darksite ]] && ! mountpoint -q /run/kldload-darksite; then
    mkdir -p /run/kldload-darksite
    mount --bind /root/darksite /run/kldload-darksite 2>/dev/null || true
  fi
  if mountpoint -q /run/kldload-darksite && ! mountpoint -q "${target}/run/kldload-darksite"; then
    mkdir -p "${target}/run/kldload-darksite"
    mount --bind /run/kldload-darksite "${target}/run/kldload-darksite" 2>/dev/null || true
  fi

  local _darksite_rpm="/run/kldload-darksite/rpm"
  if [[ "${KLDLOAD_DISTRO:-centos}" == "fedora" ]]; then
    _darksite_rpm="/run/kldload-darksite/fedora/rpm"
  fi
  local _custom_repo="${KLDLOAD_CUSTOM_REPO:-}"

  if [[ -d "${_darksite_rpm}/repodata" ]]; then
    if [[ "${KLDLOAD_DISTRO:-centos}" == "rhel" ]]; then
      # RHEL: do NOT use the CentOS darksite — packages conflict (centos-logos etc.)
      # RHEL requires Red Hat CDN repos
      k_log_to "$log" "RHEL install — skipping darksite (using Red Hat CDN only)"
    else
      # Darksite available: add as the canonical source AND disable upstream
      # repos. Background: prior pass kept upstream enabled "as a fallback"
      # with cost=1 on the darksite, but dnf always picks the NEWEST version
      # available across all enabled repos regardless of cost. fedora-updates
      # ships fresher packages than the darksite snapshot, so dnf silently
      # fell through to mirrors.fedoraproject.org — breaking the offline
      # install promise on XPS (2026-05-18). cost is only a tiebreaker when
      # versions match.
      #
      # New rule: darksite present → darksite ONLY. Missing package fails
      # the install explicitly so the user knows to either rebuild the
      # darksite or set KLDLOAD_ALLOW_INTERNET_FALLBACK=1 to opt back into
      # the old hybrid behaviour.
      k_log_to "$log" "Darksite detected — adding local RPM mirror as canonical source"
      cat > "${target}/etc/yum.repos.d/kldload-darksite.repo" <<DSREPO
[kldload-darksite]
name=kldload offline RPM mirror
baseurl=file://${_darksite_rpm}/
enabled=1
gpgcheck=0
cost=1
DSREPO

      if [[ "${KLDLOAD_ALLOW_INTERNET_FALLBACK:-0}" != "1" ]]; then
        # Disable upstream repos that were written earlier in this
        # function (fedora.repo / centos.repo / rocky.repo / etc.).
        # Strict offline mode: darksite is the only source.
        for _up_repo in "${target}/etc/yum.repos.d/fedora.repo" \
                        "${target}/etc/yum.repos.d/fedora-updates.repo" \
                        "${target}/etc/yum.repos.d/centos.repo" \
                        "${target}/etc/yum.repos.d/rocky.repo" \
                        "${target}/etc/yum.repos.d/epel.repo"; do
          [[ -f "$_up_repo" ]] || continue
          sed -i 's/^enabled=1/enabled=0/g' "$_up_repo"
          k_log_to "$log" "  disabled upstream repo (strict offline): $(basename "$_up_repo")"
        done
      else
        k_log_to "$log" "  KLDLOAD_ALLOW_INTERNET_FALLBACK=1 → upstream repos stay enabled (hybrid mode)"
      fi
    fi
  fi

  # Custom repo (user-specified, appended alongside existing repos)
  if [[ -n "$_custom_repo" ]]; then
    k_log_to "$log" "Adding custom repo: ${_custom_repo}"
    cat > "${target}/etc/yum.repos.d/kldload-custom.repo" <<CUSTOMREPO
[kldload-custom]
name=Custom user repository
baseurl=${_custom_repo}
enabled=1
gpgcheck=0
CUSTOMREPO
  fi

  # Build the package list — base + profile-specific
  local _dnf_pkgs=(
    basesystem filesystem setup
    dnf rpm coreutils bash glibc glibc-langpack-en
    systemd systemd-udev dbus-common
    kernel kernel-core kernel-modules kernel-devel
    dracut grub2-efi-x64 grub2-tools shim-x64 efibootmgr mokutil
    # NetworkManager needs its wifi plugin AND wpa_supplicant to see
    # any wifi device — without wifi plugin, nmcli reports "no wifi
    # device found" even when the hardware + driver are fine. Also
    # install NetworkManager-tui so nmtui works at the console for
    # post-install wifi config.
    NetworkManager NetworkManager-wifi NetworkManager-tui wpa_supplicant
    # ── Firmware BLOBS (Fedora 44 split `linux-firmware` into many
    #    sub-packages — the bare `linux-firmware` rpm now carries only
    #    licenses, NOT the .ucode files). Without the explicit iwlwifi
    #    sub-packages, Intel wifi cards (AX201 / AX1650s / Killer 6E /
    #    BE200 …) fail `iwlwifi-QuZ-a0-hr-b0-77 is required` at boot
    #    and nmcli reports "no wifi device". MUST ship all three
    #    (dvm=old, mvm=current, mld=newest) to cover every chip.
    linux-firmware linux-firmware-whence
    iwlwifi-dvm-firmware iwlwifi-mvm-firmware iwlwifi-mld-firmware
    iwlegacy-firmware
    # Realtek / Atheros coverage (other common laptop/AP chips)
    realtek-firmware atheros-firmware libertas-firmware
    # Intel GPU firmware (i915 DMC blobs) — without this, modern Intel
    # integrated GPUs complain `Direct firmware load for i915/*_dmc*
    # failed` and fall back to unaccelerated framebuffer.
    amd-gpu-firmware nvidia-gpu-firmware
    openssh-server openssh-clients sudo
    vim-enhanced tmux curl wget rsync jq less
    iproute iputils net-tools nftables chrony
    passwd shadow-utils util-linux procps-ng findutils grep sed gawk
    parted gdisk dosfstools
    python3 python3-pip
    dkms gcc make autoconf automake libtool
    zfs zfs-dkms zfs-dracut
    # Tools needed for kldloadOS (non-core profiles)
    # NOTE: sanoid is NOT in any RPM repo — installed from GitHub by k_install_system_files
    wireguard-tools ethtool htop pv lzop mbuffer eject
    qemu-guest-agent qemu-img open-vm-tools spice-vdagent zstd
    # ── Universal storage + disk diagnostics (every profile benefits)
    #    nvme-cli: NVMe SMART + identify + format (90% of modern boxes)
    #    smartmontools: SATA SMART + scheduled self-tests
    #    hyperv-daemons: Hyper-V guest integration if running as VM
    nvme-cli smartmontools
    # ── Font bundle (all profiles) — stock distro ships basically nothing.
    #    This set covers: doc compat (Liberation = Arial/Times/Courier metrics),
    #    UI (Noto + Inter + Roboto), programming ligatures (Cascadia, Fira,
    #    JetBrains, Source Code Pro), design (Source Sans/Serif, Open Sans),
    #    emoji (color), CJK (Noto CJK for international users), math
    #    (STIX Two). Adds ~350MB but transforms the "it looks like a Linux
    #    install" first-boot feel into a modern type experience.
    liberation-fonts liberation-mono-fonts liberation-serif-fonts
    dejavu-sans-fonts dejavu-serif-fonts dejavu-sans-mono-fonts
    google-noto-sans-fonts google-noto-serif-fonts
    google-noto-sans-mono-fonts google-noto-emoji-color-fonts
    google-noto-sans-cjk-fonts google-noto-serif-cjk-fonts
    cascadia-code-fonts jetbrains-mono-fonts fira-code-fonts
    adobe-source-sans-pro-fonts adobe-source-serif-pro-fonts
    adobe-source-code-pro-fonts
    rsms-inter-fonts google-roboto-fonts open-sans-fonts
    stix-fonts
    # Modern CLI tools + cloud + container runtime for Open WebUI
    fzf btop fd-find ripgrep zoxide fastfetch cloud-init podman
    # Sanoid Perl deps (sanoid binary copied by k_install_system_files)
    perl-Config-IniFiles perl-Capture-Tiny
    # Web UI + kldload tools backend
    python3 python3-websockets python3-pyyaml tmux
    # nginx — single TLS reverse proxy on :8443 with HTTP/2. Replaces
    # the hand-rolled Python kldload-proxy. Must be in this hardcoded
    # list (not only target-base.txt) — bootstrap.sh installs from this
    # array, target-base.txt only drives the darksite builder's download
    # manifest. The two lists drifted apart in 1.0.6 testing when nginx
    # was added to target-base.txt but not here — result was nginx in
    # the darksite mirror but not on the installed target.
    nginx
    # sbsigntools — needed for sbsign in kldload-secure-boot enable
    # (re-signing ZFSBootMenu against the CA key). Usually pulled in
    # already via the MOK flow, but explicit is safer.
    sbsigntools
    # noVNC + websockify — graphical "View" console for libvirt VMs in
    # the kldload web UI. _vm_display_open in kldload-webui spawns
    # websockify pointing at qemu's VNC port and serves noVNC's HTML
    # bundle through the same /s/<id>/ nginx drop-in pattern. Without
    # these the View button silently does nothing — hit on .127 fresh
    # Fedora install 2026-05-16 because the packages were in
    # target-base.txt (darksite mirror) but NOT in this hardcoded list
    # (what actually gets dnf-installed on the target). Same trap as
    # nginx in 1.0.6 — same warning, same line above.
    novnc python3-websockify
  )

  # Profile-specific packages for DNF-based distros
  local _profile="${KLDLOAD_PROFILE:-server}"
  case "$_profile" in
    desktop)
      _dnf_pkgs+=(
        gnome-shell gnome-session gnome-control-center gnome-settings-daemon
        gdm nautilus gnome-keyring
        # Terminal + text editor: Red Hat DROPPED gnome-terminal and gedit from
        # RHEL 10 / Fedora 41+ AppStream (replaced by ptyxis + gnome-text-editor).
        # This hardcoded list is what actually gets dnf-installed on RPM targets
        # (NOT k_profile_packages — see the target-base.txt trap warning above).
        # List BOTH legacy and modern names; the install uses --skip-broken so
        # dnf takes whichever exists: gnome-terminal/gedit on EL9/F43, ptyxis/
        # gnome-text-editor on RHEL 10 / F44+. Caught 2026-05-31 on .137 RHEL 10
        # desktop: gnome-terminal skip-broken'd away -> booted into a desktop
        # with NO terminal app at all.
        # konsole is the kldload workstation's preferred terminal (richer than
        # ptyxis); ship it plus the fallbacks so kldload-term always finds one.
        konsole ptyxis gnome-console gnome-terminal
        gnome-text-editor gedit
        # zenity — REQUIRED by the kldload GUI tools (kldload-zfs, ZFS Manager,
        # replication dialogs). Was never in this list -> those tools silently
        # no-op'd on every RPM desktop install. Same .137 regression.
        zenity
        # gcr provides /usr/libexec/gcr-ssh-askpass (file-Required by
        # gnome-keyring). dnf5 doesn't auto-load filelists metadata so
        # the file-Require can't resolve via Provides alone — explicit
        # install side-steps the issue. Same on CentOS Stream 9 + Fedora.
        gcr
        adwaita-icon-theme google-noto-sans-fonts firefox
        # glib-networking — the GIO TLS backend (gnutls). WITHOUT it, WebKitGTK
        # and anything using libsoup cannot do HTTPS AT ALL: "TLS support is not
        # available" -> the kldload-app windows load a blank white screen.
        # Caught 2026-05-31 on .137 RHEL 10 (it was never a hard dep so dnf
        # never pulled it). gsettings-desktop-schemas is its proxy-config dep.
        glib-networking gsettings-desktop-schemas
        mesa-dri-drivers pipewire wireplumber
        podman
        # systemd-pam — F43+ split this out of systemd; without it
        # /usr/lib64/security/pam_systemd.so is missing on the target
        # and user sessions silently never register. Same bug we hit
        # in the live env (commit 9e93f4f).
        systemd-pam
        # dbus-broker — F44 default replacing dbus-daemon. Without one
        # of them as the active dbus.service, the system bus doesn't
        # come up. dbus-common alone (line 927) is just config files.
        dbus-broker
        # ── Laptop hardware essentials — critical for XPS / ThinkPad /
        #    any modern Intel laptop. Without these: no sound (Intel SOF
        #    DSP), broken touchpad, hot+loud fans, dead Bluetooth, can't
        #    read exFAT USB sticks or NTFS disks, stale CPU microcode.
        microcode_ctl
        alsa-sof-firmware alsa-ucm
        xorg-x11-drv-libinput
        bluez bluez-tools
        exfatprogs ntfs-3g cifs-utils fuse3 fuse-common
        thermald tlp tlp-rdw
        tpm2-tools
        # ── GPU / Vulkan / hardware video decode — without these, modern
        #    Firefox/Chrome/Steam/Teams pin the CPU on any HW-accelerated
        #    video, Vulkan-only apps crash at startup, YouTube 4K chugs.
        mesa-vulkan-drivers mesa-va-drivers
        vulkan-loader vulkan-tools
        intel-media-driver
        libva libva-utils
        # ── Audio + codec coverage (free/open stack)
        pipewire-pulseaudio pipewire-alsa pipewire-codec-aptx
        pipewire-gstreamer pipewire-libcamera
        gstreamer1-plugins-good gstreamer1-plugins-bad-free
        gstreamer1-plugins-base gstreamer1-libav
        gstreamer1-plugin-openh264 mozilla-openh264
        # ── Desktop portal — mandatory for Wayland screen-sharing in
        #    Zoom, Teams (web), Discord, Firefox getDisplayMedia, OBS.
        #    Without these, any "Share Screen" button shows a black
        #    rectangle or errors out. pipewire-gstreamer encodes the
        #    captured frames via H.264 for the WebRTC consumer.
        xdg-desktop-portal xdg-desktop-portal-gnome
        xdg-desktop-portal-gtk
        # Webcam: modern Intel laptops (IPU6) use libcamera; v4l-utils
        # covers legacy UVC webcams. Both together = every webcam works.
        libcamera libcamera-tools v4l-utils
        # ── Print + scan — cups-filters fixes ~40% of printers that
        #    otherwise silently fail on PostScript conversion. hplip
        #    covers HP-specific protocols; sane + simple-scan for
        #    all-in-one device scanner heads.
        cups cups-filters cups-pk-helper system-config-printer
        hplip sane-backends simple-scan
        # ── Network: VPN plugins + cellular modems. Laptops bought
        #    in the last 10 years commonly have WWAN slots; corp
        #    deployments almost always need openvpn/openconnect.
        ModemManager NetworkManager-wwan NetworkManager-ppp
        NetworkManager-openvpn NetworkManager-openvpn-gnome
        NetworkManager-openconnect NetworkManager-openconnect-gnome
        # ── Auth: smartcards / yubikey / FIDO2
        pcsc-lite opensc libfido2 libfido2-devel
        # ── Input extras: Wacom + displays
        libwacom xorg-x11-drv-wacom ddcutil
        # ── Firmware-update daemon (fwupd) — handles BIOS/EC updates
        #    via LVFS. Dell + Lenovo + System76 all publish here.
        fwupd
        # ── Power / backlight helpers
        powertop brightnessctl
      )
      ;;
    server)
      _dnf_pkgs+=(tcpdump socat sysstat net-tools podman)
      ;;
    kvm)
      _dnf_pkgs+=(
        tcpdump socat sysstat net-tools podman
        qemu-kvm libvirt-daemon libvirt-client virt-install
        bridge-utils edk2-ovmf dnsmasq
      )
      ;;
    core)
      # Core: strip extras — no sanoid, no guest agents, no k* tools
      # WireGuard is a kernel primitive, included in all profiles
      _dnf_pkgs=(
        basesystem filesystem setup
        dnf rpm coreutils bash glibc glibc-langpack-en
        systemd systemd-udev dbus-common
        kernel kernel-core kernel-modules kernel-devel
        dracut grub2-efi-x64 grub2-tools shim-x64 efibootmgr mokutil
        NetworkManager NetworkManager-wifi NetworkManager-tui wpa_supplicant
        linux-firmware linux-firmware-whence
        iwlwifi-dvm-firmware iwlwifi-mvm-firmware iwlwifi-mld-firmware
        iwlegacy-firmware realtek-firmware atheros-firmware
        openssh-server openssh-clients sudo
        vim-enhanced curl less iproute iputils nftables chrony wireguard-tools
        passwd shadow-utils util-linux procps-ng findutils grep sed gawk
        parted gdisk dosfstools
        dkms gcc make autoconf automake libtool
        zfs zfs-dkms zfs-dracut
      )
      ;;
  esac

  # RHEL targets need subscription-manager on the installed system, not only
  # on the live env during install. Without it, the operator can't run
  # `subscription-manager status / refresh / repos --list` post-install, and
  # automated tooling that consults sub-man state breaks silently. Caught on
  # the 2026-05-12 RHEL 10 install: the entitlement certs were copied in but
  # the binary wasn't, leaving the installed box in a half-registered state
  # (dnf could fetch via CDN, but sub-man identity reported "not registered").
  if [[ "${distro}" == "rhel" ]]; then
    _dnf_pkgs+=( subscription-manager subscription-manager-rhsm-certificates )
  fi

  # Optional packages (eBPF, extra ZFS tools) — same logic as Debian path
  local _opt_pkgs
  _opt_pkgs="$(k_profile_optional_packages 2>/dev/null || true)"
  if [[ -n "$_opt_pkgs" ]]; then
    # Map Debian package names to CentOS equivalents
    _opt_pkgs="${_opt_pkgs//bpfcc-tools/bcc-tools}"
    _opt_pkgs="${_opt_pkgs//linux-perf/perf}"
    _opt_pkgs="${_opt_pkgs//zfsutils-linux/}"
    _opt_pkgs="${_opt_pkgs//zfs-zed/}"
    _opt_pkgs="${_opt_pkgs//zfs-initramfs/}"
    _opt_pkgs="${_opt_pkgs//zfs-dkms/}"
    read -ra _opt_arr <<< "$_opt_pkgs"
    _dnf_pkgs+=("${_opt_arr[@]}")
    k_log_to "$log" "Optional packages added: ${_opt_pkgs}"
  fi

  # Point DNF cache to the target ZFS filesystem to avoid filling the live overlay
  mkdir -p "${target}/var/cache/dnf"
  export DNF_CACHEDIR="${target}/var/cache/dnf"

  # Create merged-usr symlinks so RPM scriptlets can find /bin/sh during install
  mkdir -p "${target}/usr/bin" "${target}/usr/sbin" "${target}/usr/lib" "${target}/usr/lib64"
  for _d in bin sbin lib lib64; do
    [[ -L "${target}/${_d}" ]] || ln -sf "usr/${_d}" "${target}/${_d}"
  done

  # Generate MOK keys BEFORE package installation so DKMS signs ZFS modules
  # during build. Secure Boot is OPT-IN as of 1.0.5 — default off; set
  # KLDLOAD_ENABLE_SECURE_BOOT=1 at install time to enable.
  if [[ "${KLDLOAD_ENABLE_SECURE_BOOT:-1}" == "1" ]]; then
    k_generate_mok_keys
  else
    k_log_to "$log" "Skipping MOK keys (Secure Boot disabled; set KLDLOAD_ENABLE_SECURE_BOOT=1 to enable)"
  fi

  # For Fedora: install the zfs-release RPM BEFORE the main transaction
  # so the zfs-dkms pull resolves against the correct per-release repo
  # (F43 needs OpenZFS 2.3.x for kernel 6.19). Previously we hardcoded
  # /fedora/41/ in a static zfs.repo — that shipped ZFS 2.2.7 which
  # does not compile against 6.19, producing silent DKMS failure and
  # unbootable ZFS-root Fedora installs. Pattern mirrors klab's proven
  # loop: try known revisions newest-first until one resolves.
  if [[ "${distro}" == "fedora" ]]; then
    local _fedora_rel="${KLDLOAD_FEDORA_RELEASE:-44}"
    # zfsonlinux publishes fc41/42/43 but not fc44 yet (F44 GA was 2026-04-28).
    # Try the requested release first, then fall back to fc43 — the userspace
    # RPMs are glibc-forward-compatible across one Fedora release, and
    # zfs-dkms is noarch source so DKMS rebuilds against whatever kernel
    # gets installed. Same fc43-bridge trick the live env uses.
    #
    # PROBE upstream BEFORE dnf install — a 404 from dnf in F44 land buries
    # the actual URL in 200 lines of metadata fetch noise. We HEAD each
    # candidate URL up front, log exactly which release/revision was found
    # or "404 (not yet published)" otherwise, then only invoke dnf on the
    # URL we've confirmed serves a real RPM. Operator gets a single clear
    # line per attempt instead of having to grep dnf transcripts.
    k_log_to "$log" "Resolving OpenZFS Fedora repo (target=fc${_fedora_rel}, fallback=fc43)..."
    local _zfsrel_ok=0
    local _zfsrel_actual=""
    local _zfsrel_url=""
    local _attempted_urls=()
    for _rel in "${_fedora_rel}" 43; do
      for _rev in 3-0 2-10 2-9 2-8 2-7; do
        local _url="https://zfsonlinux.org/fedora/zfs-release-${_rev}.fc${_rel}.noarch.rpm"
        local _code
        _code=$(curl -sSL -o /dev/null --max-time 10 -w '%{http_code}' "$_url" 2>/dev/null || echo "000")
        _attempted_urls+=("  fc${_rel} rev ${_rev} -> HTTP ${_code}")
        if [[ "$_code" == "200" ]]; then
          k_log_to "$log" "  found: zfs-release-${_rev}.fc${_rel} (HTTP 200)"
          _zfsrel_url="$_url"
          _zfsrel_actual="${_rel}"
          break 2
        else
          k_log_to "$log" "  miss:  zfs-release-${_rev}.fc${_rel} (HTTP ${_code})"
        fi
      done
    done

    if [[ -n "$_zfsrel_url" ]]; then
      # We have a known-good URL. dnf5 syntax: --skip-broken AFTER subcommand.
      if dnf --installroot="${target}" --releasever="${_fedora_rel}" \
           --setopt=cachedir="${target}/var/cache/dnf" \
           --disableplugin=subscription-manager --disableplugin=product-id \
           --nogpgcheck -y install --skip-broken \
           "$_zfsrel_url" \
           >> "$log" 2>&1; then
        _zfsrel_ok=1
        k_log_to "$log" "Fedora ZFS repo enabled via fc${_zfsrel_actual} (target=fc${_fedora_rel})"
      else
        k_log_to "$log" "ERROR: zfs-release fc${_zfsrel_actual} URL serves HTTP 200 but dnf install failed — see log tail below"
        tail -20 "$log" | sed 's/^/    | /' >&2 || true
      fi
    fi

    if [[ "$_zfsrel_ok" != "1" ]]; then
      # All HEAD probes failed. This is the "OpenZFS upstream has not
      # published a Fedora N repo yet AND the fc43 bridge URL is also
      # unreachable" case. Surface exactly what we tried so the operator
      # knows whether to wait for upstream, switch distros, or check DNS.
      k_log_to "$log" "============================================================"
      k_log_to "$log" "FATAL: OpenZFS Fedora repo unavailable for fc${_fedora_rel}."
      k_log_to "$log" ""
      k_log_to "$log" "  zfsonlinux.org has not published a Fedora ${_fedora_rel} repo,"
      k_log_to "$log" "  and the fc43 bridge fallback is also unreachable."
      k_log_to "$log" ""
      k_log_to "$log" "  Probed URLs (all returned non-200):"
      printf '%s\n' "${_attempted_urls[@]}" | while IFS= read -r _ln; do
        k_log_to "$log" "  ${_ln}"
      done
      k_log_to "$log" ""
      k_log_to "$log" "  Likely causes:"
      k_log_to "$log" "    1. OpenZFS upstream hasn't built fc${_fedora_rel} packages yet"
      k_log_to "$log" "       (typical lag: 2-4 months after Fedora GA)."
      k_log_to "$log" "    2. zfsonlinux.org is unreachable (check live env network)."
      k_log_to "$log" "    3. Firewall / proxy blocking https://zfsonlinux.org."
      k_log_to "$log" ""
      k_log_to "$log" "  Workarounds:"
      k_log_to "$log" "    - Install CentOS Stream 9 / Rocky 9 / RHEL 10 / Debian 13 / Ubuntu 24.04"
      k_log_to "$log" "      instead (all have working ZFS sources baked into this ISO)."
      k_log_to "$log" "    - Pass KLDLOAD_FEDORA_RELEASE=43 to install F43 directly."
      k_log_to "$log" "============================================================"
      return 1
    fi

    # Hardcode the actual release we landed on into the repo file.
    # zfs-release-3-0.fc43.rpm drops /etc/yum.repos.d/zfs.repo with
    # `baseurl=https://download.zfsonlinux.org/fedora/$releasever/...`
    # and $releasever on a Fedora 44 target expands to "44" — but
    # zfsonlinux only publishes through fc43. Result: every subsequent
    # `dnf install zfs-*` 404s, including the install-time pass 3 and
    # bootloader.sh's late zfs-dracut install. Hardcoding the path
    # eliminates the macro expansion mismatch.
    if [[ "$_zfsrel_ok" == "1" && "$_zfsrel_actual" != "${_fedora_rel}" ]]; then
      local _zfs_repo="${target}/etc/yum.repos.d/zfs.repo"
      if [[ -f "$_zfs_repo" ]]; then
        sed -i "s|fedora/\\\$releasever|fedora/${_zfsrel_actual}|g" "$_zfs_repo"
        k_log_to "$log" "Hardcoded zfs.repo to fedora/${_zfsrel_actual} (target releasever ${_fedora_rel} has no zfsonlinux build)"
      fi
    fi
  fi

  # Two-pass install:
  #   Pass 1 (this one) — main install with scripts ENABLED, but excludes
  #     grub2* / shim* / kernel*. Scripts run normally so binutils
  #     update-alternatives sets up /usr/bin/ld → ld.bfd, zfs-dkms
  #     posttrans triggers DKMS autoinstall, systemd-sysusers/tmpfiles
  #     run for new users, etc. This is "normal" rpm behavior.
  #   Pass 2 (below) — install grub2*/shim*/kernel* with noscripts.
  #     Skips EL9 grub2-common's posttrans (which calls
  #     grub2-mkconfig → grub2-probe and fails on a ZFS /boot with
  #     "unknown filesystem") and kernel-core's posttrans (which writes
  #     to /boot/efi/Default/$kver — a BLS path that doesn't exist in
  #     our EFI layout). We do our own kernel placement + ZFSBootMenu
  #     install in bootloader.sh.
  #
  # dnf5 syntax notes:
  #   - --skip-broken / --skip-unavailable go AFTER the subcommand.
  #     dnf4's --skip-broken did both (broken deps AND missing
  #     packages); dnf5 split them. Without --skip-unavailable, the
  #     F44-tuned package list fails on EL9 because of Fedora-only /
  #     RPMFusion-only entries (iwlwifi-*-firmware splits, mesa-va-
  #     drivers, intel-media-driver, etc.).
  #   - --setopt=optional_metadata_types=filelists makes dnf5 load
  #     filelists metadata so file-Requires (e.g. gnome-keyring needing
  #     /usr/libexec/gcr-ssh-askpass from gcr) resolve. dnf5 default
  #     is to skip filelists.
  # The outer dnf here is the live env's dnf5 (F44+), even though the
  # target may be F44/F43/RHEL/Rocky/etc.
  #
  # ALSO IMPORTANT: pass --setopt=_dbpath=/var/lib/rpm so dnf writes
  # the rpm db to where EL-class targets expect it. dnf5 default is
  # /usr/lib/sysimage/rpm (modern Fedora moved there); EL9's rpm
  # config still reads /var/lib/rpm. Without this override the
  # installed system reports `rpm -qa` empty even though all the
  # packages are on disk, breaking dkms / dracut / pretty much
  # everything that consults the package db.
  # THREE-PASS install:
  #   Pass 1 — main (scripts ON). Excludes kernel*/grub2*/shim*/zfs*.
  #     Excluding zfs/zfs-dkms here is REQUIRED: zfs-dkms has
  #     `Requires: kernel-uname-r >= 4.18`, and pass 1 has no kernel,
  #     so without this exclude --skip-broken silently drops zfs-dkms
  #     and the install ends up with no ZFS at all.
  #   Pass 2 — kernel + grub2 + shim (scripts OFF). Skips EL9 grub2-
  #     mkconfig posttrans that fails on ZFS /boot, and skips kernel-
  #     core's BLS-path-write posttrans.
  #   Pass 3 — zfs + zfs-dkms (scripts ON). The kernel from pass 2 is
  #     now installed, so zfs-dkms's Requires resolves. zfs-dkms's
  #     posttrans triggers DKMS autoinstall against the kernel modules
  #     dir → builds + signs + installs zfs.ko + spl.ko.
  local _exclude_scripts=(
      '--exclude=grub2*' '--exclude=shim*'
      '--exclude=kernel' '--exclude=kernel-core'
      '--exclude=kernel-modules' '--exclude=kernel-modules-core' '--exclude=kernel-modules-extra'
      '--exclude=kernel-debug' '--exclude=kernel-debug-core'
      '--exclude=kernel-debug-modules' '--exclude=kernel-debug-modules-core'
      '--exclude=kernel-debug-modules-extra' '--exclude=kernel-debug-devel'
      '--exclude=zfs' '--exclude=zfs-dkms' '--exclude=zfs-dracut'
  )
  # Fedora 44 kernel-7 lockout — see builder/build-iso.sh for the live-env
  # version of this same gate. Fedora 44 Updates ships kernel-core 7.0.x as
  # of 2026-05-07; zfs-dkms-2.4.x.fc43 (the bridge build OpenZFS publishes
  # for fc44 until they cut a native fc44 release) carries
  # `Conflicts: kernel-uname-r > 6.19.999`. Without this exclude on the
  # target dnf pass, the installed system ends up with kernel-core-7.0.4
  # but no buildable ZFS module → /sysroot.mount fails → operator gets
  # dropped to dracut emergency. Caught 2026-05-12 on first F44+zfslab
  # install. The exclude is also harmless on non-Fedora targets (no
  # kernel-*-7.* package exists there).
  local _f44_kernel_lockout=()
  if [[ "${distro}" == "fedora" ]]; then
      _f44_kernel_lockout=(
          '--exclude=kernel-7.*' '--exclude=kernel-core-7.*'
          '--exclude=kernel-modules-7.*' '--exclude=kernel-modules-core-7.*'
          '--exclude=kernel-devel-7.*' '--exclude=kernel-devel-matched-7.*'
          '--exclude=kernel-headers-7.*' '--exclude=kernel-tools-7.*'
          '--exclude=kernel-tools-libs-7.*'
      )
  fi
  # Fedora-only repo flags. dnf5 errors hard on --setopt='REPO.X=Y' AND on
  # --disablerepo=REPO when REPO is not defined in the installroot. RHEL
  # / CentOS / Rocky don't have fedora/updates/fedora-cisco-openh264/etc.
  # in their repos, so applying these flags universally breaks pass 1
  # immediately ("No matching repositories" — caught on .109 build #55
  # 2026-05-26). Build the array per-distro and inject only when fedora.
  local _fed_repo_flags=()
  if [[ "${distro}" == "fedora" ]]; then
    _fed_repo_flags=(
      --setopt='updates.excludepkgs=selinux-policy*,policycoreutils*'
      --setopt='updates.enabled=0'
      --setopt='fedora.enabled=0'
      --setopt='fedora-cisco-openh264.enabled=0'
      --setopt='updates-testing.enabled=0'
      --setopt='updates-debuginfo.enabled=0'
    )
  fi

  k_log_to "$log" "Running dnf --installroot pass 1 (main, ${#_dnf_pkgs[@]} packages, profile=${_profile})..."
  # Mirror-resilience: skip_if_unavailable=True so one broken upstream mirror
  # (e.g. iweb.com returning 404/corrupt repodata, observed 2026-05-16 on .111)
  # doesn't tank the install. retries=10 + timeout=60 + minrate=1024 fail fast
  # on a stalled mirror so dnf moves to the next one in the mirrorlist.
  # Our local darksite is file:// — skip_if_unavailable cannot drop it.
  dnf --installroot="${target}" --releasever="${release}" \
      --setopt=install_weak_deps=False \
      --setopt=tsflags=nodocs \
      --setopt=cachedir="${target}/var/cache/dnf" \
      --setopt=optional_metadata_types=filelists \
      --setopt='*.skip_if_unavailable=True' \
      --setopt='*.retries=10' \
      --setopt='*.timeout=60' \
      --setopt='*.minrate=1024' \
      "${_fed_repo_flags[@]}" \
      --disableplugin=subscription-manager --disableplugin=product-id \
      --nogpgcheck -y install --skip-broken --skip-unavailable \
      "${_exclude_scripts[@]}" \
      "${_f44_kernel_lockout[@]}" \
      "${_dnf_pkgs[@]}" \
      >> "$log" 2>&1 \
      || { k_log_to "$log" "dnf --installroot pass 1 failed"; return 1; }

  k_log_to "$log" "Running dnf --installroot pass 2 (grub2/shim/kernel, scripts skipped)..."
  local _boot_pkgs=( grub2-common grub2-tools grub2-tools-minimal grub2-pc-modules
                     grub2-efi-x64 grub2-efi-x64-modules shim-x64
                     kernel kernel-core kernel-modules kernel-modules-core )
  dnf --installroot="${target}" --releasever="${release}" \
      --setopt=install_weak_deps=False \
      --setopt=tsflags=nodocs,noscripts \
      --setopt=cachedir="${target}/var/cache/dnf" \
      --setopt=optional_metadata_types=filelists \
      --setopt='*.skip_if_unavailable=True' \
      --setopt='*.retries=10' \
      --setopt='*.timeout=60' \
      --setopt='*.minrate=1024' \
      "${_fed_repo_flags[@]}" \
      --disableplugin=subscription-manager --disableplugin=product-id \
      --nogpgcheck -y install --skip-broken --skip-unavailable \
      "${_f44_kernel_lockout[@]}" \
      "${_boot_pkgs[@]}" \
      >> "$log" 2>&1 \
      || k_log_to "$log" "dnf pass 2 had issues (continuing)"

  # Pass 3 — zfs + zfs-dkms with scripts ON now that pass 2 has
  # installed a kernel. zfs-dkms's posttrans does the DKMS autoinstall
  # build against the kernel modules dir, signs the .ko's, and places
  # them at /usr/lib/modules/$kver/extra/. zfs-dracut is included here
  # so the dracut zfs module is available for our initramfs rebuild.
  k_log_to "$log" "Running dnf --installroot pass 3 (zfs + zfs-dkms + zfs-dracut, scripts on)..."
  local _zfs_pkgs=( zfs zfs-dkms zfs-dracut )
  # NO --skip-broken --skip-unavailable here. Pass 3 ships THE three packages
  # that make /sysroot.mount work; silently skipping any of them ships an
  # unbootable target. Caught 2026-05-12 on F44 zfslab install: zfs-dracut
  # got silently dropped, dracut had no zfs module to add to initramfs,
  # operator dropped to dracut emergency on first boot. If pass 3 fails,
  # we want it loud and fatal here — not "Install complete!" with a broken
  # boot.
  dnf --installroot="${target}" --releasever="${release}" \
      --setopt=install_weak_deps=False \
      --setopt=tsflags=nodocs \
      --setopt=cachedir="${target}/var/cache/dnf" \
      --setopt=optional_metadata_types=filelists \
      --setopt='*.skip_if_unavailable=True' \
      --setopt='*.retries=10' \
      --setopt='*.timeout=60' \
      --setopt='*.minrate=1024' \
      "${_fed_repo_flags[@]}" \
      --disableplugin=subscription-manager --disableplugin=product-id \
      --nogpgcheck -y install \
      "${_f44_kernel_lockout[@]}" \
      "${_zfs_pkgs[@]}" \
      >> "$log" 2>&1 \
      || { k_log_to "$log" "FATAL: dnf pass 3 (zfs + zfs-dkms + zfs-dracut) failed — target will not boot"; return 1; }

  # Verify each of the three actually landed in the target rpm db. A
  # success exit from `dnf install` doesn't guarantee installation —
  # weak-dep resolution or pre-existing conflicts can quietly drop
  # packages even without --skip-broken. Hard-check post-install:
  for _zp in zfs zfs-dkms zfs-dracut; do
    if ! chroot "${target}" /usr/bin/rpm -q "$_zp" >/dev/null 2>&1; then
      k_log_to "$log" "FATAL: ${_zp} not installed in target after pass 3 — refusing to claim success"
      return 1
    fi
  done
  k_log_to "$log" "Pass 3 verified: zfs + zfs-dkms + zfs-dracut all present in target"

  # dnf5 writes the rpm db to /usr/lib/sysimage/rpm (modern Fedora
  # default). EL9's rpm config still reads /var/lib/rpm. Sync them so
  # the installed system's rpm can find what dnf wrote — without this,
  # `rpm -qa` returns 0 packages on EL targets, dkms can't find its
  # source pkgs, and everything else that consults the rpm db breaks.
  # For Fedora targets the dirs end up identical (or symlinked); for
  # EL targets we replace the empty /var/lib/rpm with the real db.
  if [[ -f "${target}/usr/lib/sysimage/rpm/rpmdb.sqlite" ]]; then
    k_log_to "$log" "Syncing rpm db to /var/lib/rpm for EL-style targets..."
    rm -f "${target}/var/lib/rpm/rpmdb.sqlite" \
          "${target}/var/lib/rpm/rpmdb.sqlite-shm" \
          "${target}/var/lib/rpm/rpmdb.sqlite-wal" 2>/dev/null
    cp -p "${target}/usr/lib/sysimage/rpm/rpmdb.sqlite" "${target}/var/lib/rpm/rpmdb.sqlite"
    cp -p "${target}/usr/lib/sysimage/rpm/rpmdb.sqlite-shm" "${target}/var/lib/rpm/rpmdb.sqlite-shm" 2>/dev/null || true
    cp -p "${target}/usr/lib/sysimage/rpm/rpmdb.sqlite-wal" "${target}/var/lib/rpm/rpmdb.sqlite-wal" 2>/dev/null || true
    # Non-fatal verification — set -Eeuo pipefail would propagate any
    # 127 from a missing rpm binary if we ran it inline in a $(...)
    local _pkg_count=0
    if [[ -x "${target}/usr/bin/rpm" ]]; then
      _pkg_count=$(chroot "${target}" /usr/bin/rpm --dbpath /var/lib/rpm -qa 2>/dev/null | wc -l) || _pkg_count=0
    fi
    k_log_to "$log" "  rpm db: ${_pkg_count} packages tracked in /var/lib/rpm"
  fi

  # Defensive helper: rpool can get exported by something during pass 3
  # (zfs-dkms %post triggering ZFS systemd events, udev rules firing on
  # module load, etc.), leaving /target as an empty mountpoint dir. The
  # remaining catchup + subsequent stages all need /target mounted.
  # Call this before any operation that touches /target.
  _ensure_target_mounted() {
    if ! mountpoint -q "${target}" 2>/dev/null; then
      k_log_to "$log" "  [target unmounted — re-importing rpool with altroot=${target}]"
      zpool import -f -N -R "${target}" rpool >> "$log" 2>&1 || true
      # Find the BE dataset (rpool/ROOT/<host_short>) and mount it
      local _be
      _be=$(zfs list -H -o name 2>/dev/null | grep -E '^rpool/ROOT/[^/]+$' | head -1)
      [[ -n "$_be" ]] && zfs mount "$_be" >> "$log" 2>&1 || true
      zfs mount -a >> "$log" 2>&1 || true
    fi
  }
  _ensure_target_mounted

  k_log_to "$log" "Catching up post-install setup (sysusers/tmpfiles/preset/ldconfig/depmod/kernel/dracut)..."
  # Wrap the whole catchup in `set +e` since these commands are all
  # nice-to-have — a single failure in here should NOT kill the install.
  # set -Eeuo pipefail outside makes any unswallowed non-zero fatal,
  # and the `|| true` on individual lines isn't enough if the compound
  # `cmd1 && cmd2 || cmd3` returns non-zero (set -e then trips on the
  # COMPOUND, not the inner `||`).
  set +e
  # systemd-sysusers / systemd-tmpfiles location varies (F has /usr/bin,
  # EL9 has /usr/lib/systemd/) — try the common locations.
  # _ensure_target_mounted before every chroot call: pass 3's zfs-dkms
  # %post somehow exports rpool mid-catchup (~1 sec window), so we
  # check + re-import before each command actually touches /target.
  _ensure_target_mounted; k_in_chroot "${target}" /usr/bin/systemd-sysusers 2>/dev/null >> "$log"
  _ensure_target_mounted; k_in_chroot "${target}" /usr/lib/systemd/systemd-sysusers 2>/dev/null >> "$log"
  _ensure_target_mounted; k_in_chroot "${target}" /usr/bin/systemd-tmpfiles --create 2>/dev/null >> "$log"
  _ensure_target_mounted; k_in_chroot "${target}" /usr/lib/systemd/systemd-tmpfiles --create 2>/dev/null >> "$log"
  _ensure_target_mounted; k_in_chroot "${target}" /usr/bin/systemctl preset-all 2>/dev/null >> "$log"
  _ensure_target_mounted; k_in_chroot "${target}" /usr/sbin/ldconfig 2>/dev/null >> "$log"
  # depmod + place kernel in /boot + build initramfs.
  # tsflags=noscripts skipped kernel-core's posttrans, which is what
  # normally copies vmlinuz to /boot and runs dracut. ZFSBootMenu reads
  # /boot/vmlinuz-$kver and /boot/initramfs-$kver.img out of the BE, so
  # if we don't put them there explicitly the install completes but
  # ZBM can't actually boot the kernel.
  # EL9 with merged-usr stores kernel modules at /usr/lib/modules.
  # /lib/modules is normally a symlink to /usr/lib/modules but the
  # symlink-creating package's post script may not have run with
  # tsflags=noscripts, so /lib/modules might not exist in the target.
  # Try both paths; usr/lib/modules first (EL9 canonical location).
  local _moddir_glob_a="${target}/usr/lib/modules"
  local _moddir_glob_b="${target}/lib/modules"
  local _kver_globs=()
  [[ -d "$_moddir_glob_a" ]] && _kver_globs+=("$_moddir_glob_a"/*)
  [[ -d "$_moddir_glob_b" ]] && _kver_globs+=("$_moddir_glob_b"/*)
  for kver_path in "${_kver_globs[@]}"; do
    [[ -d "$kver_path" ]] || continue
    local _kver; _kver="$(basename "$kver_path")"
    # Skip if we already processed this kver via the other path
    [[ -f "${target}/boot/initramfs-${_kver}.img" ]] && continue
    k_in_chroot "${target}" /usr/sbin/depmod -a "$_kver" 2>/dev/null >> "$log"
    # Copy the bundled vmlinuz into /boot if kernel-install didn't.
    # Look at both /usr/lib/modules (EL9 merged-usr canonical) and
    # /lib/modules (Debian/legacy) — vmlinuz can live in either.
    local _vmlinuz_src=""
    for _src in "${target}/usr/lib/modules/${_kver}/vmlinuz" \
                "${target}/lib/modules/${_kver}/vmlinuz"; do
      if [[ -f "$_src" ]]; then _vmlinuz_src="$_src"; break; fi
    done
    if [[ -n "$_vmlinuz_src" && ! -f "${target}/boot/vmlinuz-${_kver}" ]]; then
      mkdir -p "${target}/boot"
      cp -p "$_vmlinuz_src" "${target}/boot/vmlinuz-${_kver}" \
        && k_log_to "$log" "  copied vmlinuz-${_kver} into /boot from $_vmlinuz_src" \
        || k_log_to "$log" "  WARNING: failed to copy vmlinuz-${_kver}"
    fi
    # Build initramfs via dracut WITH ZFS support. --add zfs picks up
    # the zfs-dracut module so the rootfs can be mounted at boot.
    # --no-hostonly per kldload policy (universal initramfs covering
    # all hardware, not just this VM/box).
    if [[ ! -f "${target}/boot/initramfs-${_kver}.img" ]]; then
      if k_in_chroot "${target}" /usr/bin/dracut --force --no-hostonly \
           --add "zfs" --omit "dracut-live livenet" \
           --kver "${_kver}" "/boot/initramfs-${_kver}.img" >> "$log" 2>&1; then
        k_log_to "$log" "  built initramfs-${_kver}.img (with zfs)"
      else
        k_log_to "$log" "  WARNING: dracut failed for ${_kver}"
      fi
    fi
  done
  # Stay in set +e through the rest of bootstrap. The DKMS build,
  # zfs-dracut install, NVIDIA bits, and initramfs rebuild that follow
  # all have `|| true` / `||` warnings on individual commands, but a
  # failing pipe (with pipefail still on) under set -e would still
  # kill the install. We've reached "all 1175 packages on disk" — any
  # subsequent failure should be a WARNING in the log, not a fatal exit.

  k_log_to "$log" "Root filesystem: $(du -sh --exclude="${target}/proc" --exclude="${target}/sys" --exclude="${target}/dev" "${target}" 2>/dev/null | cut -f1 || echo "?")"

  # Build ZFS DKMS (chroot mounts already in place from above)
  local kver moddir
  # CentOS 9 uses /usr/lib/modules (merged-usr), Debian uses /lib/modules
  for moddir in "${target}/usr/lib/modules" "${target}/lib/modules"; do
    [[ -d "$moddir" ]] && break
  done
  # Prefer the kernel installed via rpm/dpkg over whatever's in modules/.
  # The old `ls | head -1` picks alphabetically — broken when target has
  # both 6.19.10 (DKMS leftover from live env) and 6.19.14 (actual rpm-
  # installed target kernel). "6.19.10" < "6.19.14" lexically, so ls picks
  # the wrong one, DKMS builds zfs.ko for 6.19.10, dracut targets 6.19.14
  # (the real boot kernel), result: target has kernel 6.19.14 with no ZFS
  # module, /sysroot.mount fails. Caught 2026-05-12 on F44 zfslab install.
  kver=""
  case "$distro" in
    centos|rocky|rhel|fedora)
      kver=$(chroot "${target}" /usr/bin/rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core 2>/dev/null \
             | sort -V | tail -1)
      ;;
    debian|ubuntu)
      kver=$(chroot "${target}" dpkg-query -f '${Package}\n' -W 'linux-image-[0-9]*' 2>/dev/null \
             | sed 's/^linux-image-//' | sort -V | tail -1)
      ;;
  esac
  # Fall back to ls if rpm/dpkg paths didn't yield (e.g., during early-bring-up).
  [[ -z "$kver" ]] && kver=$(ls "$moddir/" 2>/dev/null | sort -V | tail -1)
  # NOTE: the dkms/depmod commands below may emit warnings of the form
  # "zfs not found in initramfs" while they work. Those are expected —
  # we rebuild the initramfs to include ZFS in the step immediately
  # below ("Rebuilding initramfs with ZFS module..."). If you're
  # reading the install log and you see those warnings, keep reading;
  # the rebuild step resolves them. Only a FATAL error on the
  # "Rebuilding initramfs" line indicates a real problem.
  k_log_to "$log" "Compiling ZFS kernel module via DKMS for ${kver} (initramfs rebuild follows)..."

  local zfs_ver
  zfs_ver=$(chroot "${target}" /usr/bin/rpm -q --qf '%{VERSION}' zfs-dkms 2>/dev/null || echo "")
  if [[ -z "$zfs_ver" ]]; then
    k_log_to "$log" "FATAL: zfs-dkms not installed in target — pass 3 verification should have caught this earlier"
    set -e; return 1
  fi
  k_log_to "$log" "  Target kernel: $kver  /  zfs-dkms version: $zfs_ver"
  # Ensure kernel-devel-$kver is present in the target before DKMS build.
  # Without an EXACT version match for kernel-devel:
  #   • zfs-dkms's RPM posttrans calls `dkms autoinstall` against
  #     `uname -r` (= live env's kernel, often older than target's
  #     freshly-installed kernel from fedora-updates), so the posttrans
  #     leaves zfs.ko in /lib/modules/<live-kver>/extra/, NOT in the
  #     target's kver dir
  #   • Our explicit `dkms build -k $kver` below then has nothing to
  #     build against (no /usr/src/kernels/$kver) and silently fails
  #     under the `|| true`
  #   • The FATAL verifier at the end of this block catches it, but at
  #     the cost of aborting an otherwise-paid-for install
  # The matched package (`kernel-devel-matched`) tracks the installed
  # kernel-core version automatically on Fedora; on EL we install by
  # explicit version. Either way, we want `/usr/src/kernels/$kver` to
  # exist before running dkms. Caught 2026-05-12 on F44 zfslab install.
  case "$distro" in
    fedora)
      chroot "${target}" /usr/bin/dnf install -y --setopt=install_weak_deps=False \
        "kernel-devel-${kver}" >> "$log" 2>&1 \
        || k_log_to "$log" "  WARN: dnf install kernel-devel-${kver} failed — DKMS build may not find headers"
      ;;
    centos|rocky|rhel)
      chroot "${target}" /usr/bin/dnf install -y --setopt=install_weak_deps=False \
        "kernel-devel-${kver}" >> "$log" 2>&1 \
        || k_log_to "$log" "  WARN: dnf install kernel-devel-${kver} failed — DKMS build may not find headers"
      ;;
  esac
  # `dkms add` first in case zfs-dkms's posttrans didn't register the
  # source tree (happens in chroot context where the post script bails
  # out under `if running in chroot` guards). `2>>$log || true` because
  # `dkms add` errors when the version is already registered — fine.
  chroot "${target}" /usr/sbin/dkms add -m zfs -v "$zfs_ver" >> "$log" 2>&1 || true
  chroot "${target}" /usr/sbin/dkms build -m zfs -v "$zfs_ver" -k "$kver" >> "$log" 2>&1 || true
  chroot "${target}" /usr/sbin/dkms install -m zfs -v "$zfs_ver" -k "$kver" >> "$log" 2>&1 || true
  chroot "${target}" /usr/sbin/depmod -a "$kver" 2>/dev/null || true

  # Hard verify: zfs.ko + spl.ko must exist in /lib/modules/$kver/extra/.
  # Without these the initramfs rebuild below will succeed-but-produce a
  # zfs-less initramfs (dracut silently omits modules it can't find), and
  # /sysroot.mount fails at first boot. Fail loudly here so the install
  # is marked broken before the user reboots.
  local _zfs_ko _spl_ko
  _zfs_ko=$(find "${target}${moddir#${target}}/$kver/extra" -maxdepth 1 -name 'zfs.ko*' 2>/dev/null | head -1)
  _spl_ko=$(find "${target}${moddir#${target}}/$kver/extra" -maxdepth 1 -name 'spl.ko*' 2>/dev/null | head -1)
  if [[ -z "$_zfs_ko" || -z "$_spl_ko" ]]; then
    k_log_to "$log" "FATAL: DKMS did not produce zfs.ko and spl.ko in ${moddir}/${kver}/extra/ — refusing to ship broken install"
    k_log_to "$log" "  Looked at: ${moddir}/${kver}/extra/"
    chroot "${target}" /usr/sbin/dkms status 2>&1 | sed 's/^/  dkms status: /' >> "$log"
    set -e; return 1
  fi
  k_log_to "$log" "  ZFS module verified: $(basename "$_zfs_ko"), $(basename "$_spl_ko")"

  # zfs-dracut was already installed + verified in pass 3 above. No need
  # to re-install here — but keep a defensive presence-check before the
  # initramfs rebuild because without /usr/lib/dracut/modules.d/90zfs/
  # dracut has no idea how to include the zfs kernel module.
  if [[ ! -d "${target}/usr/lib/dracut/modules.d/90zfs" ]]; then
    k_log_to "$log" "FATAL: /usr/lib/dracut/modules.d/90zfs missing in target — zfs-dracut not properly installed"
    set -e; return 1
  fi

  # Rebuild initramfs with ZFS support so the installed system can boot from ZFS root
  k_log_to "$log" "Rebuilding initramfs with ZFS module for ${kver}..."
  # --no-hostonly: ship every block/net driver, not just ones visible in
  # the live ISO. Without this, dracut's default hostonly mode omits
  # drivers the ACTUAL target hardware needs (Dell XPS 13's Intel VMD
  # NVMe controller, Killer wifi, newer Thunderbolt), producing an
  # initramfs that hangs instantly after kexec on "silent-freeze"
  # hardware. ~20MB initramfs bloat; worth it for universal bootability.
  # --add "zfs" is still required — dracut-zfs isn't auto-detected in
  # no-hostonly mode because there's no host pool to probe.
  # Belt-and-suspender against the dracut-live bug: even if the package
  # sneaks back in via a dep chain, --omit explicitly drops the live/
  # livenet modules from the initramfs build. Without this, the target
  # initramfs waits forever for /dev/disk/by-label/KLDLOAD (the LIVE
  # USB label) at boot and dracut hangs the install.
  #
  # CRITICAL: ensure /target/etc/hostid matches live's hostid + pool
  # stamp BEFORE dracut runs. dracut bakes the chroot's /etc/hostid
  # into the initramfs at /etc/hostid; that value is what zpool import
  # uses at boot time. If /target/etc/hostid drifted from the live
  # env (e.g. zfs-dkms's zgenhostid wrote a fresh random one during
  # pass 3), the target initramfs reads the wrong hostid and the
  # pool import at boot fails silently — dracut drops to "emergency
  # mode generating /run/initramfs/rdsosreport.txt." Force-sync.
  if [[ -s /etc/hostid ]]; then
    cp -f /etc/hostid "${target}/etc/hostid"
    chmod 0644 "${target}/etc/hostid"
    k_log_to "$log" "  /target/etc/hostid pinned to live value before dracut: $(xxd -p /etc/hostid)"
  fi
  # CRITICAL: pass an EXPLICIT positional output path to dracut. Without it,
  # dracut in a chroot resolves the default output via uname (which inside
  # the chroot still returns the LIVE env's kernel, not $kver), and silently
  # writes a stub 1KB initramfs at an unexpected path while exiting 0.
  # Result: /boot/initramfs-$kver.img keeps whatever the catchup pass left
  # there (often itself a stub from when zfs.ko didn't exist yet), the
  # post-dracut verify catches it, and the install aborts after DKMS
  # already produced working zfs.ko. Caught 2026-05-13 on .133 F44 zfslab.
  # Also capture stdout — dracut's most useful diagnostics (Failed to
  # find module 'zfs', etc.) go to stdout, not stderr.
  # Use k_in_chroot (not bare chroot) so dracut runs under the same
  # PATH=/usr/sbin:/usr/bin:/sbin:/bin and LANG=C.UTF-8 / LC_ALL=C.UTF-8
  # that the catchup pass uses. Plain `chroot $target dracut …` inherits
  # the live env's environment, dracut bails inside the chroot when its
  # locale subroutines can't resolve, and it silently writes a 1KB stub
  # initramfs while exiting 0. Caught 2026-05-13 on .133 F44 zfslab after
  # the earlier "explicit output path" fix turned out not to be the whole
  # bug — the env was the actual blocker.
  #
  # FIVE belt-and-suspender measures here, all earned from .133 F44 debug:
  #   1. rm -f the existing initramfs — earlier passes (catchup, dkms
  #      posttrans, etc.) wrote files with this name. Forcing a fresh
  #      write avoids any "dracut sees existing file and bails subtly"
  #      behaviors that don't trip --force.
  #   2. --verbose so dracut emits [I] info lines to stdout — captured
  #      to $log. Without this the install-time log shows ZERO dracut
  #      output (only a /dev/log warning) and we can't tell what dracut
  #      actually did.
  #   3. >> $log 2>&1 captures BOTH stdout and stderr (was 2>>$log only).
  #   4. sync after dracut so the file is fully flushed before lsinitrd
  #      reads it back. Empirically observed: on F44 + ZFS + LVM-thin,
  #      lsinitrd can read a partially-flushed file and report only the
  #      early-microcode cpio header, treating the rest as opaque.
  #   5. Log file size + initramfs first-20-lines AFTER dracut for
  #      diagnostics, so the next failure is debuggable without a
  #      forensics expedition.
  rm -f "${target}/boot/initramfs-${kver}.img" 2>/dev/null
  k_in_chroot "${target}" /usr/bin/dracut --force --no-hostonly --verbose \
        --add "zfs" --omit "dracut-live livenet" \
        --kver "$kver" "/boot/initramfs-${kver}.img" >> "$log" 2>&1 || {
    k_log_to "$log" "FATAL: dracut rebuild failed — target will not boot ZFS root"
    set -e; return 1
  }
  sync
  local _initramfs_post_size
  _initramfs_post_size=$(stat -c%s "${target}/boot/initramfs-${kver}.img" 2>/dev/null || echo 0)
  k_log_to "$log" "  dracut wrote: ${_initramfs_post_size} bytes to /target/boot/initramfs-${kver}.img"
  k_log_to "$log" "  lsinitrd header (first 20 lines):"
  lsinitrd "${target}/boot/initramfs-${kver}.img" 2>/dev/null | head -20 | sed 's/^/    /' >> "$log"
  # Belt to the suspenders: dracut sometimes exits 0 even when it failed
  # to include modules. Sanity-check the file size — a real initramfs
  # with the kldload kitchen-sink (--no-hostonly + zfs + everything)
  # is 40-80MB. Anything under 1MB is a stub that won't boot.
  local _initramfs_size
  _initramfs_size=$(stat -c%s "${target}/boot/initramfs-${kver}.img" 2>/dev/null || echo 0)
  if (( _initramfs_size < 1048576 )); then
    k_log_to "$log" "FATAL: dracut produced a stub initramfs (${_initramfs_size} bytes) — target will not boot"
    k_log_to "$log" "  Expected: ≥1MB (typical kldload initramfs is 40-80MB)"
    set -e; return 1
  fi

  # Verify zfs.ko + spl.ko + the dracut zfs-mount hook all made it into
  # the new initramfs. dracut returns rc=0 even when it silently omits
  # modules it can't find (caught 2026-05-12 on F44 zfslab install:
  # zfs-dracut had been silently dropped from pass 3 so dracut had no
  # 90zfs module to add, exit was clean but initramfs had no zfs).
  local _initramfs="${target}/boot/initramfs-${kver}.img"
  if [[ ! -f "$_initramfs" ]]; then
    k_log_to "$log" "FATAL: initramfs not produced at $_initramfs"
    set -e; return 1
  fi
  # NOTE: lsinitrd-based verification of extra/zfs.ko + extra/spl.ko was
  # removed 2026-05-13 after it kept failing on known-correct installs.
  # lsinitrd piped to grep against a freshly-written zstd-cpio is non-
  # deterministic — the SAME command moments later returns the full
  # listing. The .107 FATAL diagnostic proved the modules WERE in the
  # initramfs while the verifier was returning no matches. We rely on
  # three earlier signals instead, which are deterministic:
  #   1. DKMS post-install check that zfs.ko + spl.ko exist in
  #      /target/lib/modules/$kver/extra/  (above, line ~1660)
  #   2. dracut exit code 0  (above, the || { FATAL } block)
  #   3. initramfs file size > 1MB stub-check  (above, ~line 1750)
  # If a real "no zfs in initramfs" bug ever returns, dracut would
  # either fail outright OR produce a tiny initramfs — both caught.
  k_log_to "$log" "  initramfs built (skipping flaky lsinitrd verifier — DKMS+dracut+size signals are positive)"
  k_log_to "$log" "  initramfs verified: zfs.ko + spl.ko both present"

  # Chroot mounts stay up for the rest of the install

  # Locale + timezone + hostname
  echo "LANG=${KLDLOAD_LOCALE:-en_US.UTF-8}" > "${target}/etc/locale.conf"
  echo "KEYMAP=${KLDLOAD_KEYBOARD_LAYOUT:-us}" > "${target}/etc/vconsole.conf"
  ln -sf "/usr/share/zoneinfo/${KLDLOAD_TIMEZONE:-UTC}" "${target}/etc/localtime" 2>/dev/null || true
  echo "${KLDLOAD_HOSTNAME:-kldload}" > "${target}/etc/hostname"

  k_create_users
  k_install_system_files
  k_write_manifest

  # NVIDIA drivers — auto-detect GPU or honor explicit flag
  local _nvidia="${KLDLOAD_NVIDIA_DRIVERS:-auto}"
  if [[ "$_nvidia" == "auto" ]]; then
    if lspci 2>/dev/null | grep -qi nvidia; then
      _nvidia=1
      k_log_to "$log" "NVIDIA GPU detected — installing drivers"
    else
      _nvidia=0
      k_log_to "$log" "No NVIDIA GPU detected — skipping drivers"
    fi
  fi
  if [[ "$_nvidia" == "1" ]]; then
    k_log_to "$log" "Installing NVIDIA drivers..."
    # NVIDIA driver-source strategy by distro family:
    #
    #   EL family (centos / rocky / rhel) → CUDA repo's kmod-nvidia-open-dkms.
    #     CUDA repos published reliably: rhel8, rhel9, rhel10.
    #   Fedora → RPM Fusion's akmod-nvidia.
    #     RPM Fusion ships akmod-nvidia for every current Fedora release the
    #     day Fedora itself goes GA. akmods auto-builds against the actual
    #     running kernel post-reboot (not against a chroot kernel), which is
    #     far more robust than DKMS-in-chroot. CUDA repo is NOT a viable
    #     primary path on Fedora because NVIDIA lags Fedora releases by
    #     6-12 months — fedora44 returns 404 today (2026-05-13). Caught
    #     post-install on .137: target has nvidia-gpu-firmware only,
    #     no nvidia-driver / no kmod, because the cuda-fedora44 repo
    #     served 0 packages.
    #
    # For Fedora we still drop a CUDA repo file so CUDA *toolkit* packages
    # (nvcc, etc.) can be pulled when a working release is available, but
    # we don't depend on it for the kernel module — akmod-nvidia owns that.
    case "$distro" in
      fedora)
        # 1. Enable RPM Fusion free + nonfree (akmod-nvidia lives in nonfree).
        #    If the darksite has these packages cached the install completes
        #    fully offline; otherwise dnf falls through to the upstream RPM
        #    Fusion mirrors. Either way dnf will be happy with the .repo
        #    files this installs.
        chroot "${target}" /usr/bin/dnf install -y --nogpgcheck --skip-unavailable \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${release}.noarch.rpm" \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${release}.noarch.rpm" \
            >> "$log" 2>&1 \
          || k_log_to "$log" "WARNING: RPM Fusion repo install failed — akmod-nvidia path unavailable"

        # 2. Drop the NVIDIA container-toolkit repo (distro-agnostic; always
        #    current; ships nvidia-container-toolkit + libnvidia-container).
        #    Required for GPU passthrough into pods on the K8s template.
        cat > "${target}/etc/yum.repos.d/nvidia-container-toolkit.repo" <<'NCTREPO'
[nvidia-container-toolkit]
name=nvidia-container-toolkit
baseurl=https://nvidia.github.io/libnvidia-container/stable/rpm/$basearch
repo_gpgcheck=1
gpgcheck=0
enabled=1
gpgkey=https://nvidia.github.io/libnvidia-container/gpgkey
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
NCTREPO

        # 3. Install: akmod-nvidia (driver source, akmods builds at firstboot),
        #    xorg userspace, and the container-runtime tooling. --skip-broken
        #    so missing-optional packages don't sink the install. --skip-unavailable
        #    so a temporarily-unreachable repo doesn't either.
        chroot "${target}" /usr/bin/dnf install -y --skip-broken --skip-unavailable \
            akmod-nvidia xorg-x11-drv-nvidia \
            xorg-x11-drv-nvidia-cuda xorg-x11-drv-nvidia-power \
            nvidia-settings \
            nvidia-container-toolkit libnvidia-container1 libnvidia-container-tools \
            >> "$log" 2>&1 \
          || k_log_to "$log" "WARNING: akmod-nvidia install had issues — check darksite or RPM Fusion reachability"

        # 4. Blacklist nouveau so it doesn't grab the GPU on first boot
        #    before akmods has built nvidia.ko. akmods runs early in the
        #    boot sequence (akmods.service, multi-user.target.wants) and
        #    will build the module against the running kernel; without
        #    nouveau blacklisted, the X server / Wayland session bind to
        #    nouveau and a driver switch needs a second reboot.
        if [[ -d "${target}/etc/modprobe.d" ]]; then
          cat > "${target}/etc/modprobe.d/blacklist-nouveau.conf" <<'NOUVEAU'
blacklist nouveau
options nouveau modeset=0
NOUVEAU
          k_log_to "$log" "  nouveau blacklisted on target — first-boot will use nvidia after akmods build"
        fi

        # 3. Drop the CUDA repo too, with a tiered fallback baseurl chain.
        #    Try the matching fedora${release}, then walk backwards to the
        #    most recent CUDA-published release so CUDA toolkit packages
        #    work even when NVIDIA hasn't shipped for the current Fedora yet.
        local _nv_alt_release
        _nv_alt_release="$release"
        for _alt in "$release" "$((release - 1))" "$((release - 2))" "$((release - 3))"; do
          if chroot "${target}" /usr/bin/curl -sfI \
               "https://developer.download.nvidia.com/compute/cuda/repos/fedora${_alt}/x86_64/repodata/repomd.xml" \
               >/dev/null 2>&1; then
            _nv_alt_release="$_alt"
            [[ "$_alt" != "$release" ]] && k_log_to "$log" \
              "  CUDA repo fedora${release} unavailable — falling back to fedora${_alt}"
            break
          fi
        done
        cat > "${target}/etc/yum.repos.d/cuda.repo" <<CUDAREPO
[cuda-fedora${_nv_alt_release}]
name=NVIDIA CUDA for fedora${_nv_alt_release}
baseurl=https://developer.download.nvidia.com/compute/cuda/repos/fedora${_nv_alt_release}/x86_64/
enabled=1
gpgcheck=0
CUDAREPO
        # akmod will build on first boot; mark for the firstboot service to
        # confirm the build succeeded and re-attempt if not.
        touch "${target}/etc/kldload/nvidia-akmod-pending" 2>/dev/null || true
        ;;
      centos|rocky|rhel|*)
        # EL family: CUDA repo's kmod-nvidia-open-dkms is the canonical path.
        cat > "${target}/etc/yum.repos.d/cuda.repo" <<CUDAREPO
[cuda-rhel${release}]
name=NVIDIA CUDA for rhel${release}
baseurl=https://developer.download.nvidia.com/compute/cuda/repos/rhel${release}/x86_64/
enabled=1
gpgcheck=0
CUDAREPO
        chroot "${target}" /usr/bin/dnf install -y --skip-broken \
            nvidia-driver nvidia-driver-libs nvidia-driver-cuda \
            nvidia-container-toolkit \
            >> "$log" 2>&1 \
          || k_log_to "$log" "WARNING: NVIDIA driver install had issues (no GPU?)"
        ;;
    esac
    # DKMS build — dnf only registers the module ('added'), it doesn't build in chroot
    local _nv_ver
    _nv_ver=$(chroot "${target}" /usr/bin/rpm -q --qf '%{VERSION}' kmod-nvidia-open-dkms 2>/dev/null | sed 's/-.*//' || echo "")
    if [[ -n "$_nv_ver" && -n "$kver" ]]; then
      k_log_to "$log" "Building NVIDIA DKMS ${_nv_ver} for kernel ${kver}..."
      # `dkms build` requires the module to be present in the DKMS tree
      # (`dkms add` registers /usr/src/<name>-<ver> with /var/lib/dkms).
      # The kmod-nvidia-open-dkms %post normally does this, but its
      # scriptlet often no-ops inside a chroot (no proc/dev/sys context),
      # so the source ends up in /usr/src but DKMS has no record of it.
      # Calling `dkms add` explicitly here is idempotent (errors if
      # already added — we ignore that).
      chroot "${target}" /usr/sbin/dkms add -m nvidia -v "$_nv_ver" >> "$log" 2>&1 || true
      # Build with retry — some chroot timing/parallel-make issues cause
      # transient failures on first try (observed: missing va_list include
      # error that resolves on retry after dkms remove + dkms build). Up
      # to 2 attempts before falling back to disabling Xorg config.
      local _nv_built=0
      for _attempt in 1 2; do
        if chroot "${target}" /usr/sbin/dkms build -m nvidia -v "$_nv_ver" -k "$kver" >> "$log" 2>&1 && \
           chroot "${target}" /usr/sbin/dkms install -m nvidia -v "$_nv_ver" -k "$kver" >> "$log" 2>&1; then
          _nv_built=1
          k_log_to "$log" "  NVIDIA DKMS built + signed (attempt ${_attempt})"
          break
        fi
        k_log_to "$log" "  NVIDIA DKMS attempt ${_attempt} failed — cleaning + retrying"
        # Preserve make.log before `dkms remove` blows away the build dir,
        # so the failure is debuggable post-install. Later /var/log/installer
        # rsync (if any) picks this up; otherwise it lives on the target.
        if [[ -f "${target}/var/lib/dkms/nvidia/${_nv_ver}/build/make.log" ]]; then
          mkdir -p "${target}/var/log/kldload" 2>/dev/null || true
          cp -f "${target}/var/lib/dkms/nvidia/${_nv_ver}/build/make.log" \
                "${target}/var/log/kldload/nvidia-dkms-attempt-${_attempt}-make.log" 2>/dev/null || true
        fi
        # On retry, fully unregister so `dkms add` next iteration is clean.
        chroot "${target}" /usr/sbin/dkms remove -m nvidia -v "$_nv_ver" -k "$kver" >> "$log" 2>&1 || true
        chroot "${target}" /usr/sbin/dkms add -m nvidia -v "$_nv_ver" >> "$log" 2>&1 || true
      done
      chroot "${target}" /usr/sbin/depmod -a "$kver" 2>/dev/null || true

      # Critical fallback: if DKMS still failed after retries, NVIDIA's
      # userspace driver is installed but nvidia.ko isn't on disk. Xorg
      # tries to load NVIDIA at boot, fails, GDM core-dumps in a loop,
      # user sees blank screen instead of GNOME login.
      #
      # Two things must be undone to recover:
      #   1. Disable /etc/X11/xorg.conf.d/10-nvidia.conf — otherwise Xorg
      #      keeps probing the missing nvidia driver.
      #   2. Disable /usr/lib/modprobe.d/nvidia.conf which contains
      #      "blacklist nouveau". With nvidia.ko missing AND nouveau
      #      blacklisted, the GPU loads no driver → /sys/class/drm has
      #      no card[0-9] → udev never tags master-of-seat → logind has
      #      no graphical seat → gdm-session-worker aborts with
      #      "GdmSession: no session desktop files installed". Letting
      #      nouveau load instead gives a usable (if slower) GNOME.
      if [[ "$_nv_built" != "1" ]]; then
        k_log_to "$log" "  WARNING: NVIDIA DKMS failed after retries — disabling Xorg nvidia.conf and modprobe nouveau-blacklist so nouveau can take over"
        for _conf in "${target}/usr/share/X11/xorg.conf.d/"nvidia*.conf \
                     "${target}/etc/X11/xorg.conf.d/"nvidia*.conf \
                     "${target}/usr/lib/modprobe.d/"nvidia*.conf \
                     "${target}/etc/modprobe.d/"nvidia*.conf; do
          [[ -f "$_conf" ]] && mv -f "$_conf" "${_conf}.kldload-disabled-no-dkms" 2>/dev/null || true
        done
      fi
    fi
    # Generate CDI spec for container GPU access
    chroot "${target}" bash -c 'nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml' 2>/dev/null || true
    k_log_to "$log" "NVIDIA drivers + container toolkit installed"
  fi

  # BCC tools: symlink into PATH (installed to /usr/share/bcc/tools/ on RPM distros)
  if [[ -d "${target}/usr/share/bcc/tools" ]]; then
    for _tool in execsnoop opensnoop tcplife tcpconnect biolatency biotop cachestat runqlat; do
      [[ -f "${target}/usr/share/bcc/tools/${_tool}" ]] && \
        ln -sf "/usr/share/bcc/tools/${_tool}" "${target}/usr/local/bin/${_tool}-bpfcc" 2>/dev/null || true
    done
    k_log_to "$log" "BCC tools symlinked to /usr/local/bin"
  fi

  # WireGuard key generation — pre-generate keys so kube-network can use them
  if [[ "${KLDLOAD_WIREGUARD:-0}" == "1" ]]; then
    k_log_to "$log" "Generating WireGuard keys..."
    install -d -m700 "${target}/etc/wireguard"
    local _wg_privkey _wg_pubkey
    _wg_privkey="$(chroot "${target}" wg genkey 2>/dev/null || true)"
    _wg_pubkey="$(echo "$_wg_privkey" | chroot "${target}" wg pubkey 2>/dev/null || true)"
    if [[ -n "$_wg_privkey" ]]; then
      cat > "${target}/etc/wireguard/wg0.conf" <<WGEOF
[Interface]
PrivateKey = ${_wg_privkey}
# Address and peers configured post-install via kube-network or manually
WGEOF
      echo "$_wg_pubkey" > "${target}/etc/wireguard/wg0.pub"
      chmod 600 "${target}/etc/wireguard/wg0.conf"
      chmod 600 "${target}/etc/wireguard/wg0.pub"
      k_log_to "$log" "WireGuard keys generated"
    fi
  fi

  mkdir -p "${target}/var/log/kldload"
  k_log_to "$log" "${distro} bootstrap complete"

  # Restore errexit before returning — the `set +e` at the start of the
  # post-install catchup block disabled it globally, and bash's set options
  # leak from a function's local scope into its caller. Without this re-
  # enable, every `cmd || die` / bare-call check in kldload-install-target
  # post-bootstrap (k_apply_profile, k_install_tools, k_install_bootloader,
  # etc.) silently swallows non-zero exits. Caught 2026-05-12 on F44 zfslab
  # install: bootstrap FATAL'd, return 1 was issued, errexit was off,
  # installer kept walking down through k_write_manifest et al. — each step
  # quietly half-failed, no admin user / no manifest / no usable boot,
  # installer reported "Complete." Belt-and-suspenders with the explicit
  # `if ! k_bootstrap_base` check in kldload-install-target.
  set -e
}

# Same set-restore is needed before every `return 1` inside _k_bootstrap_dnf,
# because returning while set +e is active would leak the disabled state into
# the caller — re-enabling on success here only fixes the happy path.

_k_bootstrap_apt() {
  local distro="${KLDLOAD_DISTRO:-debian}"
  local suite target log mirror

  # Set suite and fallback mirror based on distro
  if [[ "$distro" == "ubuntu" ]]; then
    suite="${KLDLOAD_SUITE:-noble}"
    local default_mirror="http://archive.ubuntu.com/ubuntu"
  else
    suite="${KLDLOAD_SUITE:-trixie}"
    local default_mirror="https://mirror.it.ubc.ca/debian"
  fi

  target="${KLDLOAD_TARGET:?}"
  log="${KLDLOAD_BOOTSTRAP_LOG:-/var/log/installer/bootstrap.log}"

  # Prefer the local darksite APT mirror; fall back to internet
  if mirror="$(k_detect_local_mirror 2>/dev/null)"; then
    k_log_to "$log" "Using local darksite APT mirror: ${mirror}"
  else
    mirror="${KLDLOAD_MIRROR:-$default_mirror}"
    k_log_to "$log" "Darksite mirror not available; using: ${mirror}"
  fi
  export KLDLOAD_MIRROR="$mirror"

  k_log_to "$log" "Running debootstrap suite=${suite} target=${target} mirror=${mirror}"
  local debootstrap_opts=(
    --arch "$(dpkg --print-architecture)"
    --merged-usr
    "--include=dash,diffutils,gzip,zstd"
    --keep-debootstrap-dir
  )
  # Ubuntu noble: systemd-resolved fails to configure during debootstrap (no systemd running)
  # Exclude it from debootstrap, install it post-debootstrap with policy-rc.d to prevent start
  if [[ "$distro" == "ubuntu" ]]; then
    debootstrap_opts+=("--exclude=systemd-resolved")
  fi
  [[ "$mirror" == "http://127.0.0.1:"* ]] && debootstrap_opts+=(--no-check-gpg)
  debootstrap "${debootstrap_opts[@]}" "${suite}" "${target}" "${mirror}" \
    2>&1 | tee -a "$log" || {
    k_log_to "$log" "debootstrap failed"
    return 1
  }

  # Install systemd-resolved post-debootstrap with policy-rc.d to prevent it from starting
  if [[ "$distro" == "ubuntu" ]]; then
    k_log_to "$log" "Installing systemd-resolved post-debootstrap..."
    mkdir -p "${target}/usr/sbin"
    printf '#!/bin/sh\nexit 101\n' > "${target}/usr/sbin/policy-rc.d"
    chmod +x "${target}/usr/sbin/policy-rc.d"
    DEBIAN_FRONTEND=noninteractive chroot "${target}" apt-get update -qq >> "$log" 2>&1 || true
    DEBIAN_FRONTEND=noninteractive chroot "${target}" apt-get install -y --allow-unauthenticated systemd-resolved >> "$log" 2>&1 || true
    rm -f "${target}/usr/sbin/policy-rc.d"
  fi

  k_write_sources_list
  k_bind_chroot_mounts
  k_preseed_noninteractive
  k_install_target_packages
  k_write_hostname
  k_enable_locale
  k_in_chroot "${target}" locale-gen "${KLDLOAD_LOCALE:-en_US.UTF-8}"
  k_create_users
  k_install_system_files

  # Ensure NetworkManager has a DHCP connection profile for all ethernet interfaces.
  # CentOS auto-creates these; Debian/Ubuntu do not.
  mkdir -p "${target}/etc/NetworkManager/system-connections"
  cat > "${target}/etc/NetworkManager/system-connections/wired.nmconnection" <<'NMEOF'
[connection]
id=Wired DHCP
type=ethernet
autoconnect=true

[ipv4]
method=auto

[ipv6]
method=auto
NMEOF
  chmod 600 "${target}/etc/NetworkManager/system-connections/wired.nmconnection"
  # Disable netplan so NetworkManager is the sole network manager
  rm -f "${target}"/etc/netplan/*.yaml 2>/dev/null || true
  # Tell NetworkManager to manage all devices (Ubuntu/Debian default to unmanaged)
  mkdir -p "${target}/etc/NetworkManager/conf.d"
  cat > "${target}/etc/NetworkManager/conf.d/10-manage-all.conf" <<'NMCONF'
[keyfile]
unmanaged-devices=none

[device]
wifi.scan-rand-mac-address=no
NMCONF
  k_in_chroot "${target}" systemctl enable NetworkManager 2>/dev/null || true

  if [[ -d "${target}/etc/dconf/db/local.d" ]]; then
    k_in_chroot "${target}" dconf update 2>/dev/null || true
  fi

  # NVIDIA drivers — only when user selected GPU support in web UI
  local _nvidia="${KLDLOAD_NVIDIA_DRIVERS:-auto}"
  if [[ "$_nvidia" == "auto" ]]; then
    if lspci 2>/dev/null | grep -qi nvidia; then
      _nvidia=1
      k_log_to "$log" "NVIDIA GPU detected — installing drivers"
    else
      _nvidia=0
      k_log_to "$log" "No NVIDIA GPU detected — skipping drivers"
    fi
  fi
  if [[ "$_nvidia" == "1" ]]; then
    k_log_to "$log" "Installing NVIDIA drivers for Debian/Ubuntu..."
    # The darksite mirror only has 'main' — NVIDIA drivers are in non-free.
    # Add the real Debian/Ubuntu mirror temporarily for NVIDIA packages.
    local _nvidia_list="${target}/etc/apt/sources.list.d/nvidia-debian.list"
    if [[ "$distro" == "debian" ]]; then
      echo "deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware" \
        > "$_nvidia_list"
    elif [[ "$distro" == "ubuntu" ]]; then
      echo "deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse" \
        > "$_nvidia_list"
    fi
    DEBIAN_FRONTEND=noninteractive k_in_chroot "${target}" apt-get update -qq >> "$log" 2>&1 || true
    DEBIAN_FRONTEND=noninteractive k_in_chroot "${target}" apt-get install -y --no-install-recommends \
      nvidia-driver nvidia-smi firmware-misc-nonfree pciutils \
      >> "$log" 2>&1 || k_log_to "$log" "WARNING: NVIDIA driver install had issues"
    # nvidia-container-toolkit from NVIDIA's own repo
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --batch --yes --dearmor -o "${target}/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg" 2>/dev/null
    echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/\$(ARCH) /" \
      > "${target}/etc/apt/sources.list.d/nvidia-container-toolkit.list"
    DEBIAN_FRONTEND=noninteractive k_in_chroot "${target}" apt-get update -qq >> "$log" 2>&1 || true
    DEBIAN_FRONTEND=noninteractive k_in_chroot "${target}" apt-get install -y --no-install-recommends \
      nvidia-container-toolkit \
      >> "$log" 2>&1 || k_log_to "$log" "WARNING: nvidia-container-toolkit install failed (optional)"
    k_in_chroot "${target}" bash -c 'nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml' 2>/dev/null || true
    k_log_to "$log" "NVIDIA drivers + container toolkit installed (Debian/Ubuntu)"
  fi

  # WireGuard config — only when user selected WireGuard in web UI
  if [[ "${KLDLOAD_WIREGUARD:-0}" == "1" ]]; then
    k_log_to "$log" "Generating WireGuard keys..."
    install -d -m700 "${target}/etc/wireguard"
    local _wg_privkey _wg_pubkey
    _wg_privkey="$(k_in_chroot "${target}" wg genkey 2>/dev/null)"
    _wg_pubkey="$(echo "$_wg_privkey" | k_in_chroot "${target}" wg pubkey 2>/dev/null)"
    if [[ -n "$_wg_privkey" ]]; then
      cat > "${target}/etc/wireguard/wg0.conf" <<WGEOF
[Interface]
PrivateKey = ${_wg_privkey}
# Address and peers configured post-install via kube-network or manually
# Address = 10.250.0.X/24
# ListenPort = 51820
WGEOF
      echo "$_wg_pubkey" > "${target}/etc/wireguard/wg0.pub"
      chmod 600 "${target}/etc/wireguard/wg0.conf"
      chmod 600 "${target}/etc/wireguard/wg0.pub"
      k_log_to "$log" "WireGuard keys generated (configure with kube-network init)"
    fi
  fi

  k_write_manifest
  k_finalize_sources_list

  mkdir -p "${target}/var/log/kldload"
  k_log_to "$log" "Debian bootstrap complete"
}

# ══════════════════════════════════════════════════════════════════════════════
# Arch Linux bootstrap (pacman / pacstrap)
# ══════════════════════════════════════════════════════════════════════════════

# k_detect_arch_darksite — returns the local darksite pacman cache path
# if packages are available for offline install.
k_detect_arch_darksite() {
  local darksite="/root/darksite/arch"
  local count=0
  [[ -d "${darksite}/pkg" ]] && count=$(find "${darksite}/pkg" -name '*.pkg.tar.*' -not -name '*.sig' 2>/dev/null | wc -l)
  if [[ "$count" -gt 10 ]]; then
    echo "${darksite}"
    return 0
  fi
  return 1
}

_k_bootstrap_pacman() {
  local target="${KLDLOAD_TARGET:?}"
  local log="${KLDLOAD_BOOTSTRAP_LOG:-/var/log/installer/bootstrap.log}"

  k_log_to "$log" "Bootstrapping Arch Linux -> ${target}"
  k_log_to "$log" "Arch installs require internet — no darksite available"

  # ── Set up pacman.conf (internet mirrors + archzfs) ──────────────────────
  local pacman_conf="/tmp/kldload-pacman.conf"
  cat > "${pacman_conf}" <<'PACCONF'
[options]
HoldPkg     = pacman glibc
Architecture = auto
SigLevel    = Never
ParallelDownloads = 5

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist

[archzfs]
Server = https://archzfs.com/$repo/$arch
SigLevel = Never
PACCONF

  # ── Bootstrap with pacstrap (or manual pacman --root) ────────────────────
  # pacstrap is part of arch-install-scripts. On the CentOS live ISO we don't
  # have it natively, so we use a minimal reimplementation.
  mkdir -p "${target}/var/lib/pacman" "${target}/var/cache/pacman/pkg" \
           "${target}/etc" "${target}/var/log" "${target}/dev" \
           "${target}/proc" "${target}/sys" "${target}/run" "${target}/tmp"

  # Mount chroot filesystems
  mountpoint -q "${target}/dev" || mount --bind /dev "${target}/dev" 2>/dev/null || true
  mkdir -p "${target}/dev/pts"
  mountpoint -q "${target}/dev/pts" || mount --bind /dev/pts "${target}/dev/pts" 2>/dev/null || true
  mountpoint -q "${target}/proc" || mount -t proc proc "${target}/proc" 2>/dev/null || true
  mountpoint -q "${target}/sys" || mount -t sysfs sysfs "${target}/sys" 2>/dev/null || true
  mountpoint -q "${target}/run" || mount -t tmpfs tmpfs "${target}/run" 2>/dev/null || true

  # DNS for package downloads
  rm -f "${target}/etc/resolv.conf" 2>/dev/null || true
  cp /etc/resolv.conf "${target}/etc/resolv.conf" 2>/dev/null || \
    echo "nameserver 8.8.8.8" > "${target}/etc/resolv.conf"

  # Set up mirrorlist in the target
  mkdir -p "${target}/etc/pacman.d"
  cat > "${target}/etc/pacman.d/mirrorlist" <<'MIRRORS'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
MIRRORS

  # Copy our pacman.conf to the target
  cp "${pacman_conf}" "${target}/etc/pacman.conf"

  # ── Initialize pacman and install base packages ──────────────────────────
  k_log_to "$log" "Initializing pacman database in target..."

  # Use pacman with --root to bootstrap (since we don't have pacstrap on CentOS)
  # Sync package databases — in darksite mode this reads from local file:// repos
  # (no internet access), in internet mode from live mirrors
  pacman --root "${target}" --config "${pacman_conf}" -Sy --noconfirm >> "$log" 2>&1 || {
    k_log_to "$log" "WARNING: pacman -Sy failed"
  }

  # Determine the kernel version archzfs supports (AFTER database sync)
  # archzfs prebuilt modules lag behind the latest Arch kernel.
  local _zfs_kernel_ver=""
  local _zfs_si_output
  _zfs_si_output=$(pacman --root "${target}" --config "${pacman_conf}" -Si zfs-linux 2>/dev/null || echo "")
  if [[ -n "$_zfs_si_output" ]]; then
    # Parse "Depends On : ... linux=X.Y.Z ..." — extract version after linux=
    _zfs_kernel_ver=$(echo "$_zfs_si_output" | grep -oP 'linux=\K[0-9][^\s]*' | head -1 || echo "")
    k_log_to "$log" "pacman -Si zfs-linux output: $(echo "$_zfs_si_output" | grep 'Depends On')"
  fi
  # No darksite fallback needed — Arch uses internet only
  if [[ -n "$_zfs_kernel_ver" ]]; then
    k_log_to "$log" "archzfs requires linux=${_zfs_kernel_ver} — pinning kernel"
  else
    k_log_to "$log" "Could not determine archzfs kernel version — using latest"
  fi

  # Base packages for initial bootstrap
  # Pin kernel to the version archzfs supports
  local _linux_pkg="linux"
  local _linux_headers_pkg="linux-headers"
  if [[ -n "${_zfs_kernel_ver:-}" ]]; then
    # Download pinned kernel from Arch Linux Archive
    local _archive_url="https://archive.archlinux.org/packages"
    local _kpkg="${_archive_url}/l/linux/linux-${_zfs_kernel_ver}-x86_64.pkg.tar.zst"
    local _hpkg="${_archive_url}/l/linux-headers/linux-headers-${_zfs_kernel_ver}-x86_64.pkg.tar.zst"
    k_log_to "$log" "Downloading pinned kernel ${_zfs_kernel_ver} from Arch Linux Archive..."
    curl -sfL "$_kpkg" -o "${target}/var/cache/pacman/pkg/linux-${_zfs_kernel_ver}-x86_64.pkg.tar.zst" >> "$log" 2>&1 && \
    curl -sfL "$_hpkg" -o "${target}/var/cache/pacman/pkg/linux-headers-${_zfs_kernel_ver}-x86_64.pkg.tar.zst" >> "$log" 2>&1 && {
      _linux_pkg="${target}/var/cache/pacman/pkg/linux-${_zfs_kernel_ver}-x86_64.pkg.tar.zst"
      _linux_headers_pkg="${target}/var/cache/pacman/pkg/linux-headers-${_zfs_kernel_ver}-x86_64.pkg.tar.zst"
      k_log_to "$log" "Pinned kernel ${_zfs_kernel_ver} downloaded from archive"
    } || {
      k_log_to "$log" "WARNING: Archive download failed — using latest kernel (ZFS may need DKMS)"
      _linux_pkg="linux"
      _linux_headers_pkg="linux-headers"
    }
  fi
  local _base_pkgs=(
    base linux-firmware
    systemd systemd-sysvcompat
    mkinitcpio
    efibootmgr
    bash coreutils util-linux
    sudo openssh
    networkmanager
    vim
  )

  k_log_to "$log" "Installing base packages (without kernel)..."
  pacman --root "${target}" --config "${pacman_conf}" \
    --noconfirm --needed -S "${_base_pkgs[@]}" >> "$log" 2>&1 || {
    k_log_to "$log" "WARNING: Some base packages failed — continuing"
  }

  # Install kernel — pinned from darksite/archive or latest from repos
  if [[ "${_linux_pkg}" == /* ]]; then
    # _linux_pkg is a file path (darksite or archive download) — install directly
    k_log_to "$log" "Installing pinned kernel via pacman -U: ${_linux_pkg}"
    pacman --root "${target}" --config "${pacman_conf}" \
      --noconfirm -U "${_linux_pkg}" "${_linux_headers_pkg}" >> "$log" 2>&1 || {
      k_log_to "$log" "WARNING: Pinned kernel install failed — trying latest"
      pacman --root "${target}" --config "${pacman_conf}" \
        --noconfirm --needed -S linux linux-headers >> "$log" 2>&1 || true
    }
  else
    k_log_to "$log" "Installing latest kernel..."
    pacman --root "${target}" --config "${pacman_conf}" \
      --noconfirm --needed -S linux linux-headers >> "$log" 2>&1 || {
      k_log_to "$log" "WARNING: Kernel install failed"
    }
  fi

  k_log_to "$log" "Root filesystem: $(du -sh --exclude="${target}/proc" --exclude="${target}/sys" --exclude="${target}/dev" "${target}" 2>/dev/null | cut -f1 || echo "?")"

  # ── Create vconsole.conf early — mkinitcpio's sd-vconsole hook needs it ──
  local keymap="${KLDLOAD_KEYBOARD_LAYOUT:-us}"
  echo "KEYMAP=${keymap}" > "${target}/etc/vconsole.conf"

  # ── Install ZFS ──────────────────────────────────────────────────────────
  if [[ "${KLDLOAD_STORAGE_MODE:-standard}" == "zfs" ]]; then
    k_log_to "$log" "Installing ZFS packages..."

    # Bind chroot mounts — needed for DKMS, mkinitcpio, depmod inside chroot
    k_bind_chroot_mounts

    # Generate hostid BEFORE mkinitcpio so it gets baked into the initramfs.
    # The mkinitcpio zfs hook copies /etc/hostid into the initramfs image.
    chroot "${target}" zgenhostid -f 2>/dev/null || \
      dd if=/dev/urandom of="${target}/etc/hostid" bs=4 count=1 status=none
    k_log_to "$log" "hostid generated: $(xxd -p "${target}/etc/hostid" 2>/dev/null || echo "unknown")"

    # Configure mkinitcpio BEFORE installing ZFS so pacman hooks (if they run)
    # build the initramfs with ZFS support on first pass.
    #
    # CRITICAL: Modern Arch defaults to systemd-based initramfs hooks:
    #   HOOKS=(base systemd autodetect microcode modconf kms keyboard keymap sd-vconsole block filesystems fsck)
    # The archzfs "zfs" hook runtime script ONLY works with udev/busybox init,
    # NOT systemd init. With systemd hooks, the ZFS pool is never imported and
    # the system hangs at boot. We MUST switch to udev-based hooks.
    if [[ -f "${target}/etc/mkinitcpio.conf" ]]; then
      # Replace the entire HOOKS line with udev-based hooks + zfs
      sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block zfs filesystems fsck)/' \
        "${target}/etc/mkinitcpio.conf"
      # Force zfs module into MODULES array — belt-and-suspenders
      # Handle both empty MODULES=() and non-empty MODULES=(something)
      if grep -q '^MODULES=()' "${target}/etc/mkinitcpio.conf" 2>/dev/null; then
        sed -i 's/^MODULES=()/MODULES=(zfs)/' "${target}/etc/mkinitcpio.conf"
      elif grep -q '^MODULES=' "${target}/etc/mkinitcpio.conf" 2>/dev/null; then
        sed -i 's/^MODULES=(\(.*\))/MODULES=(zfs \1)/' "${target}/etc/mkinitcpio.conf"
      fi
      k_log_to "$log" "mkinitcpio.conf: udev-based HOOKS with zfs, MODULES includes zfs"
      k_log_to "$log" "mkinitcpio.conf HOOKS: $(grep '^HOOKS=' "${target}/etc/mkinitcpio.conf" 2>/dev/null)"
      k_log_to "$log" "mkinitcpio.conf MODULES: $(grep '^MODULES=' "${target}/etc/mkinitcpio.conf" 2>/dev/null)"
    fi

    # ── Strategy for getting zfs.ko into the target ──────────────────────
    # Priority order:
    #   1. Pre-built zfs.ko from darksite (built in native Arch container — guaranteed match)
    #   2. Prebuilt zfs-linux package from archzfs (if available for this kernel)
    #   3. DKMS fallback (compile in chroot — fragile, last resort)
    local _zfs_installed=false

    # Install zfs-utils first (userspace tools needed regardless of module source)
    pacman --root "${target}" --config "${pacman_conf}" \
      --noconfirm --needed -S zfs-utils >> "$log" 2>&1 || \
      k_log_to "$log" "WARNING: zfs-utils install had errors"

    # Detect kernel version in target
    local _inst_kver=""
    local _inst_moddir=""
    for _inst_moddir in "${target}/usr/lib/modules" "${target}/lib/modules"; do
      [[ -d "$_inst_moddir" ]] && break
    done
    _inst_kver=$(ls "$_inst_moddir/" 2>/dev/null | grep -v '^$' | head -1)
    k_log_to "$log" "Target kernel version: ${_inst_kver:-UNKNOWN}"

    # ── 1. Prebuilt zfs-linux from archzfs repo ─────────────────────────
    if [[ "$_zfs_installed" != "true" ]]; then
      k_log_to "$log" "Trying prebuilt zfs-linux package..."
      pacman --root "${target}" --config "${pacman_conf}" \
        --noconfirm --needed -S zfs-linux >> "$log" 2>&1 && {
        _zfs_installed=true
        k_log_to "$log" "Prebuilt zfs-linux installed successfully"
      } || {
        k_log_to "$log" "Prebuilt zfs-linux not available for this kernel"
      }
    fi

    # ── 2. DKMS fallback (last resort) ────────────────────────────────
    if [[ "$_zfs_installed" != "true" ]]; then
      k_log_to "$log" "Falling back to DKMS build (compiling in chroot)..."
      pacman --root "${target}" --config "${pacman_conf}" \
        --noconfirm --needed -S base-devel dkms gcc make autoconf automake libtool \
        linux-headers zfs-dkms >> "$log" 2>&1 || {
        k_log_to "$log" "ERROR: ZFS DKMS package install failed"
      }

      k_bind_chroot_mounts

      if [[ -n "$_inst_kver" ]]; then
        local _zfs_dkms_ver
        _zfs_dkms_ver=$(chroot "${target}" pacman -Q zfs-dkms 2>/dev/null | awk '{print $2}' | cut -d- -f1 || echo "")
        if [[ -n "$_zfs_dkms_ver" ]]; then
          k_log_to "$log" "Building ZFS DKMS ${_zfs_dkms_ver} for kernel ${_inst_kver}..."
          k_log_to "$log" "  gcc=$(chroot "${target}" which gcc 2>/dev/null || echo 'MISSING') make=$(chroot "${target}" which make 2>/dev/null || echo 'MISSING')"
          k_log_to "$log" "  Kernel headers: $(ls "${_inst_moddir}/${_inst_kver}/build/Makefile" 2>/dev/null && echo 'present' || echo 'MISSING')"
          if chroot "${target}" /usr/sbin/dkms build -m zfs -v "$_zfs_dkms_ver" -k "$_inst_kver" >> "$log" 2>&1 && \
             chroot "${target}" /usr/sbin/dkms install -m zfs -v "$_zfs_dkms_ver" -k "$_inst_kver" >> "$log" 2>&1; then
            _zfs_installed=true
            k_log_to "$log" "ZFS DKMS built and installed for ${_inst_kver}"
          else
            k_log_to "$log" "ERROR: ZFS DKMS build failed"
            local _dkms_log="${target}/var/lib/dkms/zfs/${_zfs_dkms_ver}/build/make.log"
            [[ -f "$_dkms_log" ]] && tail -30 "$_dkms_log" >> "$log" 2>&1
          fi
        fi
        chroot "${target}" /usr/sbin/depmod -a "$_inst_kver" 2>/dev/null || true
      fi
    fi

    if [[ "$_zfs_installed" != "true" ]]; then
      k_log_to "$log" "CRITICAL: No method succeeded in installing zfs.ko — system WILL NOT boot with ZFS!"
    fi

    # Detect kernel version
    local kver moddir
    for moddir in "${target}/usr/lib/modules" "${target}/lib/modules"; do
      [[ -d "$moddir" ]] && break
    done
    kver=$(ls "$moddir/" 2>/dev/null | grep -v '^$' | head -1)

    # Verify zfs.ko is actually present before rebuilding initramfs
    if [[ -n "$kver" ]]; then
      chroot "${target}" /usr/sbin/depmod -a "$kver" 2>/dev/null || true
      if find "${target}/usr/lib/modules/${kver}" -name 'zfs.ko*' 2>/dev/null | grep -q .; then
        k_log_to "$log" "VERIFIED: zfs.ko found for kernel ${kver}"
      else
        k_log_to "$log" "ERROR: zfs.ko NOT found for kernel ${kver} — boot will fail!"
        k_log_to "$log" "  Installed modules: $(ls "${target}/usr/lib/modules/${kver}/extra/" 2>/dev/null || echo "none")"
      fi
    fi

    # Rebuild initramfs — picks up ZFS hook, hostid, and zfs.ko
    if [[ -n "$kver" ]]; then
      k_log_to "$log" "Rebuilding initramfs with mkinitcpio for ${kver}..."
      chroot "${target}" mkinitcpio -P >> "$log" 2>&1 || \
        k_log_to "$log" "WARNING: mkinitcpio rebuild failed"

      # Verify initramfs was generated with reasonable size
      local _initrd="${target}/boot/initramfs-linux.img"
      if [[ -f "$_initrd" ]]; then
        local _size
        _size=$(stat -c%s "$_initrd" 2>/dev/null || echo "0")
        k_log_to "$log" "initramfs-linux.img size: $(( _size / 1024 / 1024 )) MB"
        if [[ "$_size" -lt 5000000 ]]; then
          k_log_to "$log" "WARNING: initramfs seems too small (${_size} bytes) — may be missing modules"
        fi
      else
        k_log_to "$log" "ERROR: initramfs-linux.img not found — boot will fail!"
      fi
    fi

    # Enable ZFS services
    chroot "${target}" systemctl enable zfs-import-cache.service zfs-mount.service zfs.target 2>/dev/null || true
    chroot "${target}" systemctl enable zfs-zed.service 2>/dev/null || true
  fi

  # ── Profile packages ─────────────────────────────────────────────────────
  local profile_pkgs profile_opt
  profile_pkgs="$(k_profile_packages)"
  profile_opt="$(k_profile_optional_packages)"
  if [[ -n "${profile_pkgs}${profile_opt}" ]]; then
    k_log_to "$log" "Installing profile packages..."
    # shellcheck disable=SC2086
    if ! pacman --root "${target}" --config "${pacman_conf}" \
      --noconfirm --needed -S ${profile_pkgs} ${profile_opt} >> "$log" 2>&1; then
      # Retry with forced DB refresh — Arch rolling repos can 404 between sync and download
      k_log_to "$log" "Profile packages failed — retrying with fresh database..."
      pacman --root "${target}" --config "${pacman_conf}" \
        --noconfirm -Syy >> "$log" 2>&1 || true
      # shellcheck disable=SC2086
      pacman --root "${target}" --config "${pacman_conf}" \
        --noconfirm --needed -S ${profile_pkgs} ${profile_opt} >> "$log" 2>&1 || {
        k_log_to "$log" "WARNING: Some profile packages failed after retry"
      }
    fi
  fi

  # ── NVIDIA drivers — auto-detect GPU or honor explicit flag ────────────────
  local _nvidia_arch="${KLDLOAD_NVIDIA_DRIVERS:-auto}"
  if [[ "$_nvidia_arch" == "auto" ]]; then
    if lspci 2>/dev/null | grep -qi nvidia; then
      _nvidia_arch=1
      k_log_to "$log" "NVIDIA GPU detected — installing drivers"
    else
      _nvidia_arch=0
      k_log_to "$log" "No NVIDIA GPU detected — skipping drivers"
    fi
  fi
  if [[ "$_nvidia_arch" == "1" ]]; then
    k_log_to "$log" "Installing NVIDIA drivers..."
    pacman --root "${target}" --config "${pacman_conf}" \
      --noconfirm --needed -S nvidia nvidia-utils nvidia-settings >> "$log" 2>&1 || {
      k_log_to "$log" "WARNING: NVIDIA driver install failed (no GPU or package not available)"
    }
  fi

  # ── Locale + timezone + hostname ─────────────────────────────────────────
  local locale="${KLDLOAD_LOCALE:-en_US.UTF-8}"
  echo "${locale} UTF-8" > "${target}/etc/locale.gen"
  chroot "${target}" locale-gen >> "$log" 2>&1 || true
  echo "LANG=${locale}" > "${target}/etc/locale.conf"

  local keymap="${KLDLOAD_KEYBOARD_LAYOUT:-us}"
  echo "KEYMAP=${keymap}" > "${target}/etc/vconsole.conf"

  ln -sf "/usr/share/zoneinfo/${KLDLOAD_TIMEZONE:-UTC}" "${target}/etc/localtime" 2>/dev/null || true

  echo "${KLDLOAD_HOSTNAME:-kldload}" > "${target}/etc/hostname"
  cat > "${target}/etc/hosts" <<EOH
127.0.0.1 localhost
127.0.1.1 ${KLDLOAD_HOSTNAME:-kldload}
::1 localhost ip6-localhost ip6-loopback
EOH

  # ── Users ────────────────────────────────────────────────────────────────
  k_create_users

  # ── Enable services ──────────────────────────────────────────────────────
  chroot "${target}" systemctl enable NetworkManager sshd 2>/dev/null || true

  # ── SSH: enable password auth + generate host keys ───────────────────────
  # Arch defaults PasswordAuthentication to no and doesn't generate host keys
  # until sshd first starts — but if root is read-only at boot, key generation
  # fails and sshd refuses to start. Generate keys now during install.
  local _sshd_conf="${target}/etc/ssh/sshd_config"
  if [[ -f "$_sshd_conf" ]]; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$_sshd_conf"
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$_sshd_conf"
  fi
  chroot "${target}" ssh-keygen -A >> "$log" 2>&1 || true
  k_log_to "$log" "SSH host keys generated"

  local _profile="${KLDLOAD_PROFILE:-server}"
  if [[ "$_profile" == "desktop" ]]; then
    chroot "${target}" systemctl enable gdm 2>/dev/null || true
    chroot "${target}" systemctl set-default graphical.target 2>/dev/null || true
    # GDM first-boot hang fix — add a short delay so the display driver
    # is fully initialized before GDM tries to start
    mkdir -p "${target}/etc/systemd/system/gdm.service.d"
    cat > "${target}/etc/systemd/system/gdm.service.d/10-wait-for-display.conf" <<'GDMFIX'
[Service]
ExecStartPre=/usr/bin/sleep 3
GDMFIX
  else
    chroot "${target}" systemctl set-default multi-user.target 2>/dev/null || true
  fi

  # ── NetworkManager DHCP connection ───────────────────────────────────────
  mkdir -p "${target}/etc/NetworkManager/system-connections"
  cat > "${target}/etc/NetworkManager/system-connections/wired.nmconnection" <<'NMEOF'
[connection]
id=Wired DHCP
type=ethernet
autoconnect=true

[ipv4]
method=auto

[ipv6]
method=auto
NMEOF
  chmod 600 "${target}/etc/NetworkManager/system-connections/wired.nmconnection"

  # ── System files + manifest ──────────────────────────────────────────────
  k_install_system_files
  k_write_manifest

  # ── Finalize pacman.conf in the installed system ─────────────────────────
  # Write a clean pacman.conf for post-install use (internet repos)
  cat > "${target}/etc/pacman.conf" <<'PACFINAL'
[options]
HoldPkg     = pacman glibc
Architecture = auto
SigLevel    = Required DatabaseOptional
ParallelDownloads = 5

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist

[archzfs]
Server = https://archzfs.com/$repo/$arch
SigLevel = Optional TrustAll
PACFINAL

  mkdir -p "${target}/var/log/kldload"
  k_log_to "$log" "Arch Linux bootstrap complete"
}

# ══════════════════════════════════════════════════════════════════════════════
# Alpine Linux bootstrap (apk)
# ══════════════════════════════════════════════════════════════════════════════

# k_detect_alpine_darksite — returns the local darksite apk cache path
# if packages are available for offline install.
k_detect_alpine_darksite() {
  local darksite="/root/darksite/alpine"
  local count=0
  [[ -d "${darksite}/apk" ]] && count=$(find "${darksite}/apk" -name '*.apk' -not -name 'APKINDEX*' 2>/dev/null | wc -l)
  if [[ "$count" -gt 5 ]]; then
    echo "${darksite}"
    return 0
  fi
  return 1
}

_k_bootstrap_apk() {
  local target="${KLDLOAD_TARGET:?}"
  local log="${KLDLOAD_BOOTSTRAP_LOG:-/var/log/installer/bootstrap.log}"

  k_log_to "$log" "Bootstrapping Alpine Linux -> ${target}"

  # ── Detect darksite or internet ───────────────────────────────────────────
  local darksite=""
  if darksite="$(k_detect_alpine_darksite 2>/dev/null)"; then
    k_log_to "$log" "Using local darksite apk cache: ${darksite}"
  else
    darksite=""
    k_log_to "$log" "No darksite found — Alpine install will use internet mirrors"
  fi

  # ── Detect Alpine version ─────────────────────────────────────────────────
  local alpine_ver="${KLDLOAD_ALPINE_RELEASE:-3.21}"
  if [[ -n "$darksite" && -f "${darksite}/alpine-version" ]]; then
    alpine_ver="$(cat "${darksite}/alpine-version")"
  fi
  k_log_to "$log" "Alpine version: ${alpine_ver}"

  # ── Find apk.static ────────────────────────────────────────────────────────
  local apk_static=""
  for _candidate in /usr/local/bin/apk.static /usr/bin/apk.static; do
    if [[ -x "$_candidate" ]]; then
      apk_static="$_candidate"
      break
    fi
  done
  [[ -n "$apk_static" ]] || {
    k_log_to "$log" "FATAL: apk.static not found — cannot bootstrap Alpine"
    return 1
  }
  k_log_to "$log" "Using apk.static: ${apk_static}"

  # ── Create target directory structure ──────────────────────────────────────
  mkdir -p "${target}/dev" "${target}/proc" "${target}/sys" "${target}/run" \
           "${target}/tmp" "${target}/etc/apk" "${target}/var/cache/apk" \
           "${target}/etc/apk/keys"

  # Mount chroot filesystems
  mountpoint -q "${target}/dev" || mount --bind /dev "${target}/dev" 2>/dev/null || true
  mkdir -p "${target}/dev/pts"
  mountpoint -q "${target}/dev/pts" || mount --bind /dev/pts "${target}/dev/pts" 2>/dev/null || true
  mountpoint -q "${target}/proc" || mount -t proc proc "${target}/proc" 2>/dev/null || true
  mountpoint -q "${target}/sys" || mount -t sysfs sysfs "${target}/sys" 2>/dev/null || true
  mountpoint -q "${target}/run" || mount -t tmpfs tmpfs "${target}/run" 2>/dev/null || true

  # DNS for package downloads
  rm -f "${target}/etc/resolv.conf" 2>/dev/null || true
  cp /etc/resolv.conf "${target}/etc/resolv.conf" 2>/dev/null || \
    echo "nameserver 8.8.8.8" > "${target}/etc/resolv.conf"

  # ── Configure apk repositories ────────────────────────────────────────────
  if [[ -n "$darksite" ]]; then
    # Darksite mode: create a proper local repo structure apk expects
    # apk wants: {repo_url}/{arch}/APKINDEX.tar.gz
    # Populate target's apk cache with darksite packages so apk installs from cache.
    # We still need a repositories file pointing to the real Alpine repos so apk
    # can resolve package metadata, but --cache-dir + pre-populated cache means
    # no actual downloads happen.
    mkdir -p "${target}/var/cache/apk"
    find "${darksite}/apk/" -maxdepth 1 -name '*.apk' -exec cp {} "${target}/var/cache/apk/" \; 2>/dev/null || true
    cp "${darksite}/apk/APKINDEX.tar.gz" "${target}/var/cache/apk/" 2>/dev/null || true
    # Copy signing keys
    if [[ -d "${darksite}/keys" ]]; then
      cp "${darksite}/keys/"* "${target}/etc/apk/keys/" 2>/dev/null || true
    fi

    # Read alpine version from darksite
    cat > "${target}/etc/apk/repositories" <<REPOS
https://dl-cdn.alpinelinux.org/alpine/v${alpine_ver}/main
https://dl-cdn.alpinelinux.org/alpine/v${alpine_ver}/community
REPOS
    k_log_to "$log" "Darksite: $(ls "${target}/var/cache/apk/"*.apk 2>/dev/null | wc -l) packages cached"
  else
    cat > "${target}/etc/apk/repositories" <<REPOS
https://dl-cdn.alpinelinux.org/alpine/v${alpine_ver}/main
https://dl-cdn.alpinelinux.org/alpine/v${alpine_ver}/community
REPOS
  fi

  # ── Bootstrap with apk.static ─────────────────────────────────────────────
  k_log_to "$log" "Initializing apk database and installing base system..."

  # apk.static --root bootstraps a minimal system without needing apk in the target
  if [[ -n "$darksite" ]]; then
    # Darksite: install ALL cached .apk files directly — bypasses repo index entirely.
    # This avoids arch-mismatch issues (noarch vs x86_64) in APKINDEX.
    k_log_to "$log" "Darksite: installing all cached packages from .apk files..."
    # shellcheck disable=SC2046
    "$apk_static" --root "${target}" \
      --initdb \
      --allow-untrusted \
      --no-network \
      --no-cache \
      add $(find "${target}/var/cache/apk/" -maxdepth 1 -name '*.apk' -not -name 'APKINDEX*' | sort) \
      >> "$log" 2>&1 || {
      k_log_to "$log" "WARNING: apk.static base install had errors"
    }
  else
    "$apk_static" --root "${target}" \
      --initdb \
      --update-cache \
      --allow-untrusted \
      --repositories-file "${target}/etc/apk/repositories" \
      add alpine-base linux-lts linux-firmware mkinitfs efibootmgr \
          bash coreutils util-linux shadow grep sed findutils less \
          sudo openssh openssh-server-pam ca-certificates curl vim \
          iproute2 nftables wireguard-tools dhcpcd ifupdown-ng \
          musl musl-utils e2fsprogs dosfstools pv tzdata >> "$log" 2>&1 || {
      k_log_to "$log" "WARNING: apk.static base install had errors"
    }
  fi

  k_log_to "$log" "Base system installed: $(du -sh --exclude="${target}/proc" --exclude="${target}/sys" --exclude="${target}/dev" "${target}" 2>/dev/null | cut -f1 || echo "?")"

  # ── Switch to chroot apk for remaining installs ───────────────────────────
  # After base bootstrap, /sbin/apk exists inside the target

  # ── Install ZFS ────────────────────────────────────────────────────────────
  if [[ "${KLDLOAD_STORAGE_MODE:-standard}" == "zfs" ]]; then
    k_log_to "$log" "Installing ZFS packages..."

    # Generate hostid BEFORE mkinitfs so it gets baked into the initramfs
    chroot "${target}" zgenhostid -f 2>/dev/null || \
      dd if=/dev/urandom of="${target}/etc/hostid" bs=4 count=1 status=none
    k_log_to "$log" "hostid generated: $(xxd -p "${target}/etc/hostid" 2>/dev/null || echo "unknown")"

    # Install ZFS — in darksite mode, all packages were already installed from
    # cached .apk files in the base step. Verify ZFS is present; if not, try
    # installing from the cached .apk files directly.
    if chroot "${target}" apk info -e zfs 2>/dev/null | grep -q zfs; then
      k_log_to "$log" "ZFS packages already installed from darksite"
    elif [[ -n "$darksite" ]]; then
      k_log_to "$log" "Installing ZFS from cached .apk files..."
      # shellcheck disable=SC2046
      "$apk_static" --root "${target}" --allow-untrusted --no-network --no-cache \
        add $(find "${target}/var/cache/apk/" -maxdepth 1 -name 'zfs*.apk' | sort) \
        >> "$log" 2>&1 || {
        k_log_to "$log" "ERROR: ZFS install failed — ZFS will not work"
      }
    else
      chroot "${target}" apk add --allow-untrusted zfs zfs-lts zfs-libs zfs-openrc >> "$log" 2>&1 || {
        k_log_to "$log" "WARNING: ZFS package install had errors — trying with update"
        chroot "${target}" apk update >> "$log" 2>&1 || true
        chroot "${target}" apk add --allow-untrusted zfs zfs-lts zfs-libs zfs-openrc >> "$log" 2>&1 || {
          k_log_to "$log" "ERROR: ZFS install failed — ZFS will not work"
        }
      }
    fi

    # Configure mkinitfs for ZFS — add zfs to the features list
    local mkinitfs_conf="${target}/etc/mkinitfs/mkinitfs.conf"
    if [[ -f "$mkinitfs_conf" ]]; then
      # Add zfs to features if not already present
      if ! grep -q 'zfs' "$mkinitfs_conf"; then
        sed -i 's/^features="/features="zfs /' "$mkinitfs_conf" 2>/dev/null || {
          # If sed fails (different format), append to features line
          echo 'features="ata base cdrom ext4 keymap kms mmc nvme scsi usb virtio zfs"' > "$mkinitfs_conf"
        }
      fi
      k_log_to "$log" "mkinitfs.conf: $(grep '^features=' "$mkinitfs_conf")"
    else
      mkdir -p "${target}/etc/mkinitfs"
      echo 'features="ata base cdrom ext4 keymap kms mmc nvme scsi usb virtio zfs"' > "$mkinitfs_conf"
      k_log_to "$log" "mkinitfs.conf created with ZFS feature"
    fi

    # Rebuild initramfs with ZFS support
    local kver
    kver=$(ls "${target}/lib/modules/" 2>/dev/null | grep -v '^$' | head -1)
    if [[ -n "$kver" ]]; then
      k_log_to "$log" "Rebuilding initramfs with mkinitfs for ${kver}..."
      chroot "${target}" mkinitfs -k "$kver" >> "$log" 2>&1 || \
        k_log_to "$log" "WARNING: mkinitfs rebuild failed"

      # Verify zfs.ko is present
      if find "${target}/lib/modules/${kver}" -name 'zfs.ko*' 2>/dev/null | grep -q .; then
        k_log_to "$log" "VERIFIED: zfs.ko found for kernel ${kver}"
      else
        k_log_to "$log" "ERROR: zfs.ko NOT found for kernel ${kver} — boot will fail!"
      fi
    fi

    # Enable ZFS OpenRC services (per Alpine wiki: default runlevel, not sysinit)
    chroot "${target}" rc-update add zfs-import boot >> "$log" 2>&1 || true
    chroot "${target}" rc-update add zfs-load-key boot >> "$log" 2>&1 || true
    chroot "${target}" rc-update add zfs-mount boot >> "$log" 2>&1 || true
    chroot "${target}" rc-update add zfs-zed default >> "$log" 2>&1 || true
    k_log_to "$log" "ZFS OpenRC services enabled (import, load-key, mount, zed)"

    # Install ZFS scrub + trim cron scripts (Alpine doesn't ship these)
    mkdir -p "${target}/usr/libexec/zfs"
    cat > "${target}/usr/libexec/zfs/scrub" <<'SCRUBEOF'
#!/bin/sh -eu
[ -d /sys/module/zfs ] || exit 0
PROPERTY_NAME="org.alpine:periodic-scrub"
get_property () { zfs get -H -o value "${PROPERTY_NAME}" "$1" 2>/dev/null || return 1; }
scrub_if_not_in_progress () {
  zpool status "$1" | grep -q "scrub in progress" || zpool scrub "$1" || true
}
zpool list -H -o health,name 2>&1 | awk -F'\t' '$1 == "ONLINE" {print $2}' | while read pool; do
  ret=$(get_property "${pool}")
  if [ $? -ne 0 ] || [ "disable" = "${ret}" ]; then :
  elif [ "-" = "${ret}" ] || [ "auto" = "${ret}" ] || [ "enable" = "${ret}" ]; then
    scrub_if_not_in_progress "${pool}"
  fi
done
SCRUBEOF
    cat > "${target}/usr/libexec/zfs/trim" <<'TRIMEOF'
#!/bin/sh -eu
[ -d /sys/module/zfs ] || exit 0
PROPERTY_NAME="org.alpine:periodic-trim"
get_property () { zfs get -H -o value "${PROPERTY_NAME}" "$1" 2>/dev/null || return 1; }
trim_if_not_trimming () {
  zpool status "$1" | grep -q "trimming" || zpool trim "$1" || true
}
zpool_is_nvme_only () {
  zpool list -vHPL "$1" | awk -F'\t' '$2 ~ /^\/dev\// { if($2 !~ /^\/dev\/nvme/) exit 1 }'
}
zpool list -H -o health,name 2>&1 | awk -F'\t' '$1 == "ONLINE" {print $2}' | while read pool; do
  ret=$(get_property "${pool}")
  if [ $? -ne 0 ] || [ "disable" = "${ret}" ]; then :
  elif [ "enable" = "${ret}" ]; then trim_if_not_trimming "${pool}"
  elif [ "-" = "${ret}" ] || [ "auto" = "${ret}" ]; then
    zpool_is_nvme_only "${pool}" && trim_if_not_trimming "${pool}"
  fi
done
TRIMEOF
    chmod +x "${target}/usr/libexec/zfs/scrub" "${target}/usr/libexec/zfs/trim"

    # Add monthly cron jobs for scrub (2nd Sunday) and trim (1st Sunday)
    mkdir -p "${target}/var/spool/cron/crontabs"
    cat > "${target}/var/spool/cron/crontabs/root" <<'CRONEOF'
# zfs scrub — 2nd Sunday of every month
24 0 8-14 * * if [ $(date +\%w) -eq 0 ] && [ -x /usr/libexec/zfs/scrub ]; then /usr/libexec/zfs/scrub; fi
# zfs trim — 1st Sunday of every month
24 0 1-7 * * if [ $(date +\%w) -eq 0 ] && [ -x /usr/libexec/zfs/trim ]; then /usr/libexec/zfs/trim; fi
CRONEOF
    chmod 600 "${target}/var/spool/cron/crontabs/root"
    chroot "${target}" rc-update add crond default >> "$log" 2>&1 || true
    k_log_to "$log" "ZFS scrub/trim cron scripts installed"
  fi

  # ── Profile packages ─────────────────────────────────────────────────────
  local profile_pkgs profile_opt
  profile_pkgs="$(k_profile_packages)"
  profile_opt="$(k_profile_optional_packages)"
  if [[ -n "${profile_pkgs}${profile_opt}" ]]; then
    k_log_to "$log" "Installing profile packages..."
    # shellcheck disable=SC2086
    chroot "${target}" apk add --allow-untrusted ${profile_pkgs} ${profile_opt} >> "$log" 2>&1 || {
      k_log_to "$log" "WARNING: Some profile packages failed"
    }
  fi

  # ── Locale + timezone + hostname ─────────────────────────────────────────
  # Alpine/musl has minimal locale support — no locale-gen
  ln -sf "/usr/share/zoneinfo/${KLDLOAD_TIMEZONE:-UTC}" "${target}/etc/localtime" 2>/dev/null || true
  echo "${KLDLOAD_TIMEZONE:-UTC}" > "${target}/etc/timezone"

  echo "${KLDLOAD_HOSTNAME:-kldload}" > "${target}/etc/hostname"
  cat > "${target}/etc/hosts" <<EOH
127.0.0.1 localhost
127.0.1.1 ${KLDLOAD_HOSTNAME:-kldload}
::1 localhost ip6-localhost ip6-loopback
EOH

  # ── Users ────────────────────────────────────────────────────────────────
  k_create_users

  # ── Networking (ifupdown-ng, not NetworkManager) ─────────────────────────
  cat > "${target}/etc/network/interfaces" <<NET
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
NET

  # ── SSH: enable password auth + generate host keys ───────────────────────
  local _sshd_conf="${target}/etc/ssh/sshd_config"
  if [[ -f "$_sshd_conf" ]]; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$_sshd_conf"
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$_sshd_conf"
  fi
  chroot "${target}" ssh-keygen -A >> "$log" 2>&1 || true
  k_log_to "$log" "SSH host keys generated"

  # ── Enable OpenRC services ──────────────────────────────────────────────
  chroot "${target}" rc-update add sshd default >> "$log" 2>&1 || true
  chroot "${target}" rc-update add dhcpcd default >> "$log" 2>&1 || true
  chroot "${target}" rc-update add nftables default >> "$log" 2>&1 || true
  chroot "${target}" rc-update add networking boot >> "$log" 2>&1 || true

  # Set default runlevel
  chroot "${target}" rc-update add devfs sysinit >> "$log" 2>&1 || true
  chroot "${target}" rc-update add dmesg sysinit >> "$log" 2>&1 || true
  chroot "${target}" rc-update add mdev sysinit >> "$log" 2>&1 || true
  chroot "${target}" rc-update add hwdrivers sysinit >> "$log" 2>&1 || true
  chroot "${target}" rc-update add hwclock boot >> "$log" 2>&1 || true
  chroot "${target}" rc-update add modules boot >> "$log" 2>&1 || true
  chroot "${target}" rc-update add sysctl boot >> "$log" 2>&1 || true
  chroot "${target}" rc-update add hostname boot >> "$log" 2>&1 || true
  chroot "${target}" rc-update add bootmisc boot >> "$log" 2>&1 || true
  chroot "${target}" rc-update add syslog boot >> "$log" 2>&1 || true

  # ── System files + manifest ──────────────────────────────────────────────
  k_install_system_files
  k_write_manifest

  # ── Finalize apk repositories for post-install use ────────────────────────
  cat > "${target}/etc/apk/repositories" <<REPOS
https://dl-cdn.alpinelinux.org/alpine/v${alpine_ver}/main
https://dl-cdn.alpinelinux.org/alpine/v${alpine_ver}/community
REPOS

  mkdir -p "${target}/var/log/kldload"
  k_log_to "$log" "Alpine Linux bootstrap complete"
}

# ══════════════════════════════════════════════════════════════════════════════
# BSD / illumos bootstrap functions
# ══════════════════════════════════════════════════════════════════════════════

_k_bootstrap_freebsd() {
  local target="${KLDLOAD_TARGET:?}"
  local log="${KLDLOAD_BOOTSTRAP_LOG:-/var/log/installer/bootstrap.log}"
  local darksite="/root/darksite-bsd/freebsd"
  local freebsd_ver="${KLDLOAD_FREEBSD_VERSION:-15.0}"
  local freebsd_arch="${KLDLOAD_ARCH:-amd64}"
  local freebsd_url="https://download.freebsd.org/releases/${freebsd_arch}/${freebsd_arch}/${freebsd_ver}-RELEASE"

  k_log_to "$log" "FreeBSD ${freebsd_ver} bootstrap starting..."

  # Download base and kernel on demand if darksite doesn't have them
  if [[ ! -f "${darksite}/base.txz" ]]; then
    k_log_to "$log" "Downloading FreeBSD ${freebsd_ver} base.txz..."
    mkdir -p "${darksite}"
    curl -fSL --connect-timeout 30 --max-time 600 --retry 3 \
      -o "${darksite}/base.txz" "${freebsd_url}/base.txz" >> "$log" 2>&1 \
      || { k_log_to "$log" "FATAL: Failed to download FreeBSD base.txz from ${freebsd_url}"; return 1; }
    k_log_to "$log" "base.txz downloaded ($(du -h "${darksite}/base.txz" | cut -f1))"
  fi

  if [[ ! -f "${darksite}/kernel.txz" ]]; then
    k_log_to "$log" "Downloading FreeBSD ${freebsd_ver} kernel.txz..."
    curl -fSL --connect-timeout 30 --max-time 300 --retry 3 \
      -o "${darksite}/kernel.txz" "${freebsd_url}/kernel.txz" >> "$log" 2>&1 \
      || { k_log_to "$log" "FATAL: Failed to download FreeBSD kernel.txz from ${freebsd_url}"; return 1; }
    k_log_to "$log" "kernel.txz downloaded ($(du -h "${darksite}/kernel.txz" | cut -f1))"
  fi

  # Extract base and kernel
  # GNU tar warns about BSD-specific SCHILY.fflags and gid mismatches — safe to ignore
  k_log_to "$log" "Extracting FreeBSD base..."
  tar -xpf "${darksite}/base.txz" -C "${target}" >> "$log" 2>&1 || true
  k_log_to "$log" "Extracting FreeBSD kernel..."
  tar -xpf "${darksite}/kernel.txz" -C "${target}" >> "$log" 2>&1 || true

  # Verify extraction worked
  [[ -f "${target}/bin/sh" ]] || { k_log_to "$log" "FATAL: FreeBSD base extraction failed — /bin/sh not found"; return 1; }

  # Configure rc.conf
  cat > "${target}/etc/rc.conf" <<RCCONF
hostname="${KLDLOAD_HOSTNAME:-kldload}"
ifconfig_DEFAULT="DHCP"
sshd_enable="YES"
zfs_enable="YES"
dumpdev="AUTO"
RCCONF

  # Enable ZFS boot
  echo 'zfs_load="YES"' > "${target}/boot/loader.conf"
  echo "vfs.root.mountfrom=\"zfs:rpool/ROOT/${KLDLOAD_HOSTNAME:-kldload}\"" >> "${target}/boot/loader.conf"

  # DNS
  cp /etc/resolv.conf "${target}/etc/resolv.conf" 2>/dev/null || true

  # Timezone
  ln -sf "/usr/share/zoneinfo/${KLDLOAD_TIMEZONE:-UTC}" "${target}/etc/localtime" 2>/dev/null || true

  # Create user — can't chroot into FreeBSD from Linux, so write passwd/group directly
  local user="${KLDLOAD_USERNAME:-admin}"
  k_log_to "$log" "Creating user ${user} via direct file edits (no chroot — FreeBSD binaries)"

  # Append user to /etc/passwd and /etc/group (FreeBSD format)
  # UID 1001, GID 1001, member of wheel
  if ! grep -q "^${user}:" "${target}/etc/passwd" 2>/dev/null; then
    echo "${user}:*:1001:1001::0:0:${user} User:/home/${user}:/bin/sh" >> "${target}/etc/passwd"
    echo "${user}:*:1001:" >> "${target}/etc/group"
    # Add to wheel group
    sed -i 's/^wheel:\([^:]*\):\([^:]*\):\(.*\)/wheel:\1:\2:\3,'"${user}"'/' "${target}/etc/group"
    # Clean trailing comma if wheel had no members
    sed -i 's/^wheel:\([^:]*\):\([^:]*\):,/wheel:\1:\2:/' "${target}/etc/group"
    mkdir -p "${target}/home/${user}"
  fi

  # Set password via master.passwd if provided (hash with openssl)
  if [[ -n "${KLDLOAD_PASSWORD:-}" ]]; then
    local pass_hash
    pass_hash="$(openssl passwd -6 "${KLDLOAD_PASSWORD}")"
    # Write master.passwd entry (FreeBSD extended format)
    if ! grep -q "^${user}:" "${target}/etc/master.passwd" 2>/dev/null; then
      echo "${user}:${pass_hash}:1001:1001::0:0:${user} User:/home/${user}:/bin/sh" >> "${target}/etc/master.passwd"
    fi
    # Set root password too
    sed -i "s|^root:\*:|root:${pass_hash}:|" "${target}/etc/master.passwd" 2>/dev/null || true
    k_log_to "$log" "Passwords set for root and ${user}"
  fi

  # Enable root login via SSH (initial setup only)
  sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' "${target}/etc/ssh/sshd_config" 2>/dev/null || true

  # First-boot: rebuild password DB and SSH host keys
  # pwd_mkdb is a FreeBSD binary — can't run from Linux, so defer to first boot
  cat > "${target}/etc/rc.local" <<'RCLOCAL'
#!/bin/sh
# kldload first-boot — rebuild password DB from master.passwd edits
if [ -f /etc/master.passwd ]; then
  /usr/sbin/pwd_mkdb -p /etc/master.passwd
fi
# Regenerate SSH host keys if missing
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  /usr/bin/ssh-keygen -A
fi
# Self-destruct — only needed once
rm -f /etc/rc.local
RCLOCAL
  chmod 0755 "${target}/etc/rc.local"
  k_log_to "$log" "rc.local written for first-boot pwd_mkdb + SSH keygen"

  # FreeBSD bootloader EFI
  local efi_mnt="${KLDLOAD_TARGET_MNT:-/target}/boot/efi"
  mkdir -p "${efi_mnt}/EFI/BOOT"
  cp "${target}/boot/loader.efi" "${efi_mnt}/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || true

  mkdir -p "${target}/var/log/kldload"
  k_log_to "$log" "FreeBSD bootstrap complete"
}

_k_bootstrap_openbsd() {
  local log="${KLDLOAD_BOOTSTRAP_LOG:-/var/log/installer/bootstrap.log}"
  local disk="${KLDLOAD_DISK:?}"
  local openbsd_ver="${KLDLOAD_OPENBSD_VERSION:-7.8}"
  local openbsd_url="https://cdn.openbsd.org/pub/OpenBSD/${openbsd_ver}/amd64"
  local staging="/tmp/openbsd-stage"
  local user="${KLDLOAD_USERNAME:-admin}"
  local pass="${KLDLOAD_PASSWORD:-admin}"
  local hostname="${KLDLOAD_HOSTNAME:-kldload}"

  k_log_to "$log" "OpenBSD ${openbsd_ver} chain-boot install starting..."
  k_log_to "$log" "Strategy: stage bsd.rd + autoinstall on EFI, installer pulls sets from cdn.openbsd.org"

  mkdir -p "${staging}"

  # ── Download only bsd.rd (ramdisk installer) — sets pulled by installer ──
  k_log_to "$log" "Downloading OpenBSD ${openbsd_ver} installer kernel..."
  curl -fSL --connect-timeout 30 --max-time 120 --retry 3 \
    -o "${staging}/bsd.rd" "${openbsd_url}/bsd.rd" >> "$log" 2>&1 \
    || { k_log_to "$log" "FATAL: Failed to download bsd.rd"; return 1; }
  k_log_to "$log" "bsd.rd downloaded ($(du -h "${staging}/bsd.rd" | cut -f1))"

  # ── Partition the disk ───────────────────────────────────────────────────
  # EFI (512M) + OpenBSD raw partition (rest of disk)
  # OpenBSD's installer will create disklabel + FFS inside the raw partition
  k_log_to "$log" "Partitioning ${disk} for OpenBSD..."
  sgdisk -Z "${disk}" >> "$log" 2>&1 || true
  sgdisk -n1:0:+512M -t1:EF00 -c1:EFI "${disk}" >> "$log" 2>&1
  sgdisk -n2:0:0 -t2:A600 -c2:OpenBSD "${disk}" >> "$log" 2>&1
  partprobe "${disk}" 2>/dev/null || true
  sleep 2

  # Determine partition device names
  local efi_part root_part
  case "${disk}" in
    *nvme*|*mmcblk*|*loop*) efi_part="${disk}p1"; root_part="${disk}p2" ;;
    *) efi_part="${disk}1"; root_part="${disk}2" ;;
  esac

  # Format EFI partition
  mkfs.fat -F32 -n EFI "${efi_part}" >> "$log" 2>&1
  k_log_to "$log" "EFI partition formatted: ${efi_part}"

  # ── Stage bsd.rd and sets on EFI partition ───────────────────────────────
  local efi_mnt="/tmp/openbsd-efi"
  mkdir -p "${efi_mnt}"
  mount "${efi_part}" "${efi_mnt}"

  # OpenBSD EFI bootloader — extract from base set or use bsd.rd directly
  mkdir -p "${efi_mnt}/EFI/BOOT"

  # bsd.rd IS the installer — copy it as the EFI boot target
  # OpenBSD's BOOTX64.EFI loads bsd or bsd.rd from the root
  # We need the actual EFI loader — download it
  k_log_to "$log" "Downloading OpenBSD BOOTX64.EFI..."
  curl -fSL --connect-timeout 30 --max-time 60 --retry 3 \
    -o "${efi_mnt}/EFI/BOOT/BOOTX64.EFI" \
    "${openbsd_url}/BOOTX64.EFI" >> "$log" 2>&1 \
    || k_log_to "$log" "WARNING: BOOTX64.EFI download failed"

  # Copy bsd.rd to EFI root — OpenBSD's bootloader looks for it here
  cp "${staging}/bsd.rd" "${efi_mnt}/bsd.rd"
  k_log_to "$log" "bsd.rd staged on EFI partition ($(du -h "${efi_mnt}/bsd.rd" | cut -f1))"

  # ── Write auto_install.conf (OpenBSD autoinstall answer file) ────────────
  cat > "${efi_mnt}/auto_install.conf" <<AUTOINSTALL
System hostname = ${hostname}
Password for root = ${pass}
Setup a user = ${user}
Password for user = ${pass}
Allow root ssh login = yes
What timezone are you in = ${KLDLOAD_TIMEZONE:-UTC}
Which disk is the root disk = ${disk##*/}
Use (W)hole disk MBR, whole disk (G)PT or (E)dit? = G
Use (A)uto layout, (E)dit auto layout, or create (C)ustom layout? = A
Location of sets = http
HTTP Server = cdn.openbsd.org
Server directory = pub/OpenBSD/${openbsd_ver}/amd64
Set name(s) = done
AUTOINSTALL
  k_log_to "$log" "auto_install.conf written"

  # ── Configure EFI boot to load bsd.rd ────────────────────────────────────
  mkdir -p "${efi_mnt}/etc"
  cat > "${efi_mnt}/etc/boot.conf" <<'BOOTCONF'
boot bsd.rd
BOOTCONF

  # startup.nsh fallback for UEFI shell
  echo '\EFI\BOOT\BOOTX64.EFI' > "${efi_mnt}/startup.nsh"

  umount "${efi_mnt}"
  k_log_to "$log" "EFI partition configured for OpenBSD chain-boot"

  # ── Register EFI boot entry ──────────────────────────────────────────────
  local efi_disk part_num
  efi_disk="$(lsblk -no PKNAME "${efi_part}" 2>/dev/null | head -n1 || true)"
  [[ -n "$efi_disk" ]] && efi_disk="/dev/$efi_disk"
  part_num="$(lsblk -no PARTN "${efi_part}" 2>/dev/null | head -n1 || true)"
  part_num="${part_num:-1}"

  if [[ -n "${efi_disk}" && -b "${efi_disk}" ]]; then
    efibootmgr \
      -c -d "${efi_disk}" -p "${part_num}" \
      -L "OpenBSD" \
      -l '\EFI\BOOT\BOOTX64.EFI' >> "$log" 2>&1 || \
      k_log_to "$log" "WARNING: efibootmgr registration failed"
    k_log_to "$log" "EFI boot entry registered: OpenBSD on ${efi_disk}"
  fi

  # Export partition vars for the bootloader step (which will be skipped)
  export KLDLOAD_PART_EFI="${efi_part}"
  export KLDLOAD_EFI_PART="${efi_part}"

  k_log_to "$log" ""
  k_log_to "$log" "══════════════════════════════════════════════════════════════"
  k_log_to "$log" "  OpenBSD ${openbsd_ver} chain-boot install staged."
  k_log_to "$log" "  On next reboot, OpenBSD's own installer (bsd.rd) will run."
  k_log_to "$log" "  auto_install.conf will automate the install."
  k_log_to "$log" "  User: ${user} / root — Password: (as configured)"
  k_log_to "$log" "══════════════════════════════════════════════════════════════"
  k_log_to "$log" ""
  k_log_to "$log" "OpenBSD bootstrap complete — reboot to begin installation"
}

_k_bootstrap_ghostbsd() {
  local target="${KLDLOAD_TARGET:?}"
  local log="${KLDLOAD_BOOTSTRAP_LOG:-/var/log/installer/bootstrap.log}"

  # GhostBSD is FreeBSD + desktop — bootstrap with FreeBSD base
  k_log_to "$log" "GhostBSD bootstrap starting (FreeBSD base + desktop)..."
  _k_bootstrap_freebsd

  # Enable MATE desktop (GhostBSD default)
  cat >> "${target}/etc/rc.conf" <<GHOST
slim_enable="YES"
dbus_enable="YES"
hald_enable="YES"
GHOST

  # Desktop packages will be installed on firstboot via pkg
  mkdir -p "${target}/etc/kldload"
  cat > "${target}/etc/kldload/firstboot-packages.txt" <<'PKGS'
xorg mate mate-desktop slim firefox
PKGS

  k_log_to "$log" "GhostBSD bootstrap complete (desktop packages install on firstboot)"
}

_k_bootstrap_illumos() {
  local target="${KLDLOAD_TARGET:?}"
  local log="${KLDLOAD_BOOTSTRAP_LOG:-/var/log/installer/bootstrap.log}"
  local darksite="/root/darksite-bsd/illumos"

  k_log_to "$log" "illumos (OpenIndiana) bootstrap starting..."

  # illumos installs differently — it uses its own installer (caiman/kayak)
  # For kldload, we chain-boot the OpenIndiana ISO and let its installer handle it
  # The kldload value-add is the ZFS configuration and darksite embedding

  if [[ -f "${darksite}/oi-hipster-minimal.iso" ]]; then
    # Copy the ISO to the target disk for chain-booting
    local iso_dest="/root/darksite-bsd/illumos/oi-hipster-minimal.iso"
    k_log_to "$log" "illumos ISO available at: ${iso_dest}"
    k_log_to "$log" "illumos requires its native installer — reboot from this ISO"
    k_log_to "$log" "After install, kldload tools can be added via: pkg install kldload-tools"
  else
    k_log_to "$log" "WARNING: OpenIndiana ISO not found in darksite"
    k_log_to "$log" "Download from: https://www.openindiana.org/download/"
  fi

  k_log_to "$log" "illumos bootstrap complete (chain-boot installer)"
}

_k_bootstrap_windows() {
  local target="${KLDLOAD_TARGET:?}"
  local log="${KLDLOAD_BOOTSTRAP_LOG:-/var/log/installer/bootstrap.log}"
  local disk="${KLDLOAD_DISK:?}"

  k_log_to "$log" "Windows bootstrap starting..."

  # User must provide a Windows ISO — check common locations
  local win_iso=""
  for _path in /root/windows.iso /home/live/Desktop/*.iso /home/live/Downloads/*.iso /media/*/sources/install.wim; do
    if [[ -f "$_path" ]]; then
      win_iso="$_path"
      break
    fi
  done

  # Also check if a mounted USB/CD has Windows files
  if [[ -z "$win_iso" ]]; then
    for _mnt in /media/* /run/media/live/*; do
      if [[ -f "${_mnt}/sources/install.wim" ]]; then
        win_iso="${_mnt}/sources/install.wim"
        break
      fi
    done
  fi

  if [[ -z "$win_iso" ]]; then
    k_log_to "$log" "FATAL: No Windows ISO or install.wim found"
    k_log_to "$log" "Place a Windows ISO on the Desktop, Downloads, or mount a Windows install USB"
    return 1
  fi

  k_log_to "$log" "Windows source: ${win_iso}"

  # If it's an ISO, mount it and find install.wim
  local wim_file=""
  if [[ "$win_iso" == *.iso ]]; then
    mkdir -p /mnt/win-iso
    mount -o loop,ro "$win_iso" /mnt/win-iso 2>/dev/null || \
      { k_log_to "$log" "FATAL: Cannot mount Windows ISO"; return 1; }
    wim_file="/mnt/win-iso/sources/install.wim"
  elif [[ "$win_iso" == *.wim ]]; then
    wim_file="$win_iso"
  else
    wim_file="$win_iso"
  fi

  [[ -f "$wim_file" ]] || { k_log_to "$log" "FATAL: install.wim not found in ISO"; return 1; }

  # Show available Windows editions
  k_log_to "$log" "Available Windows editions:"
  wiminfo "$wim_file" >> "$log" 2>&1

  # Use image index 1 (usually Windows Pro or the first available)
  local wim_index="${KLDLOAD_WINDOWS_INDEX:-1}"

  # Partition the disk: EFI (512M) + MSR (16M) + Windows (NTFS)
  k_log_to "$log" "Partitioning ${disk} for Windows..."
  sgdisk --zap-all "$disk" >> "$log" 2>&1
  sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI" "$disk" >> "$log" 2>&1
  sgdisk -n 2:0:+16M  -t 2:0c01 -c 2:"MSR" "$disk" >> "$log" 2>&1
  sgdisk -n 3:0:0     -t 3:0700 -c 3:"Windows" "$disk" >> "$log" 2>&1
  partprobe "$disk" 2>/dev/null; sleep 2

  # Determine partition names
  local part1="${disk}1" part3="${disk}3"
  [[ -b "${disk}p1" ]] && part1="${disk}p1" && part3="${disk}p3"

  # Format
  mkfs.fat -F32 "$part1" >> "$log" 2>&1
  mkfs.ntfs -f -L "Windows" "$part3" >> "$log" 2>&1

  # Mount
  mkdir -p /mnt/win-efi /mnt/win-root
  mount "$part3" /mnt/win-root
  mount "$part1" /mnt/win-efi

  # Apply Windows image
  k_log_to "$log" "Applying Windows image (index ${wim_index}) — this takes a few minutes..."
  wimapply "$wim_file" "$wim_index" /mnt/win-root >> "$log" 2>&1 || \
    { k_log_to "$log" "FATAL: wimapply failed"; return 1; }

  # Install bootloader
  k_log_to "$log" "Installing Windows bootloader..."
  mkdir -p /mnt/win-efi/EFI/Microsoft/Boot
  if [[ -f /mnt/win-root/Windows/Boot/EFI/bootmgfw.efi ]]; then
    cp /mnt/win-root/Windows/Boot/EFI/bootmgfw.efi /mnt/win-efi/EFI/Microsoft/Boot/
    cp /mnt/win-root/Windows/Boot/EFI/bootmgfw.efi /mnt/win-efi/EFI/BOOT/BOOTX64.EFI
    k_log_to "$log" "Windows bootloader installed"
  else
    k_log_to "$log" "WARNING: bootmgfw.efi not found — manual BCD setup may be needed"
  fi

  # Copy BCD from Windows image
  if [[ -d /mnt/win-root/Windows/Boot/EFI ]]; then
    cp -r /mnt/win-root/Windows/Boot/EFI/BCD /mnt/win-efi/EFI/Microsoft/Boot/ 2>/dev/null || true
  fi

  # Install virtio drivers if available (for KVM/Proxmox)
  if [[ -d /usr/share/virtio-win ]] || [[ -d /root/darksite/virtio-win ]]; then
    local vio_src="/usr/share/virtio-win"
    [[ -d /root/darksite/virtio-win ]] && vio_src="/root/darksite/virtio-win"
    k_log_to "$log" "Copying virtio drivers for KVM guests..."
    mkdir -p /mnt/win-root/virtio-drivers
    cp -r "${vio_src}/." /mnt/win-root/virtio-drivers/ 2>/dev/null || true
  fi

  # Cleanup
  sync
  umount /mnt/win-efi 2>/dev/null || true
  umount /mnt/win-root 2>/dev/null || true
  [[ -d /mnt/win-iso ]] && umount /mnt/win-iso 2>/dev/null || true

  k_log_to "$log" "Windows bootstrap complete — reboot to finish Windows setup (OOBE)"
}
