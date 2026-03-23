#!/usr/bin/env bash
#
# debian-diagnostics.sh
#
# Collects a comprehensive system diagnostic into diagnostic.md (Markdown format).
# Best on Debian/Ubuntu; degrades gracefully elsewhere.
#
# Sections:
#   1) Networking Snapshot
#   2) System / Log Trouble Scan
#   3) Security / Firewall Snapshot
#   4) APT Package Audit (Debian/Ubuntu)
#   5) Usual Suspects (AppArmor, Samba, NFS, Disks, Auth)
#   6) Performance Snapshot
#
# Usage:
#   sudo ./debian-diagnostics.sh
#
# optinal packages
#
# apt-get update
# apt-get install -y netcat-openbsd traceroute smartmontools sysstat systemd-timesyncd && systemctl enable --now systemd-timesyncd

set -euo pipefail

# -----------------------------
# General configuration / env
# -----------------------------
OUT="results-$HOSTNAME.md"                               # Output Markdown file
TS="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"       # Timestamp used in header
HOST="$(hostname -f 2>/dev/null || hostname)"  # Try FQDN, fallback to short
PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
LC_ALL=C                                       # Predictable parsing/sorting
TRY_TO=10                                      # Default timeout (seconds) for risky commands

# Warn if not root (script still runs, but some info may be missing)
NOT_ROOT_MSG=""
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Not running as root; some sections may be incomplete."
  NOT_ROOT_MSG="(Note: not running as root; some sections may be incomplete.)"
fi

# -----------------------------
# Helper functions
# -----------------------------

# Wrap output in Markdown code fences
code() { printf '```\n'; cat; printf '```\n'; }

# Run a single command safely; keep going even if it fails; record exit code
run() {
  local title="$1"; shift
  printf "\n### %s\n\n" "$title" >> "$OUT"
  {
    set +e
    "$@"
    ec=$?
    set -e
    echo "[exit=$ec]"
  } 2>&1 | code >> "$OUT"
}

# Run a full shell snippet safely (in the current shell so functions exist)
# NOTE: use single argument for the snippet; we call: run_multi "Title" 'commands...'
run_multi() {
  local title="$1"; shift
  printf "\n### %s\n\n" "$title" >> "$OUT"
  {
    set +e
    eval "$*"
    ec=$?
    set -e
    echo "[exit=$ec]"
  } 2>&1 | code >> "$OUT"
}

# Timeout wrapper to prevent hangs (uses coreutils `timeout` if present)
TRY() {
  if command -v timeout >/dev/null; then
    timeout "$TRY_TO" "$@"
  else
    "$@"
  fi
}

# -----------------------------
# Report header
# -----------------------------
cat > "$OUT" <<EOF
# System Diagnostic Report

- **Host:** $HOST  
- **Generated:** $TS  
- **User:** $(whoami)  
- **Kernel:** $(uname -srmo 2>/dev/null || uname -a)
- **Notes:** ${NOT_ROOT_MSG:-none}

> This report aggregates networking, system health, security/firewall, package audit, common service checks, and performance into a single Markdown file.

---
EOF

########################################
# 1) NETWORKING SNAPSHOT
########################################
printf "\n## 1) Networking Snapshot\n" >> "$OUT"

# Interface/IP summary (IPv4+IPv6), link state, hostname/time
run "Interfaces (IPv4/IPv6 addresses)"        bash -lc 'ip -br addr 2>/dev/null || ifconfig -a'
run "Link State"                              bash -lc 'ip -br link 2>/dev/null || true'
run "Hostname / Time"                         bash -lc '(hostname -f || hostname); date'

# DNS config (systemd-resolved or resolv.conf)
run_multi "DNS Configuration"                 'command -v resolvectl >/dev/null && resolvectl status || grep -E "^(nameserver|search|options)" /etc/resolv.conf || true'

# Routing (IPv4+IPv6), default path probe, neighbor table
run "IPv4 Routes"                             bash -lc 'ip route 2>/dev/null || route -n'
run "IPv6 Routes"                             bash -lc 'ip -6 route 2>/dev/null || true'
run "Default Path Probe (8.8.8.8)"            bash -lc 'ip route get 8.8.8.8 2>/dev/null || true'
run "ARP / Neighbors (first 20)"              bash -lc 'ip neigh 2>/dev/null | sed -n "1,20p"'

