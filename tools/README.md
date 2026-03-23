# kldloadOS Starter Tools

Community tools from [unixbox-net/linux-tools](https://github.com/unixbox-net/linux-tools) — included as starter examples for kldloadOS deployments. All work on both CentOS/RHEL and Debian.

## Monitoring

| Tool | Description |
|------|-------------|
| `monitoring/socket_snoop.py` | Real-time TCP socket state monitoring via eBPF. Tracks connections, retransmits, TIME_WAIT. |
| `monitoring/latency_snoop.py` | TCP latency measurement with Prometheus exporter. Connect latency, RTT, retransmits, K8s enrichment. |

## Diagnostics

| Tool | Description |
|------|-------------|
| `diagnostics/diagnostics.sh` | Comprehensive Debian/Ubuntu system diagnostic — network, logs, security, packages, performance. |
| `diagnostics/rhel-diag.sh` | Same for RHEL/CentOS/Rocky — includes subscription, SELinux, tuned, kdump checks. |

## Email

| Tool | Description |
|------|-------------|
| `email/mail-audit.py` | Domain & mail flow auditor — SPF, DKIM, DMARC, TLS, MX hygiene, DNSBL checks, scoring. |

## eBPF

| Tool | Description |
|------|-------------|
| `ebpf/` | Custom eBPF network telemetry tool (C). Kernel-space BPF program + userspace loader. CO-RE build with Makefile. |

## AWS

| Tool | Description |
|------|-------------|
| `aws/deploy-vm.sh` | Safe-by-default EC2 deployer. IMDSv2, EBS encryption, auto-SSH, clean teardown. |
| `aws/meta-scrape.py` | AWS EC2 metadata inspector. IMDSv2-first, summary/full modes, sensitive data redaction. |

## Utils

| Tool | Description |
|------|-------------|
| `utils/lh/` | LogHog — fast log forensics tool. Real-time event correlation, auth failures, regex search, JSON export. |
| `utils/ral/` | RAL — high-performance file renaming utility (C). Batch normalize filenames, replace spaces, lowercase. |

## Installation

These tools are not installed by default — they're starter examples you can deploy as needed:

```bash
# Socket monitoring
cd /opt && git clone https://github.com/kldload/kldload.git
cd kldload/tools/monitoring
make setup && make deps
sudo make run

# Diagnostics
sudo bash tools/diagnostics/diagnostics.sh    # Debian
sudo bash tools/diagnostics/rhel-diag.sh      # RHEL/CentOS

# LogHog
cd tools/utils/lh && ./install.sh
lh

# eBPF tool
cd tools/ebpf && make clean && make all
sudo ./build/ebpf_tool

# Mail audit
pip install dnspython cryptography pyOpenSSL requests
python3 tools/email/mail-audit.py example.com
```

## License

BSD 2-Clause (from [unixbox-net/linux-tools](https://github.com/unixbox-net/linux-tools)).
