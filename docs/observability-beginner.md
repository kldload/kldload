# Observability — Beginner

Start here if you've never traced a system call or looked at a flame graph. Everything below runs on kldloadOS out of the box — no extra packages to install on Debian, and a single `kpkg install` on CentOS/RHEL.

---

## Level 0: What am I looking at?

### kst — your first command

```bash
kst
```

This is the one-command health check. It shows:
- Is the ZFS pool healthy?
- How much disk space is left?
- Are snapshots running?
- How many boot environments do I have?
- Is anything using too much memory?
- Are my services running?

If `kst` looks green, your system is fine. If something is yellow or red, keep reading.

### System diagnostics — the full picture

kldloadOS includes comprehensive diagnostic scripts that collect everything about your system into a single Markdown report:

```bash
# Debian
sudo diagnostics.sh

# CentOS/RHEL
sudo rhel-diag.sh
```

This generates `diagnostic.md` — a complete snapshot of:
- Network interfaces, routes, DNS
- Failed services, disk usage
- Firewall rules, listening ports
- Package status, security updates
- ZFS pool health, disk SMART status
- CPU/memory/I/O pressure

**When to use it:** Something is wrong and you don't know where to start. Run the diagnostics, read the report, search for the red flags.

---

## Level 1: What's happening right now?

### Watch processes

```bash
# What's using CPU?
top

# Better top (if installed)
htop

# What processes just launched?
# (This is your first eBPF command)
execsnoop
```

`execsnoop` uses eBPF under the hood — it hooks into the kernel's `execve` syscall and prints every new process as it starts. No performance impact, no log parsing, just live data.

### Watch files being opened

```bash
opensnoop
```

Shows every file open in real time — which process, which file, whether it succeeded or failed. Useful for finding "file not found" errors, permission denials, or figuring out what config files an application reads at startup.

### Watch network connections

```bash
# New TCP connections
tcpconnect

# TCP sessions with duration and bytes
tcplife
```

`tcpconnect` shows every outbound TCP connection with the process that made it. `tcplife` is like `tcpconnect` but waits for connections to close and shows how long they lasted and how much data moved.

### Watch disk I/O

```bash
# I/O latency histogram
biolatency

# Slow filesystem operations (>10ms)
fileslower 10

# Per-process I/O stats
biotop
```

---

## Level 2: Your first bpftrace one-liner

`bpftrace` is like `awk` for the kernel. You write tiny programs that attach to kernel events.

### Who's calling open()?

```bash
bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s %s\n", comm, str(args.filename)); }'
```

Output:
```
nginx /etc/nginx/nginx.conf
sshd /etc/ssh/sshd_config
bash /etc/profile
```

**What this means:**
- `tracepoint:syscalls:sys_enter_openat` — fires every time any process opens a file
- `comm` — the process name
- `args.filename` — the file being opened

### How big are read() calls?

```bash
bpftrace -e 'tracepoint:syscalls:sys_exit_read /args.ret > 0/ { @bytes = hist(args.ret); }'
```

Press Ctrl+C to see a histogram of read sizes. If most reads are tiny (1–16 bytes), something might be doing inefficient I/O.

### Count syscalls by process

```bash
bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }'
```

Ctrl+C after a few seconds. Shows which processes are making the most syscalls — a quick way to find noisy applications.

---

## Level 3: Log forensics with LogHog

LogHog (`lh`) stitches logs from multiple sources by timestamp and gives you an interactive forensics interface:

```bash
lh
```

Interactive menu:
- **(A)uth** — authentication failures (brute force, bad passwords, key rejections)
- **(E)rrors** — system errors across all logs
- **(L)ive All** — tail all logs stitched by timestamp
- **(N)etwork** — network protocol activity (HTTP, SSH, DNS, etc.)
- **(R)egEX** — search by pattern
- **(I)P Search** — extract and locate IP addresses
- **(J)SON Export** — structured output for further analysis

### Example: find authentication failures

Launch `lh`, press `A`. It pulls auth failures from syslog, auth.log, journald, and sshd logs, stitched together chronologically:

```
Mar 21 14:23:01 sshd[1234]: Failed password for root from 203.0.113.5 port 43210
Mar 21 14:23:02 sshd[1234]: Failed password for root from 203.0.113.5 port 43210
Mar 21 14:23:03 sshd[1234]: Connection closed by 203.0.113.5 port 43210
```

### Example: follow everything live

Launch `lh`, press `L`. All logs from all sources, merged by timestamp, streaming in real time. Ctrl+C to stop.

---

## Installing the tools

### Debian (most tools pre-installed)

eBPF tools (`bpftrace`, `bpfcc-tools`, `bpftool`, `linux-perf`) are in the kldloadOS base image.

For LogHog:
```bash
kpkg install libjson-c-dev libreadline-dev
cd /opt
git clone https://github.com/unixbox-net/linux-tools.git
cd linux-tools/debian/utils/lh
./install.sh
```

### CentOS/RHEL

```bash
# eBPF tools
kpkg install bcc-tools bpftrace perf

# LogHog
kpkg install json-c-devel readline-devel
cd /opt
git clone https://github.com/unixbox-net/linux-tools.git
cd linux-tools/debian/utils/lh
./install.sh
```

The diagnostics scripts work out of the box:
```bash
# Use the right one for your distro
sudo /opt/linux-tools/debian/diagnostics/diagnostics.sh   # Debian
sudo /opt/linux-tools/rhel/rhel-diag.sh                   # CentOS/RHEL
```

---

## Cheat sheet

| I want to... | Run this |
|--------------|----------|
| Quick health check | `kst` |
| Full system diagnostic | `diagnostics.sh` or `rhel-diag.sh` |
| See new processes | `execsnoop` |
| See file opens | `opensnoop` |
| See TCP connections | `tcpconnect` |
| See TCP session details | `tcplife` |
| See disk I/O latency | `biolatency` |
| See slow file ops | `fileslower 10` |
| Watch all logs live | `lh` → L |
| Find auth failures | `lh` → A |
| Count syscalls by process | `bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }'` |

---

## Next level

Once you're comfortable with the BCC tools and basic bpftrace, move on to [Observability — Intermediate](observability-intermediate.md) to build real-time dashboards with socket_snoop, latency_snoop, and Prometheus.