# Connectivity tests (IPv4, IPv6); note: ICMP may be blocked by firewalls
run_multi "Connectivity (Ping IPv4)"          'TRY ping -c2 -W1 1.1.1.1; TRY ping -c2 -W1 8.8.8.8; TRY ping -c2 -W1 google.com || echo "ICMP may be blocked"'
run_multi "Connectivity (Ping IPv6)"          'TRY ping6 -c2 -W1 2001:4860:4860::8888 || echo "IPv6 ping failed"'

# DNS resolution sanity (via libc + optional dig)
run_multi "DNS Lookups (getent/dig)"          'getent hosts google.com; getent hosts xaeon.io; (command -v dig >/dev/null && { dig +short google.com @1.1.1.1; dig +short xaeon.io @8.8.8.8; } || true)'

# Sockets: listeners with PIDs/users; established TCP; top talkers
run "Listening Sockets (PID/USER)"            bash -lc '(ss -tulpen 2>/dev/null || netstat -tulpen 2>/dev/null) | head -n 200'
run "Established TCP (first 100)"             bash -lc 'ss -tan state established 2>/dev/null | head -n 100'
run_multi "Top Talkers (remote endpoints)"    '(ss -tan 2>/dev/null || netstat -tan 2>/dev/null) | awk "/ESTAB|ESTABLISHED/{print \$5}" | cut -d: -f1 | sort | uniq -c | sort -nr | head -n 20'

# Outbound port checks with nc if available, otherwise /dev/tcp + timeout
run_multi "Outbound Port Checks" '
for t in "1.1.1.1 53" "8.8.8.8 53" "google.com 80" "google.com 443"; do
  set -- $t
  host="$1"; port="$2"
  if command -v nc >/dev/null; then
    echo -n "$host:$port -> "
    TRY nc -zvw2 "$host" "$port" 2>&1 | tail -n1
  else
    echo -n "$host:$port -> "
    if command -v timeout >/dev/null; then
      if timeout 3 bash -lc "</dev/tcp/$host/$port" 2>/dev/null; then echo "open"; else echo "closed/time-out"; fi
    else
      echo "nc/timeout not available"
    fi
  fi
done'

# HTTPS/TLS quick test and short traceroute/tracepath
run "HTTPS Test (TLS handshake + HEAD)"       bash -lc 'TRY curl -skI https://google.com --max-time 5 || echo "curl not available"'
run_multi "Traceroute (best effort)"          '(command -v traceroute >/dev/null && TRY traceroute -n -w2 -q1 8.8.8.8 | head -n 15) || (command -v tracepath >/dev/null && TRY tracepath -n 8.8.8.8 | head -n 15) || echo "no traceroute/tracepath"'

########################################
# 2) SYSTEM & LOG TROUBLE SCAN
########################################
printf "\n## 2) System / Log Trouble Scan\n" >> "$OUT"

# Failed units, disk pressure, kernel warnings/errors, critical logs, app/mail errors, last boots
run "Failed Systemd Units"                    bash -lc 'systemctl --failed || true'
run_multi "Disk Usage (>= 90%)"               'df -hP | awk "NR==1 || \$5+0>=90"'
run_multi "Kernel Messages (recent warnings/errors)" '(dmesg -T 2>/dev/null || dmesg) | egrep -i "error|fail|warn|panic|oom|segfault|blocked|reset" | tail -n 100'
run_multi "Recent Critical Logs"              'TRY journalctl -xb -p 3 --no-pager | tail -n 200 || for f in /var/log/syslog /var/log/messages /var/log/daemon.log /var/log/kern.log; do [ -f "$f" ] && echo "--- $f ---" && tail -n 500 "$f" | egrep -i "error|fail|crit|alert|emerg|panic|segfault|denied|refused"; done'
run_multi "Mail/Auth/App Log Errors"          'for f in /var/log/mail.log /var/log/maillog /var/log/auth.log /var/log/nginx/error.log /var/log/httpd/error_log; do [ -f "$f" ] && echo "--- $f ---" && tail -n 500 "$f" | egrep -i "error|fail|defer|bounce|reject|timeout|denied|refused|quota|tls|auth"; done'
run "Last Boot Summary"                       bash -lc 'last -x | head -n 5'

