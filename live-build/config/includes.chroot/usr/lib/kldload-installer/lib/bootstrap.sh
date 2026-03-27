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
}

k_unbind_chroot_mounts() {
  local target="${KLDLOAD_TARGET:?}"
  k_umount_if_mounted "${target}/sys/firmware/efi/efivars"
  k_umount_if_mounted "${target}/run"
  k_umount_if_mounted "${target}/sys"
  k_umount_if_mounted "${target}/proc"
  k_umount_if_mounted "${target}/dev/pts"
  k_umount_if_mounted "${target}/dev"
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

  if [[ -n "${KLDLOAD_ROOT_PASSWORD:-}" ]]; then
    echo "root:${KLDLOAD_ROOT_PASSWORD}" | chroot "${target}" chpasswd
  fi

  if ! chroot "${target}" id "${user}" >/dev/null 2>&1; then
    # CentOS uses 'wheel', Debian uses 'sudo'
    local admin_group="sudo"
    chroot "${target}" getent group wheel >/dev/null 2>&1 && admin_group="wheel"
    k_in_chroot "${target}" useradd -m -s /bin/bash -G "${admin_group}" "${user}"
  fi

  if [[ -n "${KLDLOAD_PASSWORD:-}" ]]; then
    echo "${user}:${KLDLOAD_PASSWORD}" | chroot "${target}" chpasswd
  fi
}

k_write_manifest() {
  local target="${KLDLOAD_TARGET_MNT:-${KLDLOAD_TARGET:-/target}}"
  mkdir -p "${target}/etc/kldload"

  cat > "${target}/etc/kldload/install-manifest.env" <<EOM
KLDLOAD_PROFILE=${KLDLOAD_PROFILE:-server}
KLDLOAD_STORAGE_MODE=${KLDLOAD_STORAGE_MODE:-standard}
KLDLOAD_ENABLE_ZFS=${KLDLOAD_ENABLE_ZFS:-0}
KLDLOAD_ENABLE_EBPF=${KLDLOAD_ENABLE_EBPF:-0}
KLDLOAD_SECURE_BOOT=${KLDLOAD_SECURE_BOOT:-0}
KLDLOAD_TPM_PRESENT=${KLDLOAD_TPM_PRESENT:-0}
KLDLOAD_ENABLE_AI=${KLDLOAD_ENABLE_AI:-0}
EOM
}

# k_generate_mok_keys — create MOK key pair at the standard DKMS paths and
# configure DKMS to sign modules during build.  Must be called BEFORE any
# package installation so that when zfs-dkms is installed, DKMS builds the
# kernel module and signs it in a single pass — no retroactive signing needed.
k_generate_mok_keys() {
  local target="${KLDLOAD_TARGET:?}"
  local mok_dir="${target}/var/lib/dkms"

  k_log_to "${KLDLOAD_BOOTSTRAP_LOG}" "Generating MOK key pair for DKMS module signing"

  mkdir -p "${mok_dir}"

  # RSA-2048 key + self-signed cert — 10-year validity, no passphrase
  openssl req -new -x509 -newkey rsa:2048 \
    -keyout "${mok_dir}/mok.key" \
    -out    "${mok_dir}/mok.pub" \
    -days 3650 -nodes \
    -subj "/CN=kldload Secure Boot MOK/" \
    >> "${KLDLOAD_BOOTSTRAP_LOG}" 2>&1

  # DER format required by mokutil --import
  openssl x509 \
    -in "${mok_dir}/mok.pub" \
    -out "${mok_dir}/mok.der" \
    -outform DER \
    >> "${KLDLOAD_BOOTSTRAP_LOG}" 2>&1

  chmod 0600 "${mok_dir}/mok.key"
  chmod 0644 "${mok_dir}/mok.pub" "${mok_dir}/mok.der"

  # DKMS sign_tool script — called by DKMS as: script KVER MODULE_PATH
  # Uses the sign-file binary from the matching linux-headers package.
  mkdir -p "${target}/etc/dkms"
  cat > "${target}/etc/dkms/sign_helper.sh" <<'EOSIGN'
#!/bin/bash
set -euo pipefail
KVER="${1:?}" MOD="${2:?}"
KEY=/var/lib/dkms/mok.key
CERT=/var/lib/dkms/mok.pub
SIGN_FILE=$(find /usr/src/linux-headers-"${KVER}" \
                 /usr/lib/linux-kbuild-"${KVER%%.*}"* \
                 -name sign-file -type f 2>/dev/null | head -1 || true)
[[ -x "${SIGN_FILE}" ]] || { echo "sign-file not found for ${KVER}" >&2; exit 0; }
exec "${SIGN_FILE}" sha256 "${KEY}" "${CERT}" "${MOD}"
EOSIGN
  chmod 0755 "${target}/etc/dkms/sign_helper.sh"

  # Wire into DKMS — all future module builds will be signed automatically
  printf 'sign_tool=/etc/dkms/sign_helper.sh\n' \
    >> "${target}/etc/dkms/framework.conf"

  k_log_to "${KLDLOAD_BOOTSTRAP_LOG}" "MOK keys ready at /var/lib/dkms/mok.{key,pub,der} — DKMS will sign on install"
}

