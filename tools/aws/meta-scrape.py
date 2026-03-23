#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AWS EC2 Metadata Inspector (IMDSv2-first, v1 fallback)

Usage:
  ./meta-scrape.py                     # summary (Markdown)
  ./meta-scrape.py --format json       # summary (JSON)
  ./meta-scrape.py --full > full.json  # full dump (JSON)
  ./meta-scrap.py -v                  # verbose

Exit codes:
  0 = success
  2 = metadata unreachable / not on EC2
  3 = internal error

Dependency:
  pip install requests
License: BSD 2 Clause 
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from dataclasses import dataclass, asdict, field
from typing import Any, Dict, Optional, Tuple, List

try:
    import requests
    from requests import Response
    from requests.adapters import HTTPAdapter
    from urllib3.util.retry import Retry
except Exception:
    sys.stderr.write(
        "[FATAL] The 'requests' package is required. Install with: pip install requests\n"
    )
    sys.exit(3)

LINK_LOCAL = "http://169.254.169.254"
AWS_ROOT = f"{LINK_LOCAL}/latest"
DEFAULT_CONNECT_TIMEOUT = 0.5
DEFAULT_READ_TIMEOUT = 1.5

SENSITIVE_KEY_FRAGMENTS = [
    "accesskey", "secret", "token", "password", "privatekey",
    "authorization", "client_secret", "refresh_token", "certificate", "keymaterial",
]

class HTTPClient:
    """requests.Session with retries, timeouts, and minimal logging."""

    def __init__(self, timeout: Tuple[float, float], verbose: bool = False) -> None:
        self.timeout = timeout
        self.verbose = verbose
        self.session = requests.Session()

        retry_methods = frozenset(["GET", "PUT", "HEAD"])
        try:
            # urllib3 v2
            retries = Retry(
                total=2,
                backoff_factor=0.2,
                status_forcelist=(429, 500, 502, 503, 504),
                allowed_methods=retry_methods,
                raise_on_status=False,
            )
        except TypeError:
            # urllib3 v1
            retries = Retry(
                total=2,
                backoff_factor=0.2,
                status_forcelist=(429, 500, 502, 503, 504),
                method_whitelist=retry_methods,
                raise_on_status=False,
            )
        adapter = HTTPAdapter(max_retries=retries)
        self.session.mount("http://", adapter)
        self.session.mount("https://", adapter)

    def get(self, url: str, headers: Optional[Dict[str, str]] = None) -> Optional[Response]:
        try:
            if self.verbose:
                logging.debug("GET %s headers=%s", url, headers)
            return self.session.get(url, headers=headers or {}, timeout=self.timeout)
        except requests.RequestException as e:
            if self.verbose:
                logging.debug("GET error for %s: %s", url, e)
            return None

    def put(self, url: str, headers: Optional[Dict[str, str]] = None) -> Optional[Response]:
        try:
            if self.verbose:
                logging.debug("PUT %s headers=%s", url, headers)
            return self.session.put(url, headers=headers or {}, timeout=self.timeout)
        except requests.RequestException as e:
            if self.verbose:
                logging.debug("PUT error for %s: %s", url, e)
            return None

@dataclass
class Summary:
    provider: str = "AWS"
    instance_id: Optional[str] = None
    instance_type: Optional[str] = None
    region: Optional[str] = None
    zone: Optional[str] = None
    hostname: Optional[str] = None
    private_ip: Optional[str] = None
    public_ip: Optional[str] = None
    account_id: Optional[str] = None
    service_identity: Optional[str] = None  # IAM role name (not credentials)
    notes: List[str] = field(default_factory=list)

def _safe_text(resp: Optional[Response]) -> Optional[str]:
    if resp is None:
        return None
    if resp.status_code == 200:
        return resp.text.strip()
    return None

def _json(resp: Optional[Response]) -> Optional[Dict[str, Any]]:
    if resp is None:
        return None
    try:
        return resp.json()
    except Exception:
        return None

