# Diagnostics.sh

`debian-diagnostics.sh` is a **comprehensive Linux system diagnostic tool** that collects system health, networking, security, and package state information into a single Markdown report (`diagnostic.md`).  

It’s designed to give sysadmins and SREs a **fast, portable, no-nonsense way to gather troubleshooting data** — useful for incident response, debugging, and audits.  

---

## Features

The script organizes checks into **6 major categories**:

### 1. Networking Snapshot
- Interfaces & IP addresses (IPv4 & IPv6)
- Link state (up/down, MAC addresses)
- Hostname & system time
- DNS configuration (`resolvectl` or `/etc/resolv.conf`)
- Routing tables (IPv4 & IPv6)
- Default path probe (e.g., how to reach `8.8.8.8`)
- ARP/Neighbor cache (first 20 entries)
- Connectivity checks:
  - Ping IPv4 (`1.1.1.1`, `8.8.8.8`, `google.com`)
  - Ping IPv6 (`2001:4860:4860::8888`)
- DNS resolution checks (`getent`, optional `dig`)
- Listening sockets (with PID/USER)
- Established TCP sessions (top 100)
- Top talkers (unique remote endpoints with connection counts)
- Outbound port checks (53, 80, 443 via `nc` or `/dev/tcp`)
- HTTPS TLS handshake (`curl`)
- Traceroute/tracepath if available

---

### 2. System & Log Trouble Scan
- Failed systemd units
- Disk usage (highlighting anything ≥ 90%)
- Kernel log warnings/errors (`dmesg`)
- Critical system logs (`journalctl`, `/var/log/syslog`, `/var/log/messages`, etc.)
- Application/service log errors (mail, auth, nginx, apache)
- Last boot summary (`last -x`)

---

### 3. Security & Firewall Snapshot
- Firewall rules (`nftables` or `iptables`)
- Listening services (top 50 with PID/USER)
- Recent SSH authentication failures
- Users with valid shells (`/etc/passwd`)
- Top processes by CPU usage (potential suspicious activity)
- Recent sudo/root usage logs

---

### 4. APT Package Audit (Debian/Ubuntu)
- Active APT sources
- Trusted APT keys
- Package counts: total, installed, removed, held
- Held packages
- Upgradable packages
- Security upgrades (heuristic scan of Debian security repos)
- Broken/unconfigured packages (`dpkg -C`)
- `apt-get check` results
- Autoremove candidates
- APT policy (origins & priorities)
- Pending reboot flag (`/var/run/reboot-required`)
- Services needing restart (`needrestart` or `checkrestart`)
- Recent APT history
- `dpkg` error/warning log scan

---

### 5. Usual Suspects: AppArmor, Samba, NFS, Disks, Auth
- Security frameworks:
  - AppArmor profiles (enforced/complain mode)
  - SELinux presence/enforcement
- Time/clock sync status (`timedatectl`)
- Disk & filesystem overview (`lsblk`, `df`)
- RAID status (`/proc/mdstat`)
- LVM volumes (`pvs`, `vgs`, `lvs`)
- ZFS pools (if `zpool`/`zfs` present)
- SMART disk health (if `smartctl` available)
- Samba service status, shares, active sessions
- NFS server/client status
- Users with valid login shells

---

### 6. Performance Snapshot
- Uptime, load averages, logged in users
- Top processes by CPU/memory (`top`)
- Memory usage (`free -h`)
- VM/CPU stats (`vmstat`)
- Disk I/O (`iostat`)
- Disk usage (`df`)
- Network interface stats (`ip -s link`)
- Linux PSI (Pressure Stall Info) if available (`/proc/pressure/*`)

---

## Requirements

The script degrades gracefully if optional tools aren’t installed, but you’ll get more data if you install:

```bash
sudo apt-get install -y \
  net-tools iproute2 curl traceroute netcat-openbsd \
  smartmontools sysstat needrestart
