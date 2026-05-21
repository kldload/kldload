#!/usr/bin/env bash
# 02-clone-from-golden.sh — clone a kldload-built golden image to a new
# VM via ZFS clone (sub-second, regardless of golden size).
#
# Usage:
#   ./02-clone-from-golden.sh <new-vm-name> [golden-dataset]
#
# Default golden: rpool/klab/goldens/debian-13-lean@golden
# (run `zfs list -t snapshot rpool/klab/goldens` to see all kldload-built goldens)
#
# Why this is fast:
#   * `zfs clone` is a CoW pointer — no bytes copied until written
#   * Clone shares blocks with the golden's snapshot
#   * Each clone costs only its DELTA from the golden
#
# How kldload uses this:
#   * kube-cluster bootstrap clones the k8s golden 4 times in ~400ms
#     to make the CP + 3 worker VMs
#   * The blue-green VM lifecycle reads "destroy + clone again" as
#     "delete a pointer + create a pointer" — essentially free
set -euo pipefail

VM_NAME="${1:?usage: $0 <new-vm-name> [golden-dataset]}"
GOLDEN="${2:-rpool/klab/goldens/debian-13-lean@golden}"
NEW_DATASET="rpool/vm/${VM_NAME}"
IMAGES_DIR=/var/lib/libvirt/images

if ! zfs list -t snapshot "$GOLDEN" >/dev/null 2>&1; then
  echo "ERROR: golden snapshot $GOLDEN doesn't exist."
  echo "Available kldload goldens:"
  zfs list -t snapshot -o name 2>/dev/null | grep "goldens" | sed 's/^/  /'
  exit 1
fi

if zfs list "$NEW_DATASET" >/dev/null 2>&1; then
  echo "ERROR: $NEW_DATASET already exists. Destroy with: zfs destroy -r $NEW_DATASET"
  exit 1
fi

echo "[1/4] Cloning $GOLDEN → $NEW_DATASET"
START=$(date +%s.%N)
zfs clone -o mountpoint=none "$GOLDEN" "$NEW_DATASET"
END=$(date +%s.%N)
printf "      done in %.3f seconds\n" "$(echo "$END - $START" | bc)"

# Symlink the cloned dataset's qcow2 (or raw) into libvirt's images dir.
# kldload goldens are typically stored as zvol or qcow2 inside the dataset.
# Adjust the path based on how the golden was built.
echo "[2/4] Resolving cloned image path"
if [[ -f "/${NEW_DATASET}/disk.qcow2" ]]; then
  IMG="/${NEW_DATASET}/disk.qcow2"
elif [[ -e "/dev/zvol/${NEW_DATASET}" ]]; then
  IMG="/dev/zvol/${NEW_DATASET}"
else
  echo "  warning: couldn't find disk.qcow2 or zvol — check zfs list -r $NEW_DATASET"
  exit 1
fi
echo "      using $IMG"

echo "[3/4] virt-install --import $IMG"
virt-install \
  --name "$VM_NAME" \
  --memory 2048 --vcpus 2 \
  --osinfo debian13 \
  --disk path="$IMG",bus=virtio \
  --network network=default,model=virtio \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole \
  --import

echo "[4/4] Waiting for DHCP lease..."
for _ in $(seq 1 30); do
  ip=$(virsh net-dhcp-leases default 2>/dev/null | awk -v vm="$VM_NAME" '$0 ~ vm {print $5}' | cut -d/ -f1)
  [[ -n "$ip" ]] && break
  sleep 2
done

if [[ -n "${ip:-}" ]]; then
  echo "READY: $VM_NAME at $ip"
  echo "       virsh console $VM_NAME    (Ctrl-] to detach)"
  echo "       ssh admin@$ip"
else
  echo "READY but no DHCP lease yet — virsh console $VM_NAME to investigate"
fi
