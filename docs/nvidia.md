# NVIDIA on kldload

NVIDIA GPU support is available on CentOS/RHEL installs. Debian installs can add NVIDIA drivers manually after install.

---

## During install (CentOS/RHEL only)

Set `KLDLOAD_NVIDIA_DRIVERS=1` in the answers file before starting the install. The installer will:

1. Add the NVIDIA CUDA repository for RHEL 9
2. Install `nvidia-driver`, `nvidia-driver-libs`, and `nvidia-driver-cuda`

### Web UI

Select the NVIDIA option in the hardware section of the web UI before clicking Install.

### Unattended install

```bash
cat > /tmp/answers.env << 'EOF'
KLDLOAD_DISTRO=centos
KLDLOAD_DISK=/dev/vda
KLDLOAD_HOSTNAME=gpu-node
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=changeme
KLDLOAD_PROFILE=desktop
KLDLOAD_NVIDIA_DRIVERS=1
EOF

kldload-install-target --config /tmp/answers.env
```

---

## Post-install (CentOS/RHEL)

If you didn't enable NVIDIA during install, add it afterward:

```bash
# Add the CUDA repo
dnf install -y \
  https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-repo-rhel9-12.9.0-1.x86_64.rpm

# Install drivers
dnf install -y nvidia-driver nvidia-driver-libs nvidia-driver-cuda

# Reboot to load the kernel module
reboot
```

### Verify

```bash
nvidia-smi
```

Expected output shows your GPU model, driver version, CUDA version, temperature, and memory usage.

---

## Post-install (Debian)

Debian installs need the non-free repo and the `nvidia-driver` package:

```bash
# Add non-free to sources
cat > /etc/apt/sources.list.d/nvidia.list << 'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
EOF

apt update
apt install -y nvidia-driver firmware-misc-nonfree

reboot
```

> This requires internet access — the NVIDIA driver is not included in the offline darksite.

---

## CUDA toolkit

For GPU computing (machine learning, rendering, etc.), install the full CUDA toolkit after the driver is working:

### CentOS/RHEL

```bash
dnf install -y cuda-toolkit
```

### Debian

```bash
# Add NVIDIA's Debian repo for CUDA
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb \
  -o /tmp/cuda-keyring.deb
dpkg -i /tmp/cuda-keyring.deb
apt update
apt install -y cuda-toolkit
```

### Verify CUDA

```bash
nvcc --version
# Compile and run a sample
cat > /tmp/hello.cu << 'EOF'
#include <stdio.h>
__global__ void hello() { printf("Hello from GPU thread %d\n", threadIdx.x); }
int main() { hello<<<1, 8>>>(); cudaDeviceSynchronize(); }
EOF
nvcc /tmp/hello.cu -o /tmp/hello_cuda && /tmp/hello_cuda
```

---

## Nouveau vs NVIDIA

kldload's CentOS kernel ships with the open-source `nouveau` driver loaded by default. Installing the proprietary NVIDIA driver blacklists `nouveau` automatically. If you need to revert:

```bash
# Remove NVIDIA and restore nouveau
dnf remove -y 'nvidia-driver*'
rm -f /etc/modprobe.d/nvidia.conf
dracut --force
reboot
```

---

## ZFS and NVIDIA memory

Both ZFS ARC and NVIDIA drivers use large amounts of memory. On systems with GPUs, you may want to cap ZFS ARC to leave room:

```bash
# Check current ARC size
cat /proc/spl/kstat/zfs/arcstats | grep c_max

# Limit ARC to 4GB (persistent across reboots)
echo "options zfs zfs_arc_max=4294967296" > /etc/modprobe.d/zfs-arc.conf
dracut --force
```

A reasonable rule of thumb: total RAM minus GPU VRAM minus 2GB for the OS, then give half of what remains to ARC.

---

## Secure Boot

The proprietary NVIDIA kernel module is not signed for Secure Boot. If Secure Boot is enabled, you need to either:

1. **Sign the module with your MOK key** (kldload sets up MOK infrastructure during install):

```bash
# Find the MOK key kldload created
ls /var/lib/kldload/mok/

# Sign the NVIDIA module
/usr/src/kernels/$(uname -r)/scripts/sign-file sha256 \
  /var/lib/kldload/mok/MOK.priv \
  /var/lib/kldload/mok/MOK.der \
  $(modinfo -n nvidia)

reboot
```

2. **Disable Secure Boot** in UEFI firmware settings.

---

## Troubleshooting

```bash
# Check if the module loaded
lsmod | grep nvidia

# If not, check for errors
dmesg | grep -i nvidia

# Common issue: kernel updated but DKMS didn't rebuild the module
dkms status
dkms autoinstall

# Check Xorg/Wayland is using NVIDIA (desktop profile)
# GNOME on Wayland:
loginctl show-session $(loginctl | grep $(whoami) | awk '{print $1}') -p Type
# Xorg:
xrandr --listproviders
```
