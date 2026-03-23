// SPDX-License-Identifier: MIT
#define _GNU_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "common.h"
#include "ebpf_tool.skel.h"

static volatile sig_atomic_t g_stop = 0;

static void on_sigint(int signo)
{
    (void)signo;
    g_stop = 1;
}

static void die(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(1);
}

static uint64_t nsec_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void ipv4_to_str(uint32_t a, char out[16])
{
    unsigned char b1 = (a) & 0xff;
    unsigned char b2 = (a >> 8) & 0xff;
    unsigned char b3 = (a >> 16) & 0xff;
    unsigned char b4 = (a >> 24) & 0xff;
    snprintf(out, 16, "%u.%u.%u.%u", b1, b2, b3, b4);
}

/* -------- ringbuf event handler -------- */
static int handle_rb_event(void *ctx, void *data, size_t data_sz)
{
    (void)ctx;
    if (data_sz < sizeof(struct event_retrans))
        return 0;

    const struct event_retrans *e = (const struct event_retrans *)data;
    char s[16], d[16];
    ipv4_to_str(e->saddr_v4, s);
    ipv4_to_str(e->daddr_v4, d);

    // JSONL-friendly line
    printf("{\"kind\":\"tcpretrans\",\"ts_ns\":%" PRIu64 ",\"pid\":%u,\"comm\":\"%s\",\"saddr\":\"%s\",\"sport\":%u,\"daddr\":\"%s\",\"dport\":%u}\n",
           e->ts_ns, e->pid, e->comm, s, e->sport, d, e->dport);
    return 0;
}

/* -------- percpu helpers -------- */
static int lookup_percpu_u64(int map_fd, const void *key, uint64_t *out_sum)
{
    int ncpu = libbpf_num_possible_cpus();
    if (ncpu <= 0) return -EINVAL;

    uint64_t *vals = calloc((size_t)ncpu, sizeof(uint64_t));
    if (!vals) return -ENOMEM;

    int err = bpf_map_lookup_elem(map_fd, key, vals);
    if (err) {
        free(vals);
        return err;
    }

    uint64_t sum = 0;
    for (int i = 0; i < ncpu; i++)
        sum += vals[i];

    free(vals);
    *out_sum = sum;
    return 0;
}

struct pid_stat {
    uint32_t pid;
    uint64_t v;
};

static int cmp_desc(const void *a, const void *b)
{
    const struct pid_stat *x = a, *y = b;
    if (x->v < y->v) return 1;
    if (x->v > y->v) return -1;
    return 0;
}

/* Iterate a (percpu) hash map of pid->u64 and collect top N deltas */
static size_t collect_top_pid_deltas(int map_fd, struct pid_stat *out, size_t out_cap,
                                     struct pid_stat *prev, size_t prev_cap,
                                     uint64_t *sum_total_delta)
{
    uint32_t key = 0, next_key;
    size_t n = 0;
    *sum_total_delta = 0;

    // for each key in map: read sum, compute delta vs prev snapshot
    int err = bpf_map_get_next_key(map_fd, NULL, &next_key);
    while (!err) {
        key = next_key;

        uint64_t cur = 0;
        if (lookup_percpu_u64(map_fd, &key, &cur) == 0) {
            uint64_t old = 0;
            // find in prev
            for (size_t i = 0; i < prev_cap; i++) {
                if (prev[i].pid == key) {
                    old = prev[i].v;
                    prev[i].v = cur;
                    break;
                }
                if (prev[i].pid == 0) { // empty slot
                    prev[i].pid = key;
                    prev[i].v = cur;
                    break;
                }
            }

            uint64_t delta = (cur >= old) ? (cur - old) : 0;
            if (delta) {
                *sum_total_delta += delta;
                if (n < out_cap) {
                    out[n].pid = key;
                    out[n].v = delta;
                    n++;
                }
            }
        }

        err = bpf_map_get_next_key(map_fd, &key, &next_key);
    }

    qsort(out, n, sizeof(out[0]), cmp_desc);
    return n;
}

/* Resolve comm for PID (best-effort) */
static void read_comm(uint32_t pid, char *buf, size_t bufsz)
{
    snprintf(buf, bufsz, "?");
    char path[64];
    snprintf(path, sizeof(path), "/proc/%u/comm", pid);
    FILE *f = fopen(path, "r");
    if (!f) return;
    if (fgets(buf, (int)bufsz, f)) {
        size_t len = strlen(buf);
        if (len && buf[len-1] == '\n') buf[len-1] = 0;
    }
    fclose(f);
}

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [--pid N] [--interval S] [--seconds N] [--events]\n"
        "\n"
        "Modes are currently unified (prints CPU+NET+RETRANS+SYSCALL hist summaries).\n"
        "  --pid N       Filter everything in-kernel to a PID (recommended)\n"
        "  --interval S  Summary print interval (default 1.0)\n"
        "  --seconds N   Run for N seconds (0=until Ctrl+C)\n"
        "  --events      Enable ringbuf retrans events (JSONL)\n",
        prog);
}

