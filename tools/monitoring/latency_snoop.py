#!/usr/bin/env python3
"""
Ultimate Socket Latency Snoop (IPv4) via eBPF/BCC + Prometheus Exporter.

Features
- Connect latency: SYN_SENT -> ESTABLISHED
- Req->Resp latency hint: first tcp_sendmsg after idle -> first tcp_cleanup_rbuf that copies to user
- RTT internals: tcp_sock.srtt_us, mdev_us (rttvar)
- Retransmits: tcp:tcp_retransmit_skb
- Process/thread: TGID (pid), TID, PPID, UID, comm
- Cgroup/Kubernetes enrichment: cgroup id, pod_uid, container_id (best effort from cgroup v2/v1 paths)
- Optional user stacks: --stacks
- Prometheus exporter: histograms + counters (low-cardinality by default)
- Optional per-flow high-cardinality metrics: --per-flow (use sparingly)

Requirements
- Linux, root
- bcc and matching kernel headers (apt install bpfcc-tools linux-headers-$(uname -r), or distro equivalent)
- prometheus_client (pip install prometheus_client)

# basic run with JSON output
sudo ./socket_latency_ultra.py --json

# add Prometheus on port 9900 (default low-card labels)
sudo ./socket_latency_ultra.py --prometheus-port 9900

# high-cardinality per-flow labels (use sparingly!)
sudo ./socket_latency_ultra.py --prometheus-port 9900 --per-flow

# include user-space stacks (needs symbols for pretty names)
sudo ./socket_latency_ultra.py --stacks --prometheus-port 9900

Tested on recent kernels with BCC 0.31+. Tracepoint field shapes vary; this code targets
inet_sock_set_state with __u8[4] saddr/daddr (common on modern distros). Adjust noted spots if needed.
"""

import argparse
import hashlib
import os
import sys
import socket
import re
import json
from datetime import datetime
from collections import deque, defaultdict

def parse_args():
    p = argparse.ArgumentParser(description="Ultimate Socket Latency Monitor + Prometheus")
    # filters
    p.add_argument("--pid", type=int, default=None, help="Filter by TGID (process id)")
    p.add_argument("--src-ip", type=str, default=None, help="Filter by source IPv4")
    p.add_argument("--dst-ip", type=str, default=None, help="Filter by destination IPv4")
    p.add_argument("--src-port", type=int, default=None, help="Filter by source port")
    p.add_argument("--dst-port", type=int, default=None, help="Filter by destination port")
    p.add_argument("--active-only", action="store_true", help="Only established/latency events")
    # telemetry/output
    p.add_argument("--log-file", default=os.environ.get("SOCKET_SNOOP_LOG", "/var/log/socket_monitor.log"))
    p.add_argument("--json", action="store_true", help="Emit events as JSON lines to stdout")
    # stacks & cardinality
    p.add_argument("--stacks", action="store_true", help="Collect user-space stacks (needs symbols for nice names)")
    p.add_argument("--per-flow", action="store_true", help="Export per-flow (5-tuple) metrics (HIGH CARDINALITY)")
    # prometheus
    p.add_argument("--prometheus-port", type=int, default=0, help="Port to expose Prometheus metrics (0=disabled)")
    p.add_argument("--buckets", type=str, default="0.5,1,2.5,5,10,25,50,100,250,500,1000,2500",
                   help="Histogram buckets in ms (comma-separated)")
    return p.parse_args()

