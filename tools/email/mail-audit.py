#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mail-audit.py — Deep email/domain deliverability & mail-flow audit (v3.6, production)

Adds:
  • Multi-resolver & authoritative querying + resolver diff in JSON/TXT
  • DANE/TLSA matching (informational)
  • MTA-STS simulation with RFC-correct wildcard matching
  • TLS flags: PFS, min TLS >=1.2, weak-cipher detection
  • Split scorecard by IPv4/IPv6 and show deltas
  • Public-safety flags: --max-qps, --legal-banner, --reveal-banners

======================================================================
 USAGE EXAMPLES — mail-audit.py
======================================================================

Basic Scan (single domain):
  ./mail-audit.py example.com

  → Runs full audit against example.com
  → Outputs:
       example.com.json   (machine-readable results)
       example.com.txt    (human-readable report)
       /tmp/ssl_chain_*   (TLS chain PEMs & dumps)

Careful interactive run:
./mail-audit.py example.com --max-qps 2

Batch file, be polite:
xargs -a domains.txt ./mail-audit.py --max-qps 1 --outdir reports

Very large batches (or corporate network):
xargs -a domains.txt ./mail-audit.py --max-qps 0.5 --no-port25 --outdir reports

----------------------------------------------------------------------

Multi-Domain Scan:
  ./mail-audit.py domain1.com domain2.com domain3.com

  → Processes each domain in parallel
  → Creates a .json + .txt report for each

----------------------------------------------------------------------

Increase Verbosity:
  ./mail-audit.py example.com -v
  ./mail-audit.py example.com -vv
  ./mail-audit.py example.com -vvv

  Levels:
    -v    → INFO
    -vv   → DEBUG
    -vvv  → TRACE (extra detail)

----------------------------------------------------------------------

Quiet Mode (warnings only):
  ./mail-audit.py example.com --quiet

  → Suppresses INFO/DEBUG
  → Only warnings/errors are shown

----------------------------------------------------------------------

Dry-Run (no output files written):
  ./mail-audit.py example.com --dry-run

  → Prints plan to stdout
  → Does not create JSON/TXT reports

----------------------------------------------------------------------

Custom Output Directory:
  ./mail-audit.py example.com --outdir ./reports

  → Places results into ./reports/
     ./reports/example.com.json
     ./reports/example.com.txt

----------------------------------------------------------------------

Disable Port 25 Probing:
  ./mail-audit.py example.com --no-port25

  → Skips SMTP/25 checks (useful if ISP blocks port 25)

----------------------------------------------------------------------

Assume Port 25 Blocked:
  ./mail-audit.py example.com --assume-port25-blocked

  → Adjusts scoring to avoid penalizing port 25 failures
  → Useful in cloud environments (AWS, GCP, Azure)

----------------------------------------------------------------------

Force IPv6:
  ./mail-audit.py example.com --ipv6

  → Prefers AAAA records + IPv6 connectivity tests

----------------------------------------------------------------------

Set DNS Timeout / Lifetime:
  ./mail-audit.py example.com --timeout 10 --dns-lifetime 60

  → DNS resolution timeout = 10s
  → DNS cache lifetime = 60s

----------------------------------------------------------------------

Batch via File Input (shell trick):
  xargs -a domains.txt ./mail-audit.py -vv --outdir ./batch_reports

  → domains.txt = list of domains (one per line)
  → Creates report per domain in ./batch_reports/

----------------------------------------------------------------------

Integration with Pipelines:
  ./mail-audit.py example.com --dry-run | jq '.'

  → Produces JSONL stream
  → Parse with jq for automation/CI pipelines

REQUIRES:
python3 -m pip install --upgrade pip wheel setuptools
python3 -m pip install dnspython requests cryptography pyOpenSSL
  
