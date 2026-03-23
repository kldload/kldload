// SPDX-License-Identifier: GPL-2.0 OR BSD-2-Clause
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_tracing.h>

#include "common.h"

char LICENSE[] SEC("license") = "Dual BSD/GPL";

/* ---------------------------
 * Config map (array[1])
 * --------------------------- */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct config);
} cfg_map SEC(".maps");

static __always_inline const struct config *get_cfg(void)
{
    __u32 k = 0;
    return bpf_map_lookup_elem(&cfg_map, &k);
}

static __always_inline bool pid_allowed(__u32 pid)
{
    const struct config *cfg = get_cfg();
    if (!cfg) return true;           // fail-open
    if (cfg->pid == 0) return true;  // all
    return cfg->pid == pid;
}

static __always_inline bool emit_events_enabled(void)
{
    const struct config *cfg = get_cfg();
    if (!cfg) return false;
    return (cfg->flags & CFG_F_EMIT_EVENTS) != 0;
}

/* ---------------------------
 * Ring buffer for events
 * --------------------------- */
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 24); // 16MB ringbuf (tune)
} events_rb SEC(".maps");

/* ---------------------------
 * CPU on-CPU time per pid
 * - start_ts: pid -> ts
 * - cpu_ns:   percpu hash pid -> accumulated ns
 * --------------------------- */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 131072);
    __type(key, __u32);
    __type(value, __u64);
} start_ts SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_HASH);
    __uint(max_entries, 131072);
    __type(key, __u32);
    __type(value, __u64);
} cpu_ns SEC(".maps");

/* ---------------------------
 * Net bytes per pid (percpu)
 * --------------------------- */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_HASH);
    __uint(max_entries, 131072);
    __type(key, __u32);
    __type(value, __u64);
} tx_bytes SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_HASH);
    __uint(max_entries, 131072);
    __type(key, __u32);
    __type(value, __u64);
} rx_bytes SEC(".maps");

/* ---------------------------
 * TCP retrans count per pid (percpu)
 * --------------------------- */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_HASH);
    __uint(max_entries, 131072);
    __type(key, __u32);
    __type(value, __u64);
} retrans_cnt SEC(".maps");

/* ---------------------------
 * Syscall latency (enter/exit)
 * - start_sc: LRU hash (pid,id)-> ts
 * - sc_total_us: percpu array[NR_SYSCALLS?] is not portable; use hash
 * - sc_count:    hash
 * - hist:        percpu array[HIST_BUCKETS]
 * --------------------------- */
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 262144);
    __type(key, struct sc_key);
    __type(value, __u64);
} start_sc SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_HASH);
    __uint(max_entries, 131072);
    __type(key, __u32);     // syscall id
    __type(value, __u64);   // total us
} sc_total_us SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_HASH);
    __uint(max_entries, 131072);
    __type(key, __u32);     // syscall id
    __type(value, __u64);   // count
} sc_count SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, HIST_BUCKETS);
    __type(key, __u32);
    __type(value, __u64);
} sc_lat_hist SEC(".maps");

/* ---------------------------
 * Helpers
 * --------------------------- */
static __always_inline void percpu_hash_add_u64(void *map, const __u32 *key, __u64 delta)
{
    __u64 *p = bpf_map_lookup_elem(map, key);
    if (p) {
        *p += delta;
    } else {
        __u64 init = delta;
        bpf_map_update_elem(map, key, &init, BPF_ANY);
    }
}

static __always_inline void percpu_array_inc(void *map, __u32 idx)
{
    __u64 *p = bpf_map_lookup_elem(map, &idx);
    if (p) (*p)++;
}

/* ---------------------------
 * sched:sched_switch -> CPU time
 * --------------------------- */
SEC("tracepoint/sched/sched_switch")
int tp_sched_switch(struct trace_event_raw_sched_switch *ctx)
{
    __u64 now = bpf_ktime_get_ns();

    __u32 prev_pid = ctx->prev_pid;
    __u32 next_pid = ctx->next_pid;

    // update prev
    __u64 *tsp = bpf_map_lookup_elem(&start_ts, &prev_pid);
    if (tsp) {
        __u64 delta = now - *tsp;
        if (pid_allowed(prev_pid)) {
            percpu_hash_add_u64(&cpu_ns, &prev_pid, delta);
        }
        bpf_map_delete_elem(&start_ts, &prev_pid);
    }

    // set next
    bpf_map_update_elem(&start_ts, &next_pid, &now, BPF_ANY);

    return 0;
}