int main(int argc, char **argv)
{
    uint32_t pid_filter = 0;
    double interval_s = 1.0;
    int seconds = 10;
    bool enable_events = false;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--pid") && i + 1 < argc) {
            pid_filter = (uint32_t)strtoul(argv[++i], NULL, 10);
        } else if (!strcmp(argv[i], "--interval") && i + 1 < argc) {
            interval_s = atof(argv[++i]);
            if (interval_s <= 0) interval_s = 1.0;
        } else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) {
            seconds = atoi(argv[++i]);
            if (seconds < 0) seconds = 0;
        } else if (!strcmp(argv[i], "--events")) {
            enable_events = true;
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage(argv[0]);
            return 0;
        } else {
            usage(argv[0]);
            return 1;
        }
    }

    libbpf_set_strict_mode(LIBBPF_STRICT_ALL);
    libbpf_set_print(libbpf_print_fn_t NULL); // keep quiet by default

    signal(SIGINT, on_sigint);
    signal(SIGTERM, on_sigint);

    struct ebpf_tool_bpf *skel = NULL;
    struct ring_buffer *rb = NULL;

    skel = ebpf_tool_bpf__open();
    if (!skel) die("Failed to open BPF skeleton");

    // Set config map
    struct config cfg = {
        .pid = pid_filter,
        .flags = enable_events ? CFG_F_EMIT_EVENTS : 0,
    };
    int cfg_fd = bpf_map__fd(skel->maps.cfg_map);
    uint32_t k0 = 0;
    if (bpf_map_update_elem(cfg_fd, &k0, &cfg, BPF_ANY))
        die("Failed to set config map: %s", strerror(errno));

    if (ebpf_tool_bpf__load(skel))
        die("Failed to load BPF skeleton");

    if (ebpf_tool_bpf__attach(skel))
        die("Failed to attach BPF programs");

    if (enable_events) {
        int rb_fd = bpf_map__fd(skel->maps.events_rb);
        rb = ring_buffer__new(rb_fd, handle_rb_event, NULL, NULL);
        if (!rb) die("Failed to create ringbuf: %s", strerror(errno));
    }

    int cpu_fd = bpf_map__fd(skel->maps.cpu_ns);
    int tx_fd  = bpf_map__fd(skel->maps.tx_bytes);
    int rx_fd  = bpf_map__fd(skel->maps.rx_bytes);
    int rt_fd  = bpf_map__fd(skel->maps.retrans_cnt);

    int sc_tot_fd = bpf_map__fd(skel->maps.sc_total_us);
    int sc_cnt_fd = bpf_map__fd(skel->maps.sc_count);
    int hist_fd   = bpf_map__fd(skel->maps.sc_lat_hist);

    // Previous snapshots (for deltas)
    const size_t PREV_CAP = 65536;
    struct pid_stat *prev_cpu = calloc(PREV_CAP, sizeof(*prev_cpu));
    struct pid_stat *prev_tx  = calloc(PREV_CAP, sizeof(*prev_tx));
    struct pid_stat *prev_rx  = calloc(PREV_CAP, sizeof(*prev_rx));
    struct pid_stat *prev_rt  = calloc(PREV_CAP, sizeof(*prev_rt));
    if (!prev_cpu || !prev_tx || !prev_rx || !prev_rt) die("OOM");

    const size_t TOPN = 15;
    struct pid_stat top_cpu[TOPN], top_tx[TOPN], top_rx[TOPN], top_rt[TOPN];

    uint64_t start_ns = nsec_now();
    uint64_t next_print_ns = start_ns;

    while (!g_stop) {
        uint64_t now_ns = nsec_now();

        // time bound
        if (seconds > 0) {
            uint64_t end_ns = start_ns + (uint64_t)seconds * 1000000000ull;
            if (now_ns >= end_ns) break;
        }

        // ringbuf poll
        if (rb) {
            // small timeout in ms; keep loop responsive
            ring_buffer__poll(rb, 50);
        } else {
            // sleep a little to avoid busy looping
            usleep(50 * 1000);
        }

        // summary print interval
        if (now_ns >= next_print_ns) {
            next_print_ns = now_ns + (uint64_t)(interval_s * 1e9);

            uint64_t cpu_sum = 0, tx_sum = 0, rx_sum = 0, rt_sum = 0;
            size_t ncpu = collect_top_pid_deltas(cpu_fd, top_cpu, TOPN, prev_cpu, PREV_CAP, &cpu_sum);
            size_t ntx  = collect_top_pid_deltas(tx_fd,  top_tx,  TOPN, prev_tx,  PREV_CAP, &tx_sum);
            size_t nrx  = collect_top_pid_deltas(rx_fd,  top_rx,  TOPN, prev_rx,  PREV_CAP, &rx_sum);
            size_t nrt  = collect_top_pid_deltas(rt_fd,  top_rt,  TOPN, prev_rt,  PREV_CAP, &rt_sum);

            printf("=== interval=%.2fs pid_filter=%u ===\n", interval_s, pid_filter);

            // CPU top (percent of all CPUs is hard without ncpu*time; show ms)
            printf("[CPU on-CPU] top PIDs by delta_ns:\n");
            for (size_t i = 0; i < ncpu; i++) {
                char comm[64]; read_comm(top_cpu[i].pid, comm, sizeof(comm));
                printf("  pid=%u comm=%s delta_ms=%.3f\n",
                       top_cpu[i].pid, comm, (double)top_cpu[i].v / 1e6);
            }

            printf("[NET] top PIDs by TX bytes (delta):\n");
            for (size_t i = 0; i < ntx; i++) {
                char comm[64]; read_comm(top_tx[i].pid, comm, sizeof(comm));
                double bps = (double)top_tx[i].v / interval_s;
                printf("  pid=%u comm=%s tx_bytes=%" PRIu64 " (%.0f B/s)\n",
                       top_tx[i].pid, comm, top_tx[i].v, bps);
            }

            printf("[NET] top PIDs by RX bytes (delta):\n");
            for (size_t i = 0; i < nrx; i++) {
                char comm[64]; read_comm(top_rx[i].pid, comm, sizeof(comm));
                double bps = (double)top_rx[i].v / interval_s;
                printf("  pid=%u comm=%s rx_bytes=%" PRIu64 " (%.0f B/s)\n",
                       top_rx[i].pid, comm, top_rx[i].v, bps);
            }

            printf("[TCP] retrans top PIDs (delta):\n");
            for (size_t i = 0; i < nrt; i++) {
                char comm[64]; read_comm(top_rt[i].pid, comm, sizeof(comm));
                printf("  pid=%u comm=%s retrans=%" PRIu64 "\n",
                       top_rt[i].pid, comm, top_rt[i].v);
            }

            // syscall histogram
            printf("[SYSCALL] latency histogram (log2(us+1) buckets):\n");
            int ncpu_possible = libbpf_num_possible_cpus();
            uint64_t *vals = calloc((size_t)ncpu_possible, sizeof(uint64_t));
            if (vals) {
                for (uint32_t b = 0; b < HIST_BUCKETS; b++) {
                    if (bpf_map_lookup_elem(hist_fd, &b, vals) == 0) {
                        uint64_t sum = 0;
                        for (int c = 0; c < ncpu_possible; c++) sum += vals[c];
                        if (sum) {
                            printf("  b=%u count=%" PRIu64 "\n", b, sum);
                        }
                    }
                }
                free(vals);
            }

            // syscall totals (top 10 by total_us)
            // iterate keys in sc_total_us (percpu hash) and sum
            struct { uint32_t id; uint64_t total_us; uint64_t count; } top_sc[10];
            memset(top_sc, 0, sizeof(top_sc));
            uint32_t sc_key, sc_next;
            int err = bpf_map_get_next_key(sc_tot_fd, NULL, &sc_next);
            while (!err) {
                sc_key = sc_next;

                uint64_t tot = 0, cnt = 0;
                if (lookup_percpu_u64(sc_tot_fd, &sc_key, &tot) == 0) {
                    (void)lookup_percpu_u64(sc_cnt_fd, &sc_key, &cnt);
                    // insert into top_sc
                    for (int i = 0; i < 10; i++) {
                        if (tot > top_sc[i].total_us) {
                            // shift down
                            for (int j = 9; j > i; j--) top_sc[j] = top_sc[j-1];
                            top_sc[i].id = sc_key;
                            top_sc[i].total_us = tot;
                            top_sc[i].count = cnt;
                            break;
                        }
                    }
                }

                err = bpf_map_get_next_key(sc_tot_fd, &sc_key, &sc_next);
            }

            printf("[SYSCALL] top syscall IDs by total_us:\n");
            for (int i = 0; i < 10; i++) {
                if (top_sc[i].id == 0 && top_sc[i].total_us == 0) continue;
                uint64_t avg = top_sc[i].count ? (top_sc[i].total_us / top_sc[i].count) : 0;
                printf("  id=%u total_us=%" PRIu64 " count=%" PRIu64 " avg_us=%" PRIu64 "\n",
                       top_sc[i].id, top_sc[i].total_us, top_sc[i].count, avg);
            }

            fflush(stdout);
        }
    }

    ring_buffer__free(rb);
    ebpf_tool_bpf__destroy(skel);

    free(prev_cpu);
    free(prev_tx);
    free(prev_rx);
    free(prev_rt);

    return 0;
}
