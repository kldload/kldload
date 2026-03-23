#!/usr/bin/env bash
#
# rhel-diagnostics.sh
#
# Collects a comprehensive system diagnostic into diagnostic.md (Markdown format).
# Tuned for RHEL/CentOS/Rocky/Alma. Degrades gracefully elsewhere.
#
# Sections:
#   1) Networking Snapshot
#   2) System / Log Trouble Scan
#   3) Security / Firewall Snapshot
#   4) DNF/YUM Package & Repo Audit (RHEL family)
#   5) Usual Suspects (SELinux, Samba, NFS, Disks, LVM/MD/ZFS, Auth)
#   6) Performance Snapshot
#   7) WireGuard Snapshot (if installed)
#   8) RHEL Extras (Subscription, Tuned, Kdump)
#
# Usage:
#   sudo ./rhel-diagnostics.sh
#
# Optional packages (helpful tools):
#   dnf -y install nmap-ncat traceroute smartmontools sysstat bind-utils curl \
#                  policycoreutils-python-utils nftables iproute iptables \
#                  yum-utils subscription-manager
#   systemctl enable --now chronyd
#
set -euo pipefail

# -----------------------------
# General configuration / env
# -----------------------------
OUT="results-${HOSTNAME}.md"
TS="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
HOST="$(hostname -f 2>/dev/null || hostname)"
PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
LC_ALL=C
TRY_TO=10

# Warn if not root
NOT_ROOT_MSG=""
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "Not running as root; some sections may be incomplete."
  NOT_ROOT_MSG="(Note: not running as root; some sections may be incomplete.)"
fi

# -----------------------------
# Helpers
# -----------------------------
code(){ printf '```\n'; cat; printf '```\n'; }
run(){ local title="$1"; shift; printf "\n### %s\n\n" "$title" >> "$OUT"; { set +e; "$@"; ec=$?; set -e; echo "[exit=$ec]"; } 2>&1 | code >> "$OUT"; }
run_multi(){ local title="$1"; shift; printf "\n### %s\n\n" "$title" >> "$OUT"; { set +e; eval "$*"; ec=$?; set -e; echo "[exit=$ec]"; } 2>&1 | code >> "$OUT"; }
TRY(){ if command -v timeout >/dev/null; then timeout "$TRY_TO" "$@"; else "$@"; fi; }

# DNF/YUM presence
PM="dnf"
command -v dnf >/dev/null 2>&1 || PM="yum"

# -----------------------------
# Report header
# -----------------------------
cat > "$OUT" <<EOF
# System Diagnostic Report (RHEL/CentOS Family)

- **Host:** $HOST  
- **Generated:** $TS  
- **User:** $(whoami)  
- **Kernel:** $(uname -srmo 2>/dev/null || uname -a)
- **Notes:** ${NOT_ROOT_MSG:-none}

> This report aggregates networking, system health, security/firewalld, package audit (DNF/YUM), common service checks, performance, WireGuard, and RHEL extras into a single Markdown file.

---
EOF

########################################
# 1) NETWORKING SNAPSHOT
########################################
printf "\n## 1) Networking Snapshot\n" >> "$OUT"

run "Interfaces (IPv4/IPv6 addresses)"        bash -lc 'ip -br addr 2>/dev/null || ifconfig -a'
run "Link State"                              bash -lc 'ip -br link 2>/dev/null || true'
run "Hostname / Time"                         bash -lc '(hostname -f || hostname); date'

# DNS: NetworkManager/resolved/resolv.conf
run_multi "DNS Configuration" '
if command -v resolvectl >/dev/null; then resolvectl status;
elif command -v nmcli >/dev/null; then nmcli dev show | egrep "IP4.DNS|IP4.DOMAIN|IP6.DNS|GENERAL.CONNECTION";
fi
grep -E "^(nameserver|search|options)" /etc/resolv.conf 2>/dev/null || true
'

run "IPv4 Routes"                             bash -lc 'ip route 2>/dev/null || route -n'
run "IPv6 Routes"                             bash -lc 'ip -6 route 2>/dev/null || true'
run "Default Path Probe (8.8.8.8)"            bash -lc 'ip route get 8.8.8.8 2>/dev/null || true'
run "ARP / Neighbors (first 20)"              bash -lc 'ip neigh 2>/dev/null | sed -n "1,20p"'