BPF_PROGRAM = r"""
#include <uapi/linux/ptrace.h>
#include <uapi/linux/in.h>
#include <uapi/linux/tcp.h>
#include <linux/tcp.h>
#include <linux/sched.h>
#include <linux/net.h>
#include <net/tcp.h>
#include <bcc/proto.h>

struct flow_key_t {
    u32 tgid;
    u32 saddr;
    u32 daddr;
    u16 sport;
    u16 dport;
};

static __always_inline void fill_key(struct flow_key_t *k, u32 tgid, const __u8 saddr[4], const __u8 daddr[4], u16 sport, u16 dport) {
    k->tgid = tgid;
    k->saddr = ((u32)saddr[0] << 24) | ((u32)saddr[1] << 16) | ((u32)saddr[2] << 8) | ((u32)saddr[3]);
    k->daddr = ((u32)daddr[0] << 24) | ((u32)daddr[1] << 16) | ((u32)daddr[2] << 8) | ((u32)daddr[3]);
    k->sport = bpf_ntohs(sport);
    k->dport = bpf_ntohs(dport);
}

struct data_t {
    u32 tgid;          // process (thread group id)
    u32 pid;           // tid
    u32 ppid;
    u32 uid;
    u64 cgroup_id;

    char comm[TASK_COMM_LEN];

    u32 src_ip;
    u32 dst_ip;
    u16 src_port;
    u16 dst_port;

    int state;         // TCP state or -1 for req/resp
    char event[24];

    // latency fields (ns)
    u64 connect_latency_ns;   // SYN_SENT -> ESTABLISHED
    u64 rr_latency_ns;        // send -> recv (copied to user)

    // TCP internals
    u32 srtt_us;              // smoothed RTT
    u32 rttvar_us;
    u32 retransmits;          // observed retransmits on flow (monotonic)

    // stacks
    int have_stack;
    u32 stack_id;
};

BPF_PERF_OUTPUT(events);

// state & timing
BPF_HASH(conn_start_ts, struct flow_key_t, u64);
BPF_HASH(last_send_ts, struct flow_key_t, u64);
BPF_HASH(retrans_count, struct flow_key_t, u32);

// stacks
struct fd_key_t { u32 tgid; int fd; };
BPF_STACK_TRACE(stack_traces, 8192);
BPF_HASH(pending_connect_stack, struct fd_key_t, u32);
BPF_HASH(pending_send_stack, struct fd_key_t, u32);

TRACEPOINT_PROBE(syscalls, sys_enter_connect) {
    struct fd_key_t fk = {};
    u64 id = bpf_get_current_pid_tgid();
    fk.tgid = id >> 32;
    fk.fd = args->fd;
    int stack_id = bpf_get_stackid(args, &stack_traces, BPF_F_USER_STACK);
    if (stack_id >= 0) {
        pending_connect_stack.update(&fk, &stack_id);
    }
    return 0;
}
TRACEPOINT_PROBE(syscalls, sys_enter_sendto) {
    struct fd_key_t fk = {};
    u64 id = bpf_get_current_pid_tgid();
    fk.tgid = id >> 32;
    fk.fd = args->fd;
    int stack_id = bpf_get_stackid(args, &stack_traces, BPF_F_USER_STACK);
    if (stack_id >= 0) {
        pending_send_stack.update(&fk, &stack_id);
    }
    return 0;
}

TRACEPOINT_PROBE(sock, inet_sock_set_state) {
    if (args->family != AF_INET)
        return 0;

    u64 id = bpf_get_current_pid_tgid();
    u32 tgid = id >> 32;
    u32 pid = id & 0xffffffff;

    struct flow_key_t key = {};
    fill_key(&key, tgid, args->saddr, args->daddr, args->sport, args->dport);

    if (args->newstate == TCP_SYN_SENT) {
        u64 ts = bpf_ktime_get_ns();
        conn_start_ts.update(&key, &ts);
        return 0;
    }

    struct data_t data = {};
    data.tgid = tgid;
    data.pid  = pid;
    data.uid  = bpf_get_current_uid_gid();
    data.cgroup_id = bpf_get_current_cgroup_id();
    bpf_get_current_comm(&data.comm, sizeof(data.comm));
    u32 ppid = 0;
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    if (task && task->real_parent) {
        bpf_probe_read_kernel(&ppid, sizeof(ppid), &task->real_parent->tgid);
    }
    data.ppid = ppid;

    data.src_ip = ((u32)args->saddr[0] << 24) | ((u32)args->saddr[1] << 16) | ((u32)args->saddr[2] << 8) | ((u32)args->saddr[3]);
    data.dst_ip = ((u32)args->daddr[0] << 24) | ((u32)args->daddr[1] << 16) | ((u32)args->daddr[2] << 8) | ((u32)args->daddr[3]);
    data.src_port = bpf_ntohs(args->sport);
    data.dst_port = bpf_ntohs(args->dport);
    data.state = args->newstate;
    __builtin_memcpy(&data.event, "State Change", 13);

    if (args->newstate == TCP_ESTABLISHED) {
        u64 *tsp = conn_start_ts.lookup(&key);
        if (tsp) {
            data.connect_latency_ns = bpf_ktime_get_ns() - *tsp;
            conn_start_ts.delete(&key);
        }
    }

    if (args->skaddr) {
        struct sock *sk = (struct sock *)args->skaddr;
        struct tcp_sock *tp = (struct tcp_sock *)tcp_sk(sk);
        if (tp) {
            u32 srtt_us = 0, rttvar_us = 0;
            bpf_probe_read_kernel(&srtt_us, sizeof(srtt_us), &tp->srtt_us);
            bpf_probe_read_kernel(&rttvar_us, sizeof(rttvar_us), &tp->mdev_us);
            data.srtt_us = srtt_us;
            data.rttvar_us = rttvar_us;
        }
    }

    u32 *rc = retrans_count.lookup(&key);
    if (rc) data.retransmits = *rc;

    data.have_stack = 0;
    data.stack_id = -1;

    events.perf_submit(args, &data, sizeof(data));
    return 0;
}

TRACEPOINT_PROBE(tcp, tcp_retransmit_skb) {
    struct flow_key_t key = {};
    key.tgid = 0; // kernel context; kept zero; keyed by 4-tuple
    key.saddr = args->saddr;
    key.daddr = args->daddr;
    key.sport = args->sport;
    key.dport = args->dport;

    u32 *cnt = retrans_count.lookup(&key);
    u32 one = 1;
    if (!cnt) {
        retrans_count.update(&key, &one);
    } else {
        __sync_fetch_and_add(cnt, 1);
    }
    return 0;
}

int kprobe__tcp_sendmsg(struct pt_regs *ctx, struct sock *sk, struct msghdr *msg, size_t size) {
    u64 id = bpf_get_current_pid_tgid();
    u32 tgid = id >> 32;

    u16 sport = 0, dport = 0;
    u32 saddr = 0, daddr = 0;
    struct inet_sock *inet = (struct inet_sock *)sk;
    bpf_probe_read_kernel(&sport, sizeof(sport), &inet->inet_sport);
    bpf_probe_read_kernel(&dport, sizeof(dport), &inet->inet_dport);
    bpf_probe_read_kernel(&saddr, sizeof(saddr), &inet->inet_saddr);
    bpf_probe_read_kernel(&daddr, sizeof(daddr), &inet->inet_daddr);

    struct flow_key_t key = {};
    key.tgid = tgid;
    key.saddr = saddr;
    key.daddr = daddr;
    key.sport = bpf_ntohs(sport);
    key.dport = bpf_ntohs(dport);

    u64 ts = bpf_ktime_get_ns();
    last_send_ts.update(&key, &ts);
    return 0;
}

int kprobe__tcp_cleanup_rbuf(struct pt_regs *ctx, struct sock *sk, int copied) {
    if (copied <= 0) return 0;

    u64 id = bpf_get_current_pid_tgid();
    u32 tgid = id >> 32;

    u16 sport = 0, dport = 0;
    u32 saddr = 0, daddr = 0;
    struct inet_sock *inet = (struct inet_sock *)sk;
    bpf_probe_read_kernel(&sport, sizeof(sport), &inet->inet_sport);
    bpf_probe_read_kernel(&dport, sizeof(dport), &inet->inet_dport);
    bpf_probe_read_kernel(&saddr, sizeof(saddr), &inet->inet_saddr);
    bpf_probe_read_kernel(&daddr, sizeof(daddr), &inet->inet_daddr);

    struct flow_key_t key = {};
    key.tgid = tgid;
    key.saddr = saddr;
    key.daddr = daddr;
    key.sport = bpf_ntohs(sport);
    key.dport = bpf_ntohs(dport);

    u64 *tsp = last_send_ts.lookup(&key);
    if (!tsp) return 0;

    struct data_t data = {};
    data.tgid = tgid;
    data.pid  = (u32)id;
    data.uid  = bpf_get_current_uid_gid();
    data.cgroup_id = bpf_get_current_cgroup_id();
    bpf_get_current_comm(&data.comm, sizeof(data.comm));
    data.src_ip = saddr;
    data.dst_ip = daddr;
    data.src_port = bpf_ntohs(sport);
    data.dst_port = bpf_ntohs(dport);
    data.state = -1;
    __builtin_memcpy(&data.event, "ReqResp Latency", 16);
    data.rr_latency_ns = bpf_ktime_get_ns() - *tsp;

    u32 *rc = retrans_count.lookup(&key);
    if (rc) data.retransmits = *rc;

    struct tcp_sock *tp = (struct tcp_sock *)tcp_sk(sk);
    if (tp) {
        u32 srtt_us = 0, rttvar_us = 0;
        bpf_probe_read_kernel(&srtt_us, sizeof(srtt_us), &tp->srtt_us);
        bpf_probe_read_kernel(&rttvar_us, sizeof(rttvar_us), &tp->mdev_us);
        data.srtt_us = srtt_us;
        data.rttvar_us = rttvar_us;
    }

    data.have_stack = 0;
    data.stack_id = -1;

    events.perf_submit(ctx, &data, sizeof(data));

    last_send_ts.delete(&key);
    return 0;
}
"""

