# Package Management

kldload does not replace or modify your distro's package manager. `apt`, `dnf`, and `pacman` work exactly as they do on a stock install — use them directly if you prefer.

kldload also includes `kpkg`, an optional convenience wrapper that auto-detects apt/dnf/pacman underneath and adds automatic ZFS snapshots before every operation. It's there if you want cross-distro consistency; it's not required for anything.

---

## Basic operations

```bash
# Install a package
kpkg install nginx

# Remove a package
kpkg remove nginx

# Search for a package
kpkg search redis

# Show package info
kpkg info nginx

# Update package lists
kpkg update

# Upgrade all packages
kpkg upgrade

# List installed packages
kpkg list
```

Every install, remove, and upgrade creates a ZFS snapshot first (`kpkg-YYYYMMDD-HHMMSS`). If the operation breaks something, roll back:

```bash
# List kpkg snapshots
ksnap list | grep kpkg

# Roll back
ksnap rollback /
```

---

## Offline package install from the darksite

kldload bakes complete package mirrors into the ISO. After install, these mirrors are available at `/root/darksite/`.

### CentOS/Fedora/RHEL/Rocky — RPM darksite

The RPM mirror is pre-configured as a local repo:

```bash
# Already configured — just install
dnf install tmux   # pulls from /root/darksite/rpm/

# Check available repos
dnf repolist
```

If the local repo isn't configured:

```bash
cat > /etc/yum.repos.d/kldload-darksite.repo << 'EOF'
[kldload-darksite]
name=kldload offline mirror
baseurl=file:///root/darksite/rpm/
enabled=1
gpgcheck=0
EOF
```

### Debian — APT darksite

The APT mirror runs as a local HTTP server on port 3142:

```bash
# Check if the mirror service is running
systemctl status kldload-apt-mirror

# If not running, start it
systemctl start kldload-apt-mirror

# Verify
curl -s http://localhost:3142/dists/trixie/Release | head -5
```

The sources list is pre-configured:

```bash
cat /etc/apt/sources.list.d/kldload-darksite.list
# deb [trusted=yes] http://localhost:3142 trixie main
```

---

## System upgrades with kupgrade

`kupgrade` is a safe upgrade tool that creates a boot environment snapshot before upgrading:

```bash
kupgrade
```

What it does:
1. Creates `pre-upgrade-YYYYMMDD-HHMMSS` boot environment
2. Runs `apt-get update` + `apt-get dist-upgrade` (Debian/Ubuntu), `dnf upgrade` (CentOS/Fedora/RHEL/Rocky), or `pacman -Syu` (Arch)
3. Runs `apt-get autoremove` to clean up
4. Verifies ZFS DKMS modules built for every installed kernel
5. Re-signs DKMS modules with MOK key if Secure Boot is enabled

If the upgrade breaks something:

```bash
# Reboot, select the pre-upgrade boot environment from ZFSBootMenu
# Or from the command line:
kbe activate pre-upgrade-20260321-143000
reboot
```

---

## Adding packages to the darksite (build time)

To include additional packages in future ISO builds, add them to the package list files:

### For CentOS/Fedora/RHEL/Rocky installs

```bash
# Base packages (all installs)
echo "htop" >> build/darksite/config/package-sets/target-base.txt

# Desktop-only packages
echo "gimp" >> build/darksite/config/package-sets/target-desktop.txt

# Server-only packages
echo "postgresql-server" >> build/darksite/config/package-sets/target-server.txt
```

### For Debian installs

```bash
# Base packages (all installs)
echo "htop" >> build/darksite-debian/config/package-sets/target-base.txt

# Desktop-only packages
echo "gimp" >> build/darksite-debian/config/package-sets/target-desktop.txt
```

Dependencies resolve automatically when you rebuild:

```bash
./deploy.sh build-debian-darksite   # rebuild APT mirror
PROFILE=desktop ./deploy.sh build   # rebuild ISO (RPM darksite rebuilds automatically)
```

---

## Package differences between distros

| Task | CentOS/Fedora/RHEL/Rocky | Debian/Ubuntu | Arch |
|------|-------------|--------|------|
| Install a package | `dnf install pkg` | `apt install pkg` | `pacman -S pkg` |
| Search | `dnf search pkg` | `apt search pkg` | `pacman -Ss pkg` |
| List installed | `dnf list installed` | `dpkg -l` | `pacman -Q` |
| Show dependencies | `dnf deplist pkg` | `apt depends pkg` | `pactree pkg` |
| Clean cache | `dnf clean all` | `apt clean` | `pacman -Sc` |
| eBPF tools | `bcc-tools` | `bpfcc-tools` | `bcc-tools` |
| Firewall | `firewalld` | `nftables` | `nftables` |
| Service manager | `systemctl` (same) | `systemctl` (same) | `systemctl` (same) |

With `kpkg`, you don't need to remember these differences — it picks the right command automatically. But the native commands always work too. `kpkg` is a shortcut, not a gate.