run_multi "Connectivity (Ping IPv4)"          'TRY ping -c2 -W1 1.1.1.1; TRY ping -c2 -W1 8.8.8.8; TRY ping -c2 -W1 google.com || echo "ICMP may be blocked"'
run_multi "Connectivity (Ping IPv6)"          'TRY ping6 -c2 -W1 2001:4860:4860::8888 || echo "IPv6 ping failed"'

run_multi "DNS Lookups (getent/dig)"          'getent hosts google.com; getent hosts example.com; (command -v dig >/dev/null && { dig +short google.com @1.1.1.1; dig +short example.com @8.8.8.8; } || true)'

run "Listening Sockets (PID/USER)"            bash -lc '(ss -tulpen 2>/dev/null || netstat -tulpen 2>/dev/null) | head -n 200'
run "Established TCP (first 100)"             bash -lc 'ss -tan state established 2>/dev/null | head -n 100'
run_multi "Top Talkers (remote endpoints)"    '(ss -tan 2>/dev/null || netstat -tan 2>/dev/null) | awk "/ESTAB|ESTABLISHED/{print \$5}" | cut -d: -f1 | sort | uniq -c | sort -nr | head -n 20'

run_multi "Outbound Port Checks" '
for t in "1.1.1.1 53" "8.8.8.8 53" "google.com 80" "google.com 443"; do
  set -- $t; host="$1"; port="$2"
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
done
'

run "HTTPS Test (TLS handshake + HEAD)"       bash -lc 'TRY curl -skI https://google.com --max-time 5 || echo "curl not available"'
run_multi "Traceroute (best effort)"          '(command -v traceroute >/dev/null && TRY traceroute -n -w2 -q1 8.8.8.8 | head -n 15) || (command -v tracepath >/dev/null && TRY tracepath -n 8.8.8.8 | head -n 15) || echo "no traceroute/tracepath"'

########################################
# 2) SYSTEM & LOG TROUBLE SCAN
########################################
printf "\n## 2) System / Log Trouble Scan\n" >> "$OUT"

run "Failed Systemd Units"                    bash -lc 'systemctl --failed || true'
run_multi "Disk Usage (>= 90%)"               'df -hP | awk "NR==1 || \$5+0>=90"'
run_multi "Kernel Messages (recent warnings/errors)" '(dmesg -T 2>/dev/null || dmesg) | egrep -i "error|fail|warn|panic|oom|segfault|blocked|reset" | tail -n 100'
run_multi "Recent Critical Logs"              'TRY journalctl -xb -p 3 --no-pager | tail -n 200 || for f in /var/log/messages /var/log/secure; do [ -f "$f" ] && echo "--- $f ---" && tail -n 500 "$f" | egrep -i "error|fail|crit|alert|emerg|panic|segfault|denied|refused"; done'
run_multi "Mail/Auth/App Log Errors"          'for f in /var/log/maillog /var/log/secure /var/log/nginx/error.log /var/log/httpd/error_log; do [ -f "$f" ] && echo "--- $f ---" && tail -n 500 "$f" | egrep -i "error|fail|defer|bounce|reject|timeout|denied|refused|quota|tls|auth"; done'
run "Last Boot Summary"                       bash -lc 'last -x | head -n 5 || last | head -n 5'

########################################
# 3) SECURITY / FIREWALL SNAPSHOT
########################################
printf "\n## 3) Security / Firewall Snapshot\n" >> "$OUT"

run_multi "Firewall (firewalld/nftables/iptables)" '
if systemctl is-active --quiet firewalld 2>/dev/null; then
  echo "# firewalld state"; firewall-cmd --state || true
  echo "# zones (active)"; firewall-cmd --get-active-zones || true
  echo "# services (public)"; firewall-cmd --zone=public --list-all || true
  echo "# rich rules"; firewall-cmd --list-rich-rules || true
else
  nft list ruleset 2>/dev/null || iptables -L -n -v 2>/dev/null || echo "no firewall"