TCP_STATES = {
    1: "ESTABLISHED",
    2: "SYN_SENT",
    3: "SYN_RECV",
    4: "FIN_WAIT1",
    5: "FIN_WAIT2",
    6: "TIME_WAIT",
    7: "CLOSED",
    8: "CLOSE_WAIT",
    9: "LAST_ACK",
    10: "LISTEN",
    11: "CLOSING",
}

def format_ip(ip_u32: int) -> str:
    return ".".join(str((ip_u32 >> s) & 0xFF) for s in (24, 16, 8, 0))

def connection_id(src_ip, src_port, dst_ip, dst_port) -> str:
    unique = f"{src_ip}:{src_port}->{dst_ip}:{dst_port}"
    return hashlib.md5(unique.encode()).hexdigest()

def ns_to_ms(ns: int) -> float:
    return round(ns / 1_000_000.0, 6)

# --- Kubernetes / cgroup enrichment (best-effort) ---
CGRX_PATTERNS = [
    # cgroup v2 pod path examples (containerd/crio)
    re.compile(r".*kubepods.*pod([0-9a-fA-F\-]{36}).*?/[0-9a-fA-F]{64}$"),          # podUID + containerID (64)
    re.compile(r".*kubepods.*pod([0-9a-fA-F\-]{36}).*?/(cri-containerd|docker)-([0-9a-fA-F]{64}).*$"),
    # docker legacy
    re.compile(r".*docker[-/].*?([0-9a-fA-F]{64}).*$"),
]

