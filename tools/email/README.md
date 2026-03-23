# (`mail-audit.py`)

**Deep email/domain deliverability & mail-flow audit tool**

`mail-audit.py` is a comprehensive **mail infrastructure audit script** for domains.  
It verifies DNS, authentication policies, TLS configurations, MX hygiene, blacklist status,  
client surface exposure, and much more — producing both JSON and human-readable reports.

This tool is designed for **operators, postmasters, security engineers, and auditors** who need  
to quickly assess the state of email delivery for one or more domains.

---

## Features

### DNS & Resolver Checks
- Multi-resolver lookups (`system`, `public`, `authoritative`, or all combined)
- Diff detection between resolvers (`A`, `AAAA`, `TXT`, `MX`, `DS`)
- DNSSEC AD flag & DS record presence
- PTR lookups + forward-confirmed reverse DNS (FCrDNS)
- CNAME, IP literal, and hygiene detection for MX records
- DNS query limiting (`--max-qps`) for safety

### Email Authentication
- **SPF**: record discovery, macro detection, parse tree, DNS lookup count, void lookup detection
- Recursive include/redirect resolution with DNS-cost calculation
- Over-limit (>10 DNS lookups) detection
- **DMARC**: record discovery, tag parsing, duplicate detection, linting (`p`, `rua`, `pct`, `aspf`, `adkim`)
- **DKIM**: brute-force selector discovery from a large common selector list

### TLS / Security
- STARTTLS and SMTPS handshakes across MX and client ports
- TLS version, cipher, PFS support, weak cipher/legacy protocol detection
- Certificate parsing (subject, issuer, SAN, serial, expiry, key type/size, sig alg)
- Hostname match validation
- Full chain capture (PEM + human text if pyOpenSSL available)
- Validation with stdlib SSL context (system trust roots)
- **DANE/TLSA** informational matching
- **MTA-STS** DNS TXT + HTTPS policy fetch + wildcard host match simulation
- **TLS-RPT** record discovery and linting

### MX & Transport
- MX lookup & preference ordering
- Hygiene checks:
  - MX must not be a CNAME
  - MX must not be IP literals
  - MX must not be bare labels
- Per-MX port probing:
  - SMTP (25, 465, 587)
  - IMAP/POP (993, 995, 143, 110)
  - Sieve (4190)
- EHLO capability parsing (STARTTLS, AUTH, PIPELINING, SIZE)

### DNSBL & Blacklisting
- Checks against multiple well-known DNSBLs:
  - Spamhaus, Spamcop, Barracuda, SORBS, Abuseat/CBL, UCEProtect, Spamrats, PSBL, HostKarma

### Client Surface Exposure
- Discovery of client endpoints:
  - SRV records (`_submission._tcp`, `_imaps._tcp`, etc.)
  - Common hosts (`imap.domain`, `smtp.domain`, etc.)
- TLS checks on client ports

### Scoring & Reporting
- Scorecard across 4 categories:
  - **Authentication** (40%)
  - **Transport** (30%)
  - **Hygiene** (20%)
  - **Client surface** (10%)
- IPv4 vs IPv6 transport scores, with delta differences
- Remediation checklist (based on detected warnings)
- Output:
  - JSON structured data
  - Human-readable TXT reports

### Public-Safety Features
- `--max-qps`: throttle DNS/TCP queries globally
- `--legal-banner`: include a custom banner at top of reports
- `--reveal-banners`: control banner redaction (`never|safe|always`)

---

## Installation

### 1. Install system packages

These provide Python, development headers, SSL libraries, and useful network tools.

```bash
# Update system package index
sudo apt update

# Install Python, development headers, compilers, SSL/crypto libs,
# and DNS/network utilities used by audit.py
sudo apt install -y \
  python3 python3-venv python3-full python3-dev \
  build-essential libssl-dev libffi-dev \
  dnsutils netcat-openbsd

# Create a virtual environment in your home directory
python3 -m venv ~/mail_audit-venv

# Activate the environment
source ~/mail_audit-venv/bin/activate

# Upgrade pip to latest version
pip install --upgrade pip

# Install required Python packages for audit.py
pip install dnspython cryptography pyOpenSSL requests

# Make the script executable
chmod +x ./mail-audit.py

# Activate the virtual environment
source ~/mail_audit-venv/bin/activate

# Run an audit against a domain
python ./mail-audit.py example.com

# Deactivate environment when finished
deactivate
```
