# Observability — Intermediate

You know `execsnoop` and `bpftrace` one-liners. Now build real-time monitoring: eBPF-powered socket tracking, latency measurement with Prometheus metrics, and dashboards that show what's happening inside the kernel.

---

## socket_snoop — Real-time TCP state monitoring

`socket_snoop` hooks into the kernel's `inet_sock_set_state` tracepoint and logs every TCP state change — connections opening, closing, hanging in TIME_WAIT, retransmitting. It's a lightweight alternative to running `tcpdump` or `ss` in a loop.

### Install

```bash
cd /opt/kldload/tools/monitoring

# One-shot install (system deps + Python venv)
chmod +x install-deps-debian.sh
sudo ./install-deps-debian.sh

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Or use the Makefile:

```bash
make setup    # system deps
make deps     # Python venv + pip
make test     # run tests
sudo make run # start monitoring
```

### Run it

```bash
sudo .venv/bin/python socket_snoop.py --log-file /var/log/socket_monitor.log
```

Output (live to console + file):

```
Mar 21 2026 14:23:25.454 State Change: SRC=10.100.10.150:39134 DST=10.100.10.202:8000 PID=30512 COMM=nginx STATE=Connection Closing (FIN_WAIT1)
Mar 21 2026 14:23:25.455 State Change: SRC=10.100.10.150:39134 DST=10.100.10.202:8000 PID=30512 COMM=nginx STATE=Waiting (FIN_WAIT2)
Mar 21 2026 14:23:25.501 State Change: SRC=10.100.10.150:39134 DST=10.100.10.202:8000 PID=30512 COMM=nginx STATE=Cooldown (TIME_WAIT)
```

### Filter by process, IP, or port

```bash
# Only watch nginx
sudo .venv/bin/python socket_snoop.py --pid $(pgrep nginx)

# Only watch connections to the database
sudo .venv/bin/python socket_snoop.py --dst-ip 10.100.10.50 --dst-port 5432

# Only active connections (skip TIME_WAIT noise)
sudo .venv/bin/python socket_snoop.py --active-only
```

### Run as a systemd service

```bash
sudo cp systemd/socket-snoop.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now socket-snoop.service

# Check status
journalctl -u socket-snoop -f
```

### Run in Docker

```bash
sudo docker build -t socket-snoop:latest .
sudo docker run --rm -it \
  --privileged --pid=host --net=host \
  -v /lib/modules:/lib/modules:ro \
  -v /usr/src:/usr/src:ro \
  -v /sys:/sys:ro \
  -v /var/log:/var/log \
  socket-snoop:latest \
  /app/.venv/bin/python /app/socket_snoop.py --log-file /var/log/socket_monitor.log
```

### What to look for

| Pattern | Meaning |
|---------|---------|
| Many SYN_SENT → no ESTABLISHED | Connection refused or firewall blocking |
| Piling up TIME_WAIT | High connection churn — consider connection pooling |
| Retransmissions | Network packet loss or congestion |
| Long-lived ESTABLISHED | Persistent connections (database pools, WebSockets) |
| CLOSE_WAIT accumulating | Application not closing sockets (resource leak) |

---

## latency_snoop — TCP latency with Prometheus

`latency_snoop` goes deeper — it measures the actual time between TCP state transitions and exports metrics to Prometheus.

### Install

Same venv as socket_snoop, plus:

```bash
source /opt/kldload/tools/monitoring/.venv/bin/activate
pip install prometheus_client
```

### Run with Prometheus exporter

```bash
sudo .venv/bin/python latency_snoop.py \
  --prometheus-port 9900 \
  --log-file /var/log/latency_monitor.log
```

Now `http://localhost:9900/metrics` serves Prometheus metrics:

```
# HELP tcp_connect_latency_ms TCP connect latency (SYN_SENT to ESTABLISHED)
# TYPE tcp_connect_latency_ms histogram
tcp_connect_latency_ms_bucket{le="1.0"} 142
tcp_connect_latency_ms_bucket{le="5.0"} 203
tcp_connect_latency_ms_bucket{le="10.0"} 215
tcp_connect_latency_ms_bucket{le="50.0"} 218
tcp_connect_latency_ms_bucket{le="100.0"} 218

# HELP tcp_retransmits_total TCP segment retransmissions
# TYPE tcp_retransmits_total counter
tcp_retransmits_total 7
```

### Advanced options

