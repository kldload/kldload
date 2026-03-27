# kldloadOS Smoke Tests

Automated post-install verification for every distro × profile combination. Run on a freshly installed system to verify everything works as expected.

## Test Matrix

| | CentOS 9 | Debian 13 | Ubuntu 24.04 | Fedora 41 | Rocky 9 | RHEL 9 | Arch |
|---|---|---|---|---|---|---|---|
| **Desktop** | `smoke-desktop.sh` | `smoke-desktop.sh` | `smoke-desktop.sh` | `smoke-desktop.sh` | `smoke-desktop.sh` | `smoke-desktop.sh` | `smoke-desktop.sh` |
| **Server** | `smoke-server.sh` | `smoke-server.sh` | `smoke-server.sh` | `smoke-server.sh` | `smoke-server.sh` | `smoke-server.sh` | `smoke-server.sh` |
| **Core** | `smoke-core.sh` | `smoke-core.sh` | `smoke-core.sh` | `smoke-core.sh` | `smoke-core.sh` | `smoke-core.sh` | `smoke-core.sh` |

## Usage

```bash
# Run on a freshly installed kldloadOS system
sudo bash /path/to/tests/smoke-core.sh
sudo bash /path/to/tests/smoke-server.sh
sudo bash /path/to/tests/smoke-desktop.sh

# Or run all tests for the detected profile
sudo bash /path/to/tests/smoke-auto.sh
```

## What gets tested

### All profiles (core + server + desktop)
- ZFS pool health (ONLINE, no errors)
- ZFS dataset hierarchy (expected datasets exist)
- ZFS module loaded
- Boot environment exists and bootfs set
- EFI partition mounted
- ZFSBootMenu EFI binary present
- SSH running
- Network connectivity
- Hostid configured
- OS branding (/etc/os-release)

### Server + Desktop only
- k* tools present and executable (kst, ksnap, kbe, kclone, kdf, kdir, kpkg, kupgrade, kexport, krecovery)
- kldload-webui service
- Sanoid timer active
- Snapshot automation (kpkg install triggers snapshot)
- Boot environment creation (kupgrade creates pre-upgrade BE)
- APT/DNF snapshot hooks working
- WireGuard tools installed
- Darksite present (/root/darksite/)

### Desktop only
- GNOME session available
- GDM running
- Firefox installed
- Display manager target set to graphical
