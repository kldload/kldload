# meta-scrape.py – AWS EC2 Metadata Inspector

The **AWS Metadata Inspector** is a lightweight Python utility that queries the **AWS EC2 Instance Metadata Service (IMDS)** to provide a clean, human-friendly view of an instance’s identity and environment.  

It supports both **IMDSv2 (token-based, recommended)** and **IMDSv1 (fallback)**, and presents results in either **Markdown** or **JSON**, making it equally suitable for human troubleshooting or machine automation.

---

## Features
- **Summary mode**  
  Get the essentials at a glance: Instance ID, type, region, zone, account ID, public/private IPs, hostname, and IAM role (if any).

- **Full mode**  
  Dump the entire metadata tree in JSON (with **redaction of sensitive fields** like keys, tokens, secrets).

- **IMDSv2-first**  
  Secure by default: requests an IMDSv2 session token, falling back to IMDSv1 only if necessary (with a clear note in output).

- **Multiple output formats**  
  Choose **Markdown** for easy human reading, or **JSON** for automation.

- **Robust HTTP client**  
  Built-in retries, timeouts, and urllib3 v1/v2 compatibility.

---

## Usage

```bash
# Summary (Markdown)
./aws-meta.py

# Summary (JSON)
./aws-meta.py --format json

# Full metadata dump (JSON, redacted)
./aws-meta.py --full > full.json

# Full dump (Markdown-wrapped JSON)
./aws-meta.py --full --format md

# Verbose mode (debug HTTP traffic)
./aws-meta.py -v

```

---
## Example
`full.json`

```json
{
  "dynamic": {
    "instance-identity": {
      "document": {
        "accountId": "123456789012",
        "architecture": "x86_64",
        "availabilityZone": "us-east-1a",
        "billingProducts": null,
        "devpayProductCodes": null,
        "imageId": "ami-0123456789abcdef0",
        "instanceId": "i-0123456789abcdef0",
        "instanceType": "t3.micro",
        "kernelId": null,
        "marketplaceProductCodes": null,
        "pendingTime": "2025-08-28T03:13:12Z",
        "privateIp": "10.0.1.23",
        "ramdiskId": null,
        "region": "us-east-1",
        "version": "2017-09-30"
      }
    }
  },
  "meta-data": {
    "hostname": "ip-10-0-1-23.ec2.internal",
    "instance-id": "i-0123456789abcdef0",
    "instance-type": "t3.micro",
    "local-ipv4": "10.0.1.23",
    "placement": {
      "availability-zone": "us-east-1a"
    },
    "public-ipv4": "203.0.113.42"
  },
  "notes": []
}

```

## Usecases

- Ops – Quickly confirm account, region, instance type, and IAM role when you SSH into a host.
- Security – Detect insecure IMDSv1 usage; safe, redacted output for audits.
- Cost/Architecture – Spot instance type and placement across your fleet.
- Automation – JSON output drops easily into pipelines or scripts.

## Integrations

- A systemd service that refreshes metadata snapshots regularly.
- A Prometheus exporter (or Node Exporter textfile collector) for Grafana dashboards.
- An S3 fleet inventory uploader (every instance drops its metadata JSON into a bucket).
- A CI/CD helper for region/account-aware automation.