/* ---------------------------
 * kprobe tcp_sendmsg -> TX
 * --------------------------- */
SEC("kprobe/tcp_sendmsg")
int BPF_KPROBE(kp_tcp_sendmsg, struct sock *sk, struct msghdr *msg, size_t size)
{
    __u32 pid = (__u32)(bpf_get_current_pid_tgid() >> 32);
    if (!pid_allowed(pid)) return 0;

    __u64 delta = (__u64)size;
    percpu_hash_add_u64(&tx_bytes, &pid, delta);
    return 0;
}

/* ---------------------------
 * kprobe tcp_cleanup_rbuf -> RX (copied bytes)
 * --------------------------- */
SEC("kprobe/tcp_cleanup_rbuf")
int BPF_KPROBE(kp_tcp_cleanup_rbuf, struct sock *sk, int copied)
{
    if (copied <= 0) return 0;

    __u32 pid = (__u32)(bpf_get_current_pid_tgid() >> 32);
    if (!pid_allowed(pid)) return 0;

    __u64 delta = (__u64)copied;
    percpu_hash_add_u64(&rx_bytes, &pid, delta);
    return 0;
}

/* ---------------------------
 * tcp:tcp_retransmit_skb -> retrans count + optional event
 * --------------------------- */
SEC("tracepoint/tcp/tcp_retransmit_skb")
int tp_tcp_retransmit_skb(struct trace_event_raw_tcp_event_sk_skb *ctx)
{
    __u32 pid = (__u32)(bpf_get_current_pid_tgid() >> 32);
    if (!pid_allowed(pid)) return 0;

    __u64 one = 1;
    percpu_hash_add_u64(&retrans_cnt, &pid, one);

    if (emit_events_enabled()) {
        struct event_retrans *e = bpf_ringbuf_reserve(&events_rb, sizeof(*e), 0);
        if (!e) return 0;

        e->ts_ns = bpf_ktime_get_ns();
        e->pid = pid;
        bpf_get_current_comm(&e->comm, sizeof(e->comm));

        // ctx fields vary; for this tracepoint in modern kernels these exist:
        // saddr/daddr/sport/dport in network order; we store raw v4.
        e->saddr_v4 = ctx->saddr;
        e->daddr_v4 = ctx->daddr;
        e->sport = (__u16)bpf_ntohs(ctx->sport);
        e->dport = (__u16)bpf_ntohs(ctx->dport);

        bpf_ringbuf_submit(e, 0);
    }

    return 0;
}

/* ---------------------------
 * raw_syscalls enter/exit -> latency hist + totals
 * --------------------------- */
SEC("tracepoint/raw_syscalls/sys_enter")
int tp_sys_enter(struct trace_event_raw_sys_enter *ctx)
{
    __u32 pid = (__u32)(bpf_get_current_pid_tgid() >> 32);
    if (!pid_allowed(pid)) return 0;

    struct sc_key k = { .pid = pid, .id = (__u32)ctx->id };
    __u64 ts = bpf_ktime_get_ns();
    bpf_map_update_elem(&start_sc, &k, &ts, BPF_ANY);
    return 0;
}

SEC("tracepoint/raw_syscalls/sys_exit")
int tp_sys_exit(struct trace_event_raw_sys_exit *ctx)
{
    __u32 pid = (__u32)(bpf_get_current_pid_tgid() >> 32);
    if (!pid_allowed(pid)) return 0;

    __u32 id = (__u32)ctx->id;
    struct sc_key k = { .pid = pid, .id = id };

    __u64 *tsp = bpf_map_lookup_elem(&start_sc, &k);
    if (!tsp) return 0;

    __u64 delta_ns = bpf_ktime_get_ns() - *tsp;
    bpf_map_delete_elem(&start_sc, &k);

    __u64 us = delta_ns / 1000;

    // histogram bucket (log2(us+1)) capped to HIST_BUCKETS-1
    __u32 b = (__u32)bpf_log2l(us + 1);
    if (b >= HIST_BUCKETS) b = HIST_BUCKETS - 1;
    percpu_array_inc(&sc_lat_hist, b);

    // totals per syscall id
    percpu_hash_add_u64(&sc_total_us, &id, us);
    __u64 one = 1;
    percpu_hash_add_u64(&sc_count, &id, one);

    return 0;
}