```bash
# JSON output (for piping to jq, Elasticsearch, etc.)
sudo .venv/bin/python latency_snoop.py --json

# Per-flow metrics (WARNING: high cardinality — use for debugging, not production)
sudo .venv/bin/python latency_snoop.py --prometheus-port 9900 --per-flow

# Collect user-space stack traces
sudo .venv/bin/python latency_snoop.py --stacks --prometheus-port 9900

# Custom histogram buckets (in milliseconds)
sudo .venv/bin/python latency_snoop.py --prometheus-port 9900 \
  --buckets "0.5,1,2,5,10,25,50,100,250,500,1000"

# Filter to just database traffic
sudo .venv/bin/python latency_snoop.py \
  --dst-port 5432 \
  --prometheus-port 9900
```

### What latency_snoop measures

| Metric | What it captures |
|--------|-----------------|
| Connect latency | Time from SYN_SENT → ESTABLISHED (TCP handshake) |
| RTT (srtt_us) | Kernel's smoothed round-trip time estimate |
| RTT deviation (mdev_us) | Jitter — how much RTT varies |
| Retransmits | Packets the kernel had to resend |
| Process metadata | PID, thread ID, parent PID, UID, command name |
| Cgroup/K8s | Cgroup ID, pod UID, container ID (if running in K8s) |

---

## Wire it into Prometheus + Grafana

### Add latency_snoop to your Prometheus config

```yaml
# /etc/prometheus/prometheus.yml
scrape_configs:
  - job_name: "latency-snoop"
    static_configs:
      - targets: ["localhost:9900"]
```

```bash
systemctl restart prometheus
```

### Build a Grafana dashboard

Create panels with these queries:

**Connect latency (p50 / p95 / p99):**
```promql
histogram_quantile(0.50, rate(tcp_connect_latency_ms_bucket[5m]))
histogram_quantile(0.95, rate(tcp_connect_latency_ms_bucket[5m]))
histogram_quantile(0.99, rate(tcp_connect_latency_ms_bucket[5m]))
```

**Retransmit rate:**
```promql
rate(tcp_retransmits_total[5m])
```

**Connection rate:**
```promql
rate(tcp_connect_latency_ms_count[5m])
```

### Alert on latency spikes

```yaml
# /etc/prometheus/alerts.yml
groups:
  - name: latency
    rules:
      - alert: HighTCPConnectLatency
        expr: histogram_quantile(0.95, rate(tcp_connect_latency_ms_bucket[5m])) > 50
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "p95 TCP connect latency >50ms on {{ $labels.instance }}"

      - alert: HighRetransmitRate
        expr: rate(tcp_retransmits_total[5m]) > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "TCP retransmit rate >10/s on {{ $labels.instance }}"
```

---

## Combine socket_snoop + latency_snoop + Prometheus

Run both as systemd services:

```bash
# socket_snoop — event log (console + file)
# latency_snoop — metrics (Prometheus)

# Create latency_snoop service
cat > /etc/systemd/system/latency-snoop.service << 'EOF'
[Unit]
Description=TCP Latency Monitor (eBPF)
After=network.target

[Service]
ExecStart=/opt/kldload/tools/monitoring/.venv/bin/python \
  /opt/kldload/tools/monitoring/latency_snoop.py \
  --prometheus-port 9900 \
  --log-file /var/log/latency_monitor.log
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now socket-snoop latency-snoop
```

Now you have:
- **socket_snoop** → real-time event stream in `/var/log/socket_monitor.log` (grep it, tail it, feed to LogHog)
- **latency_snoop** → continuous metrics on `:9900` (scrape with Prometheus, visualize in Grafana)

---

## Email infrastructure auditing with mail-audit

If your kldloadOS system runs a mail server or you need to audit mail delivery:

```bash
cd /opt/kldload/tools/email

# Install dependencies
pip install dnspython cryptography pyOpenSSL requests

# Audit a domain
./mail-audit.py example.com
```

Generates `example.com.json` + `example.com.txt` with:
- SPF record analysis (DNS cost, over-limit detection)
- DKIM selector discovery (brute-force scan)
- DMARC policy parsing and linting
- TLS/STARTTLS handshake testing per MX
- DANE/TLSA record checks
- MTA-STS policy fetch
- DNSBL blacklist checks (Spamhaus, Spamcop, Barracuda, etc.)
- Per-MX port probing (25, 465, 587, IMAP, POP)
- Overall score: Authentication (40%), Transport (30%), Hygiene (20%), Client (10%)

```bash
# Verbose mode
./mail-audit.py example.com -vv

# Rate-limited (for batch scanning)
./mail-audit.py example.com --max-qps 2

# Skip port 25 checks (cloud environments block outbound SMTP)
./mail-audit.py example.com --assume-port25-blocked

# Batch scan
xargs -a domains.txt -I{} ./mail-audit.py {} --max-qps 1
```

---

## Next level

Ready to write your own eBPF programs in C, build custom kernel modules, and deploy kldloadOS images to AWS/Azure? Move on to [Observability — Advanced](observability-advanced.md).
