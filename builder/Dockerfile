FROM quay.io/centos/centos:stream9

# ---------------------------------------------------------------------------
# KLDload live ISO builder image
# Base: CentOS Stream 9
# Purpose: Provides the lorax/livemedia-creator toolchain for building the
#          KLDload live ISO. ZFS packages are installed INTO the ISO via
#          kickstart — NOT here in the builder.
# ---------------------------------------------------------------------------

RUN dnf install -y epel-release && \
    /usr/bin/crb enable && \
    dnf install -y --allowerasing \
        lorax \
        createrepo_c \
        rpm-build \
        dnf-plugins-core \
        squashfs-tools \
        xorriso \
        grub2-efi-x64 \
        shim-x64 \
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