def _redact(obj: Any) -> Any:
    """Recursively redact sensitive keys in dicts/lists/strings."""
    def is_sensitive_key(k: str) -> bool:
        lk = k.lower()
        return any(fragment in lk for fragment in SENSITIVE_KEY_FRAGMENTS)

    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if is_sensitive_key(k):
                out[k] = "***REDACTED***"
            else:
                out[k] = _redact(v)
        return out
    elif isinstance(obj, list):
        return [_redact(x) for x in obj]
    else:
        return obj

class AWSMetadata:
    ROOT = AWS_ROOT
    HDR_TOKEN_TTL = {"X-aws-ec2-metadata-token-ttl-seconds": "60"}

    @staticmethod
    def _token(client: HTTPClient) -> Optional[str]:
        r = client.put(f"{AWSMetadata.ROOT}/api/token", headers=AWSMetadata.HDR_TOKEN_TTL)
        if r and r.status_code == 200:
            return r.text.strip()
        return None

    @staticmethod
    def _hdr(token: Optional[str]) -> Dict[str, str]:
        return {"X-aws-ec2-metadata-token": token} if token else {}

    @staticmethod
    def reachable(client: HTTPClient) -> bool:
        token = AWSMetadata._token(client)
        hdr = AWSMetadata._hdr(token)
        r = client.get(f"{AWSMetadata.ROOT}/meta-data/", headers=hdr)
        return bool(r and r.status_code == 200)

    @staticmethod
    def summary(client: HTTPClient) -> Summary:
        token = AWSMetadata._token(client)
        hdr = AWSMetadata._hdr(token)

        def get(path: str) -> Optional[str]:
            return _safe_text(client.get(f"{AWSMetadata.ROOT}{path}", headers=hdr))

        s = Summary()
        s.instance_id = get("/meta-data/instance-id")
        s.instance_type = get("/meta-data/instance-type")
        s.hostname = get("/meta-data/hostname")
        s.private_ip = get("/meta-data/local-ipv4")
        s.public_ip = get("/meta-data/public-ipv4")

        ident = _json(client.get(f"{AWSMetadata.ROOT}/dynamic/instance-identity/document", headers=hdr)) or {}
        s.region = ident.get("region")
        s.account_id = ident.get("accountId")

        s.zone = get("/meta-data/placement/availability-zone")

        role_name = _safe_text(client.get(f"{AWSMetadata.ROOT}/meta-data/iam/security-credentials/", headers=hdr))
        if role_name:
            s.service_identity = role_name.splitlines()[0].strip()
            s.notes.append("IAM role detected (credentials redacted).")

        if token is None:
            s.notes.append("IMDSv2 token unavailable; IMDSv1 used (less secure).")

        return s

    @staticmethod
    def full(client: HTTPClient, redact: bool = True) -> Dict[str, Any]:
        token = AWSMetadata._token(client)
        hdr = AWSMetadata._hdr(token)
        data: Dict[str, Any] = {"notes": []}

        data["meta-data"] = {
            "instance-id": _safe_text(client.get(f"{AWSMetadata.ROOT}/meta-data/instance-id", headers=hdr)),
            "instance-type": _safe_text(client.get(f"{AWSMetadata.ROOT}/meta-data/instance-type", headers=hdr)),
            "hostname": _safe_text(client.get(f"{AWSMetadata.ROOT}/meta-data/hostname", headers=hdr)),
            "local-ipv4": _safe_text(client.get(f"{AWSMetadata.ROOT}/meta-data/local-ipv4", headers=hdr)),
            "public-ipv4": _safe_text(client.get(f"{AWSMetadata.ROOT}/meta-data/public-ipv4", headers=hdr)),
            "placement": {
                "availability-zone": _safe_text(client.get(f"{AWSMetadata.ROOT}/meta-data/placement/availability-zone", headers=hdr)),
            },
        }

        ident = _json(client.get(f"{AWSMetadata.ROOT}/dynamic/instance-identity/document", headers=hdr)) or {}
        data["dynamic"] = {"instance-identity": {"document": ident}}

        role_name = _safe_text(client.get(f"{AWSMetadata.ROOT}/meta-data/iam/security-credentials/", headers=hdr))
        if role_name:
            role_name = role_name.splitlines()[0].strip()
            data["meta-data"]["iam"] = {"role": role_name, "credentials": "present (redacted)"}

        if token is None:
            data["notes"].append("IMDSv2 token unavailable; IMDSv1 used (less secure).")

        return _redact(data) if redact else data

