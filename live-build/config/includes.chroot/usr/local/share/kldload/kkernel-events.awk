# kkernel-events.awk — format kkernel-events.bt output for tmux display
#
# Reads sentinel-marked lines from the bpftrace program and emits a
# color-coded, indented, sectioned view -- same role as ktcp-format.awk
# plays for the kernel-tcp pane.
#
# Input shape (from kkernel-events.bt):
#
#   KK-START
#   KK-TS 22:34:12
#   KK-SECTION exec
#   @exec[bash]: 22
#   @exec[curl]: 11
#   ...
#   KK-SECTION open
#   ...
#   KK-END
#
# Output shape (rendered to the tmux window):
#
#   ─── kldload kernel-events — userland from the kernel's point of view ───
#   22:34:12   2s window
#
#   [exec]   new processes
#       45  systemd-coredum
#       22  bash
#       11  curl
#   [open]   file opens (AT_FDCWD)
#      892  systemd-journal
#      450  prometheus
#       ...
#   [tcp]    outbound TCP connects
#        9  curl
#        3  ssh
#   [err]    failed syscalls (ENOENT/EAGAIN/...)
#      154  prometheus
#       33  cilium-agent
#
# ANSI colours: cyan section headers, dim grey for source-cmd line,
# normal for counts, dim for the trailing per-section descriptor.

BEGIN {
    # Buffered output mode -- accumulate one full snapshot, then dump
    # via tput-cuup + clear-to-end so the screen updates as a single
    # frame rather than scrolling per-line (avoids the flicker the
    # raw bpftrace output has on a slow terminal).
    CYAN    = "\033[1;36m"
    DIM     = "\033[2;37m"
    YELLOW  = "\033[1;33m"
    GREEN   = "\033[1;32m"
    RED     = "\033[1;31m"
    GREY    = "\033[2;90m"
    RESET   = "\033[0m"
    CLEAR   = "\033[H\033[2J"   # cursor home + clear screen

    SEC_DESC["exec"] = "new processes"
    SEC_DESC["open"] = "file opens (AT_FDCWD)"
    SEC_DESC["tcp"]  = "outbound TCP connects"
    SEC_DESC["err"]  = "failed syscalls (ENOENT/EAGAIN/...)"

    SEC_COLOR["exec"] = GREEN
    SEC_COLOR["open"] = CYAN
    SEC_COLOR["tcp"]  = YELLOW
    SEC_COLOR["err"]  = RED

    section = ""
    ts = ""
    buffered = ""
    first_frame = 1
}

# Section change -- record what bucket we're in
/^KK-SECTION / {
    section = $2
    desc    = SEC_DESC[section]
    color   = SEC_COLOR[section]
    buffered = buffered sprintf("%s[%s]%s  %s%s%s\n",
                                color, section, RESET,
                                DIM, desc, RESET)
    next
}

# Timestamp line -- new snapshot starting
/^KK-TS / {
    ts = $2
    next
}

# Start of a full frame -- emit the previous one (if any), reset buffer
/^KK-START/ {
    next
}

# End of a full frame -- flush the accumulated snapshot to the screen
/^KK-END/ {
    out = CLEAR
    out = out sprintf("%s─── kldload kernel-events — userland from the kernel's point of view ───%s\n",
                       CYAN, RESET)
    out = out sprintf("%s%s%s  %s2-sec rolling window  -  top-8 per axis  -  bpftrace + awk%s\n\n",
                       GREEN, ts, RESET, DIM, RESET)
    out = out buffered
    out = out sprintf("\n%spress F12 again to close this window%s\n", GREY, RESET)
    printf("%s", out)
    fflush()
    buffered = ""
    next
}

# Per-key counts inside a section -- e.g. `@exec[systemd-journal]: 892`
# bpftrace's print(@map, N) emits them sorted descending by value.
/^@[a-z]+\[/ {
    # Extract the comm name (between [ and ]) and the count
    # Format: @exec[bash]: 22
    line = $0
    n = split(line, a, /\[|\]:/)
    if (n >= 3) {
        comm  = a[2]
        count = a[3] + 0
        buffered = buffered sprintf("    %6d  %s\n", count, comm)
    }
    next
}

# Anything else from bpftrace (Attaching N probes..., warnings, blank
# lines between sections) -- silently swallow. We don't want it in the
# polished view.
