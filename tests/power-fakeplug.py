#!/usr/bin/env python3
"""A fake smart plug for kldload-power tests: shelly1 | shelly2 | tasmota.

Usage: FAKEPLUG_PASSWORD=pw power-fakeplug.py KIND PORT  (request log in CWD)
The password comes from the environment, not argv: an argv password showed
up in the gate's own ps check and read as a leak in the tool (2026-09-29).
Implements only what the vendor docs describe (see kldload-power's header):
shelly1 Basic auth, shelly2 RFC 7616 SHA-256 digest with user admin, tasmota
user/password in the query. Writes every request line (never the password)
to requests.log so a test can see what the tool sent.
"""
import base64, hashlib, json, os, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

KIND, PORT = sys.argv[1], int(sys.argv[2])
PASSWORD = os.environ.get("FAKEPLUG_PASSWORD", "")
NONCE = "abc123nonce"
state = {"on": False}


def h(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def deny(self, challenge):
        self.send_response(401)
        self.send_header("WWW-Authenticate", challenge)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def authed(self, q) -> bool:
        if not PASSWORD:
            return True
        a = self.headers.get("Authorization", "")
        if KIND == "shelly1":
            ok = a == "Basic " + base64.b64encode(f"admin:{PASSWORD}".encode()).decode()
            if not ok:
                self.deny('Basic realm="shelly"')
            return ok
        if KIND == "shelly2":
            if not a.startswith("Digest "):
                self.deny(f'Digest qop="auth", realm="shelly", nonce="{NONCE}", algorithm=SHA-256')
                return False
            f = {}
            for part in a[7:].split(","):
                k, _, v = part.strip().partition("=")
                f[k] = v.strip('"')
            ha1 = h(f"admin:shelly:{PASSWORD}")
            ha2 = h(f"GET:{f.get('uri','')}")
            want = h(f"{ha1}:{f.get('nonce')}:{f.get('nc')}:{f.get('cnonce')}:{f.get('qop')}:{ha2}")
            ok = f.get("username") == "admin" and f.get("response") == want
            if not ok:
                self.deny(f'Digest qop="auth", realm="shelly", nonce="{NONCE}", algorithm=SHA-256')
            return ok
        if KIND == "tasmota":
            ok = q.get("user", [""])[0] == "admin" and q.get("password", [""])[0] == PASSWORD
            if not ok:
                self.send_json(401, {"WARNING": "Need user=<username>&password=<password>"})
            return ok
        return False

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        with open("requests.log", "a") as lg:
            safe = {k: v for k, v in q.items() if k != "password"}
            lg.write(f"{u.path} {json.dumps(safe)}\n")
        if not self.authed(q):
            return
        if KIND == "shelly1" and u.path == "/relay/0":
            t = q.get("turn", [None])[0]
            if t in ("on", "off"):
                state["on"] = t == "on"
            return self.send_json(200, {"ison": state["on"], "has_timer": False})
        if KIND == "shelly2" and u.path == "/rpc/Switch.Set":
            was = state["on"]
            state["on"] = q.get("on", ["false"])[0] == "true"
            return self.send_json(200, {"was_on": was})
        if KIND == "shelly2" and u.path == "/rpc/Switch.GetStatus":
            return self.send_json(200, {"id": 0, "output": state["on"], "apower": 0})
        if KIND == "tasmota" and u.path == "/cm":
            cmd = q.get("cmnd", [""])[0].split()
            if len(cmd) == 2:
                state["on"] = cmd[1].lower() == "on"
            # a one-relay plug answers POWER, not POWER1 (SetOption26 off)
            return self.send_json(200, {"POWER": "ON" if state["on"] else "OFF"})
        self.send_json(404, {"error": "not found"})


HTTPServer(("127.0.0.1", PORT), H).serve_forever()