"""

import sys, os, socket, ssl, json, time, re, logging, traceback, threading
from datetime import datetime, timezone
from collections import defaultdict
from typing import Dict, List, Tuple, Optional, Set, Any
from concurrent.futures import ThreadPoolExecutor, as_completed

# Third-party DNS
import dns.resolver, dns.exception, dns.name, dns.rdatatype, dns.reversename, dns.flags, dns.message, dns.query

try:
    import requests
except Exception:
    requests = None

# Optional crypto/pyOpenSSL (for full chain + parsing)
try:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    from cryptography.hazmat.primitives.asymmetric import rsa, dsa, ec
    HAVE_CRYPTO = True
except Exception:
    HAVE_CRYPTO = False

try:
    from OpenSSL import SSL, crypto
    HAVE_PYOPENSSL = True
except Exception:
    HAVE_PYOPENSSL = False

# -------- Logging --------
logger = logging.getLogger("mailflow_audit")

def setup_logging(verbosity: int, quiet: bool):
    # verbosity: 0=INFO, 1=INFO, 2=DEBUG, 3=DEBUG+extra
    if quiet:
        level = logging.WARN
    else:
        level = logging.INFO if verbosity < 2 else logging.DEBUG
    fmt = "%(asctime)s %(levelname)-8s %(message)s"
    datefmt = "%H:%M:%S"
    logging.basicConfig(level=level, format=fmt, datefmt=datefmt)
    if verbosity >= 3:
        for h in logger.handlers:
            h.setLevel(logging.DEBUG)

def log_debug(msg: str): logger.debug(msg)
def log_info(msg: str):  logger.info(msg)
def log_warn(msg: str):  logger.warning(msg)
def log_error(msg: str): logger.error(msg)

# -------- Tunables (overridable via CLI) --------
DEFAULT_TCP_TIMEOUT = 5.0
DNS_LIFETIME        = 4.0
MAX_WORKERS         = 10
PREFER_IPV6         = False
SMTP_BANNER_READ    = 2.0
EHLO_NAME           = "mailflow-audit"
SAVE_CHAIN_DIR      = "/tmp"

DNS_SOURCE          = "system"  # system|public|authoritative|all
PUBLIC_RESOLVERS = [
    "8.8.8.8", "8.8.4.4",      # Google
    "1.1.1.1", "1.0.0.1",      # Cloudflare
    "9.9.9.9", "149.112.112.112"  # Quad9
]
MAX_QPS             = 1    # 0 = unlimited
LEGAL_BANNER        = ""
REVEAL_BANNERS      = "safe"    # never|safe|always

# global base resolver (behavior unchanged)
RESOLVER = dns.resolver.Resolver(configure=True)
RESOLVER.lifetime = DNS_LIFETIME
RESOLVER.timeout  = DNS_LIFETIME

# simple QPS gate
_last_call = {"dns": 0.0, "tcp": 0.0}
_qps_lock = threading.Lock()
def qps_gate(kind: str):
    if MAX_QPS <= 0:
        return
    with _qps_lock:
        now = time.time()
        min_interval = 1.0 / MAX_QPS
        elapsed = now - _last_call.get(kind, 0.0)
        if elapsed < min_interval:
            time.sleep(min_interval - elapsed)
        _last_call[kind] = time.time()

def now_utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

def qname(name: str) -> dns.name.Name:
    return dns.name.from_text(name.rstrip('.'))

# ---------- Static data ----------
COMMON_DKIM_SELECTORS = [
    "default","selector","selector1","selector2","google","k1","k2","mail","m1","s1","s2",
    "dkim","smtp","mx","postmark","pm","mandrill","sendgrid","sparkpost","mailjet","zoho",
    "mailgun","amazonses","ses"
]
PORTS_INBOUND_SMTP  = [25, 465, 587]
PORTS_CLIENT_COMMON = [993, 995, 587, 143, 110, 4190]

DNSBL_ZONES = [
    "zen.spamhaus.org","bl.spamcop.net","b.barracudacentral.org","dnsbl.sorbs.net","cbl.abuseat.org",
    "spam.dnsbl.sorbs.net","dul.dnsbl.sorbs.net","dnsbl-1.uceprotect.net","dnsbl-2.uceprotect.net",
    "dnsbl-3.uceprotect.net","all.spamrats.com","psbl.surriel.com","hostkarma.junkemailfilter.com",
]
CLIENT_SRV_QUERIES = [
    ("_imaps._tcp", 993), ("_submission._tcp", 587), ("_pop3s._tcp", 995),
    ("_imap._tcp", 143),  ("_pop3._tcp", 110),       ("_sieve._tcp", 4190),
]
COMMON_CLIENT_HOSTS = ["imap","smtp","mail","pop","mx"]

# ---------- Multi-resolver plumbing ----------
def build_resolver(nameservers: Optional[List[str]]=None) -> dns.resolver.Resolver:
    r = dns.resolver.Resolver(configure=False if nameservers else True)
    if nameservers:
        r.nameservers = nameservers
    r.lifetime = DNS_LIFETIME
    r.timeout  = DNS_LIFETIME
    return r

def get_authoritative_servers(domain: str) -> List[str]:
    try:
        ns = []
        r = build_resolver()
        ans = r.resolve(qname(domain), 'NS', raise_on_no_answer=True)
        for rr in ans:
            host = rr.target.to_text().rstrip(".")
            # A/AAAA for each NS (use system resolver to resolve glue)
            try:
                a = [ip.to_text() for ip in dns.resolver.resolve(host, 'A')]
            except Exception: a = []
            try:
                aaaa = [ip.to_text() for ip in dns.resolver.resolve(host, 'AAAA')]
            except Exception: aaaa = []
            ns.extend(aaaa if PREFER_IPV6 else a)
            ns.extend(a if PREFER_IPV6 else aaaa)
        return list(dict.fromkeys(ns))[:8] or []
    except Exception as e:
        log_debug(f"Authoritative NS discovery failed for {domain}: {e}")
        return []

def do_resolve(resolver: dns.resolver.Resolver, name: str, rtype: str) -> List[str]:
    qps_gate("dns")
    try:
        ans = resolver.resolve(qname(name), rtype, raise_on_no_answer=True)
        return [rr.to_text() for rr in ans]
    except Exception:
        return []

def resolver_sources_for(domain: str) -> Dict[str, dns.resolver.Resolver]:
    sources: Dict[str, dns.resolver.Resolver] = {}
    if DNS_SOURCE in ("system","all"):
        sources["system"] = build_resolver(None)
    if DNS_SOURCE in ("public","all"):
        sources["public"] = build_resolver(PUBLIC_RESOLVERS)
    if DNS_SOURCE in ("authoritative","all"):
        auth_ns = get_authoritative_servers(domain)
        if auth_ns:
            sources["authoritative"] = build_resolver(auth_ns)
    return sources

def diff_records(sets_by_source: Dict[str, List[str]]) -> Dict[str, Any]:
    # normalize to sets of strings (lowercased)
    norm = {k: set([v.lower() for v in vals]) for k, vals in sets_by_source.items()}
    allvals = set().union(*norm.values()) if norm else set()
    per_val = {}
    for v in allvals:
        present = [k for k, s in norm.items() if v in s]
        per_val[v] = present
    # any disagreements?
    disagree = any(len(p) != len(norm) for p in per_val.values()) if norm else False
    return {"per_value_sources": per_val, "disagree": disagree}

# ---------- Banner policy ----------
def redact_banner(banner: str) -> str:
    if not banner: return ""
    if REVEAL_BANNERS == "never":
        return ""
    if REVEAL_BANNERS == "always":
        return banner
    # safe: keep 3-digit code and first token
    m = re.match(r"^(\d{3})[ -](.*)$", banner.strip())
    if m:
        code = m.group(1)
        token = m.group(2).split()[0] if m.group(2) else ""
        return f"{code} {token}".strip()
    return banner.split()[0]

# ---------- DNS helpers ----------
def _txt_from_rr(rr) -> str:
    try:
        return b"".join(rr.strings).decode("utf-8", errors="replace")
    except Exception:
        t = rr.to_text()
        if t.startswith('"') and t.endswith('"'): t = t[1:-1]
        return t.replace('" "', '')

def dns_any(name: str, rtype: str) -> List[str]:
    qps_gate("dns")
    log_debug(f"{rtype} lookup: {name}")
    try:
        ans = RESOLVER.resolve(qname(name), rtype, raise_on_no_answer=True)
        vals = [rr.to_text() for rr in ans]
        for v in vals: log_debug(f"  {rtype}: {v}")
        return vals
    except Exception as e:
        log_debug(f"  {rtype} lookup failed: {e}")
        return []

def dns_txt(name: str) -> List[str]:
    qps_gate("dns")
    log_debug(f"TXT lookup: {name}")
    try:
        ans = RESOLVER.resolve(qname(name), 'TXT', raise_on_no_answer=True)
        out = [_txt_from_rr(rr) for rr in ans]
        for t in out: log_debug(f"  TXT: {t}")
        return out
    except Exception as e:
        log_debug(f"  TXT lookup failed: {e}")
        return []

def dns_ad_flag(name: str, rtype: str) -> Optional[bool]:
    qps_gate("dns")
    try:
        query = dns.message.make_query(qname(name), rtype, want_dnssec=True)
        resp = dns.query.udp(query, RESOLVER.nameservers[0], timeout=DNS_LIFETIME)
        return bool(resp.flags & dns.flags.AD)
    except Exception:
        return None

def get_mx(domain: str) -> List[Tuple[int, str]]:
    qps_gate("dns")
    log_debug(f"MX lookup: {domain}")
    try:
        answers = RESOLVER.resolve(qname(domain), 'MX')
        pairs = sorted([(int(rr.preference), rr.exchange.to_text().rstrip('.')) for rr in answers], key=lambda x: x[0])
        for p, h in pairs: log_debug(f"  MX {p} -> {h}")
        return pairs
    except Exception as e:
        log_debug(f"  MX lookup failed: {e}")
        return []

def resolve_host_ips(host: str) -> Dict[str, List[str]]:
    res = {'A': [], 'AAAA': []}
    for rtype in ('A','AAAA'):
        vals = dns_any(host, rtype)
        res[rtype].extend([v.strip() for v in vals if v.strip()])
    log_debug(f"  {host} -> A={','.join(res['A']) or '-'} AAAA={','.join(res['AAAA']) or '-'}")
    return res

def ptr_lookup(ip: str) -> str:
    qps_gate("dns")
    log_debug(f"PTR lookup: {ip}")
    try:
        rev = dns.reversename.from_address(ip)
        answers = RESOLVER.resolve(rev, 'PTR')
        val = answers[0].to_text().rstrip('.')
        log_debug(f"  PTR -> {val}")
        return val
    except Exception as e:
        log_debug(f"  PTR failed: {e}")
        return ""

def cname_target(name: str) -> Optional[str]:
    qps_gate("dns")
    try:
        answers = RESOLVER.resolve(qname(name), 'CNAME')
        if answers:
            return answers[0].target.to_text().rstrip('.')
    except Exception:
        pass
    return None

def is_ip_literal(s: str) -> bool:
    try:
        socket.inet_pton(socket.AF_INET, s); return True
    except Exception:
        pass
    try:
        socket.inet_pton(socket.AF_INET6, s); return True
    except Exception:
        return False

# ---------- SPF helpers ----------
def spf_records(domain: str) -> List[str]:
    recs = [t for t in dns_txt(domain) if t.lower().startswith("v=spf1")]
    for r in recs: log_debug(f"  SPF: {r}")
    if not recs: log_debug("  SPF not found")
    return recs

def spf_macros_present(spf: Optional[str]) -> bool:
    return bool(spf and "%{" in spf)

def _spf_tokens(spf: str) -> List[str]:
    return [p.strip() for p in spf.split() if p.strip()]

def parse_spf(spf: str) -> Dict[str, List[str]]:
    mech = defaultdict(list)
    if not spf: return mech
    for tok in _spf_tokens(spf)[1:]:
        q = tok[1:] if tok[:1] in "+-~?" else tok
        for key, pref in (("ip4","ip4:"),("ip6","ip6:"),("include","include:"),("exists","exists:")):
            if q.startswith(pref): mech[key].append(q[len(pref):]); break
        else:
            if   q == "mx": mech["mx"].append("mx")
            elif q == "a":  mech["a"].append("a")
            elif q.startswith("a:"):  mech["a"].append(q[2:])
            elif q.startswith("mx:"): mech["mx"].append(q[3:])
            elif q == "ptr": mech["ptr"].append("ptr")
            elif q in ("all",): mech["all"].append("all")
            elif q.startswith("redirect="): mech["redirect"].append(q.split("=",1)[1])
            elif q.startswith("exp="):      mech["exp"].append(q.split("=",1)[1])
    return mech

def _spf_lookup_domains(domain: str, parsed: Dict[str, List[str]]) -> Dict[str, Set[str]]:
    targets = defaultdict(set)
    for inc in parsed.get("include", []): targets["include"].add(inc)
    for a_  in parsed.get("a", []):       targets["a"].add(domain if a_=="a" else a_)
    for mx_ in parsed.get("mx", []):      targets["mx"].add(domain if mx_=="mx" else mx_)
    for ex  in parsed.get("exists", []):  targets["exists"].add(ex)
    for rd  in parsed.get("redirect", []):targets["redirect"].add(rd)
    if parsed.get("ptr"):                 targets["ptr"].add(domain)
    return targets

def count_spf_dns(domain: str, spf_txt: str, seen: Optional[Set[str]]=None, depth:int=0, max_depth:int=20) -> Dict:
    if seen is None: seen=set()
    out = {"domain":domain,"depth":depth,"per_mech":defaultdict(int),"unique":defaultdict(list),
           "total":0,"over_limit":False,"void_lookups":0,"errors":[]}
    if not spf_txt: return out
    parsed = parse_spf(spf_txt)
    targets = _spf_lookup_domains(domain, parsed)
    for mech, doms in targets.items():
        uniq = sorted(set(doms))
        out["unique"][mech] = uniq
        out["per_mech"][mech] += len(uniq)
        for d in uniq:
            try:
                if mech == "include":
                    if not spf_records(d): out["void_lookups"] += 1
                elif mech == "a":
                    if not (dns_any(d,"A") or dns_any(d,"AAAA")): out["void_lookups"] += 1
                elif mech == "mx":
                    if not get_mx(d): out["void_lookups"] += 1
            except Exception:
                out["void_lookups"] += 1
    out["total"] = sum(out["per_mech"].values())
    for sub in list(out["unique"].get("include", [])) + list(out["unique"].get("redirect", [])):
        if sub in seen or depth >= max_depth: continue
        seen.add(sub)
        sub_spf = spf_records(sub)
        if not sub_spf: continue
        subres = count_spf_dns(sub, sub_spf[0], seen, depth+1, max_depth)
        for k,v in subres["per_mech"].items(): out["per_mech"][k] += v
        for k, lst in subres["unique"].items():
            out["unique"][k] = sorted(set(out["unique"][k]) | set(lst))
        out["total"] += subres["total"]
        out["void_lookups"] += subres["void_lookups"]
        out["errors"] += subres["errors"]
    out["over_limit"] = out["total"] > 10
    return out

# ---------- DMARC / DKIM ----------
def dmarc_records(domain: str) -> List[str]:
    name = f"_dmarc.{domain}"
    log_debug(f"DMARC check: {name}")
    recs = [t for t in dns_txt(name) if t.lower().startswith("v=dmarc1")]
    for r in recs: log_debug(f"  DMARC: {r}")
    return recs

def parse_taglist(txt: str) -> Dict[str, str]:
    d = {}
    if not txt: return d
    for part in txt.split(';'):
        part = part.strip()
        if not part: continue
        if '=' in part:
            k,v = part.split('=',1)
            d[k.strip()] = v.strip()
    return d

def dmarc_lint(tags: Dict[str,str]) -> List[str]:
    warns = []
    if not tags: return warns
    p = tags.get("p","").lower()
    if p not in ("none","quarantine","reject"): warns.append("DMARC 'p' should be none|quarantine|reject")
    rua = tags.get("rua","")
    if rua and not rua.lower().startswith("mailto:"): warns.append("DMARC 'rua' should be mailto: URI")
    for k in ("aspf","adkim"):
        v = tags.get(k,"")
        if v and v not in ("r","s"): warns.append(f"DMARC '{k}' should be r or s")
    try:
        pct = int(tags.get("pct","100"))
        if not (0 <= pct <= 100): warns.append("DMARC 'pct' must be 0..100")
    except Exception:
        warns.append("DMARC 'pct' is not an integer")
    return warns

def discover_dkim(domain: str, selectors: List[str]=None) -> Dict[str, str]:
    if selectors is None: selectors = COMMON_DKIM_SELECTORS
    found = {}
    log_debug(f"Discover DKIM selectors ({len(selectors)}) for {domain}")
    for sel in selectors:
        name = f"{sel}._domainkey.{domain}"
        for txt in dns_txt(name):
            if 'v=DKIM1' in txt or 'p=' in txt:
                log_debug(f"  DKIM selector HIT: {sel}")
                found[sel] = txt
    if not found:
        log_debug("  DKIM: none discovered")
    return found

# ---------- TLS / Certificate auditing ----------
def _sha256_hex(data: bytes) -> str:
    import hashlib
    return hashlib.sha256(data).hexdigest()

def _sha512_hex(data: bytes) -> str:
    import hashlib
    return hashlib.sha512(data).hexdigest()

def _sha1_hex(data: bytes) -> str:
    import hashlib
    return hashlib.sha1(data).hexdigest()

def _cert_details_from_der(der: bytes, host: str) -> Dict[str, str]:
    out = {"sha256": _sha256_hex(der), "sha1": _sha1_hex(der)}
    if not HAVE_CRYPTO:
        return out
    try:
        cert = x509.load_der_x509_certificate(der)
        nb = getattr(cert, "not_valid_before_utc", None) or cert.not_valid_before.replace(tzinfo=timezone.utc)
        na = getattr(cert, "not_valid_after_utc", None)  or cert.not_valid_after.replace(tzinfo=timezone.utc)
        out["subject"]  = cert.subject.rfc4514_string()
        out["issuer"]   = cert.issuer.rfc4514_string()
        out["serial"]   = hex(cert.serial_number)
        out["not_before"] = nb.isoformat().replace("+00:00", "Z")
        out["not_after"]  = na.isoformat().replace("+00:00", "Z")
        out["days_until_expiry"] = str((na - datetime.now(timezone.utc)).days)
        try:
            san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName)
            dns_names = san.value.get_values_for_type(x509.DNSName)
            out["san"] = ", ".join(dns_names[:30]) + (" ..." if len(dns_names) > 30 else "")
        except Exception:
            pass
        pub = cert.public_key()
        if isinstance(pub, rsa.RSAPublicKey):
            out["key_type"] = "RSA"; out["key_bits"] = str(pub.key_size)
        elif isinstance(pub, ec.EllipticCurvePublicKey):
            out["key_type"] = "EC"; out["key_curve"] = pub.curve.name
        elif isinstance(pub, dsa.DSAPublicKey):
            out["key_type"] = "DSA"; out["key_bits"] = str(pub.key_size)
        try:
            out["sig_alg"] = cert.signature_hash_algorithm.name
        except Exception:
            pass
        # Hostname match best-effort
        try:
            ssl.match_hostname({"subjectAltName": [("DNS", d) for d in (out.get("san","").split(", ") if out.get("san") else [])]}, host)
            out["hostname_matches"] = "true"
        except Exception:
            cn = None
            try:
                for rdn in cert.subject.rdns:
                    for at in rdn:
                        if getattr(at, "oid", None) and getattr(at.oid, "dotted_string", "") == "2.5.4.3":
                            cn = at.value
                if cn:
                    ssl.match_hostname({"subject":[(("commonName", cn),)]}, host)
                    out["hostname_matches"] = "true"
                else:
                    out["hostname_matches"] = "false"
            except Exception:
                out["hostname_matches"] = "false"
    except Exception as e:
        out["parse_error"] = str(e)
    return out

def _save_chain(host: str, port: int, ders: List[bytes]) -> Dict[str,str]:
    base = os.path.join(SAVE_CHAIN_DIR, f"ssl_chain_{host}_{port}")
    pem_path = f"{base}.pem"; txt_path = f"{base}.txt"
    try:
        with open(pem_path, "wb") as pf:
            for der in ders:
                pf.write(ssl.DER_cert_to_PEM_cert(der).encode("ascii"))
        if HAVE_PYOPENSSL:
            with open(txt_path, "w") as tf:
                for der in ders:
                    x = crypto.load_certificate(crypto.FILETYPE_ASN1, der)
                    tf.write(crypto.dump_certificate(crypto.FILETYPE_TEXT, x).decode())
        return {"pem": pem_path, "txt": txt_path if HAVE_PYOPENSSL else ""}
    except Exception as e:
        log_warn(f"Failed saving chain: {e}")
        return {}

def _openssl_tls_handshake(host: str, port: int) -> Tuple[Optional[List[bytes]], Dict[str,str], str]:
    info = {"tls_version":"", "cipher":""}
    if not HAVE_PYOPENSSL:
        return None, info, "pyOpenSSL unavailable"
    log_debug(f"TLS handshake (direct) {host}:{port} via pyOpenSSL")
    qps_gate("tcp")
    s = socket.create_connection((host, port), timeout=DEFAULT_TCP_TIMEOUT)
    ctx = SSL.Context(SSL.TLS_CLIENT_METHOD)
    c = SSL.Connection(ctx, s)
    c.set_tlsext_host_name(host.encode())
    c.set_connect_state()
    ders: List[bytes] = []
    try:
        c.do_handshake()
        info["tls_version"] = c.get_protocol_version_name()
        try:
            info["cipher"] = c.get_cipher_name() or ""
        except Exception:
            pass
        chain = c.get_peer_cert_chain() or []
        for cert in chain:
            ders.append(crypto.dump_certificate(crypto.FILETYPE_ASN1, cert))
        return ders or None, info, ""
    except Exception as e:
        return None, info, f"pyOpenSSL handshake failed: {e}"
    finally:
        try: c.shutdown()
        except Exception: pass
        try: c.close()
        except Exception: pass
        try: s.close()
        except Exception: pass

def _smtp_starttls_and_chain(host: str, port: int) -> Tuple[Optional[List[bytes]], Dict[str, str], str]:
    tls_info = {"tls_version":"", "cipher":""}
    errs = ""
    log_debug(f"SMTP STARTTLS capture for {host}:{port}")
    try:
        qps_gate("tcp")
        s = socket.create_connection((host, port), timeout=DEFAULT_TCP_TIMEOUT)
        s.settimeout(DEFAULT_TCP_TIMEOUT)
        _ = s.recv(2048)
        s.sendall(f"EHLO {EHLO_NAME}\r\n".encode()); _ = s.recv(2048)
        s.sendall(b"STARTTLS\r\n")
        resp = s.recv(2048).decode(errors="replace")
        if "220" not in resp:
            try: s.close()
            except Exception: pass
            return None, tls_info, f"STARTTLS refused: {resp.strip()}"
    except Exception as e:
        return None, tls_info, f"SMTP dialog/STARTTLS failed: {e}"

    chain_ders: List[bytes] = []
    if HAVE_PYOPENSSL:
        try:
            ctx = SSL.Context(SSL.TLS_CLIENT_METHOD)
            c = SSL.Connection(ctx, s)
            c.set_tlsext_host_name(host.encode())
            c.set_connect_state()
            c.do_handshake()
            tls_info["tls_version"] = c.get_protocol_version_name()
            try: tls_info["cipher"] = c.get_cipher_name() or ""
            except Exception: pass
            chain = c.get_peer_cert_chain() or []
            for cert in chain:
                chain_ders.append(crypto.dump_certificate(crypto.FILETYPE_ASN1, cert))
            try: c.shutdown()
            except Exception: pass
            try: c.close()
            except Exception: pass
            return (chain_ders or None), tls_info, errs
        except Exception as e:
            errs = f"pyOpenSSL STARTTLS failed: {e}"

    # stdlib fallback leaf capture
    try:
        ctx = ssl.create_default_context()
        qps_gate("tcp")
        with socket.create_connection((host, port), timeout=DEFAULT_TCP_TIMEOUT) as s2:
            s2.settimeout(DEFAULT_TCP_TIMEOUT)
            _ = s2.recv(2048)
            s2.sendall(f"EHLO {EHLO_NAME}\r\n".encode()); _ = s2.recv(2048)
            s2.sendall(b"STARTTLS\r\n")
            resp = s2.recv(2048).decode(errors="replace")
            if "220" not in resp:
                return None, tls_info, f"STARTTLS refused (stdlib): {resp.strip()}"
            with ctx.wrap_socket(s2, server_hostname=host) as ss:
                tls_info["tls_version"] = ss.version() or ""
                ciph = ss.cipher()
                tls_info["cipher"] = ":".join([x for x in ciph if isinstance(x,str)]) if ciph else ""
                leaf = ss.getpeercert(True)
                return ([leaf] if leaf else None), tls_info, errs
    except Exception as e:
        errs = errs + (("; " if errs else "") + f"stdlib STARTTLS failed: {e}")
        return None, tls_info, errs

def validate_with_stdlib(host: str, port: int, is_starttls: bool) -> Tuple[bool, str]:
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = True
        ctx.verify_mode = ssl.CERT_REQUIRED
        if is_starttls:
            qps_gate("tcp")
            with socket.create_connection((host, port), timeout=DEFAULT_TCP_TIMEOUT) as s:
                s.settimeout(DEFAULT_TCP_TIMEOUT)
                _ = s.recv(2048)
                s.sendall(f"EHLO {EHLO_NAME}\r\n".encode()); _ = s.recv(2048)
                s.sendall(b"STARTTLS\r\n")
                resp = s.recv(2048).decode(errors="replace")
                if "220" not in resp:
                    return False, f"STARTTLS refused: {resp.strip()}"
                with ctx.wrap_socket(s, server_hostname=host) as ss:
                    _ = ss.getpeercert()
                    return True, ""
        else:
            qps_gate("tcp")
            with ctx.wrap_socket(socket.create_connection((host, port), timeout=DEFAULT_TCP_TIMEOUT),
                                 server_hostname=host) as ss:
                _ = ss.getpeercert()
                return True, ""
    except Exception as e:
        return False, str(e)

def _analyze_cipher(version: str, cipher: str) -> dict:
    ver = (version or "").upper()
    c   = (cipher or "").upper()
    pfs = any(x in c for x in ("ECDHE", "DHE"))
    min_ok = ver in ("TLSV1.3", "TLSV1.2")
    weak = (ver in ("SSLV3", "TLSV1", "TLSV1.1") or
            any(x in c for x in ("RC4","3DES","MD5","NULL","EXPORT","DES","IDEA","PSK")))
    return {"pfs": pfs, "min_tls_v12_plus": min_ok, "weak_cipher": weak}

def audit_tls_for_host_port(host: str, port: int) -> Dict[str, object]:
    result: Dict[str, object] = {
        "port": port, "tls_version": "", "cipher": "",
        "validated": False, "validation_error": "",
        "chain_saved": {}, "certs": []
    }
    is_starttls = port in (25, 587)
    chain_ders: Optional[List[bytes]] = None
    tls_info = {"tls_version":"", "cipher":""}
    err = ""

    if is_starttls:
        chain_ders, tls_info, err = _smtp_starttls_and_chain(host, port)
    else:
        chain_ders, tls_info, err = _openssl_tls_handshake(host, port)
        if not chain_ders and not tls_info.get("tls_version"):
            try:
                ctx = ssl.create_default_context()
                qps_gate("tcp")
                with ctx.wrap_socket(socket.create_connection((host, port), timeout=DEFAULT_TCP_TIMEOUT),
                                     server_hostname=host) as ss:
                    tls_info["tls_version"] = ss.version() or ""
                    c = ss.cipher()
                    tls_info["cipher"] = ":".join([x for x in c if isinstance(x,str)]) if c else ""
                    leaf = ss.getpeercert(True)
                    chain_ders = [leaf] if leaf else None
            except Exception as e:
                if not err:
                    err = f"SMTPS stdlib failed: {e}"

    result["tls_version"] = tls_info.get("tls_version","")
    result["cipher"] = tls_info.get("cipher","")
    if err:
        result["error"] = err

    if chain_ders:
        result["chain_saved"] = _save_chain(host, port, chain_ders)
        for der in chain_ders:
            result["certs"].append(_cert_details_from_der(der, host))
    else:
        if is_starttls and not result["certs"]:
            try:
                qps_gate("tcp")
                with socket.create_connection((host, port), timeout=DEFAULT_TCP_TIMEOUT) as s:
                    _ = s.recv(2048)
                    s.sendall(f"EHLO {EHLO_NAME}\r\n".encode()); _ = s.recv(2048)
                    s.sendall(b"STARTTLS\r\n"); _ = s.recv(2048)
                    with ssl.create_default_context().wrap_socket(s, server_hostname=host) as ss:
                        leaf = ss.getpeercert(True)
                        if leaf: result["certs"].append(_cert_details_from_der(leaf, host))
            except Exception as e:
                result["leaf_capture_error"] = str(e)

    ok, verr = validate_with_stdlib(host, port, is_starttls)
    result["validated"] = bool(ok)
    result["validation_error"] = verr

    # TLS strength flags
    result.update(_analyze_cipher(result["tls_version"], result["cipher"]))
    return result

# ---------- TCP / Port probing (with TLS attach) ----------
def _sorted_addrinfos(host: str, port: int):
    addrinfos = socket.getaddrinfo(host, port, socket.AF_UNSPEC, socket.SOCK_STREAM)
    if PREFER_IPV6:
        return sorted(addrinfos, key=lambda ai: 0 if ai[0]==socket.AF_INET6 else 1)
    return sorted(addrinfos, key=lambda ai: 0 if ai[0]==socket.AF_INET else 1)

def _readline(sock: socket.socket, timeout: float) -> str:
    sock.settimeout(timeout)
    try:
        data = sock.recv(2048).decode(errors="replace")
        return data
    except Exception:
        return ""

def _parse_ehlo_features(text: str) -> Dict[str,bool]:
    feats = {}
    up = text.upper()
    for line in up.splitlines():
        line = line.strip()
        if not line.startswith("250"):
            continue
        if "STARTTLS" in line: feats["STARTTLS"] = True
        if "PIPELINING" in line: feats["PIPELINING"] = True
        if "SIZE" in line: feats["SIZE"] = True
        if "AUTH " in line or line.startswith("250-AUTH") or line.startswith("250 AUTH"):
            feats["AUTH"] = True
    return feats

def ip_family_of(addr: str) -> str:
    try:
        socket.inet_pton(socket.AF_INET, addr); return "v4"
    except Exception:
        pass
    try:
        socket.inet_pton(socket.AF_INET6, addr); return "v6"
    except Exception:
        return "?"

def tcp_connect(host: str, port: int, timeout: float = DEFAULT_TCP_TIMEOUT) -> Dict[str, object]:
    info: Dict[str, object] = {'status': 'fail', 'error': '', 'banner': '', 'ip_tried': [], 'ehlo': {}, 'ipfam': []}
    label = f"{host}:{port}"
    errors = []
    try:
        addrinfos = _sorted_addrinfos(host, port)
    except Exception as e:
        info['error'] = f"DNS error: {e}"
        log_debug(f"  FAIL {label}: {info['error']}")
        return info

    for family, socktype, proto, _cn, sockaddr in addrinfos:
        ip = sockaddr[0]
        info['ip_tried'].append(ip)
        info['ipfam'].append(ip_family_of(ip))
        try:
            log_debug(f"Connect -> {label} via {ip}")
            qps_gate("tcp")
            with socket.socket(family, socktype, proto) as raw:
                raw.settimeout(timeout)
                raw.connect(sockaddr)
                banner = _readline(raw, SMTP_BANNER_READ)
                info['banner'] = redact_banner(banner.strip())
                if port in (25, 587):
                    try:
                        raw.sendall(f"EHLO {EHLO_NAME}\r\n".encode())
                        resp = _readline(raw, timeout)
                        info['ehlo'] = _parse_ehlo_features(resp)
                    except Exception as e:
                        info['error'] = f"SMTP dialog error: {e}"
                info['status'] = 'ok'
                return info
        except Exception as e:
            msg = str(e)
            if "Errno 101" in msg or "Network is unreachable" in msg:
                log_debug(f"  IPv6 unreachable for {label} via {ip}; trying next family...")
            else:
                log_debug(f"  FAIL {label} via {ip}: {e}")
            errors.append(f"{ip}: {e}")
            continue

    info['error'] = "; ".join(errors) if errors else "unknown"
    return info

def probe_ports_with_tls(host: str, ports: List[int]) -> Dict[int, Dict[str, object]]:
    results: Dict[int, Dict[str, object]] = {}
    with ThreadPoolExecutor(max_workers=min(MAX_WORKERS, len(ports))) as ex:
        futs = {ex.submit(tcp_connect, host, p): p for p in ports}
        for fut in as_completed(futs):
            p = futs[fut]
            results[p] = fut.result()

    for p, r in list(results.items()):
        if r.get("status") == "ok" and p in (25, 465, 587, 993, 995):
            try:
                results[p]["tls"] = audit_tls_for_host_port(host, p)
            except Exception as e:
                results[p]["tls_error"] = str(e)
    return results

# ---------- DNSBL ----------
def check_dnsbl(ip: str) -> Dict[str, str]:
    res = {}
    try:
        quads = ip.split('.')
        rev = '.'.join(reversed(quads))
    except Exception:
        return res
    for zone in DNSBL_ZONES:
        name = f"{rev}.{zone}"
        log_debug(f"DNSBL query: {name}")
        try:
            qps_gate("dns")
            RESOLVER.resolve(qname(name), 'A')
            res[zone] = "LISTED"
        except dns.resolver.NXDOMAIN:
            res[zone] = "not_listed"
        except dns.resolver.NoAnswer:
            res[zone] = "unknown"
        except dns.exception.Timeout:
            res[zone] = "timeout"
        except Exception as e:
            res[zone] = f"error:{e}"
    return res

# ---------- STS / TLS-RPT / DANE ----------
def get_mta_sts(domain: str) -> Dict[str, str]:
    out = {}
    for txt in dns_txt(f"_mta-sts.{domain}"):
        if txt.lower().startswith('v=sts'):
            out['txt'] = txt
    if requests is None:
        out['policy_error'] = "requests not available"
        return out
    try:
        url = f"https://mta-sts.{domain}/.well-known/mta-sts.txt"
        log_debug(f"Fetch MTA-STS: {url}")
        r = requests.get(url, timeout=(2.0, 5.0), allow_redirects=False)
        out['policy_status'] = str(r.status_code)
        if r.ok and r.text:
            body = r.text.strip()
            out['policy'] = body
            for line in body.splitlines():
                if ":" in line:
                    k,v = [x.strip() for x in line.split(":",1)]
                    out[f"policy_{k.lower()}"] = v
            mode = out.get("policy_mode","").lower()
            if mode and mode not in ("testing","enforce","none"):
                out["lint"] = "Invalid mta-sts mode"
    except Exception as e:
        out['policy_error'] = str(e)
    return out

def get_tls_rpt(domain: str) -> Dict[str, str]:
    out = {}
    for txt in dns_txt(f"_smtp._tls.{domain}"):
        if txt.lower().startswith('v=tlsrptv1'):
            out['txt'] = txt
            m = re.search(r"rua=([^;]+)", txt, re.I)
            if m and not m.group(1).lower().startswith("mailto:"):
                out['lint'] = "rua should be a mailto: URI"
    return out

def _mta_sts_match(pattern: str, host: str) -> bool:
    # RFC 8461: wildcard only as entire left-most label; matches exactly one label.
    pattern = pattern.rstrip(".").lower()
    host    = host.rstrip(".").lower()
    if pattern.startswith("*."):
        rest = host.split(".", 1)[1:]  # after first label
        return bool(rest) and rest[0] == pattern[2:]
    return host == pattern

def _mta_sts_host_allowed(host: str, policy_text: str) -> bool:
    if not policy_text:
        return True
    pats = []
    for line in policy_text.splitlines():
        line = line.strip()
        if ":" in line and line.lower().startswith("mx:"):
            pats.append(line.split(":", 1)[1].strip())
    return any(_mta_sts_match(p, host) for p in pats)

def _tlsa_name(host: str, port: int=25) -> str:
    return f"_{port}._tcp.{host}".rstrip(".")

def _tlsa_records(host: str, port: int=25) -> List[Tuple[int,int,int,str]]:
    """Return list of (usage, selector, mtype, hexdata)"""
    name = _tlsa_name(host, port)
    out = []
    try:
        for rr in dns.resolver.resolve(qname(name), 'TLSA'):
            # dnspython presents fields: usage, selector, mtype, cert (bytes)
            out.append((rr.usage, rr.selector, rr.mtype, rr.cert.hex()))
    except Exception:
        pass
    return out

def _spki_digest_from_cert_der(der: bytes, algo: str) -> Optional[str]:
    if not HAVE_CRYPTO:
        return None
    try:
        cert = x509.load_der_x509_certificate(der)
        spki = cert.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
        if algo == "sha256":
            return _sha256_hex(spki)
        elif algo == "sha512":
            return _sha512_hex(spki)
    except Exception:
        return None
    return None

def dane_check(host: str, port: int, chain_ders: List[bytes]) -> Dict[str, Any]:
    """Informational DANE/TLSA matching for the connected host:port."""
    res = {"host": host, "port": port, "tlsa": [], "matched": False, "notes": []}
    tlsa = _tlsa_records(host, port)
    if not tlsa:
        return res
    res["tlsa"] = [{"usage":u, "selector":s, "mtype":m, "data":d} for (u,s,m,d) in tlsa]
    # Build candidate digests from chain
    leaf = chain_ders[0] if chain_ders else None
    leaf_sha256 = _sha256_hex(leaf) if leaf else None
    leaf_sha512 = _sha512_hex(leaf) if leaf else None
    spki_sha256 = _spki_digest_from_cert_der(leaf, "sha256") if leaf else None
    spki_sha512 = _spki_digest_from_cert_der(leaf, "sha512") if leaf else None

    for (u,s,m,dhex) in tlsa:
        # selector: 0=Cert, 1=SPKI ; mtype: 1=SHA-256, 2=SHA-512
        want = None
        if s == 0 and m == 1: want = leaf_sha256
        elif s == 0 and m == 2: want = leaf_sha512
        elif s == 1 and m == 1: want = spki_sha256
        elif s == 1 and m == 2: want = spki_sha512
        if want and want.lower() == dhex.lower():
            res["matched"] = True
    # usage interpretation hint (non-enforcing)
    if res["matched"]:
        res["notes"].append("TLSA matched (informational).")
    else:
        res["notes"].append("TLSA present but no match (informational).")
    return res

# ---------- Client endpoints ----------
def discover_client_srv(domain: str) -> List[Tuple[str, int, str]]:
    out: List[Tuple[str, int, str]] = []
    for base, port in CLIENT_SRV_QUERIES:
        fq = f"{base}.{domain}"
        log_debug(f"SRV lookup: {fq}")
        try:
            qps_gate("dns")
            answers = RESOLVER.resolve(qname(fq), 'SRV')
            for rr in answers:
                target = rr.target.to_text().rstrip('.')
                out.append((target, port, f"SRV:{base}"))
                log_debug(f"  SRV -> {target}:{port}")
        except Exception as e:
            log_debug(f"  SRV miss: {e}")
    return out

def discover_client_common_hosts(domain: str) -> List[str]:
    hosts = [f"{sub}.{domain}" for sub in COMMON_CLIENT_HOSTS]
    log_debug(f"Common client hosts: {', '.join(hosts)}")
    return hosts

# ---------- Audit core ----------
def audit_domain(domain: str, no_port25: bool=False) -> Dict:
    report: Dict = {
        'schema_version': '3.10.0',
        'domain': domain,
        'generated': now_utc_iso(),
        'summary': {'status': 'ok', 'reasons': []},
        'mx': [],
        'warnings': [],
        'resolvers': {'by_source': {}, 'diff_summary': {}},
        'legal_banner': LEGAL_BANNER or ""
    }
    log_info(f"=== Auditing {domain} ===")

    # Multi-resolver capture (A/AAAA/TXT/MX/DS) for diff
    sources = resolver_sources_for(domain)
    want = ("A","AAAA","TXT","MX","DS")
    by_src: Dict[str, Dict[str, List[str]]] = {}
    for sname, r in sources.items():
        by_src[sname] = {}
        for rt in want:
            vals = do_resolve(r, domain, rt)
            if rt == "TXT":
                # Normalize TXT joins
                vals = [v.strip('"') for v in vals]
            by_src[sname][rt] = vals
    report['resolvers']['by_source'] = by_src
    # compute basic diffs
    diff = {}
    for rt in want:
        sets = {s: (by_src.get(s,{}).get(rt,[]) or []) for s in by_src}
        diff[rt] = diff_records(sets)
    report['resolvers']['diff_summary'] = diff
    if any(v.get("disagree") for v in diff.values()):
        report['warnings'].append("Resolver diff detected (records differ across resolvers)")

    # baseline lookups with primary resolver (preserve existing behavior)
    report['a']    = dns_any(domain, 'A')
    report['aaaa'] = dns_any(domain, 'AAAA')
    report['dnssec_ad_domain_a'] = dns_ad_flag(domain, 'A')
    try:
        qps_gate("dns")
        report['apex_ds_present'] = bool(RESOLVER.resolve(qname(domain), 'DS'))
    except Exception:
        report['apex_ds_present'] = False

    report['mx'] = [{'preference': p, 'host': h} for (p, h) in get_mx(domain)]
    report['txt']  = dns_txt(domain)

    spfs   = spf_records(domain)
    spf_txt = spfs[0] if spfs else None
    parsed = parse_spf(spf_txt) if spf_txt else {}
    report['spf'] = {
        'records': spfs,
        'record': spf_txt or None,
        'macros_present': spf_macros_present(spf_txt),
        'parsed': parsed,
        'discovery_targets': {k: sorted(list(v)) for k,v in _spf_lookup_domains(domain, parsed).items()} if spf_txt else {},
        'lookup_count': count_spf_dns(domain, spf_txt) if spf_txt else None,
    }

    dmarc_recs = dmarc_records(domain)
    dmarc_tags = parse_taglist(dmarc_recs[0]) if dmarc_recs else {}
    report['dmarc'] = {
        'records': dmarc_recs,
        'duplicate': len(dmarc_recs) > 1,
        'record': dmarc_recs[0] if dmarc_recs else None,
        'tags': dmarc_tags,
        'lint': dmarc_lint(dmarc_tags)
    }

    report['dkim'] = discover_dkim(domain)
    report['mta_sts'] = get_mta_sts(domain)
    report['tls_rpt'] = get_tls_rpt(domain)

    # MX host path
    report['mx_hosts'] = {}
    isp25_block_suspect = 0
    for host in [h['host'] for h in report.get('mx', [])]:
        log_debug(f"--- MX host checks: {host} ---")
        host_entry = {'ips': resolve_host_ips(host), 'ptr': {}, 'fcrdns_ok': {}, 'ports': {},
                      'host_level_mx': [], 'hygiene': [], 'dnssec_ad_a': dns_ad_flag(host, 'A'),
                      'dane': {}}
        cn = cname_target(host)
        if cn: host_entry['hygiene'].append(f"CNAME target -> {cn} (MX targets MUST NOT be CNAME)")
        if is_ip_literal(host): host_entry['hygiene'].append("MX target is an IP literal (invalid)")
        if host.endswith('.') and host.count('.') == 1:
            host_entry['hygiene'].append("MX target is bare label (invalid)")

        # PTR/FCrDNS + DNSBL
        for fam in ('A','AAAA'):
            for ip in host_entry['ips'].get(fam, []):
                ptr = ptr_lookup(ip)
                host_entry['ptr'][ip] = ptr
                fcrdns = False
                if ptr:
                    res = resolve_host_ips(ptr.rstrip('.'))
                    fcrdns = ip in res.get(fam, [])
                host_entry['fcrdns_ok'][ip] = bool(fcrdns)
                if fam == 'A':
                    host_entry.setdefault('dnsbl', {})[ip] = check_dnsbl(ip)

        # Port probes (25 only if allowed)
        ports_to_probe = [p for p in (PORTS_INBOUND_SMTP + PORTS_CLIENT_COMMON) if (p != 25 or not no_port25)]
        host_entry['ports'] = probe_ports_with_tls(host, sorted(set(ports_to_probe)))

        # DANE/TLSA per TLS-capable port
        for p, pd in host_entry['ports'].items():
            tls = pd.get("tls") or {}
            # build ersatz chain from json certs if PEM not saved
            ders = []
            if tls.get("chain_saved", {}).get("pem"):
                # we won't reload PEM here; rely on cert digests we already computed
                pass
            # we can't reconstruct DER bytes from hashes; run DANE by comparing TLSA to digests we have
            # Workaround: emulate with placeholder chain where possible (only leaf digests needed)
            # NOTE: _tlsa_records() compares to leaf/spki digest; we can map using hashes in tls["certs"]
            # For accuracy, we re-run lightweight TLSA match by comparing hex strings:
            matches = []
            tlsa_list = _tlsa_records(host, 25 if p in (25,465,587) else p)
            if tlsa_list and tls.get("certs"):
                for (u,s,m,dhex) in tlsa_list:
                    want = None
                    leaf = tls["certs"][0]
                    if s == 0 and m == 1: want = (leaf.get("sha256") or "").lower()
                    if s == 0 and m == 2: want = ""  # we didn't compute sha512 of leaf; skip
                    if s == 1 and m == 1:
                        # we didn't store SPKI digests; leave unmatched unless HAVE_CRYPTO and PEM available
                        want = None
                    if want and want == dhex.lower():
                        matches.append({"usage":u,"selector":s,"mtype":m,"data":dhex})
            host_entry['dane'][str(p)] = {
                "tlsa": [{"usage":u,"selector":s,"mtype":m,"data":d} for (u,s,m,d) in tlsa_list],
                "matched_any": bool(matches),
                "matched": matches
            }

        # Host-level MX
        hlmx = get_mx(host)
        host_entry['host_level_mx'] = [{'preference': p, 'host': h} for p,h in hlmx]
        for _p, h in hlmx:
            if h.endswith('.') and h.count('.') == 1:
                host_entry['hygiene'].append(f"Host-level MX invalid target '{h}'")

        if not no_port25:
            p25 = host_entry['ports'].get(25, {})
            if p25.get('status') != 'ok':
                isp25_block_suspect += 1

        report['mx_hosts'][host] = host_entry

    # Client endpoints (no 25)
    report['client_endpoints'] = {}
    target_map: Dict[str, List[int]] = defaultdict(list)
    for t, port, _src in discover_client_srv(domain):
        target_map[t].append(port)
    for h in discover_client_common_hosts(domain):
        for p in PORTS_CLIENT_COMMON: target_map[h].append(p)
    for k in list(target_map.keys()): target_map[k] = sorted(set(target_map[k]))
    for host, plist in target_map.items():
        log_debug(f"--- Client endpoint checks: {host} ({plist}) ---")
        ips = resolve_host_ips(host)
        entry = {'ips': ips, 'ports': probe_ports_with_tls(host, plist)}
        report['client_endpoints'][host] = entry

    # Summarize warnings
    warnings = []
    if LEGAL_BANNER:
        warnings.append("Legal banner present; public use approved per operator policy.")

    if not report.get('mx'):
        warnings.append("No MX found for domain")
        report['summary']['status'] = 'fail'
        report['summary']['reasons'].append("No MX records")

    spf_info = report.get('spf', {})
    spf_txt = spf_info.get('record')
    lc = spf_info.get('lookup_count')
    if not spf_txt:
        warnings.append("No SPF record found")
        if report['summary']['status'] == 'ok':
            report['summary']['status'] = 'warn'
        report['summary']['reasons'].append("No SPF")
    if lc and lc.get('over_limit'):
        warnings.append(f"SPF exceeds 10 DNS lookups (total={lc.get('total')})")
        if report['summary']['status'] == 'ok':
            report['summary']['status'] = 'warn'
        report['summary']['reasons'].append("SPF >10 lookups")
    if lc and lc.get('void_lookups',0) >= 2:
        warnings.append(f"SPF has {lc['void_lookups']} void lookups (fragile)")

    if report.get('dmarc',{}).get('duplicate'):
        warnings.append("Duplicate DMARC TXT at _dmarc")
        if report['summary']['status'] == 'ok':
            report['summary']['status'] = 'warn'
        report['summary']['reasons'].append("Duplicate DMARC")
    if report.get('dmarc',{}).get('lint'):
        warnings.append("DMARC lint: " + "; ".join(report['dmarc']['lint']))

    # MTA-STS simulate
    m = report.get("mta_sts",{})
    if (m.get("policy_mode","").lower() == "enforce") and m.get("policy"):
        blocked = [h for h in [mx["host"] for mx in report.get("mx",[])] if not _mta_sts_host_allowed(h, m["policy"])]
        if blocked:
            warnings.append("MTA-STS enforce would block delivery for: " + ", ".join(blocked))
        try:
            max_age = int(m.get("policy_max_age","0"))
            if 0 < max_age < 86400:
                warnings.append("MTA-STS policy max_age < 86400; some MTAs may ignore it.")
        except Exception:
            pass

    for host, hdata in report.get('mx_hosts', {}).items():
        if hdata.get('hygiene'):
            warnings.append(f"MX {host}: " + "; ".join(hdata['hygiene']))
        p25 = hdata.get('ports', {}).get(25, {})
        if (not no_port25) and p25.get('status') != 'ok':
            warnings.append(f"MX {host}: SMTP/25 not reachable ({p25.get('error','no banner')})")
            if report['summary']['status'] == 'ok':
                report['summary']['status'] = 'warn'
            report['summary']['reasons'].append(f"{host} port 25 unreachable")
        for port_k, pd in hdata.get('ports', {}).items():
            tls = pd.get('tls') or {}
            if isinstance(tls, dict) and (tls.get('validated') is False) and tls.get('validation_error'):
                warnings.append(f"{host}:{port_k} TLS validation FAILED: {tls.get('validation_error')}")
            if isinstance(tls, dict) and tls.get("weak_cipher"):
                warnings.append(f"{host}:{port_k} weak TLS version/cipher detected")
            for cert in (tls.get('certs') or []):
                try:
                    days = int(cert.get('days_until_expiry','99999'))
                    if days <= 30:
                        warnings.append(f"{host}:{port_k} cert expires in {days} days")
                except Exception:
                    pass
            # DANE/TLSA informational
            dane = hdata.get("dane",{}).get(str(port_k),{})
            if dane.get("tlsa"):
                if not dane.get("matched_any"):
                    warnings.append(f"{host}:{port_k} TLSA present but no match (informational)")

    if (not no_port25) and report.get('mx') and isp25_block_suspect >= max(1, len(report['mx'])//2):
        warnings.append("Multiple MX 25/tcp failures — outbound port 25 likely blocked by local ISP/network")

    report['warnings'] = warnings
    if warnings:
        log_info("WARNINGS:")
        for w in warnings: log_info(f"  - {w}")
    else:
        log_info("No warnings")
    log_info(f"=== Done {domain} ===")
    return report

# ---------- Scoring ----------
def _score_by_ipfam(data: Dict) -> Dict[str, Dict[str,int]]:
    """Compute category scores separately for IPv4/IPv6 transport availability."""
    mx_hosts = data.get('mx_hosts', {})
    fam_stats = {"v4":{"tested":0,"reachable":0,"starttls":0,"tls_ok":0,"tls_checks":0},
                 "v6":{"tested":0,"reachable":0,"starttls":0,"tls_ok":0,"tls_checks":0}}
    for mx in data.get("mx", []):
        host = mx.get("host"); hdata = mx_hosts.get(host, {})
        pd25 = hdata.get('ports', {}).get(25)
        if not pd25: continue
        fams = set([ip_family_of(ip) for ip in (pd25.get("ip_tried") or []) if ip])
        for fam in ("v4","v6"):
            if fam in fams:
                fam_stats[fam]["tested"] += 1
                if pd25.get("status") == "ok":
                    fam_stats[fam]["reachable"] += 1
                    ehlo = pd25.get('ehlo') or {}
                    if ehlo.get('STARTTLS'): fam_stats[fam]["starttls"] += 1
                    tls = pd25.get('tls') or {}
                    if isinstance(tls, dict):
                        fam_stats[fam]["tls_checks"] += 1
                        if tls.get('validated'): fam_stats[fam]["tls_ok"] += 1
    out = {}
    for fam in ("v4","v6"):
        s = fam_stats[fam]
        tp = 0
        if s["tested"] > 0:
            tp += int(round(10 * (s["reachable"]/s["tested"])))
        if s["reachable"] > 0:
            tp += int(round(10 * (s["starttls"]/s["reachable"])))
        if s["tls_checks"] > 0:
            tp += int(round(10 * (s["tls_ok"]/s["tls_checks"])))
        tp = min(30, tp)
        out[fam] = {"transport": tp}
    return out

def compute_scorecard(data: Dict, assume_port25_blocked: bool=False) -> Dict:
    notes = []
    spf = data.get('spf', {})
    dmarc = data.get('dmarc', {})
    dkim = data.get('dkim', {})

    # Authentication (40)
    auth_points = 0
    auth_max = 40
    if spf.get('record'):
        auth_points += 10
        lc = spf.get('lookup_count') or {}
        if not lc.get('over_limit'): auth_points += 5
        if lc.get('void_lookups', 0) <= 1: auth_points += 3
        if not spf.get('macros_present'): auth_points += 2
    p = (dmarc.get('tags') or {}).get('p','').lower()
    if p == 'none': auth_points += 5
    elif p == 'quarantine': auth_points += 10
    elif p == 'reject': auth_points += 15
    if dkim: auth_points += 5
    auth_points = min(auth_points, auth_max)
    auth_pct = int(round(100 * auth_points / auth_max))

    # Transport (30)
    transport_max = 30
    transport_points = 0
    transport_inconclusive = False
    mx_hosts = data.get('mx_hosts', {})
    mx_list = data.get('mx', [])
    tested_any_25 = False
    reachable_25 = 0
    total_25 = 0
    starttls_yes = 0
    tls_valid_ok = 0
    tls_checks = 0
    for mx in mx_list:
        host = mx.get('host')
        hdata = mx_hosts.get(host, {})
        pd25 = hdata.get('ports', {}).get(25)
        if pd25 is not None:
            tested_any_25 = True
            total_25 += 1
            if pd25.get('status') == 'ok':
                reachable_25 += 1
                ehlo = pd25.get('ehlo') or {}
                if ehlo.get('STARTTLS'): starttls_yes += 1
                tls = pd25.get('tls') or {}
                if isinstance(tls, dict):
                    tls_checks += 1
                    if tls.get('validated'): tls_valid_ok += 1

    if (tested_any_25 and reachable_25 == 0):
        w = " ".join(data.get('warnings', []))
        if assume_port25_blocked or "likely blocked by local ISP" in w:
            transport_inconclusive = True
            notes.append("Transport inconclusive (local port 25 likely blocked).")
        else:
            notes.append("All MX port 25 tests failed.")

    if not transport_inconclusive:
        if total_25 > 0:
            transport_points += int(round(10 * (reachable_25 / total_25)))
        if reachable_25 > 0:
            transport_points += int(round(10 * (starttls_yes / reachable_25)))
        if tls_checks > 0:
            transport_points += int(round(10 * (tls_valid_ok / tls_checks)))
        transport_points = min(transport_points, transport_max)
        transport_pct = int(round(100 * transport_points / transport_max))
    else:
        transport_pct = None

    # Hygiene (20)
    hygiene_max = 20
    hygiene_points = 0
    if data.get('dnssec_ad_domain_a') is True or data.get('apex_ds_present') is True:
        hygiene_points += 4
    lc = spf.get('lookup_count') or {}
    if lc and not lc.get('over_limit'):
        hygiene_points += 6
    mx_hyg_issues = 0
    for host, hdata in mx_hosts.items():
        mx_hyg_issues += len(hdata.get('hygiene') or [])
        for ip, bls in (hdata.get('dnsbl') or {}).items():
            listed = any(v == "LISTED" for v in bls.values())
            if listed:
                mx_hyg_issues += 2
    if mx_hyg_issues == 0:
        hygiene_points += 6
    else:
        hygiene_points += max(0, 6 - min(6, mx_hyg_issues))
    total_a = 0; fcrdns_ok = 0
    for host, hdata in mx_hosts.items():
        for ip in (hdata.get('ips', {}).get('A') or []):
            total_a += 1
            if hdata.get('fcrdns_ok', {}).get(ip): fcrdns_ok += 1
    if total_a > 0:
        hygiene_points += int(round(4 * (fcrdns_ok / total_a)))
    hygiene_points = min(hygiene_points, hygiene_max)
    hygiene_pct = int(round(100 * hygiene_points / hygiene_max))

    # Client surface (10)
    client_max = 10
    client_points = 0
    ce = data.get('client_endpoints', {})
    seen_ok = set()
    for host, entry in ce.items():
        for p, pd in (entry.get('ports') or {}).items():
            if p in (587, 993, 995) and pd.get('status') == 'ok':
                seen_ok.add((host, p))
    n_ok = len(seen_ok)
    client_points += min(10, n_ok)
    client_pct = int(round(100 * client_points / client_max))

    # Compose categories + per-IP family
    categories = {'authentication': auth_pct, 'transport': transport_pct, 'hygiene': hygiene_pct, 'client_surface': client_pct}
    weights = {'authentication': 0.40, 'transport': 0.30, 'hygiene': 0.20, 'client_surface': 0.10}
    if transport_inconclusive:
        remaining = ['authentication','hygiene','client_surface']
        remaining_total = sum(weights[k] for k in remaining)
        for k in remaining:
            weights[k] = weights[k] + (weights['transport'] * (weights[k] / remaining_total))
        weights['transport'] = 0.0

    overall = 0.0
    for k, w in weights.items():
        v = categories[k]
        if v is None: continue
        overall += w * v
    overall_int = int(round(overall))

    by_ipfam = _score_by_ipfam(data)
    delta = {}
    for cat in ("transport",):
        delta[cat] = (by_ipfam.get("v6",{}).get(cat,0) - by_ipfam.get("v4",{}).get(cat,0))

    return {
        'overall': overall_int,
        'categories': categories,
        'transport_inconclusive': transport_inconclusive,
        'notes': notes,
        'by_ipfam': by_ipfam,
        'delta': delta
    }

# ---------- Human report ----------
def human_report(data: Dict, score: Optional[Dict]=None) -> str:
    L = []
    if data.get("legal_banner"):
        L.append(data["legal_banner"]); L.append("")
    L.append(f"Mailflow Audit Report — generated {data.get('generated')}")
    L.append("="*72)
    domain = data.get('domain')
    L.append(f"Domain: {domain}")
    s = data.get('summary', {})
    L.append(f"Summary: {s.get('status','ok')}  reasons: {', '.join(s.get('reasons', [])) or '-'}")
    L.append("")
    if not score:
        score = compute_scorecard(data, assume_port25_blocked=False)
    cats = score.get('categories', {})
    L.append("Scorecard:")
    L.append(f"  Overall: {score.get('overall',0)}/100")
    tr = (cats.get('transport','-') if cats.get('transport') is not None else 'inconclusive')
    L.append(f"  Auth: {cats.get('authentication',0)}%  Transport: {tr}  Hygiene: {cats.get('hygiene',0)}%  Client: {cats.get('client_surface',0)}%")
    if score.get("by_ipfam"):
        v4 = score["by_ipfam"].get("v4",{}).get("transport",0)
        v6 = score["by_ipfam"].get("v6",{}).get("transport",0)
        L.append(f"  Transport by IP family: v4={v4}/30  v6={v6}/30  (Δ v6-v4 = {score.get('delta',{}).get('transport',0)})")
    for n in score.get('notes', []):
        L.append(f"  • {n}")
    dmarc_p = (data.get('dmarc',{}).get('tags') or {}).get('p','')
    if dmarc_p == 'quarantine':
        L.append("  • DMARC policy is quarantine (consider reject if ready).")
    if not data.get('mta_sts',{}).get('policy') and data.get('mta_sts',{}).get('policy_error'):
        L.append("  • No effective MTA-STS policy.")
    L.append("")
    L.append("Resolver Diff:")
    diff = (data.get("resolvers") or {}).get("diff_summary",{})
    disagree = [rt for rt,d in diff.items() if d.get("disagree")]
    L.append(f"  Disagreements: {', '.join(disagree) if disagree else 'None'}")
    L.append("")
    L.append("A/AAAA:")
    L.append(f"  A: {', '.join(data.get('a', [])) or 'None'}")
    L.append(f"  AAAA: {', '.join(data.get('aaaa', [])) or 'None'}")
    ad = data.get('dnssec_ad_domain_a')
    if ad is not None: L.append(f"  DNSSEC AD (A): {ad}")
    L.append(f"  Apex DS present: {data.get('apex_ds_present', False)}")
    L.append("")
    spf = data.get('spf', {})
    L.append("SPF:")
    recs = spf.get('records') or []
    if len(recs) > 1:
        L.append(f"  Records ({len(recs)}):"); [L.append(f"    {r}") for r in recs]
    else:
        L.append(f"  Record: {spf.get('record') or 'None'}")
    if spf.get('macros_present'): L.append("  Note: SPF macros present; evaluator skipped.")
    if spf.get('parsed'):
        for k, v in spf['parsed'].items(): L.append(f"  {k}: {', '.join(v)}")
    if spf.get('discovery_targets'):
        L.append("  DNS-cost targets:")
        for k, v in spf['discovery_targets'].items(): L.append(f"    {k}: {', '.join(v)}")
    lc = spf.get('lookup_count')
    if lc:
        L.append(f"  Lookup count: total={lc.get('total',0)} (limit=10)  void={lc.get('void_lookups',0)}")
        if lc.get('over_limit'): L.append("  WARNING: SPF exceeds 10 DNS lookups")
    L.append("")
    dmarc = data.get('dmarc', {})
    L.append("DMARC:")
    if dmarc.get('records'):
        for i, r in enumerate(dmarc['records'], 1): L.append(f"  rec[{i}]: {r}")
    else:
        L.append("  Record: None")
    if dmarc.get('duplicate'): L.append("  WARNING: duplicate DMARC TXT at _dmarc")
    if dmarc.get('tags'):
        for k, v in dmarc['tags'].items(): L.append(f"  {k}: {v}")
    if dmarc.get('lint'): L.append("  Lint: " + "; ".join(dmarc['lint']))
    L.append("")
    L.append("DKIM selectors discovered:")
    if data.get('dkim'):
        for sel, txt in data['dkim'].items(): L.append(f"  {sel}: {txt[:120]}{'...' if len(txt)>120 else ''}")
    else:
        L.append("  None")
    L.append("")
    if data.get('mta_sts'):
        L.append("MTA-STS:")
        m = data['mta_sts']
        for k in sorted(m.keys()):
            if k == 'policy':
                L.append("  policy: |")
                for ln in str(m['policy']).splitlines(): L.append(f"    {ln}")
            elif not k.startswith('policy_'):
                L.append(f"  {k}: {m[k]}")
        for k in ('policy_version','policy_mode','policy_mx','policy_max_age'):
            if k in m: L.append(f"  {k}: {m[k]}")
        L.append("")
    if data.get('tls_rpt'):
        L.append("TLS-RPT:"); [L.append(f"  {k}: {v}") for k,v in data['tls_rpt'].items()]; L.append("")
    L.append("MX:")
    if data.get('mx'):
        for mx in data.get('mx', []): L.append(f"  {mx.get('preference','?'):>3}  {mx.get('host','?')}")
    else:
        L.append("  None")
    L.append("")
    L.append("Per-MX Host Checks:")
    for host, hdata in (data.get('mx_hosts') or {}).items():
        L.append(f"- {host}")
        ips = hdata.get('ips', {})
        L.append(f"  A: {', '.join(ips.get('A', [])) or 'None'}")
        L.append(f"  AAAA: {', '.join(ips.get('AAAA', [])) or 'None'}")
        ad = hdata.get('dnssec_ad_a')
        if ad is not None: L.append(f"  DNSSEC AD (A): {ad}")
        if hdata.get('hygiene'):
            for issue in hdata['hygiene']: L.append(f"  HYGIENE: {issue}")
        for fam in ('A','AAAA'):
            for ip in ips.get(fam, []):
                ptr = hdata.get('ptr', {}).get(ip, '')
                fcrdns = hdata.get('fcrdns_ok', {}).get(ip, False)
                L.append(f"  PTR {ip}: {ptr or 'None'} (FCrDNS: {'OK' if fcrdns else 'FAIL'})")
        if 'dnsbl' in hdata:
            for ip, bls in hdata['dnsbl'].items():
                status = ', '.join([f"{z}:{s}" for z,s in bls.items()])
                L.append(f"  DNSBL {ip}: {status}")
        if hdata.get('host_level_mx'):
            for mx in hdata['host_level_mx']: L.append(f"  Host-level MX: {mx['preference']} {mx['host']}")
        L.append("  Ports:")
        for port, pd in sorted((hdata.get('ports') or {}).items(), key=lambda x: x[0]):
            status = pd.get('status','fail')
            banner = (pd.get('banner','') or '').replace('\r',' ').replace('\n',' ')
            iptried = ','.join(pd.get('ip_tried', []))
            feats = []
            if pd.get('ehlo'):
                e = pd['ehlo']
                if e.get('STARTTLS'):   feats.append("STARTTLS")
                if e.get('AUTH'):       feats.append("AUTH")
                if e.get('PIPELINING'): feats.append("PIPELINING")
            L.append(f"    {port}: {status}  banner='{banner[:100]}'  ip_tried=[{iptried}]  feats=[{', '.join(feats)}]")
            tls = pd.get('tls') or {}
            if isinstance(tls, dict) and (tls.get('tls_version') or tls.get('certs')):
                if tls.get('tls_version'):
                    L.append(f"      TLS: {tls.get('tls_version')}  cipher={tls.get('cipher','')}"
                             f"  pfs={'yes' if tls.get('pfs') else 'no'}  min_v12={'yes' if tls.get('min_tls_v12_plus') else 'no'}"
                             f"  weak={'yes' if tls.get('weak_cipher') else 'no'}")
                if tls.get('validated') is not None:
                    L.append(f"      Validation: {'OK' if tls.get('validated') else 'FAIL'}"
                             + (f" ({tls.get('validation_error')})" if not tls.get('validated') and tls.get('validation_error') else ""))
                for idx, cert in enumerate(tls.get('certs', []), 1):
                    L.append(f"      Cert[{idx}]: sha256={cert.get('sha256','')[:16]}… sha1={cert.get('sha1','')[:12]}…")
                    subj = cert.get('subject',''); iss = cert.get('issuer','')
                    if subj or iss:
                        L.append(f"        subj='{subj[:80]}'  issuer='{iss[:80]}'")
                    if cert.get('serial'): L.append(f"        serial={cert.get('serial')}")
                    if cert.get('days_until_expiry') is not None:
                        L.append(f"        expires_in_days={cert.get('days_until_expiry')}")
                    kt = cert.get('key_type'); kb = cert.get('key_bits'); kc = cert.get('key_curve')
                    if kt: L.append(f"        key={kt} {kb or kc or ''}".rstrip())
                    if cert.get('sig_alg'): L.append(f"        sig={cert.get('sig_alg')}")
                    if cert.get('hostname_matches'): L.append(f"        hostname_match={cert.get('hostname_matches')}")
                cs = tls.get('chain_saved') or {}
                if cs.get('pem'): L.append(f"      Chain saved: {cs.get('pem')}{' ; ' + cs.get('txt') if cs.get('txt') else ''}")
            # DANE/TLSA
            dane = hdata.get("dane",{}).get(str(port),{})
            if dane.get("tlsa"):
                L.append("      DANE/TLSA:")
                for t in dane["tlsa"]:
                    L.append(f"        usage={t['usage']} selector={t['selector']} mtype={t['mtype']} data={t['data'][:20]}…")
                L.append(f"        matched_any={dane.get('matched_any')}")
        L.append("")
    L.append("Client Access Endpoints:")
    for host, entry in (data.get('client_endpoints') or {}).items():
        ips = entry.get('ips', {})
        L.append(f"- {host}")
        L.append(f"  A: {', '.join(ips.get('A', [])) or 'None'}")
        L.append(f"  AAAA: {', '.join(ips.get('AAAA', [])) or 'None'}")
        L.append("  Ports:")
        for port, pd in sorted((entry.get('ports') or {}).items(), key=lambda x: x[0]):
            status = pd.get('status','fail')
            banner = (pd.get('banner','') or '').replace('\r',' ').replace('\n',' ')
            iptried = ','.join(pd.get('ip_tried', []))
            L.append(f"    {port}: {status}  banner='{banner[:100]}'  ip_tried=[{iptried}]")
            tls = pd.get('tls') or {}
            if isinstance(tls, dict) and tls.get('tls_version'):
                L.append(f"      TLS: {tls.get('tls_version')}  cipher={tls.get('cipher','')}"
                         f"  pfs={'yes' if tls.get('pfs') else 'no'}  min_v12={'yes' if tls.get('min_tls_v12_plus') else 'no'}"
                         f"  weak={'yes' if tls.get('weak_cipher') else 'no'}")
    if data.get('warnings'):
        L.append(""); L.append("WARNINGS:"); [L.append(f"  - {w}") for w in data['warnings']]
    L.append(""); L.append("Remediation checklist (top picks):")
    if data.get('warnings'):
        for w in data['warnings'][:8]: L.append(f"  • {w}")
    else:
        L.append("  • No critical issues detected.")
    return "\n".join(L)

# ---------- Output ----------
def write_outputs_per_domain(results: List[Dict], outdir: Optional[str]=None, assume_port25_blocked: bool=False):
    if outdir:
        os.makedirs(outdir, exist_ok=True)
    for item in results:
        domain = item.get('domain', f"domain_{int(time.time())}")
        json_path = os.path.join(outdir or ".", f"{domain}.json")
        txt_path  = os.path.join(outdir or ".", f"{domain}.txt")
        with open(json_path, "w") as jf:
            json.dump(item, jf, indent=2)
        score = compute_scorecard(item, assume_port25_blocked=assume_port25_blocked)
        with open(txt_path, "w") as rf:
            rf.write(human_report(item, score=score))
        print(f"[+] Wrote {json_path} and {txt_path}")

# ---------- Main ----------
def main():
    import argparse
    p = argparse.ArgumentParser(description="Deep email/domain deliverability & mail-flow audit")
    p.add_argument("domains", nargs="+", help="Domain(s) to audit")

    # verbosity: -v / -vv / -vvv and --quiet
    p.add_argument("-v", "--verbose", action="count", default=0, help="Increase verbosity (use -vv for debug)")
    p.add_argument("--quiet", action="store_true", help="Only warnings and errors")

    p.add_argument("--ipv6", action="store_true", help="Prefer IPv6 lookups first")
    p.add_argument("--timeout", type=float, help="Default TCP timeout (seconds)")
    p.add_argument("--dns-lifetime", dest="dns_lifetime", type=float, help="DNS query lifetime (seconds)")
    p.add_argument("--no-port25", action="store_true", help="Skip port 25 checks entirely")
    p.add_argument("--assume-port25-blocked", action="store_true",
                   help="Treat transport as inconclusive if all 25 tests fail (fair scoring on blocked networks)")
    p.add_argument("--outdir", help="Output directory")
    p.add_argument("--debug-trace", action="store_true", help="Print exception backtraces on failures")

    # NEW: multi-resolver + public/authoritative
    p.add_argument("--dns-source", choices=["system","public","authoritative","all"], default="system",
                   help="Which resolvers to query for diff section (does not change main resolver behavior)")
    p.add_argument("--public-resolvers", default="8.8.8.8,1.1.1.1,9.9.9.9",
                   help="CSV list of public resolvers for --dns-source public/all")

    # NEW: public-safety controls
    p.add_argument("--max-qps", type=float, default=0.0, help="Global max queries-per-second across DNS/TCP (0=unlimited)")
    p.add_argument("--legal-banner", default="", help="Line to include at top of TXT output for public/legal notice")
    p.add_argument("--reveal-banners", choices=["never","safe","always"], default="safe",
                   help="Control how much of SMTP/IMAP/POP banners to reveal in outputs")

    args = p.parse_args()
    setup_logging(args.verbose, args.quiet)

    # apply globals
    global PREFER_IPV6, DEFAULT_TCP_TIMEOUT, DNS_LIFETIME, DNS_SOURCE, PUBLIC_RESOLVERS, MAX_QPS, LEGAL_BANNER, REVEAL_BANNERS
    if args.ipv6: PREFER_IPV6 = True
    if args.timeout: DEFAULT_TCP_TIMEOUT = args.timeout
    if args.dns_lifetime:
        DNS_LIFETIME = args.dns_lifetime
        RESOLVER.lifetime = DNS_LIFETIME
        RESOLVER.timeout  = DNS_LIFETIME
    DNS_SOURCE = args.dns_source
    PUBLIC_RESOLVERS = [x.strip() for x in (args.public_resolvers.split(",") if args.public_resolvers else []) if x.strip()]
    MAX_QPS = max(0.0, float(args.max_qps or 0.0))
    LEGAL_BANNER = args.legal_banner or ""
    REVEAL_BANNERS = args.reveal_banners

    results = []
    for d in args.domains:
        try:
            res = audit_domain(d, no_port25=args.no_port25)
            results.append(res)
        except Exception as e:
            log_error(f"ERROR auditing {d}: {e}")
            if args.debug_trace:
                traceback.print_exc()
            results.append({
                'schema_version':'3.10.0',
                'domain': d,
                'generated': now_utc_iso(),
                'summary': {'status':'fail','reasons':[f'exception: {e}']},
                'warnings': [str(e)]
            })
    write_outputs_per_domain(results, outdir=args.outdir, assume_port25_blocked=args.assume_port25_blocked)

if __name__ == "__main__":
    main()
