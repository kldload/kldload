#!/bin/bash
set -euo pipefail
cd /root/kldload-free

R2_ENDPOINT="https://de773e770a75e7fd1d6e748ac30fc866.r2.cloudflarestorage.com"
R2_BUCKET="s3://kldload-releases"

./deploy.sh clean
./deploy.sh builder-image

# Build free edition (desktop) — full kldloadOS
PROFILE=desktop EDITION=free ./deploy.sh build
FREE_ISO=$(ls -t live-build/output/kldload-free-*.iso | head -1)

# Deploy free edition to KVM + Proxmox (before core build so latest_iso picks free)
./deploy.sh deploy-all

# Burn free edition to USB
echo "=== Burning free ISO to USB ==="
dd if="$FREE_ISO" of=/dev/sda bs=4M status=progress oflag=sync conv=fsync
sync

# Build core edition (server) — just ZFS on root, nothing else
EDITION=core PROFILE=server ./deploy.sh build
CORE_ISO=$(ls -t live-build/output/kldload-core-*.iso | head -1)

# Upload both editions to R2
for ISO in "$FREE_ISO" "$CORE_ISO"; do
    BASENAME=$(basename "$ISO")
    LATEST=$(echo "$BASENAME" | sed -E 's/^(kldload-(free|core))-.*/\1-latest.iso/')

    echo "=== Uploading $BASENAME → $LATEST ==="
    aws s3 cp "$ISO" "${R2_BUCKET}/${LATEST}" --endpoint-url "$R2_ENDPOINT" --profile r2

    sha256sum "$ISO" | sed "s|.*/|${LATEST}  |" > /tmp/latest.sha256
    aws s3 cp /tmp/latest.sha256 "${R2_BUCKET}/${LATEST}.sha256" --endpoint-url "$R2_ENDPOINT" --profile r2
done

echo "=== DONE: KVM + Proxmox + USB + R2 (free + core) ==="