fi
'
run "Listening Services (top 50)"             bash -lc '(ss -tulpen 2>/dev/null || netstat -tulpen 2>/dev/null) | head -n 50'
run_multi "Recent SSH Auth Failures"          'journalctl -u sshd -n 200 --no-pager 2>/dev/null | egrep -i "fail|invalid|denied" || for f in /var/log/secure; do [ -f "$f" ] && tail -n 200 "$f" | egrep -i "fail|invalid|denied"; done'
run "Users with Shells"                       bash -lc 'awk -F: '\''$7 ~ /(bash|zsh|fish|sh)$/ {printf "user:%-16s uid:%-6s home:%-30s shell:%s\n",$1,$3,$6,$7}'\'' /etc/passwd'
run "Suspicious Processes (top 15 by CPU)"    bash -lc 'ps -eo pid,ppid,user,pcpu,pmem,etime,cmd --sort=-%cpu | head -n 15'
run_multi "SELinux Status"                    '(getenforce 2>/dev/null || echo "getenforce not found"); [ -f /etc/selinux/config ] && grep -E "^(SELINUX|SELINUXTYPE)=" /etc/selinux/config || true'

########################################
# 4) DNF/YUM PACKAGE & REPO AUDIT
########################################
printf "\n## 4) DNF/YUM Package & Repo Audit\n" >> "$OUT"

run_multi "Enabled Repos"                     "$PM repolist -v 2>/dev/null || $PM repolist all 2>/dev/null || echo 'no repo info'"
run_multi "Repo Files"                        'grep -hEv "^\s*(#|$)" /etc/yum.repos.d/*.repo 2>/dev/null || echo "no repo files"'
run_multi "Package Counts"                    '
if command -v rpm >/dev/null; then
  total=$(rpm -qa | wc -l); echo "total installed: $total"
  echo "kernel packages:"; rpm -qa | grep -E "^kernel(|-core|-modules|-devel)" | sort
else echo "rpm not found"; fi'
run "Held/Excluded Packages"                  bash -lc 'grep -RHi "exclude=" /etc/dnf/dnf.conf /etc/dnf/*.conf /etc/yum.conf /etc/yum/*.conf 2>/dev/null || echo "none"'
run "Available Updates"                       bash -lc "$PM -q check-update || true"
run_multi "Security Updates (best effort)"    '
if [ "$PM" = "dnf" ]; then dnf -q updateinfo list security all 2>/dev/null || true; dnf -q updateinfo summary 2>/dev/null || true;
else yum -q updateinfo list security all 2>/dev/null || true; fi'
run_multi "Broken deps / Check"               '$PM -q check 2>/dev/null || echo "pm check not available"'
run_multi "Need Reboot?"                      '
if command -v needs-restarting >/dev/null; then needs-restarting -r; fi || echo "unknown/not installed"'
run_multi "Services Need Restart?"            '
if command -v needs-restarting >/dev/null; then needs-restarting -s | head -n 200; else echo "needs-restarting not installed"; fi'
run_multi "Recent DNF/YUM History"            '
if [ "$PM" = "dnf" ]; then dnf history | head -n 50; else yum history | head -n 50; fi'

########################################
# 5) USUAL SUSPECTS (SELinux/Samba/NFS/Disks/Auth)
########################################
printf "\n## 5) Usual Suspects: SELinux, Samba, NFS, Disks, Auth\n" >> "$OUT"

run "Time / NTP"                              bash -lc 'timedatectl || true'

run "Disks / Filesystems (lsblk)"             bash -lc 'lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,UUID'
run "Mounted Filesystems"                     bash -lc 'df -hP'
run "RAID Status (/proc/mdstat)"              bash -lc 'cat /proc/mdstat 2>/dev/null || echo "no mdstat"'
run "LVM Volumes"                             bash -lc 'pvs 2>/dev/null; vgs 2>/dev/null; lvs 2>/dev/null'
run "ZFS Pools (if any)"                      bash -lc 'zpool status 2>/dev/null || echo "no zpool"; zfs list 2>/dev/null || true'
run_multi "SMART Disk Health"                 '
if command -v smartctl >/dev/null; then
  for d in /dev/sd[a-z] /dev/nvme[0-9] /dev/vd[a-z]; do
    [ -b "$d" ] && echo "--- $d ---" && smartctl -H "$d" 2>/dev/null | egrep -i "SMART overall|SMART Health|result|PASSED|FAILED";
  done
