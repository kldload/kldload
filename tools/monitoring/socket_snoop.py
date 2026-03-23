#!/usr/bin/env python3
"""
# Socket Snoop - Realtime Socket Monitoring, @OR(ϵ)SOURCES

## Overview

The Socket Monitoring Tool is a powerful and lightweight solution designed for system administrators who need real-time insights into socket-level network activity on their systems. By leveraging eBPF, this tool provides detailed logs of connection states, including source and destination IP addresses, ports, process IDs (PIDs), and associated commands (COMM), as well as TCP state transitions. Socket_snoop is a poerful addition to tcpdump.

```plaintext
FEATURES:
- Captures TCP state changes (inet_sock_set_state tracepoint).
- Monitors key TCP connection states like SYN_SENT, FIN_WAIT, and TIME_WAIT.
- Tracks TCP retransmissions (tcp_retransmit_skb tracepoint), a key indicator of network issues.
- Logs the process ID (PID) and command name (COMM) associated with each connection.
- Logs connection details (source/destination IP and port, process ID, and state) to /var/log/socket_monitor.log.
- Skips noisy or invalid entries, like connections with IP 0.0.0.0.
- Maps TCP states to human-readable descriptions.
- Formats IP addresses for readability.
- Uses perf_buffer for real-time event handling.
- Can run continuously and provide live updates via the console and log file.
- Real-Time Logging: Captures and logs socket connections as they occur.
- Detailed Insights: Provides source and destination IP addresses, ports, PIDs, command names, and TCP states.
- Formatted Output: Logs are time-stamped and categorized (e.g., Opened Connection, Closed Connection, Established Connection).
- Lightweight and Efficient: Runs efficiently using eBPF without significant performance overhead.

BENEFITS:
- Simplifies network monitoring by highlighting key details often buried in more complex tools.
- Reduces the need for deep packet analysis with tools like tcpdump or wireshark.
- Enhances operational awareness for system administrators managing critical infrastructure.

LIMITATIONS:
- IP4 only (wip)
- Need to add Dynamic Filters / pid/ip/ports
- Enhance Error Handling
- Perfomance Tuning
```
## Use Cases

Security Monitoring: Detect suspicious or unauthorized network activity.
Performance Debugging: Identify network latency or dropped connections by observing TCP states.
Audit Logging: Maintain a comprehensive record of all socket-level network interactions.
Real-Time Monitoring: Observe live network activity without the complexity of tools like tcpdump or wireshark. In addition, no network frames are captured so it's perfect for high security networks.
"""
import argparse
import hashlib
import os
import sys
from datetime import datetime
from collections import deque
from typing import Dict, Any, List, Optional


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Enhanced Socket Monitoring Script")
    p.add_argument("--pid", type=int, default=None, help="Filter by PID")
    p.add_argument("--src-ip", type=str, default=None, help="Filter by source IPv4")
    p.add_argument("--dst-ip", type=str, default=None, help="Filter by destination IPv4")
    p.add_argument("--src-port", type=int, default=None, help="Filter by source port")
    p.add_argument("--dst-port", type=int, default=None, help="Filter by destination port")
    p.add_argument("--active-only", action="store_true", help="Only established connections")
    p.add_argument(
        "--log-file",
        default=os.environ.get("SOCKET_SNOOP_LOG", "/var/log/socket_monitor.log"),
        help="Log file path (default: /var/log/socket_monitor.log or $SOCKET_SNOOP_LOG)",
    )
    return p.parse_args()


# ---------------------------------------------------------------------------
# BPF program
# ---------------------------------------------------------------------------

