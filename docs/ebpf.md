# eBPF on kldload

eBPF lets you attach small programs to kernel events — trace syscalls, watch network packets, profile CPU usage, measure latency — without modifying the kernel or restarting anything.

---

## What's installed

**Debian installs** include eBPF tools in the base image:

| Tool | What it does |
|------|-------------|
| `bpftrace` | High-level tracing language (like awk for the kernel) |
| `bpftool` | Low-level BPF program/map inspection |
| `bpfcc-tools` | 100+ ready-made scripts (opensnoop, execsnoop, tcplife, etc.) |
| `linux-perf` | Performance counters, flame graphs |

**CentOS/RHEL installs** can enable eBPF by setting `KLDLOAD_ENABLE_EBPF=1` in the answers file before install, or install afterward:

```bash
dnf install -y bpftool bcc-tools bpftrace perf
```

> Note: On CentOS the BCC tools package is `bcc-tools` (not `bpfcc-tools`). The individual tool names are the same.

---

## Quick examples with bpftrace

bpftrace is the fastest way to start. Every example below runs as root and exits with Ctrl+C.

### Who's opening files?

```bash
bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s %s\n", comm, str(args.filename)); }'
```

Output:
```
firefox /usr/lib/firefox/libxul.so
sshd /etc/ssh/sshd_config
bash /etc/profile
```

### Trace process execution

```bash
bpftrace -e 'tracepoint:syscalls:sys_enter_execve { printf("%s -> %s\n", comm, str(args.filename)); }'
```

Output:
```
bash -> /usr/bin/ls
bash -> /usr/bin/grep
cron -> /usr/sbin/logrotate
```

### Histogram of read() sizes

```bash
bpftrace -e 'tracepoint:syscalls:sys_exit_read /args.ret > 0/ { @bytes = hist(args.ret); }'
```

Press Ctrl+C to see the histogram:
```
@bytes:
[1]                   42 |@@@@@@@@                        |
[2, 4)                18 |@@@                             |
[4, 8)                37 |@@@@@@@                         |
[8, 16)               64 |@@@@@@@@@@@@                    |
[16, 32)             156 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
[32, 64)              91 |@@@@@@@@@@@@@@@@@@@             |
```

### DNS lookups

```bash
bpftrace -e 'tracepoint:net:net_dev_xmit /args.len > 0/ { @packets[comm] = count(); }'
```

### Latency of disk I/O

```bash
bpftrace -e '
kprobe:blk_account_io_start { @start[arg0] = nsecs; }
kprobe:blk_account_io_done /@start[arg0]/ {
  @usecs = hist((nsecs - @start[arg0]) / 1000);
  delete(@start[arg0]);
}'
```

---

## BCC tools (ready-made scripts)

The BCC toolkit ships ~100 tools. On Debian they're in `/usr/sbin/`; on CentOS in `/usr/share/bcc/tools/`. Some highlights:

```bash
# Watch every file being opened system-wide
opensnoop

# Watch every process being launched
execsnoop

# TCP connections with latency and PID
tcpconnect

# TCP sessions with duration and bytes transferred
tcplife

# Trace DNS queries (requires running DNS resolver)
# gethostlatency   # traces getaddrinfo/gethostbyname

# Slow filesystem operations (>10ms)
fileslower 10

# Block device I/O latency histogram
biolatency

# Snoop on ext4/ZFS read/write calls
ext4slower 1
zfsslower 1

# Cache hit rate
cachestat

# CPU scheduler latency (how long tasks wait before running)
runqlat

# Memory allocation tracing
memleak
```

Run any of these with `-h` for options. Most accept a duration or count argument:

```bash
# Show TCP connections for 30 seconds then exit
tcplife 30

# Show top 10 processes by block I/O
biotop 10
```

---

## bpftool — inspect loaded programs

```bash
# List all loaded BPF programs
bpftool prog list

# Show details of a specific program
bpftool prog show id 42

# List BPF maps (shared data structures)
bpftool map list

# Dump a map's contents
bpftool map dump id 7

# Show BTF (type information) availability
bpftool btf list
```

---

## Practical use cases on kldload

### Monitor ZFS pool I/O

```bash
# Trace ZFS read/write operations slower than 1ms
zfsslower 1

# Or trace the underlying block device
biolatency -d /dev/sda
```

### Watch what the installer does

During a kldload install, trace every file being created:

```bash
opensnoop -f O_CREAT
```

### Profile a slow boot

```bash
# Record a flame graph of the next 30 seconds
perf record -g -a sleep 30
perf script > out.perf

# Convert to flame graph (requires flamegraph.pl from github.com/brendangregg/FlameGraph)
stackcollapse-perf.pl out.perf | flamegraph.pl > flamegraph.svg
```

### Network debugging

```bash
# See all new TCP connections with the process that made them
tcpconnect

# Count packets per process
bpftrace -e 'tracepoint:net:net_dev_xmit { @[comm] = count(); }'

# Trace TCP retransmits (sign of network problems)
tcpretrans
```

---

## Writing a custom bpftrace script

Save as `trace-zpool-imports.bt`:

```
#!/usr/bin/env bpftrace

/* Trace zpool import operations via the spa_open path */
kprobe:spa_open {
  printf("zpool open: pid=%d comm=%s\n", pid, comm);
}

kretprobe:spa_open {
  printf("zpool open returned: pid=%d ret=%d\n", pid, retval);
}
```

Run it:

```bash
chmod +x trace-zpool-imports.bt
bpftrace trace-zpool-imports.bt
```

---

## Kernel requirements

eBPF needs:
- Kernel 4.x+ (kldload ships 5.14+ on CentOS, 6.x on Debian — both fine)
- `CONFIG_BPF=y`, `CONFIG_BPF_SYSCALL=y` — enabled in all kldload kernels
- BTF (BPF Type Format) for bpftrace struct access — present in kldload kernels
- Root access (or `CAP_BPF` + `CAP_PERFMON` on newer kernels)

Check BTF availability:

```bash
ls /sys/kernel/btf/vmlinux && echo "BTF available" || echo "No BTF"
```
