# bpftrace one-liners that work on the kldload kernel

Copy any line, paste into a root shell. Each runs until Ctrl-C.

bpftrace ships in the kldload base packages; tracepoints + kprobes are
enabled out of the box. Most BCC-equivalent observations can be done
in one bpftrace command.

## Process / scheduler

```bash
# Every process exec, with full args
sudo bpftrace -e 'tracepoint:sched:sched_process_exec { printf("%-6d %-16s %s\n", pid, comm, str(args->filename)); }'

# Process runtime by command (10s sample)
sudo bpftrace -e 'tracepoint:sched:sched_process_exit { @runtime_ms[comm] = sum((nsecs - @start[tid]) / 1000000); delete(@start[tid]); }
                  tracepoint:sched:sched_process_exec { @start[tid] = nsecs; }' -c 'sleep 10'

# Off-CPU profile — what's stalling and why
sudo bpftrace -e 'tracepoint:sched:sched_switch /args->prev_state == 0/ {
                    @[kstack, comm] = count();
                  }'
```

## Filesystem

```bash
# Every file open, named
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_openat {
                    printf("%-6d %-16s %s\n", pid, comm, str(args->filename));
                  }'

# ZFS read/write latency histogram (5s window)
sudo bpftrace -e 'kprobe:zfs_read,kprobe:zfs_write { @start[tid] = nsecs; }
                  kretprobe:zfs_read  /@start[tid]/ { @us["zfs_read"]  = hist((nsecs - @start[tid])/1000); delete(@start[tid]); }
                  kretprobe:zfs_write /@start[tid]/ { @us["zfs_write"] = hist((nsecs - @start[tid])/1000); delete(@start[tid]); }
                  interval:s:5 { print(@us); clear(@us); }'

# Slow VFS reads (> 10ms) — what file, who, how long
sudo bpftrace -e 'kprobe:vfs_read  { @start[tid] = nsecs; }
                  kretprobe:vfs_read /@start[tid]/ {
                    $us = (nsecs - @start[tid]) / 1000;
                    if ($us > 10000) {
                      printf("%dus %-16s\n", $us, comm);
                    }
                    delete(@start[tid]);
                  }'
```

## Network

```bash
# Every TCP connect, by command + dest
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_connect {
                    printf("%-16s connect()\n", comm);
                  }'

# TCP retransmits with kernel state
sudo bpftrace -e 'kprobe:tcp_retransmit_skb {
                    printf("%-16s tcp_retransmit\n", comm);
                  }'

# Bytes per process, 1-second updates
sudo bpftrace -e 'kprobe:tcp_sendmsg { @bytes[comm] = sum(arg2); }
                  interval:s:1 { print(@bytes); clear(@bytes); }'
```

## Memory

```bash
# Page faults by process
sudo bpftrace -e 'software:page-faults:1 { @[comm] = count(); }'

# kmalloc allocations (size histogram)
sudo bpftrace -e 'kprobe:__kmalloc { @[bucket] = hist(arg1); }'
```

## kldload-specific

```bash
# Watch every BPF program load (Cilium / Tetragon dynamic JITs)
sudo bpftrace -e 'tracepoint:bpf:bpf_prog_load_event { time("%H:%M:%S "); printf("comm=%-16s prog_type=%d\n", comm, args->type); }'

# OOM kills — what got killed and by whom
sudo bpftrace -e 'kprobe:oom_kill_process { printf("OOM kill: %s (uid %d)\n", str(((struct task_struct *)arg0)->comm), uid); }'
```

Many more at: https://github.com/iovisor/bpftrace/tree/master/tools
