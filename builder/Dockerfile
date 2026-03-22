FROM quay.io/centos/centos:stream9

# ---------------------------------------------------------------------------
# KLDload live ISO builder image
# Base: CentOS Stream 9
# Purpose: Provides the lorax/livemedia-creator toolchain for building the
#          KLDload live ISO. ZFS packages are installed INTO the ISO via
#          kickstart — NOT here in the builder.
# Supports: x86_64 and aarch64 (auto-detects architecture)
# ---------------------------------------------------------------------------

# Detect architecture for EFI packages
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "aarch64" ]; then \
        EFI_GRUB="grub2-efi-aa64" ; \
        EFI_SHIM="shim-aa64" ; \
    else \
        EFI_GRUB="grub2-efi-x64" ; \
        EFI_SHIM="shim-x64" ; \
    fi && \
    dnf install -y epel-release && \
    /usr/bin/crb enable && \
    dnf install -y --allowerasing \
        lorax \
        createrepo_c \
        rpm-build \
        dnf-plugins-core \
        squashfs-tools \
        xorriso \
        ${EFI_GRUB} \
        ${EFI_SHIM} \
        dracut \
        dracut-live \
        dracut-squash \
        git \
        openssl \
        curl \
        wget \
        jq \
        rsync \
        genisoimage \
        syslinux \
        mtools \
        python3 \
        python3-pyyaml \
    && dnf clean all

WORKDIR /build

ENTRYPOINT ["/build/builder/build-iso.sh"]
