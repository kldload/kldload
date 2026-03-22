# Unattended Installation

kldload supports fully automated installs via an answers file — no web UI or user interaction required. Boot the ISO, and it installs to disk using pre-defined settings.

Works for CentOS/RHEL and Debian targets.

---

## The answers file

The installer reads environment variables from a file. Create one:

```bash
cat > answers.env << 'EOF'
KLDLOAD_DISTRO=debian
KLDLOAD_DISK=/dev/vda
KLDLOAD_HOSTNAME=web-server-01
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=changeme
KLDLOAD_PROFILE=server
KLDLOAD_STORAGE_MODE=zfs
KLDLOAD_ZFS_ENCRYPT=0
KLDLOAD_NET_METHOD=dhcp
KLDLOAD_TIMEZONE=America/New_York
KLDLOAD_LOCALE=en_US.UTF-8
KLDLOAD_KEYBOARD_LAYOUT=us
EOF
```

---

## All supported variables

| Variable | Values | Default | Description |
|----------|--------|---------|-------------|
| `KLDLOAD_DISTRO` | `centos`, `debian`, `rhel`, `rocky` | — | Target distro |
| `KLDLOAD_DISK` | `/dev/vda`, `/dev/sda`, etc. | — | Install disk |
| `KLDLOAD_HOSTNAME` | any hostname | `kldload-node` | System hostname |
| `KLDLOAD_USERNAME` | any username | `admin` | Admin user |
| `KLDLOAD_PASSWORD` | any string | — | User password |
| `KLDLOAD_PROFILE` | `desktop`, `server` | `desktop` | Install profile |
| `KLDLOAD_STORAGE_MODE` | `zfs` | `zfs` | Always ZFS |
| `KLDLOAD_ZFS_ENCRYPT` | `0`, `1` | `0` | Enable encryption |
| `KLDLOAD_NET_METHOD` | `dhcp`, `static` | `dhcp` | Network config |
| `KLDLOAD_NET_IP` | IP/CIDR | — | Static IP (if static) |
| `KLDLOAD_NET_GATEWAY` | IP | — | Gateway (if static) |
| `KLDLOAD_NET_DNS` | IP | — | DNS server (if static) |
| `KLDLOAD_TIMEZONE` | tz database name | `UTC` | Timezone |
| `KLDLOAD_LOCALE` | locale string | `en_US.UTF-8` | System locale |
| `KLDLOAD_KEYBOARD_LAYOUT` | `us`, `de`, etc. | `us` | Keyboard layout |
| `KLDLOAD_NVIDIA_DRIVERS` | `0`, `1` | `0` | Install NVIDIA (CentOS only) |
| `KLDLOAD_ENABLE_EBPF` | `0`, `1` | `0` | Install eBPF tools |
| `KLDLOAD_INFRA_MODE` | `standalone`, `cluster-manager`, `join` | `standalone` | Deployment mode |
| `KLDLOAD_HUB_LAN` | IP | — | CM IP (if join mode) |

---

## Run the install manually

From the live ISO command line:

```bash
kldload-install-target --config /path/to/answers.env
```

---

## Inject the answers file into the ISO

### Method 1: USB sidecar

Place `answers.env` on a second USB drive. The installer checks:
- `/run/kldload-answers.env`
- `/mnt/answers.env`
- `/etc/kldload/answers.env`

```bash
# Format a small USB stick
mkfs.fat -F32 /dev/sdb1
mount /dev/sdb1 /mnt
cp answers.env /mnt/answers.env
umount /mnt
```

Boot the kldload ISO with the answers USB plugged in. The installer detects it automatically.

### Method 2: Bake into the ISO

Add the file to `live-build/config/includes.chroot/` before building:

```bash
cp answers.env live-build/config/includes.chroot/etc/kldload/answers.env
PROFILE=server ./deploy.sh build
```

### Method 3: Kernel command line

Pass the config file path on the GRUB command line:

Edit `live-build/config/includes.binary/EFI/BOOT/grub.cfg`:

```
linuxefi /images/pxeboot/vmlinuz ... kldload.config=/etc/kldload/answers.env
```

---

## Example: fleet of identical servers

Build 10 identical servers:

```bash
cat > answers.env << 'EOF'
KLDLOAD_DISTRO=centos
KLDLOAD_DISK=/dev/sda
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=fleetpass123
KLDLOAD_PROFILE=server
KLDLOAD_NET_METHOD=dhcp
KLDLOAD_TIMEZONE=UTC
EOF
```

Each server will get the same config except the hostname, which defaults to `kldload-node`. To set unique hostnames, either:

1. Use separate answers files per machine
2. Set the hostname after install via Salt/Ansible
3. Use a firstboot script that derives the hostname from the MAC address

---

## Example: encrypted desktop

```bash
cat > answers.env << 'EOF'
KLDLOAD_DISTRO=debian
KLDLOAD_DISK=/dev/nvme0n1
KLDLOAD_HOSTNAME=dev-workstation
KLDLOAD_USERNAME=developer
KLDLOAD_PASSWORD=securepass
KLDLOAD_PROFILE=desktop
KLDLOAD_ZFS_ENCRYPT=1
KLDLOAD_NVIDIA_DRIVERS=0
KLDLOAD_ENABLE_EBPF=1
KLDLOAD_NET_METHOD=dhcp
KLDLOAD_TIMEZONE=America/Los_Angeles
EOF
```

---

## Example: static IP server

```bash
cat > answers.env << 'EOF'
KLDLOAD_DISTRO=centos
KLDLOAD_DISK=/dev/sda
KLDLOAD_HOSTNAME=db-primary
KLDLOAD_USERNAME=admin
KLDLOAD_PASSWORD=dbpass
KLDLOAD_PROFILE=server
KLDLOAD_NET_METHOD=static
KLDLOAD_NET_IP=10.100.10.50/24
KLDLOAD_NET_GATEWAY=10.100.10.1
KLDLOAD_NET_DNS=1.1.1.1
KLDLOAD_TIMEZONE=UTC
EOF
```

---

## Post-install automation

After the base install, kldload runs a firstboot service. You can hook into this:

```bash
# Create a post-install script
cat > live-build/config/includes.chroot/usr/local/sbin/my-firstboot.sh << 'SCRIPT'
#!/bin/bash
# Runs once after first boot

# Install additional packages
kpkg install htop tmux

# Configure NTP
timedatectl set-ntp true

# Start your application
systemctl enable --now myapp

# Remove this script after running
rm -f /usr/local/sbin/my-firstboot.sh
SCRIPT
chmod +x live-build/config/includes.chroot/usr/local/sbin/my-firstboot.sh
```

Wire it into the firstboot service or create a systemd oneshot:

```bash
cat > live-build/config/includes.chroot/etc/systemd/system/my-firstboot.service << 'EOF'
[Unit]
Description=Custom firstboot
After=network-online.target kldload-firstboot.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/my-firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
```

Rebuild the ISO to include it.