########################################
# 3) SECURITY / FIREWALL SNAPSHOT
########################################
printf "\n## 3) Security / Firewall Snapshot\n" >> "$OUT"

# Firewall rules, listening services, auth failures, shell users, hot processes, sudo use
run_multi "Firewall Rules (nftables/iptables)" '(nft list ruleset 2>/dev/null || iptables -L -n -v 2>/dev/null || echo "no firewall")'
run "Listening Services (top 50)"             bash -lc '(ss -tulpen 2>/dev/null || netstat -tulpen 2>/dev/null) | head -n 50'
run_multi "Recent SSH Auth Failures"          'journalctl -u ssh -n 200 --no-pager 2>/dev/null | egrep -i "fail|invalid|denied" || for f in /var/log/auth.log /var/log/secure; do [ -f "$f" ] && tail -n 200 "$f" | egrep -i "fail|invalid|denied"; done'
run "Users with Shells"                       bash -lc 'awk -F: '\''\$7 ~ /(bash|zsh|fish|sh)$/ {printf "user:%-16s uid:%-6s home:%-30s shell:%s\n",$1,$3,$6,$7}'\'' /etc/passwd'
run "Suspicious Processes (top 15 by CPU)"    bash -lc 'ps -eo pid,ppid,user,pcpu,pmem,etime,cmd --sort=-%cpu | head -n 15'
run_multi "Recent sudo/root use"              'grep -i "sudo" /var/log/auth.log 2>/dev/null | tail -n 50 || journalctl _COMM=sudo -n 50 --no-pager'

########################################
# 4) APT PACKAGE AUDIT (Debian/Ubuntu)
########################################
printf "\n## 4) APT Package Audit\n" >> "$OUT"

# Sources/keys/counts/upgrades/broken/autoremove/policy/reboot/restart/logs
run_multi "APT Sources"                       'grep -hEv "^\s*(#|$)" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || echo "no sources"'
run "Trusted Keys"                            bash -lc 'ls -1 /etc/apt/trusted.gpg.d 2>/dev/null || echo "no per-repo keyrings"'
run_multi "Package Counts"                    'total=$(dpkg -l | awk "NR>5{print \$1}" | wc -l); ii=$(dpkg -l | awk "NR>5 && \$1==\"ii\"" | wc -l); rc=$(dpkg -l | awk "NR>5 && \$1==\"rc\"" | wc -l); hold=$(apt-mark showhold 2>/dev/null | wc -l); echo "total: $total | installed: $ii | removed-config: $rc | held: $hold"'
run "Held Packages"                           bash -lc 'apt-mark showhold 2>/dev/null || echo "none"'
run "Upgradable Packages"                     bash -lc 'apt list --upgradable 2>/dev/null | sed "1d" || echo "none"'
run_multi "Security Upgrades (better check)"  'apt-get -s dist-upgrade | awk '"'"'/^Inst /{sec=0; for(i=1;i<=NF;i++) if ($i ~ /Debian-Security|security/) sec=1; if(sec) print}'"'"' || echo "none detected"'
run "Broken/Unconfigured Packages"            bash -lc 'dpkg -C || true'
run "-- apt-get check --"                     bash -lc 'apt-get -s -o Debug::NoLocking=true check'
run "Autoremove Candidates"                   bash -lc 'apt-get -s -o Debug::NoLocking=true autoremove | awk "/Remv /{print \$2,\$3}" || echo "n/a"'
run "APT Policy (origins/priorities)"         bash -lc 'apt-cache policy | head -n 200'
run "Need Reboot?"                            bash -lc 'test -f /var/run/reboot-required && (echo YES; cat /var/run/reboot-required.pkgs 2>/dev/null) || echo NO'
run "Services Need Restart?"                  bash -lc 'command -v needrestart >/dev/null && needrestart -b 2>/dev/null || command -v checkrestart >/dev/null && checkrestart 2>/dev/null || echo "not installed"'
run "Recent APT History"                      bash -lc 'tail -n 200 /var/log/apt/history.log 2>/dev/null || echo "no apt history"'
run "dpkg Errors/Warnings"                    bash -lc 'grep -Ei "(dpkg: error|warning:|dependency problems|broken)" /var/log/dpkg.log 2>/dev/null | tail -n 200 || echo "no dpkg errors found"'

