# Reformat `ss -tnHpi` two-line-per-socket output into a rich,
# colour-coded, sorted dashboard. Driven by `_ktcp-expanded` (F9).
#
# State-based parsing (NOT NR-parity) because IPv6 sockets / some TCP
# states emit irregular line counts and parity gets misaligned. A
# "header" line starts with numbers (Recv-Q Send-Q ...) and carries a
# users:(...) field; a "TCP_INFO" line starts with whitespace and
# carries rtt:/cubic/cwnd:/bytes_sent:. Each tells us where we are.
#
# Atomic state-file write at END: write to .tmp, rename. If awk dies
# mid-emit, the state file isn't corrupted.

BEGIN {
    G="\033[32m"; Y="\033[33m"; R="\033[31m"
    DIM="\033[2m"; B="\033[1m"; CY="\033[36m"; MA="\033[35m"; N="\033[0m"
    STATE_FILE = "/tmp/kldload-tcp-state"
    STATE_TMP  = STATE_FILE ".tmp"
    if ((getline prev_line < STATE_FILE) > 0) {
        if (split(prev_line, ts_kv, "=") == 2 && ts_kv[1] == "TS") {
            prev_ts = ts_kv[2] + 0
        }
        while ((getline line < STATE_FILE) > 0) {
            n = split(line, sf, "\t")
            if (n == 3) prev[sf[1]] = sf[2] " " sf[3]
        }
        close(STATE_FILE)
    }
    dt_s = (prev_ts > 0) ? (systime() - prev_ts) : 0
    if (dt_s < 1) dt_s = 1
    n_rows = 0
    have_header = 0
}

# Header line detector: starts with a digit (Recv-Q), and has users:(...) inside
/^[0-9]/ && /users:\(/ {
    # If a prior header had no TCP_INFO follow-up, flush it as empty.
    src  = $3; dst  = $4
    proc = "?"; pid_save = "?"; comm = "?"
    for (i = 5; i <= NF; i++) {
        if ($i ~ /^users:/) {
            split($i, ua, "\"")
            comm = ua[2]
            if (match($i, /pid=[0-9]+/)) {
                pid_save = substr($i, RSTART+4, RLENGTH-4)
            }
            proc = comm "(" pid_save ")"
            break
        }
    }
    have_header = 1
    # Pre-fill defaults in case we never see a TCP_INFO follow-up.
    rtt = "-"; retrans = "-"; cwnd = "-"; cc_algo = "-"
    bytes_out_n = 0; bytes_in_n = 0
    rtt_num = 0; retr_num = 0; cwnd_num = 0
    next
}

# TCP_INFO line detector: leading whitespace, contains rtt: or a known congestion-algo word
have_header && /^[ \t]/ && /(rtt:|cubic|bbr|reno|dctcp|hybla)/ {
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^(cubic|bbr|bbr2|reno|cdg|dctcp|highspeed|htcp|hybla|illinois|lp|nv|vegas|veno|westwood|yeah)$/) {
            cc_algo = $i
        }
        if ($i ~ /^rtt:/)            { split($i, a, "[:/]"); rtt = sprintf("%.1f", a[2]+0); rtt_num = a[2]+0 }
        if ($i ~ /^retrans:/)        { split($i, a, "[:/]"); retrans = a[2] "/" a[3]; retr_num = a[3]+0 }
        if ($i ~ /^cwnd:/)           { split($i, a, ":");    cwnd = a[2]; cwnd_num = a[2]+0 }
        if ($i ~ /^bytes_sent:/)     { split($i, a, ":");    bytes_out_n = a[2]+0 }
        if ($i ~ /^bytes_received:/) { split($i, a, ":");    bytes_in_n  = a[2]+0 }
    }
    emit_row()
    have_header = 0
    next
}