BPF_PROGRAM = r"""
// Compatibility shims for mixed header sets (e.g. new kernel + older userspace)
// Some kernels/userspace combos reference BPF_LOAD_ACQ / BPF_STORE_REL in
// include/linux/bpf.h but older uapi headers do not define them, causing
// "use of undeclared identifier" errors. Defining them here is harmless for
// our program and keeps compilation portable.
#ifndef BPF_LOAD_ACQ
#define BPF_LOAD_ACQ 0x85
#endif

#ifndef BPF_STORE_REL
#define BPF_STORE_REL 0xa5
#endif

#include <uapi/linux/ptrace.h>
#include <uapi/linux/in.h>
#include <linux/tcp.h>
#include <linux/sched.h>
#include <bcc/proto.h>

struct data_t {
    u32 pid;
    u32 ppid;
    char comm[TASK_COMM_LEN];
    u32 src_ip;
    u32 dst_ip;
    u16 src_port;
    u16 dst_port;
    int state;
    char event[16];
    u32 uid;
};

BPF_PERF_OUTPUT(events);

// Tracepoint: sock:inet_sock_set_state
// This fires on TCP state transitions.
TRACEPOINT_PROBE(sock, inet_sock_set_state)
{
    if (args->family != AF_INET)
        return 0;

    struct data_t data = {};
    u64 pid_tgid = bpf_get_current_pid_tgid();
    data.pid = pid_tgid >> 32;
    data.uid = bpf_get_current_uid_gid();
    bpf_get_current_comm(&data.comm, sizeof(data.comm));

    // parent PID (verifier-safe)
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    u32 ppid = 0;
    if (task && task->real_parent) {
        bpf_probe_read_kernel(&ppid, sizeof(ppid), &task->real_parent->tgid);
    }
    data.ppid = ppid;

    // Many modern kernels (and Debian 13 / BCC 0.31) use __u8[4] for
    // saddr/daddr in this tracepoint.
    //
    // We treat args->saddr / args->daddr as byte arrays and pack into u32.
    data.src_ip = ((u32)args->saddr[0] << 24) |
                  ((u32)args->saddr[1] << 16) |
                  ((u32)args->saddr[2] <<  8) |
                  ((u32)args->saddr[3]);
    data.dst_ip = ((u32)args->daddr[0] << 24) |
                  ((u32)args->daddr[1] << 16) |
                  ((u32)args->daddr[2] <<  8) |
                  ((u32)args->daddr[3]);

    data.src_port = ntohs(args->sport);
    data.dst_port = ntohs(args->dport);
    data.state = args->newstate;

    __builtin_strncpy(data.event, "State Change", sizeof(data.event));
    events.perf_submit(args, &data, sizeof(data));
    return 0;
}
"""