else echo "smartctl not installed"; fi
'

run_multi "Samba Status"                      'systemctl status smb 2>/dev/null | head -n 20 || systemctl status smb.service 2>/dev/null | head -n 20 || echo "smb not running"; command -v testparm >/dev/null && testparm -s 2>/dev/null || true; command -v smbstatus >/dev/null && smbstatus 2>/dev/null || true'
run_multi "NFS Status"                        'systemctl status nfs-server 2>/dev/null | head -n 20 || echo "nfs-server not running"; command -v exportfs >/dev/null && exportfs -v 2>/dev/null || true; command -v showmount >/dev/null && showmount -e 2>/dev/null || true; command -v rpcinfo >/dev/null && TRY rpcinfo -p 2>/dev/null || true'

run "Users with Shells"                       bash -lc 'awk -F: '\''$7 ~ /(bash|zsh|fish|sh)$/ {printf "user:%-16s uid:%-6s home:%-30s shell:%s\n",$1,$3,$6,$7}'\'' /etc/passwd'

########################################
# 6) PERFORMANCE SNAPSHOT
########################################
printf "\n## 6) Performance Snapshot\n" >> "$OUT"

run "Uptime / Load / Users"                   bash -lc 'uptime; who'
run "CPU/Memory Summary (top)"                bash -lc 'top -b -n1 | head -n 20'
run "Memory Usage (free -h)"                  bash -lc 'free -h'
run "VM/CPU Stats (vmstat 1 3)"               bash -lc 'vmstat 1 3'
run "Disk I/O (iostat -xz 1 3)"               bash -lc 'iostat -xz 1 3 2>/dev/null || echo "iostat not installed"'
run "Disk Usage (df -hP)"                     bash -lc 'df -hP'
run "Network Interface Stats (ip -s link)"    bash -lc 'ip -s link | head -n 100'
run "Pressure Stall Info (if available)"      bash -lc 'grep -H . /proc/pressure/* 2>/dev/null || echo "no PSI available"'

########################################
# 7) WIREGUARD SNAPSHOT (if installed)
########################################
printf "\n## 7) WireGuard Snapshot\n" >> "$OUT"

run_multi "WireGuard Interfaces" '
if command -v wg >/dev/null; then
  (wg show || true)
  echo; ip -br addr | grep -E "^\s*wg[0-9]"
  echo; ss -lunp | egrep -i ":(51820|51821|51822|51823)\b" || true
  echo; nft list ruleset 2>/dev/null | grep -n "udp dport" | grep -E "5182[0-3]" || true
else
  echo "wg not installed"
fi
'

########################################
# 8) RHEL EXTRAS: Subscription / Tuned / Kdump
########################################
printf "\n## 8) RHEL Extras\n" >> "$OUT"

run_multi "Subscription Status"               '
if command -v subscription-manager >/dev/null; then
  subscription-manager status || true
  subscription-manager list --consumed 2>/dev/null || true
else echo "subscription-manager not installed"; fi
'

run_multi "Tuned Profile"                     '
if systemctl is-active --quiet tuned 2>/dev/null; then
  tuned-adm active || true
  tuned-adm recommend || true
else echo "tuned inactive/not installed"; fi
'

run_multi "Kdump Status"                      '
systemctl status kdump 2>/dev/null | head -n 20 || echo "kdump not running"
[ -f /etc/kdump.conf ] && grep -Ev "^\s*(#|$)" /etc/kdump.conf || true
'

# -----------------------------
# Build a proper Table of Contents at the top
# -----------------------------
{
  echo "## Table of Contents"
  awk '
    /^## /{
      t=$0; sub(/^## /,"",t);
      a=tolower(t); gsub(/[^a-z0-9 ]/,"",a); gsub(/[ ]+/,"-",a);
      printf("- [%s](#%s)\n", t, a);
    }
  ' "$OUT"
  echo
  cat "$OUT"
} > "${OUT}.tmp" && mv "${OUT}.tmp" "$OUT"

echo "Wrote $OUT"
