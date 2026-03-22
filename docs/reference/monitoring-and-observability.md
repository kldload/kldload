# Monitoring and Observability

Setting up Prometheus, Grafana, and node_exporter on kldload systems. All examples work on CentOS/RHEL and Debian.

---

## Quick health check with kst

Every kldload system includes `kst` — a one-command health dashboard:

```bash
kst
```

Shows: ZFS pool health, root usage, compression ratio, snapshot count, boot environments, memory, CPU, uptime, and service status.

---

## node_exporter (per-host metrics)

Install on every node you want to monitor:

### CentOS/RHEL

```bash
dnf install -y golang  # or download the binary directly

# Download node_exporter
curl -LO https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
tar xzf node_exporter-1.8.2.linux-amd64.tar.gz
cp node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/
```

### Debian

```bash
apt install -y prometheus-node-exporter
systemctl enable --now prometheus-node-exporter
# Done — skip the systemd unit creation below
```

### Systemd service (CentOS, or if installed from binary)

```bash
useradd --no-create-home --shell /sbin/nologin node_exporter

cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter \
  --collector.zfs \
  --collector.systemd \
  --collector.processes
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter
```

### Verify

```bash
curl -s http://localhost:9100/metrics | head -20
# Should show metric lines like node_cpu_seconds_total, node_memory_MemTotal_bytes, etc.
```

### ZFS-specific metrics

node_exporter's `--collector.zfs` exposes:

```
node_zfs_arc_hits_total
node_zfs_arc_misses_total
node_zfs_arc_size
node_zfs_pool_state{pool="rpool"}     # 0=online, 1=degraded, etc.
```

---

## Prometheus (metrics server)

Install on your monitoring node:

```bash
# Download
curl -LO https://github.com/prometheus/prometheus/releases/download/v2.54.1/prometheus-2.54.1.linux-amd64.tar.gz
tar xzf prometheus-2.54.1.linux-amd64.tar.gz
cp prometheus-2.54.1.linux-amd64/{prometheus,promtool} /usr/local/bin/
mkdir -p /etc/prometheus /var/lib/prometheus
```

### Configuration

```bash
cat > /etc/prometheus/prometheus.yml << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "kldload-nodes"
    static_configs:
      - targets:
        - "10.78.0.1:9100"     # node 0 (hub)
        - "10.78.1.1:9100"     # node 1
        - "10.78.2.1:9100"     # node 2
        - "10.78.3.1:9100"     # node 3
        # ... add all your nodes
    relabel_configs:
      - source_labels: [__address__]
        regex: '(.+):.*'
        target_label: instance
EOF
```

If using the WireGuard mesh, use `wg2` addresses (10.79.x.x) — that's the metrics plane.

### Systemd service

```bash
useradd --no-create-home --shell /sbin/nologin prometheus
chown -R prometheus:prometheus /var/lib/prometheus /etc/prometheus

cat > /etc/systemd/system/prometheus.service << 'EOF'
[Unit]
Description=Prometheus
After=network-online.target

[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=30d
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now prometheus
```

### Store Prometheus data on ZFS

```bash
zfs create -o mountpoint=/var/lib/prometheus \
           -o compression=zstd \
           -o recordsize=128k \
           rpool/prometheus

chown prometheus:prometheus /var/lib/prometheus
systemctl restart prometheus
```

`zstd` compression works well on time-series data — expect 3–5x compression ratio.

### Verify

Open `http://<monitoring-node>:9090` in a browser. Try a query:

```promql
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100
```

---

## Grafana (dashboards)

```bash
# CentOS/RHEL
cat > /etc/yum.repos.d/grafana.repo << 'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
EOF
dnf install -y grafana

# Debian
apt install -y apt-transport-https software-properties-common
curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /usr/share/keyrings/grafana.gpg
echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list
apt update
apt install -y grafana
```

```bash
systemctl enable --now grafana-server
```

Open `http://<monitoring-node>:3000` — default login is `admin`/`admin`.

### Add Prometheus as a data source

1. Settings → Data Sources → Add data source → Prometheus
2. URL: `http://localhost:9090`
3. Save & Test

### Import the Node Exporter dashboard

1. Dashboards → Import
2. Enter ID: `1860` (Node Exporter Full)
3. Select your Prometheus data source
4. Import

This gives you CPU, memory, disk, network, and ZFS metrics for every node.

---

## ZFS-specific dashboard

Create a custom panel in Grafana with these queries:

### ARC hit rate

```promql
rate(node_zfs_arc_hits_total[5m]) /
(rate(node_zfs_arc_hits_total[5m]) + rate(node_zfs_arc_misses_total[5m])) * 100
```

A healthy ARC hit rate is >90%. Below 80% means the ARC is too small.

### ARC size

```promql
node_zfs_arc_size
```

### Pool free space

```promql
node_filesystem_avail_bytes{mountpoint="/"}
```

### Snapshot count over time

Use eBPF or a custom exporter, or run a cron job:

```bash
# /usr/local/bin/zfs-metrics.sh — called by a textfile collector
echo "# HELP zfs_snapshot_count Number of ZFS snapshots"
echo "# TYPE zfs_snapshot_count gauge"
echo "zfs_snapshot_count $(zfs list -t snapshot -H | wc -l)"
```

Configure node_exporter to read it:

```bash
# Add to node_exporter ExecStart:
--collector.textfile.directory=/var/lib/node_exporter/textfile

# Create the directory and cron job
mkdir -p /var/lib/node_exporter/textfile
echo '*/5 * * * * root /usr/local/bin/zfs-metrics.sh > /var/lib/node_exporter/textfile/zfs.prom' \
  >> /etc/crontab
```

---

## Alerting

Add alert rules to Prometheus:

```bash
cat > /etc/prometheus/alerts.yml << 'EOF'
groups:
  - name: kldload
    rules:
      - alert: ZFSPoolDegraded
        expr: node_zfs_pool_state{state="degraded"} == 1
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "ZFS pool degraded on {{ $labels.instance }}"

      - alert: DiskSpaceLow
        expr: node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} < 0.1
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Less than 10% disk space on {{ $labels.instance }}"

      - alert: HighMemoryUsage
        expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Memory usage >90% on {{ $labels.instance }}"

      - alert: ARCHitRateLow
        expr: rate(node_zfs_arc_hits_total[5m]) / (rate(node_zfs_arc_hits_total[5m]) + rate(node_zfs_arc_misses_total[5m])) < 0.8
        for: 15m
        labels:
          severity: warning
        annotations:
          summary: "ZFS ARC hit rate below 80% on {{ $labels.instance }}"
EOF
```

Reference it in `prometheus.yml`:

```yaml
rule_files:
  - "alerts.yml"
```

```bash
systemctl restart prometheus
```