TCP_STATES: Dict[int, str] = {
    1: "Connection Established",
    2: "Connection Opening (SYN_SENT)",
    3: "Connection Opening (SYN_RECV)",
    4: "Connection Closing (FIN_WAIT1)",
    5: "Connection Closing (FIN_WAIT2)",
    6: "Connection Closed (TIME_WAIT)",
    7: "Connection Closed",
    8: "Connection Closing (CLOSE_WAIT)",
    9: "Connection Closing (LAST_ACK)",
    10: "Listening for Connections",
    11: "Connection Closing (CLOSING)",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def format_ip(ip_u32: int) -> str:
    return ".".join(str((ip_u32 >> s) & 0xFF) for s in (24, 16, 8, 0))


def connection_id(src_ip: str, src_port: int, dst_ip: str, dst_port: int) -> str:
    unique = f"{src_ip}:{src_port}->{dst_ip}:{dst_port}"
    return hashlib.md5(unique.encode(), usedforsecurity=False).hexdigest()


def resolve_kernel_include_cflags() -> List[str]:
    """
    Build a list of -I cflags pointing at the *host* kernel headers.

    This is especially important when running in a container with:
      - /lib/modules mounted from the host
      - userspace headers from a different distro (e.g. Debian in container,
        Fedora on host) that might be out of sync.

    We prefer the host kernel's own source tree, if present.
    """
    cflags: List[str] = []

    # Inside container but using host kernel
    rel = os.uname().release
    candidates = [
        f"/lib/modules/{rel}/build",
        f"/lib/modules/{rel}/source",
    ]

    for base in candidates:
        if not os.path.isdir(base):
            continue
        for inc in ("include", "include/uapi", "include/generated"):
            path = os.path.join(base, inc)
            if os.path.isdir(path):
                cflags.append(f"-I{path}")

    return cflags


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    if os.uname().sysname.lower() != "linux":
        print("This tool requires Linux (eBPF/BCC).", file=sys.stderr)
        sys.exit(1)

    args = parse_args()

    # Prepare log file
    log_file = args.log_file
    try:
        if not os.path.exists(log_file):
            with open(log_file, "w") as f:
                f.write("Enhanced Socket Monitoring Log\n" + "=" * 60 + "\n")
    except PermissionError:
        print(
            f"Warning: cannot write to {log_file}; falling back to ./socket_monitor.log",
            file=sys.stderr,
        )
        log_file = "./socket_monitor.log"

    # Lazy import so unit tests can run without BCC
    try:
        from bcc import BPF
    except ImportError:
        print("Error: python3-bcc (BCC bindings) not available.", file=sys.stderr)
        sys.exit(1)

    # Resolve kernel include paths for containerized host-tracing setups
    cflags = resolve_kernel_include_cflags()
    if cflags:
        print(f"[socket-snoop] Using extra BPF cflags: {cflags}", file=sys.stderr)

    # Compile BPF program
    try:
        if cflags:
            b = BPF(text=BPF_PROGRAM, cflags=cflags)
        else:
            b = BPF(text=BPF_PROGRAM)
    except Exception as e:
        print(f"[socket-snoop] Failed to compile BPF program: {e}", file=sys.stderr)
        # Hint for containerized use
        print(
            "[socket-snoop] Hint: make sure the host kernel headers are available "
            "inside the container (e.g. mount /lib/modules and /usr/src) and that "
            "kernel/BCC versions are compatible.",
            file=sys.stderr,
        )
        sys.exit(1)

    metrics: Dict[str, int] = {
        "active_connections": 0,
        "closing_connections": 0,
        "closed_connections": 0,
    }
    recent_events: deque = deque(maxlen=2000)

    def handle_event(cpu: int, data: Any, size: int) -> None:
        event = b["events"].event(data)
        state_str = TCP_STATES.get(event.state, "UNKNOWN STATE")
        timestamp = datetime.now().strftime("%b %d %Y %H:%M:%S.%f")[:-3]

        src_ip = format_ip(event.src_ip)
        dst_ip = format_ip(event.dst_ip)

        # User-space filters (cheap, flexible)
        if args.pid is not None and int(event.pid) != args.pid:
            return
        if args.src_ip and src_ip != args.src_ip:
            return
        if args.dst_ip and dst_ip != args.dst_ip:
            return
        if args.src_port is not None and int(event.src_port) != args.src_port:
            return
        if args.dst_port is not None and int(event.dst_port) != args.dst_port:
            return
        if args.active_only and int(event.state) != 1:
            return

        # Simple metrics
        st = int(event.state)
        if st == 1:
            metrics["active_connections"] += 1
        elif st in (4, 5, 8, 9, 11):
            metrics["closing_connections"] += 1
        elif st in (6, 7):
            if metrics["active_connections"] > 0:
                metrics["active_connections"] -= 1
            metrics["closed_connections"] += 1

        # De-dup rapid repeats
        event_key = (
            src_ip,
            int(event.src_port),
            dst_ip,
            int(event.dst_port),
            int(event.pid),
            st,
        )
        if event_key in recent_events:
            return
        recent_events.append(event_key)

        entry: Dict[str, Any] = {
            "timestamp": timestamp,
            "event": event.event.decode(errors="ignore"),
            "src_ip": src_ip,
            "dst_ip": dst_ip,
            "src_port": int(event.src_port),
            "dst_port": int(event.dst_port),
            "protocol": "TCP",
            "state": state_str,
            "connection_id": connection_id(
                src_ip, int(event.src_port), dst_ip, int(event.dst_port)
            ),
            "metrics": dict(metrics),
            "pid": int(event.pid),
            "ppid": int(event.ppid),
            "uid": int(event.uid),
            "comm": event.comm.decode(errors="ignore"),
        }

        print(entry)
        try:
            with open(log_file, "a") as f:
                f.write(str(entry) + "\n")
        except Exception as e:
            print(f"Log write failed: {e}", file=sys.stderr)

    # Attach perf buffer
    b["events"].open_perf_buffer(handle_event)
    print(f"Monitoring socket connections. Logging to {log_file}")
    try:
        while True:
            b.perf_buffer_poll()
    except KeyboardInterrupt:
        print("\nStopping monitoring...")


if __name__ == "__main__":
    main()

