#ifndef EBPF_TOOL_COMMON_H
#define EBPF_TOOL_COMMON_H

#include <linux/types.h>

#define HIST_BUCKETS 64

enum {
    CFG_F_EMIT_EVENTS = 1u << 0,   // emit ringbuf events (retrans)
};

struct config {
    __u32 pid;     // 0 = all (not recommended on busy systems)
    __u32 flags;
};

struct event_retrans {
    __u64 ts_ns;
    __u32 pid;
    __u32 saddr_v4;
    __u32 daddr_v4;
    __u16 sport;
    __u16 dport;
    char  comm[16];
};

struct sc_key {
    __u32 pid;
    __u32 id;
};

#endif
