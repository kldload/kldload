#!/bin/bash
set -euo pipefail
cd /root/kldload-free

R2_ENDPOINT="https://de773e770a75e7fd1d6e748ac30fc866.r2.cloudflarestorage.com"
R2_BUCKET="s3://kldload-releases"

./deploy.sh clean
./deploy.sh builder-image

# Build the ISO — one ISO with Desktop, Server, and Core profiles
PROFILE=desktop ./deploy.sh build
ISO=$(ls -t live-build/output/kldload-free-*.iso | head -1)

# Deploy to KVM + Proxmox
./deploy.sh deploy-all

# Burn to USB
echo "=== Burning ISO to USB ==="
dd if="$ISO" of=/dev/sda bs=4M status=progress oflag=sync conv=fsync
sync

# Upload to R2
echo "=== Uploading to R2 ==="
aws s3 cp "$ISO" "${R2_BUCKET}/kldload-free-latest.iso" --endpoint-url "$R2_ENDPOINT" --profile r2
sha256sum "$ISO" | sed "s|.*/|kldload-free-latest.iso  |" > /tmp/latest.sha256
aws s3 cp /tmp/latest.sha256 "${R2_BUCKET}/kldload-free-latest.iso.sha256" --endpoint-url "$R2_ENDPOINT" --profile r2

# Deploy website
ssh -o StrictHostKeyChecking=no -i /root/.ssh/kldload-deploy kldload.com@ssh.us.stackcp.com "cd ~/public_html && git pull"

echo "=== DONE: KVM + Proxmox + USB + R2 + website ==="