k_install_target_packages() {
  local target="${KLDLOAD_TARGET:?}"
  local -a pkgs
  local profile_pkgs profile_opt

  # Generate MOK keys BEFORE package installation so DKMS signs ZFS modules
  # during build rather than requiring retroactive signing afterward.
  k_generate_mok_keys

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
    k_in_chroot "${target}" bash -lc "apt-get install -y ${profile_pkgs} ${profile_opt}"
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

  # Fedora uses its own release version (41), not the EL release (9)
  if [[ "${distro}" == "fedora" ]]; then
    release="${KLDLOAD_FEDORA_RELEASE:-41}"
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

      # Step 2: Install redhat-release into the installroot so it has proper
      # RHEL identity from the start (no CentOS packages ever touch it)
      k_log_to "$log" "Setting up clean RHEL ${release} installroot..."
      local rhel_rpms="/root/darksite/rhel-release"
      [[ -d "$rhel_rpms" ]] || rhel_rpms="/usr/share/kldload/rhel-release"
      if [[ -d "$rhel_rpms" ]] && ls "$rhel_rpms"/redhat-release*.rpm >/dev/null 2>&1; then
        mkdir -p "${target}/tmp"
        cp "$rhel_rpms"/redhat-release*.rpm "${target}/tmp/"
        rpm --root="${target}" -ivh --nodeps "${target}"/tmp/redhat-release*.rpm 2>>"$log" || true
        rm -f "${target}"/tmp/redhat-release*.rpm
        k_log_to "$log" "redhat-release installed: $(chroot "${target}" cat /etc/redhat-release 2>/dev/null || echo unknown)"
      else
        k_log_to "$log" "WARNING: redhat-release RPMs not found — creating minimal RHEL identity"
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
        mount -t proc proc "${target}/proc" 2>/dev/null || true
        mount -t sysfs sysfs "${target}/sys" 2>/dev/null || true
        mount --bind /dev "${target}/dev" 2>/dev/null || true
        mount --bind /dev/pts "${target}/dev/pts" 2>/dev/null || true
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
        chroot "${target}" rpm -e --nodeps --allmatches \
          $(chroot "${target}" rpm -qa 'centos-*' 2>/dev/null) 2>>"$log" || true
        # Install redhat-release
        local rhel_rpms="/root/darksite/rhel-release"
        [[ -d "$rhel_rpms" ]] || rhel_rpms="/usr/share/kldload/rhel-release"
        if [[ -d "$rhel_rpms" ]]; then
          cp "$rhel_rpms"/redhat-release*.rpm "${target}/tmp/"
          chroot "${target}" rpm -ivh --force --nodeps /tmp/redhat-release*.rpm 2>>"$log" || true
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
      local fedora_release="${KLDLOAD_FEDORA_RELEASE:-41}"
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

  # ZFS repo — Fedora uses /fedora/$releasever, EL uses /epel/$releasever
  if [[ "${distro}" == "fedora" ]]; then
    local _fedora_rel="${KLDLOAD_FEDORA_RELEASE:-41}"
    cat > "${target}/etc/yum.repos.d/zfs.repo" <<ZFSREPO
[zfs]
name=ZFS on Linux for Fedora ${_fedora_rel}
baseurl=http://download.zfsonlinux.org/fedora/${_fedora_rel}/\$basearch/
enabled=1
gpgcheck=0
ZFSREPO
  else
    cat > "${target}/etc/yum.repos.d/zfs.repo" <<ZFSREPO
[zfs]
name=ZFS on Linux for EL${release}
baseurl=http://download.zfsonlinux.org/epel/${release}/\$basearch/
enabled=1
gpgcheck=0
ZFSREPO
  fi

  # Mount chroot filesystems BEFORE dnf so postinst scripts (grub, dracut) work
  mkdir -p "${target}/proc" "${target}/sys" "${target}/dev" "${target}/dev/pts" "${target}/run"
  mount -t proc proc "${target}/proc" 2>/dev/null || true
  mount -t sysfs sysfs "${target}/sys" 2>/dev/null || true
  mount --bind /dev "${target}/dev" 2>/dev/null || true
  mount --bind /dev/pts "${target}/dev/pts" 2>/dev/null || true
  mount -t tmpfs tmpfs "${target}/run" 2>/dev/null || true

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
  # Fedora has its own darksite; CentOS/Rocky share one
  local _darksite_rpm="/root/darksite/rpm"
  if [[ "${KLDLOAD_DISTRO:-centos}" == "fedora" ]]; then
    _darksite_rpm="/root/darksite/fedora/rpm"
  fi
  local _darksite_mode="${KLDLOAD_DARKSITE_MODE:-0}"
  local _custom_repo="${KLDLOAD_CUSTOM_REPO:-}"

  if [[ "$_darksite_mode" == "1" && -d "${_darksite_rpm}/repodata" ]]; then
    # Darksite mode: disable ALL internet repos, use only local mirror
    k_log_to "$log" "DARKSITE MODE: using only local RPM mirror (no internet)"
    rm -f "${target}"/etc/yum.repos.d/*.repo 2>/dev/null || true
    cat > "${target}/etc/yum.repos.d/kldload-darksite.repo" <<DSREPO
[kldload-darksite]
name=kldload offline RPM mirror
baseurl=file://${_darksite_rpm}/
enabled=1
gpgcheck=0
DSREPO
  elif [[ -d "${_darksite_rpm}/repodata" ]]; then
    # RHEL: do NOT use the CentOS darksite — packages conflict (centos-logos etc.)
    # CentOS/Rocky: use darksite as supplement
    if [[ "${KLDLOAD_DISTRO:-centos}" == "rhel" ]]; then
      k_log_to "$log" "RHEL install — skipping CentOS darksite (using Red Hat CDN only)"
    else
      k_log_to "$log" "Using local RPM darksite + internet repos"
      cat > "${target}/etc/yum.repos.d/kldload-darksite.repo" <<DSREPO
[kldload-darksite]
name=kldload offline RPM mirror
baseurl=file://${_darksite_rpm}/
enabled=1
gpgcheck=0
cost=500
DSREPO
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
    NetworkManager openssh-server openssh-clients sudo
    vim-enhanced tmux curl wget rsync jq less
    iproute iputils net-tools nftables chrony
    passwd shadow-utils util-linux procps-ng findutils grep sed gawk
    parted gdisk dosfstools
    python3 python3-pip
    dkms gcc make autoconf automake libtool
    zfs zfs-dkms
    # Tools needed for kldloadOS (non-core profiles)
    # NOTE: sanoid is NOT in any RPM repo — installed from GitHub by k_install_system_files
    wireguard-tools ethtool htop pv lzop mbuffer eject
    qemu-guest-agent qemu-img open-vm-tools zstd
    # Modern CLI tools + cloud
    fzf btop fd-find ripgrep zoxide fastfetch cloud-init
    # Sanoid Perl deps (sanoid binary copied by k_install_system_files)
    perl-Config-IniFiles perl-Capture-Tiny
    # Web UI + kldload tools backend
    python3 python3-websockets python3-pyyaml tmux
  )

  # Profile-specific packages for DNF-based distros
  local _profile="${KLDLOAD_PROFILE:-server}"
  case "$_profile" in
    desktop)
      _dnf_pkgs+=(
        gnome-shell gnome-session gnome-control-center gnome-settings-daemon
        gdm nautilus gnome-terminal gedit gnome-keyring
        adwaita-icon-theme google-noto-sans-fonts firefox
        mesa-dri-drivers pipewire wireplumber
      )
      ;;
    server)
      _dnf_pkgs+=(tcpdump socat sysstat net-tools)
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
        NetworkManager openssh-server openssh-clients sudo
        vim-enhanced curl less iproute iputils nftables chrony wireguard-tools
        passwd shadow-utils util-linux procps-ng findutils grep sed gawk
        parted gdisk dosfstools
        dkms gcc make autoconf automake libtool
        zfs zfs-dkms
      )
      ;;
  esac

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

  k_log_to "$log" "Running dnf --installroot (${#_dnf_pkgs[@]} packages, profile=${_profile})..."
  dnf --installroot="${target}" --releasever="${release}" \
      --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
      --setopt=cachedir="${target}/var/cache/dnf" \
      --disableplugin=subscription-manager --disableplugin=product-id \
      --nogpgcheck --skip-broken -y install \
      "${_dnf_pkgs[@]}" \
      >> "$log" 2>&1 \
      || { k_log_to "$log" "dnf --installroot failed"; return 1; }

  k_log_to "$log" "Root filesystem: $(du -sh --exclude="${target}/proc" --exclude="${target}/sys" --exclude="${target}/dev" "${target}" 2>/dev/null | cut -f1 || echo "?")"

  # Build ZFS DKMS (chroot mounts already in place from above)
  local kver moddir
  # CentOS 9 uses /usr/lib/modules (merged-usr), Debian uses /lib/modules
  for moddir in "${target}/usr/lib/modules" "${target}/lib/modules"; do
    [[ -d "$moddir" ]] && break
  done
  kver=$(ls "$moddir/" 2>/dev/null | grep -v '^$' | head -1)
  k_log_to "$log" "Building ZFS DKMS for kernel ${kver}..."

  local zfs_ver
  zfs_ver=$(chroot "${target}" rpm -q --qf '%{VERSION}' zfs-dkms 2>/dev/null || echo "")
  if [[ -n "$zfs_ver" ]]; then
    chroot "${target}" dkms build -m zfs -v "$zfs_ver" -k "$kver" >> "$log" 2>&1 || true
    chroot "${target}" dkms install -m zfs -v "$zfs_ver" -k "$kver" >> "$log" 2>&1 || true
  fi
  chroot "${target}" depmod -a "$kver" 2>/dev/null || true

  # Install zfs-dracut inside the chroot where the ZFS repo is local
  k_log_to "$log" "Installing zfs-dracut in chroot..."
  chroot "${target}" dnf install -y --nogpgcheck zfs-dracut >> "$log" 2>&1 || \
    k_log_to "$log" "WARNING: zfs-dracut install failed"

  # Rebuild initramfs with ZFS support so the installed system can boot from ZFS root
  k_log_to "$log" "Rebuilding initramfs with ZFS module for ${kver}..."
  chroot "${target}" dracut --force --add "zfs" --kver "$kver" 2>>"$log" || \
    k_log_to "$log" "WARNING: dracut rebuild failed"

  # Chroot mounts stay up for the rest of the install

  # Locale + timezone + hostname
  echo "LANG=${KLDLOAD_LOCALE:-en_US.UTF-8}" > "${target}/etc/locale.conf"
  echo "KEYMAP=${KLDLOAD_KEYBOARD_LAYOUT:-us}" > "${target}/etc/vconsole.conf"
  ln -sf "/usr/share/zoneinfo/${KLDLOAD_TIMEZONE:-UTC}" "${target}/etc/localtime" 2>/dev/null || true
  echo "${KLDLOAD_HOSTNAME:-kldload-node}" > "${target}/etc/hostname"

  k_create_users
  k_install_system_files
  k_write_manifest

  # NVIDIA drivers if requested
  if [[ "${KLDLOAD_NVIDIA_DRIVERS:-0}" == "1" ]]; then
    k_log_to "$log" "Installing NVIDIA drivers..."
    # Add NVIDIA CUDA repo — use repo config instead of versioned RPM
    cat > "${target}/etc/yum.repos.d/cuda.repo" <<'CUDAREPO'
[cuda-rhel9]
name=NVIDIA CUDA for RHEL 9
baseurl=https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/
enabled=1
gpgcheck=0
CUDAREPO
    chroot "${target}" dnf install -y --skip-broken \
        nvidia-driver nvidia-driver-libs nvidia-driver-cuda \
        >> "$log" 2>&1 || k_log_to "$log" "WARNING: NVIDIA driver install had issues (no GPU?)"
    k_log_to "$log" "NVIDIA drivers installed"
  fi

  # BCC tools: symlink into PATH (installed to /usr/share/bcc/tools/ on RPM distros)
  if [[ -d "${target}/usr/share/bcc/tools" ]]; then
    for _tool in execsnoop opensnoop tcplife tcpconnect biolatency biotop cachestat runqlat; do
      [[ -f "${target}/usr/share/bcc/tools/${_tool}" ]] && \
        ln -sf "/usr/share/bcc/tools/${_tool}" "${target}/usr/local/bin/${_tool}-bpfcc" 2>/dev/null || true
    done
    k_log_to "$log" "BCC tools symlinked to /usr/local/bin"
  fi

  mkdir -p "${target}/var/log/kldload"
  k_log_to "$log" "${distro} bootstrap complete"
}

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
  if [[ -d "${darksite}/pkg" ]] && ls "${darksite}/pkg/"*.pkg.tar.* >/dev/null 2>&1; then
    echo "${darksite}"
    return 0
  fi
  return 1
}

_k_bootstrap_pacman() {
  local target="${KLDLOAD_TARGET:?}"
  local log="${KLDLOAD_BOOTSTRAP_LOG:-/var/log/installer/bootstrap.log}"

  k_log_to "$log" "Bootstrapping Arch Linux -> ${target}"

  # ── Detect darksite or internet ───────────────────────────────────────────
  local darksite=""
  if darksite="$(k_detect_arch_darksite 2>/dev/null)"; then
    k_log_to "$log" "Using local darksite pacman cache: ${darksite}"
  else
    darksite=""
    k_log_to "$log" "No darksite found — Arch install will use internet mirrors"
  fi

  # ── Set up pacman.conf for the bootstrap ──────────────────────────────────
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
PACCONF

  # Add archzfs repo for ZFS packages
  cat >> "${pacman_conf}" <<'ARCHZFS'

[archzfs]
Server = https://archzfs.com/$repo/$arch
SigLevel = Never
ARCHZFS

  # ── If darksite, set up a local file:// repo ─────────────────────────────
  if [[ -n "$darksite" ]]; then
    # Create a local repo from the darksite cache
    local local_repo="/tmp/kldload-arch-repo"
    mkdir -p "$local_repo"

    # Symlink all packages to the local repo
    ln -sf "${darksite}/pkg/"*.pkg.tar.* "$local_repo/" 2>/dev/null || true

    # Generate a package database
    if command -v repo-add >/dev/null 2>&1; then
      repo-add "${local_repo}/kldload.db.tar.gz" "${local_repo}/"*.pkg.tar.* >> "$log" 2>&1 || true
    fi

    # Prepend local repo to pacman.conf (highest priority)
    local pacman_conf_new="/tmp/kldload-pacman-local.conf"
    cat > "${pacman_conf_new}" <<LOCALREPO
[options]
HoldPkg     = pacman glibc
Architecture = auto
SigLevel    = Never
ParallelDownloads = 5
CacheDir    = ${darksite}/pkg/

[kldload-darksite]
Server = file://${local_repo}
SigLevel = Never

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[archzfs]
Server = https://archzfs.com/\$repo/\$arch
SigLevel = Never
LOCALREPO
    pacman_conf="$pacman_conf_new"
  fi

  # ── Bootstrap with pacstrap (or manual pacman --root) ────────────────────
  # pacstrap is part of arch-install-scripts. On the CentOS live ISO we don't
  # have it natively, so we use a minimal reimplementation.
  mkdir -p "${target}/var/lib/pacman" "${target}/var/cache/pacman/pkg" \
           "${target}/etc" "${target}/var/log" "${target}/dev" \
           "${target}/proc" "${target}/sys" "${target}/run" "${target}/tmp"

  # Copy darksite packages into the target cache for offline use
  if [[ -n "$darksite" ]]; then
    cp "${darksite}/pkg/"*.pkg.tar.* "${target}/var/cache/pacman/pkg/" 2>/dev/null || true
    # Copy sync databases
    mkdir -p "${target}/var/lib/pacman/sync"
    cp "${darksite}/db/"*.db "${target}/var/lib/pacman/sync/" 2>/dev/null || true
    k_log_to "$log" "Darksite packages cached in target"
  fi

  # Mount chroot filesystems
  mount --bind /dev "${target}/dev" 2>/dev/null || true
  mkdir -p "${target}/dev/pts"
  mount --bind /dev/pts "${target}/dev/pts" 2>/dev/null || true
  mount -t proc proc "${target}/proc" 2>/dev/null || true
  mount -t sysfs sysfs "${target}/sys" 2>/dev/null || true
  mount -t tmpfs tmpfs "${target}/run" 2>/dev/null || true

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
  # First sync the databases
  pacman --root "${target}" --config "${pacman_conf}" -Sy --noconfirm >> "$log" 2>&1 || {
    k_log_to "$log" "WARNING: pacman -Sy failed — trying with individual repos"
  }

  # Base packages for initial bootstrap
  local _base_pkgs=(
    base linux linux-headers linux-firmware
    systemd systemd-sysvcompat
    mkinitcpio
    efibootmgr
    bash coreutils util-linux
    sudo openssh
    networkmanager
    vim
  )

  k_log_to "$log" "Installing base packages: ${_base_pkgs[*]}"
  pacman --root "${target}" --config "${pacman_conf}" \
    --noconfirm --needed -S "${_base_pkgs[@]}" >> "$log" 2>&1 || {
    k_log_to "$log" "WARNING: Some base packages failed — continuing"
  }

  k_log_to "$log" "Root filesystem: $(du -sh --exclude="${target}/proc" --exclude="${target}/sys" --exclude="${target}/dev" "${target}" 2>/dev/null | cut -f1 || echo "?")"

  # ── Install ZFS ──────────────────────────────────────────────────────────
  if [[ "${KLDLOAD_STORAGE_MODE:-standard}" == "zfs" ]]; then
    k_log_to "$log" "Installing ZFS packages..."

    local _zfs_pkgs=(dkms gcc make linux-headers zfs-dkms zfs-utils)
    pacman --root "${target}" --config "${pacman_conf}" \
      --noconfirm --needed -S "${_zfs_pkgs[@]}" >> "$log" 2>&1 || {
      k_log_to "$log" "WARNING: ZFS package install had issues"
    }

    # Build ZFS DKMS
    local kver moddir
    for moddir in "${target}/usr/lib/modules" "${target}/lib/modules"; do
      [[ -d "$moddir" ]] && break
    done
    kver=$(ls "$moddir/" 2>/dev/null | grep -v '^$' | head -1)
    if [[ -n "$kver" ]]; then
      k_log_to "$log" "Building ZFS DKMS for kernel ${kver}..."
      local zfs_ver
      zfs_ver=$(chroot "${target}" pacman -Q zfs-dkms 2>/dev/null | awk '{print $2}' | cut -d- -f1 || echo "")
      if [[ -n "$zfs_ver" ]]; then
        chroot "${target}" dkms build -m zfs -v "$zfs_ver" -k "$kver" >> "$log" 2>&1 || true
        chroot "${target}" dkms install -m zfs -v "$zfs_ver" -k "$kver" >> "$log" 2>&1 || true
      fi
      chroot "${target}" depmod -a "$kver" 2>/dev/null || true
    fi

    # Configure mkinitcpio to include ZFS
    if [[ -f "${target}/etc/mkinitcpio.conf" ]]; then
      # Add zfs to HOOKS after filesystems
      sed -i 's/HOOKS=(\(.*\)filesystems\(.*\))/HOOKS=(\1filesystems zfs\2)/' \
        "${target}/etc/mkinitcpio.conf" 2>/dev/null || true
      k_log_to "$log" "mkinitcpio.conf updated with ZFS hook"
    fi

    # Rebuild initramfs with ZFS support
    if [[ -n "$kver" ]]; then
      k_log_to "$log" "Rebuilding initramfs with mkinitcpio for ${kver}..."
      chroot "${target}" mkinitcpio -P >> "$log" 2>&1 || \
        k_log_to "$log" "WARNING: mkinitcpio rebuild failed"
    fi

    # Enable ZFS services
    chroot "${target}" systemctl enable zfs-import-cache.service zfs-mount.service zfs.target 2>/dev/null || true
  fi

  # ── Profile packages ─────────────────────────────────────────────────────
  local profile_pkgs profile_opt
  profile_pkgs="$(k_profile_packages)"
  profile_opt="$(k_profile_optional_packages)"
  if [[ -n "${profile_pkgs}${profile_opt}" ]]; then
    k_log_to "$log" "Installing profile packages..."
    # shellcheck disable=SC2086
    pacman --root "${target}" --config "${pacman_conf}" \
      --noconfirm --needed -S ${profile_pkgs} ${profile_opt} >> "$log" 2>&1 || {
      k_log_to "$log" "WARNING: Some profile packages failed"
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

  echo "${KLDLOAD_HOSTNAME:-kldload-node}" > "${target}/etc/hostname"
  cat > "${target}/etc/hosts" <<EOH
127.0.0.1 localhost
127.0.1.1 ${KLDLOAD_HOSTNAME:-kldload-node}
::1 localhost ip6-localhost ip6-loopback
EOH

  # ── Users ────────────────────────────────────────────────────────────────
  k_create_users

  # ── Enable services ──────────────────────────────────────────────────────
  chroot "${target}" systemctl enable NetworkManager sshd 2>/dev/null || true

  local _profile="${KLDLOAD_PROFILE:-server}"
  if [[ "$_profile" == "desktop" ]]; then
    chroot "${target}" systemctl enable gdm 2>/dev/null || true
    chroot "${target}" systemctl set-default graphical.target 2>/dev/null || true
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
# BSD / illumos bootstrap functions
# ══════════════════════════════════════════════════════════════════════════════

_k_bootstrap_freebsd() {
  local target="${KLDLOAD_TARGET:?}"
  local log="${KLDLOAD_BOOTSTRAP_LOG:-/var/log/installer/bootstrap.log}"
  local darksite="/root/darksite-bsd/freebsd"

  k_log_to "$log" "FreeBSD bootstrap starting..."

  # Extract base and kernel
  [[ -f "${darksite}/base.txz" ]] || { k_log_to "$log" "FATAL: FreeBSD base.txz not found"; return 1; }
  k_log_to "$log" "Extracting FreeBSD base..."
  tar -xpf "${darksite}/base.txz" -C "${target}" >> "$log" 2>&1
  k_log_to "$log" "Extracting FreeBSD kernel..."
  tar -xpf "${darksite}/kernel.txz" -C "${target}" >> "$log" 2>&1

  # Configure rc.conf
  cat > "${target}/etc/rc.conf" <<RCCONF
hostname="${KLDLOAD_HOSTNAME:-kldload-node}"
ifconfig_DEFAULT="DHCP"
sshd_enable="YES"
zfs_enable="YES"
dumpdev="AUTO"
RCCONF

  # Enable ZFS boot
  echo 'zfs_load="YES"' > "${target}/boot/loader.conf"
  echo "vfs.root.mountfrom=\"zfs:rpool/ROOT/${KLDLOAD_HOSTNAME:-kldload-node}\"" >> "${target}/boot/loader.conf"

  # DNS
  cp /etc/resolv.conf "${target}/etc/resolv.conf" 2>/dev/null || true

  # Timezone
  ln -sf "/usr/share/zoneinfo/${KLDLOAD_TIMEZONE:-UTC}" "${target}/etc/localtime" 2>/dev/null || true

  # Create user
  local user="${KLDLOAD_USERNAME:-admin}"
  chroot "${target}" pw useradd "${user}" -m -G wheel -s /bin/sh 2>/dev/null || true
  if [[ -n "${KLDLOAD_PASSWORD:-}" ]]; then
    echo "${KLDLOAD_PASSWORD}" | chroot "${target}" pw usermod "${user}" -h 0
  fi
  # Enable root login via SSH (initial setup only)
  sed -i '' 's/^#PermitRootLogin.*/PermitRootLogin yes/' "${target}/etc/ssh/sshd_config" 2>/dev/null || true

  # FreeBSD bootloader EFI
  local efi_mnt="${KLDLOAD_TARGET_MNT:-/target}/boot/efi"
  mkdir -p "${efi_mnt}/EFI/BOOT"
  cp "${target}/boot/loader.efi" "${efi_mnt}/EFI/BOOT/BOOTX64.EFI" 2>/dev/null || true

  mkdir -p "${target}/var/log/kldload"
  k_log_to "$log" "FreeBSD bootstrap complete"
}

