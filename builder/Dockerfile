FROM registry.fedoraproject.org/fedora:44

# ---------------------------------------------------------------------------
# kldload live ISO builder image
# Base: Fedora 44 (kernel ~6.14)
# Purpose: Provides the lorax/livemedia-creator toolchain for building the
#          kldload live ISO. ZFS packages are installed INTO the ISO via
#          kickstart — NOT here in the builder.
#
# Migrated from CentOS Stream 9 (kernel 5.14) → Fedora 44 to pick up modern
# kernel hardware support (Wi-Fi, NVMe, GPU, USB boot quirks on XPS/HP) and
# the latest lorax/dracut. Fedora has EPEL/CRB equivalents in its default
# repos so no extra repo enable step is needed.
# ---------------------------------------------------------------------------

RUN dnf install -y --allowerasing \
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