def k8s_enrich_from_pid(pid: int):
    """Return dict with {'pod_uid', 'container_id'} if derivable from /proc/<pid>/cgroup."""
    cgroup_path = f"/proc/{pid}/cgroup"
    res = {}
    try:
        with open(cgroup_path, "r") as f:
            data = f.read()
        # v2 line: 0::/kubepods.slice/.../pod<uuid>/<containerid>
        # v1 lines include subsystems; we just scan every path component.
        for line in data.splitlines():
            parts = line.split(":")
            if len(parts) < 3:
                continue
            path = parts[-1]
            for rx in CGRX_PATTERNS:
                m = rx.match(path)
                if m:
                    groups = m.groups()
                    # try to map
                    if len(groups) == 1:
                        cont = groups[0]
                        res.setdefault("container_id", cont)
                    elif len(groups) >= 2:
                        pod = groups[0]
                        cont = groups[-1]
                        res.setdefault("pod_uid", pod)
                        res.setdefault("container_id", cont)
        return res
    except Exception:
        return res

def main():
    if os.uname().sysname.lower() != "linux":
        print("This tool requires Linux (eBPF/BCC).", file=sys.stderr)
        sys.exit(1)

    args = parse_args()

    # buckets
    try:
        buckets_ms = [float(x.strip()) for x in args.buckets.split(",") if x.strip()]
    except Exception:
        buckets_ms = [0.5,1,2.5,5,10,25,50,100,250,500,1000,2500]

    log_file = args.log_file
    try:
        if log_file and not os.path.exists(log_file):
            with open(log_file, "w") as f:
                f.write("Ultimate Socket Latency Log\n" + "=" * 60 + "\n")
    except PermissionError:
        print(f"Warning: cannot write to {log_file}; falling back to ./socket_monitor.log", file=sys.stderr)
        log_file = "./socket_monitor.log"

    # Prometheus setup (optional)
    have_prom = False
    if args.prometheus_port:
        try:
            from prometheus_client import start_http_server, Counter, Histogram, Gauge
            have_prom = True
        except Exception as e:
            print(f"Prometheus disabled (prometheus_client not available): {e}", file=sys.stderr)

    # Histograms (low-cardinality labels)
    if have_prom:
        # shared labels for aggregated view
        common_labels = ["role"]  # "client" or "server" (best-effort), keep small
        k8s_labels = ["pod_uid", "container_id"]
        proc_labels = ["comm"]
        agg_labels = common_labels + k8s_labels + proc_labels

        # per-flow labels (dangerously high cardinality)
        flow_labels = agg_labels + (["src_ip","src_port","dst_ip","dst_port"] if args.per_flow else [])

        def make_hist(name, desc):
            return Histogram(
                name, desc, labelnames=flow_labels,
                buckets=[b/1000.0 for b in buckets_ms]  # convert ms buckets to seconds (Prom wants seconds)
            )

        def make_ctr(name, desc):
            return Counter(name, desc, labelnames=flow_labels)

        def make_gauge(name, desc):
            return Gauge(name, desc, labelnames=flow_labels)

        H_CONNECT = make_hist("socket_connect_latency_seconds", "TCP connect latency (SYN_SENT->ESTABLISHED)")
        H_REQRESP = make_hist("socket_reqresp_latency_seconds", "Request->Response latency (send->recv to user)")
        G_SRTT    = make_gauge("socket_srtt_seconds", "Smoothed RTT from tcp_sock")
        G_RTTVAR  = make_gauge("socket_rttvar_seconds", "RTT variance (mdev) from tcp_sock")
        C_RETRANS = make_ctr("socket_retransmissions_total", "Retransmits observed for this flow")
        C_EVENTS  = make_ctr("socket_events_total", "Events emitted by type and flow")

    from bcc import BPF  # lazy import for bcc
    b = BPF(text=BPF_PROGRAM)

    recent_events = deque(maxlen=8000)

    def role_guess(src_ip, dst_ip, state):
        # crude: if state is ESTABLISHED and src_port >= 1024, call it client; else server
        try:
            return "client" if state in (1, -1) else "unknown"
        except Exception:
            return "unknown"

    def labels_for(entry):
        base = {
            "role": role_guess(entry["src_ip"], entry["dst_ip"], entry.get("state_code", -1)),
            "pod_uid": entry.get("pod_uid") or "",
            "container_id": entry.get("container_id") or "",
            "comm": entry.get("comm") or "",
        }
        if args.per_flow:
            base.update({
                "src_ip": entry["src_ip"], "src_port": str(entry["src_port"]),
                "dst_ip": entry["dst_ip"], "dst_port": str(entry["dst_port"]),
            })
        return base

    def emit_prom(entry):
        if not have_prom:
            return
        lbl = labels_for(entry)
        # counters/gauges/histograms
        C_EVENTS.labels(**lbl).inc()
        if entry["latency"]["connect_ms"] is not None:
            H_CONNECT.labels(**lbl).observe(entry["latency"]["connect_ms"]/1000.0)
        if entry["latency"]["req_resp_ms"] is not None:
            H_REQRESP.labels(**lbl).observe(entry["latency"]["req_resp_ms"]/1000.0)
        if entry["latency"]["srtt_ms"] is not None:
            G_SRTT.labels(**lbl).set(entry["latency"]["srtt_ms"]/1000.0)
        if entry["latency"]["rttvar_ms"] is not None:
            G_RTTVAR.labels(**lbl).set(entry["latency"]["rttvar_ms"]/1000.0)
        if entry["tcp"]["retransmits"] is not None:
            # we don't know deltas per event; just add 0 (no-op) and rely on event counts for trend,
            # or convert to gauge; here we track increments when we see larger cumulative values.
            pass

    # start exporter
    if have_prom and args.prometheus_port:
        from prometheus_client import start_http_server
        start_http_server(args.prometheus_port)
        print(f"[prometheus] exporting on :{args.prometheus_port}")

    # aux
    def write_log(s: str):
        try:
            with open(log_file, "a") as f:
                f.write(s + "\n")
        except Exception as e:
            print(f"Log write failed: {e}", file=sys.stderr)

    # retransmit delta tracker (so we can increment the counter)
    last_retx = {}

    def handle_event(cpu, data, size):
        event = b["events"].event(data)
        timestamp = datetime.now().strftime("%b %d %Y %H:%M:%S.%f")[:-3]

        src_ip = format_ip(event.src_ip)
        dst_ip = format_ip(event.dst_ip)

        if args.pid and event.tgid != args.pid: return
        if args.src_ip and src_ip != args.src_ip: return
        if args.dst_ip and dst_ip != args.dst_ip: return
        if args.src_port and event.src_port != args.src_port: return
        if args.dst_port and event.dst_port != args.dst_port: return
        if args.active_only and event.state not in (1, -1): return

        # de-dup spam
        event_key = (
            src_ip, int(event.src_port), dst_ip, int(event.dst_port),
            int(event.tgid), int(event.state), event.event.decode(errors="ignore"),
            int(event.connect_latency_ns != 0), int(event.rr_latency_ns != 0),
            int(event.srtt_us), int(event.rttvar_us)
        )
        if event_key in recent_events:
            return
        recent_events.append(event_key)

        # k8s enrichment
        k8s = k8s_enrich_from_pid(int(event.tgid))
        pod_uid = k8s.get("pod_uid")
        container_id = k8s.get("container_id")

        state_code = int(event.state)
        state_str = TCP_STATES.get(state_code, "N/A") if state_code != -1 else "N/A"

        entry = {
            "timestamp": timestamp,
            "event": event.event.decode(errors="ignore"),
            "src_ip": src_ip,
            "dst_ip": dst_ip,
            "src_port": int(event.src_port),
            "dst_port": int(event.dst_port),
            "protocol": "TCP",
            "state": state_str,
            "state_code": state_code,
            "pid": int(event.tgid),
            "tid": int(event.pid),
            "ppid": int(event.ppid),
            "uid": int(event.uid),
            "cgroup_id": int(event.cgroup_id),
            "comm": event.comm.decode(errors="ignore"),
            "pod_uid": pod_uid,
            "container_id": container_id,
            "latency": {
                "connect_ms": ns_to_ms(int(event.connect_latency_ns)) if event.connect_latency_ns else None,
                "req_resp_ms": ns_to_ms(int(event.rr_latency_ns)) if event.rr_latency_ns else None,
                "srtt_ms": round(float(event.srtt_us) / 1000.0, 6) if event.srtt_us else None,
                "rttvar_ms": round(float(event.rttvar_us) / 1000.0, 6) if event.rttvar_us else None,
            },
            "tcp": {
                "retransmits": int(event.retransmits) if event.retransmits else 0,
            },
        }

        # Increment retrans counter by delta (per flow)
        if have_prom:
            flow_delta_key = (entry["src_ip"], entry["src_port"], entry["dst_ip"], entry["dst_port"])
            prev = last_retx.get(flow_delta_key, 0)
            cur = entry["tcp"]["retransmits"]
            if cur > prev:
                # increment counter by delta
                from prometheus_client import Counter
                # build labels and inc
                lbl = labels_for(entry)
                # define/use a separate bare counter for deltas to avoid double registration
                # Reuse C_RETRANS with .inc(delta) since it's already Counter; safe as long as labels are identical.
                C_RETRANS.labels(**lbl).inc(cur - prev)
                last_retx[flow_delta_key] = cur

        # output
        if args.json:
            print(json.dumps(entry, separators=(",", ":")))
        else:
            print(entry)
        if log_file:
            write_log(json.dumps(entry))

        # prometheus hist/gauges
        emit_prom(entry)

    b["events"].open_perf_buffer(handle_event)

    print("Monitoring sockets + latency. Ctrl-C to stop.")
    if log_file:
        print(f"Logging to {log_file}")

    try:
        while True:
            b.perf_buffer_poll()
    except KeyboardInterrupt:
        print("\nStopping monitoring... Bye!")

if __name__ == "__main__":
    main()