_k_bootstrap_openbsd() {
  local target="${KLDLOAD_TARGET:?}"
  local log="${KLDLOAD_BOOTSTRAP_LOG:-/var/log/installer/bootstrap.log}"
  local darksite="/root/darksite-bsd/openbsd"
  local ver_short
  ver_short="$(cat "${darksite}/VERSION" 2>/dev/null | tr -d '.')"

  k_log_to "$log" "OpenBSD bootstrap starting..."

  # Extract base sets
  for f in "base${ver_short}.tgz" "comp${ver_short}.tgz" "man${ver_short}.tgz"; do
    if [[ -f "${darksite}/${f}" ]]; then
      k_log_to "$log" "Extracting ${f}..."
      tar -xzpf "${darksite}/${f}" -C "${target}" >> "$log" 2>&1
    fi
  done

  # Copy kernel
  [[ -f "${darksite}/bsd" ]] && cp "${darksite}/bsd" "${target}/bsd"
  [[ -f "${darksite}/bsd.rd" ]] && cp "${darksite}/bsd.rd" "${target}/bsd.rd"

  # Configure hostname
  echo "${KLDLOAD_HOSTNAME:-kldload-node}" > "${target}/etc/myname"

  # Network — DHCP on first interface
  echo "dhcp" > "${target}/etc/hostname.vio0"
  echo "dhcp" > "${target}/etc/hostname.em0"

  # Enable SSH
  echo "sshd_flags=" >> "${target}/etc/rc.conf.local"

  # DNS
  cp /etc/resolv.conf "${target}/etc/resolv.conf" 2>/dev/null || true

  # Create user
  local user="${KLDLOAD_USERNAME:-admin}"
  chroot "${target}" useradd -m -G wheel -s /bin/ksh "${user}" 2>/dev/null || true
  if [[ -n "${KLDLOAD_PASSWORD:-}" ]]; then
    echo "${KLDLOAD_PASSWORD}" | chroot "${target}" chpasswd 2>/dev/null || true
  fi

  # Enable doas (OpenBSD's sudo)
  echo "permit persist :wheel" > "${target}/etc/doas.conf"

  mkdir -p "${target}/var/log/kldload"
  k_log_to "$log" "OpenBSD bootstrap complete"
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