# If we hit ANOTHER header before a TCP_INFO line, emit the previous
# header anyway (with zero metrics) so we don't lose the row.
have_header && /^[0-9]/ && /users:\(/ { emit_row(); }   # (handled by the rule above with have_header reset)

function emit_row() {
    if (length(src)  > 22) src  = substr(src,  1, 19) "..."
    if (length(dst)  > 22) dst  = substr(dst,  1, 19) "..."
    if (length(proc) > 24) proc = substr(proc, 1, 21) "..."
    key = src "->" dst
    rate_out = 0; rate_in = 0
    if ((key in prev) && dt_s > 0) {
        split(prev[key], pp, " ")
        rate_out = (bytes_out_n - pp[1]) / dt_s
        rate_in  = (bytes_in_n  - pp[2]) / dt_s
        if (rate_out < 0) rate_out = 0
        if (rate_in  < 0) rate_in  = 0
    }
    n_rows++
    rows_proc[n_rows]    = proc
    rows_comm[n_rows]    = comm
    rows_src[n_rows]     = src
    rows_dst[n_rows]     = dst
    rows_rtt[n_rows]     = rtt
    rows_rtt_n[n_rows]   = rtt_num
    rows_retr[n_rows]    = retrans
    rows_retr_n[n_rows]  = retr_num
    rows_cwnd[n_rows]    = cwnd
    rows_cwnd_n[n_rows]  = cwnd_num
    rows_cc[n_rows]      = cc_algo
    rows_bout[n_rows]    = bytes_out_n
    rows_bin[n_rows]     = bytes_in_n
    rows_rate_tot[n_rows]= rate_out + rate_in
    rows_key[n_rows]     = key
    total_bytes_out += bytes_out_n
    total_bytes_in  += bytes_in_n
    total_rtt       += rtt_num
    total_retr      += retr_num
    total_rate      += rate_out + rate_in
    if ((rate_out + rate_in) > max_rate) max_rate = rate_out + rate_in
    pp_count[comm] += 1
    pp_bytes[comm] += bytes_out_n + bytes_in_n
    pp_rate[comm]  += rate_out + rate_in
}

function human_bytes(v,    units, i) {
    units[0]="B"; units[1]="KB"; units[2]="MB"; units[3]="GB"; units[4]="TB"
    if (v < 1024) return v " " units[0]
    i = 0; while (v >= 1024 && i < 4) { v /= 1024; i++ }
    return sprintf("%.1f %s", v, units[i])
}
function human_rate(v,    units, i) {
    units[0]="B/s"; units[1]="KB/s"; units[2]="MB/s"; units[3]="GB/s"
    if (v < 1) return "-"
    if (v < 1024) return sprintf("%.0f %s", v, units[0])
    i = 0; while (v >= 1024 && i < 3) { v /= 1024; i++ }
    return sprintf("%.1f %s", v, units[i])
}
function bar(value, mx, width,    full, frac, out, k, blocks, units_d) {
    blocks[0]=" "; blocks[1]="▏"; blocks[2]="▎"; blocks[3]="▍"; blocks[4]="▌"
    blocks[5]="▋"; blocks[6]="▊"; blocks[7]="▉"; blocks[8]="█"
    if (mx <= 0) return sprintf("%-" width "s", "")
    units_d = (value / mx) * width * 8
    full = int(units_d / 8); frac = int(units_d) % 8
    out = ""
    for (k = 0; k < full && k < width; k++) out = out blocks[8]
    if (full < width) out = out blocks[frac]
    while (length(out) < width) out = out " "
    return out
}

END {
    printf "%s═══ TCP_INFO snapshot ═══%s  %sconns:%s %d  %sthrough:%s %s  %strans-out:%s %s  %strans-in:%s %s  %savg RTT:%s %.1fms  %sretrans:%s %d\n\n",
        B CY, N, DIM, N, n_rows, DIM, N, human_rate(total_rate),
        DIM, N, human_bytes(total_bytes_out), DIM, N, human_bytes(total_bytes_in),
        DIM, N, (n_rows ? total_rtt/n_rows : 0), DIM, N, total_retr

    printf "%sPer-process rollup (top by total bytes):%s\n", DIM, N
    n_proc = 0
    for (pname in pp_bytes) { proc_keys[++n_proc] = pname }
    for (i = 1; i <= n_proc; i++)
        for (j = i+1; j <= n_proc; j++)
            if (pp_bytes[proc_keys[j]] > pp_bytes[proc_keys[i]]) {
                tmp = proc_keys[i]; proc_keys[i] = proc_keys[j]; proc_keys[j] = tmp
            }
    for (i = 1; i <= n_proc && i <= 5; i++) {
        pname = proc_keys[i]
        printf "  %s%-18s%s  %d conn(s)  %s%-10s%s  %s%-9s%s rate\n",
               MA, pname, N, pp_count[pname],
               DIM, human_bytes(pp_bytes[pname]), N,
               DIM, human_rate(pp_rate[pname]), N
    }
    printf "\n"

    # Sort by current rate desc
    for (i = 1; i <= n_rows; i++) idx[i] = i
    for (i = 1; i <= n_rows; i++)
        for (j = i+1; j <= n_rows; j++)
            if (rows_rate_tot[idx[j]] > rows_rate_tot[idx[i]]) {
                tmp = idx[i]; idx[i] = idx[j]; idx[j] = tmp
            }

    printf "%-24s %-22s %-22s %7s %5s %7s %4s %10s %10s %12s %-10s\n",
           "PROCESS", "SRC", "DST", "RTT", "RTRN", "CWND", "CC", "BYTES_OUT", "BYTES_IN", "RATE", "BAR"
    printf "%s%-24s %-22s %-22s %7s %5s %7s %4s %10s %10s %12s %-10s%s\n", DIM,
           "------------------------", "----------------------",
           "----------------------", "-------", "-----", "-------", "----",
           "----------", "----------", "------------", "----------", N

    for (i = 1; i <= n_rows; i++) {
        k = idx[i]
        rc  = (rows_rtt_n[k]  >= 50) ? R : (rows_rtt_n[k]  >= 10 ? Y : G)
        rec = (rows_retr_n[k] > 5)   ? R : (rows_retr_n[k] > 0   ? Y : G)
        cc  = (rows_cwnd_n[k] <= 10) ? DIM : ""
        printf "%-24s %-22s %-22s %s%7s%s %s%5s%s %s%7s%s %s%4s%s %10s %10s %s%12s%s %s%-10s%s\n",
               rows_proc[k], rows_src[k], rows_dst[k],
               rc, rows_rtt[k], N,
               rec, rows_retr[k], N,
               cc, rows_cwnd[k], N,
               CY, rows_cc[k], N,
               human_bytes(rows_bout[k]), human_bytes(rows_bin[k]),
               (rows_rate_tot[k] > 0 ? G : DIM), human_rate(rows_rate_tot[k]), N,
               CY, bar(rows_rate_tot[k], max_rate, 10), N
    }

    # Atomic state write: temp file + rename. If awk dies mid-write
    # the previous-pass state stays intact.
    printf "TS=%d\n", systime() > STATE_TMP
    for (i = 1; i <= n_rows; i++)
        printf "%s\t%d\t%d\n", rows_key[i], rows_bout[i], rows_bin[i] >> STATE_TMP
    close(STATE_TMP)
    system("mv -f " STATE_TMP " " STATE_FILE)
}