########################################
# 5) USUAL SUSPECTS (AppArmor/Samba/NFS/Disks/Auth)
########################################
printf "\n## 5) Usual Suspects: AppArmor, Samba, NFS, Disks, Auth\n" >> "$OUT"

# Security frameworks (AppArmor/SELinux)
run_multi "Security Frameworks"               'command -v aa-status >/dev/null && aa-status || echo "AppArmor not installed"; [ -f /sys/fs/selinux/enforce ] && echo "SELinux enforce=$(cat /sys/fs/selinux/enforce)" || echo "SELinux not present"'

# Time sync / clocks
run "Time / NTP"                              bash -lc 'timedatectl || true'

# Disks/filesystems/RAID/LVM/ZFS/SMART (best effort)
run "Disks / Filesystems (lsblk)"             bash -lc 'lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,UUID'
run "Mounted Filesystems"                     bash -lc 'df -hP'
run "RAID Status (/proc/mdstat)"              bash -lc 'cat /proc/mdstat 2>/dev/null || echo "no mdstat"'
run "LVM Volumes"                             bash -lc 'pvs 2>/dev/null; vgs 2>/dev/null; lvs 2>/dev/null'
run "ZFS Pools"                               bash -lc 'zpool status 2>/dev/null || echo "no zpool"; zfs list 2>/dev/null || true'
run_multi "SMART Disk Health"                 'if command -v smartctl >/dev/null; then for d in /dev/sd[a-z] /dev/nvme[0-9] /dev/vd[a-z]; do [ -b "$d" ] && echo "--- $d ---" && smartctl -H "$d" 2>/dev/null | egrep -i "SMART overall|SMART Health|result|PASSED|FAILED"; done; else echo "smartctl not installed"; fi'

# Samba/NFS statuses (only if present)
run_multi "Samba Status"                      'systemctl status smbd 2>/dev/null | head -n 20 || echo "smbd not running"; command -v testparm >/dev/null && testparm -s 2>/dev/null || true; command -v smbstatus >/dev/null && smbstatus 2>/dev/null || true'
run_multi "NFS Status"                        'systemctl status nfs-server 2>/dev/null | head -n 20 || echo "nfs-server not running"; command -v exportfs >/dev/null && exportfs -v 2>/dev/null || true; command -v showmount >/dev/null && showmount -e 2>/dev/null || true; command -v rpcinfo >/dev/null && TRY rpcinfo -p 2>/dev/null || true'

# Auth stack & users
run "Users with Shells"                       bash -lc 'awk -F: '\''\$7 ~ /(bash|zsh|fish|sh)$/ {printf "user:%-16s uid:%-6s home:%-30s shell:%s\n",$1,$3,$6,$7}'\'' /etc/passwd'

########################################
# 6) PERFORMANCE SNAPSHOT
########################################
printf "\n## 6) Performance Snapshot\n" >> "$OUT"

# Quick CPU/load/users, memory, vm/disk IO, disk usage, net stats, PSI
run "Uptime / Load / Users"                   bash -lc 'uptime; who'
run "CPU/Memory Summary (top)"                bash -lc 'top -b -n1 | head -n 20'
run "Memory Usage (free -h)"                  bash -lc 'free -h'
run "VM/CPU Stats (vmstat 1 3)"               bash -lc 'vmstat 1 3'
run "Disk I/O (iostat -xz 1 3)"               bash -lc 'iostat -xz 1 3 2>/dev/null || echo "iostat not installed"'
run "Disk Usage (df -hP)"                     bash -lc 'df -hP'
run "Network Interface Stats (ip -s link)"    bash -lc 'ip -s link | head -n 100'
run "Pressure Stall Info (if available)"      bash -lc 'grep -H . /proc/pressure/* 2>/dev/null || echo "no PSI available"'

# -----------------------------
# Build a proper Table of Contents at the top
# -----------------------------
{
  echo "## Table of Contents"
  # Generate GitHub-style anchors for '## ' headers
  awk '
    BEGIN{}
    /^## /{
      t=$0; sub(/^## /,"",t);
      a=tolower(t);
      gsub(/[^a-z0-9 ]/,"",a);
      gsub(/[ ]+/,"-",a);
      printf("- [%s](#%s)\n", t, a);
    }
  ' "$OUT"
  echo
  cat "$OUT"
} > "${OUT}.tmp" && mv "${OUT}.tmp" "$OUT"

echo "Wrote $OUT"