def summary_to_markdown(s: Summary) -> str:
    lines = [
        "# Cloud Metadata Report",
        "",
        f"- **Provider:** {s.provider}",
        f"- **Instance ID:** {s.instance_id or '-'}",
        f"- **Instance Type:** {s.instance_type or '-'}",
        f("- **Region:** {0}".format(s.region)) if s.region else "- **Region:** -",
        f("- **Zone:** {0}".format(s.zone)) if s.zone else "- **Zone:** -",
        f("- **Hostname:** {0}".format(s.hostname)) if s.hostname else "- **Hostname:** -",
        f("- **Private IP:** {0}".format(s.private_ip)) if s.private_ip else "- **Private IP:** -",
        f("- **Public IP:** {0}".format(s.public_ip)) if s.public_ip else "- **Public IP:** -",
    ]
    if s.account_id:
        lines.append(f"- **Account ID:** {s.account_id}")
    if s.service_identity:
        lines.append(f"- **Service Identity:** {s.service_identity}")
    if s.notes:
        lines.append(f"- **Notes:** " + "; ".join(s.notes))
    return "\n".join(lines)

def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="AWS EC2 Metadata Inspector (IMDSv2-first).")
    p.add_argument("--full", action="store_true", help="Return full metadata instead of summary")
    p.add_argument("--format", choices=["md", "json"], default=None,
                   help="Output format (default: md for summary, json for full)")
    p.add_argument("--timeout", type=float, default=None,
                   help="Per-request read timeout (seconds). Connect timeout defaults to 0.5s.")
    p.add_argument("--connect-timeout", type=float, default=None,
                   help="Override connect timeout (seconds).")
    p.add_argument("--no-redact", action="store_true",
                   help="Do not redact sensitive fields in full dumps")
    p.add_argument("--verbose", "-v", action="store_true", help="Verbose logging to stderr")
    return p.parse_args(argv)

def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.WARNING,
        format="%(levelname)s: %(message)s",
    )

    connect_timeout = args.connect_timeout if args.connect_timeout is not None else DEFAULT_CONNECT_TIMEOUT
    read_timeout = args.timeout if args.timeout is not None else DEFAULT_READ_TIMEOUT
    client = HTTPClient(timeout=(connect_timeout, read_timeout), verbose=args.verbose)

    try:
        if not AWSMetadata.reachable(client):
            sys.stderr.write("ERROR: AWS EC2 metadata service not reachable. Are you on EC2?\n")
            return 2

        if args.full:
            data = AWSMetadata.full(client, redact=not args.no_redact)
            fmt = args.format or "json"
            if fmt == "json":
                print(json.dumps(data, indent=2, sort_keys=True))
            else:
                print("# Full Metadata Dump")
                print("```json")
                print(json.dumps(data, indent=2, sort_keys=True))
                print("```")
        else:
            s = AWSMetadata.summary(client)
            fmt = args.format or "md"
            if fmt == "json":
                print(json.dumps(asdict(s), indent=2, sort_keys=True))
            else:
                print(summary_to_markdown(s))
        return 0
    except Exception as e:
        logging.exception("Unhandled error: %s", e)
        return 3

if __name__ == "__main__":
    sys.exit(main())
