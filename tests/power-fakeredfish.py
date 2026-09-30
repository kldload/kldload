#!/usr/bin/env python3
"""A Redfish BMC test double for kldload-power: one ComputerSystem, over HTTPS.

Usage: FAKERF_PASSWORD=pw power-fakeredfish.py PORT CERT KEY   (request log in CWD)

It implements what the DMTF Redfish ComputerSystem schema describes and
kldload-power uses: PowerState; Actions/#ComputerSystem.Reset with its
ResetType@Redfish.AllowableValues; the Boot override, where "Once" is consumed
by the next power-on and "Disabled" clears it. Basic authentication, user
"admin".

Why a double as well as sushy-tools: sushy's libvirt driver writes every
override as Continuous and rejects Disabled (its own source says so), so the
one-time boot -- the part a reinstall depends on -- cannot be tested against
it. This is the spec as I read it, not a vendor; the last word is `selftest
--cycle` on real hardware.

Switches (environment): FAKERF_NO_MODE=1 rejects BootSourceOverrideMode with
400 (older BMCs); FAKERF_LICENSE=1 answers everything 403 OemLicenseNotPassed
(Supermicro X11, abyss 2026-09-29); FAKERF_IGNORE_GRACEFUL=1 accepts a
GracefulShutdown and stays on (no OS to act on it).
"""
import base64
import json
import os
import ssl
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, CERT, KEY = int(sys.argv[1]), sys.argv[2], sys.argv[3]
PASSWORD = os.environ.get("FAKERF_PASSWORD", "")
SYS = "/redfish/v1/Systems/1"
RESET = SYS + "/Actions/ComputerSystem.Reset"
ALLOWED_RESET = ["On", "ForceOff", "GracefulShutdown", "ForceRestart", "PowerCycle"]
ALLOWED_TARGET = ["None", "Pxe", "Hdd", "Cd", "BiosSetup"]
st = {"power": "Off", "target": "None", "enabled": "Disabled", "mode": "UEFI", "boots": 0}


def env(k: str) -> bool:
    return os.environ.get(k) == "1"


class H(BaseHTTPRequestHandler):
    def log_message(self, *a: object) -> None:
        pass

    def reply(self, code: int, obj: object = None) -> None:
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        if obj is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def error(self, code: int, msg: str, msgid: str = "Base.1.8.GeneralError") -> None:
        self.reply(code, {"error": {"code": msgid, "message": msg,
                                    "@Message.ExtendedInfo": [{"MessageId": msgid, "Message": msg}]}})

    def gate(self) -> bool:
        with open("requests.log", "a") as lg:
            lg.write(f"{self.command} {self.path}\n")
        if env("FAKERF_LICENSE"):
            self.reply(403, {"error": {"code": "Base.v1_4_0.GeneralError", "Message": "A general error",
                                       "@Message.ExtendedInfo": [{
                                           "MessageId": "Base.v1_4_0.OemLicenseNotPassed",
                                           "Message": "Not licensed to perform this request. The "
                                                      "following licenses SUM DCMS OOB  were needed",
                                           "MessageArgs": ["SUM DCMS OOB "]}]}})
            return False
        want = "Basic " + base64.b64encode(f"admin:{PASSWORD}".encode()).decode()
        if self.headers.get("Authorization") != want:
            self.reply(401, {"error": {"code": "Base.1.8.InsufficientPrivilege", "message": "login"}})
            return False
        return True

    def system(self) -> dict:
        return {
            "@odata.id": SYS, "Id": "1", "PowerState": st["power"],
            "Boot": {"BootSourceOverrideTarget": st["target"],
                     "BootSourceOverrideEnabled": st["enabled"],
                     "BootSourceOverrideMode": st["mode"],
                     "BootSourceOverrideTarget@Redfish.AllowableValues": ALLOWED_TARGET},
            "Actions": {"#ComputerSystem.Reset": {
                "target": RESET, "ResetType@Redfish.AllowableValues": ALLOWED_RESET}},
        }

    def body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return {}

    def power_on(self) -> None:
        st["power"] = "On"
        st["boots"] += 1
        if st["enabled"] == "Once":  # a one-time override is spent by the boot it applies to
            st["enabled"], st["target"] = "Disabled", "None"

    def do_GET(self) -> None:
        if not self.gate():
            return
        if self.path == "/redfish/v1/":
            return self.reply(200, {"RedfishVersion": "1.6.0",
                                    "Systems": {"@odata.id": "/redfish/v1/Systems"}})
        if self.path == "/redfish/v1/Systems":
            return self.reply(200, {"Members": [{"@odata.id": SYS}], "Members@odata.count": 1})
        if self.path == SYS:
            return self.reply(200, self.system())
        self.error(404, "no such resource")

    def do_POST(self) -> None:
        if not self.gate():
            return
        if self.path != RESET:
            return self.error(404, "no such action")
        t = self.body().get("ResetType")
        if t not in ALLOWED_RESET:
            return self.error(400, f"ResetType {t} not allowed", "Base.1.8.ActionParameterValueNotInList")
        if t == "On":
            self.power_on()
        elif t == "ForceOff":
            st["power"] = "Off"
        elif t == "GracefulShutdown":
            if not env("FAKERF_IGNORE_GRACEFUL"):
                st["power"] = "Off"
        elif t in ("ForceRestart", "PowerCycle"):
            self.power_on()
        self.reply(204)

    def do_PATCH(self) -> None:
        if not self.gate():
            return
        if self.path != SYS:
            return self.error(404, "no such resource")
        boot = self.body().get("Boot") or {}
        if "BootSourceOverrideMode" in boot and env("FAKERF_NO_MODE"):
            return self.error(400, "BootSourceOverrideMode is read-only", "Base.1.8.PropertyNotWritable")
        t, e, m = (boot.get("BootSourceOverrideTarget"), boot.get("BootSourceOverrideEnabled"),
                   boot.get("BootSourceOverrideMode"))
        if t is not None and t not in ALLOWED_TARGET:
            return self.error(400, f"target {t}", "Base.1.8.PropertyValueNotInList")
        if e is not None and e not in ("Disabled", "Once", "Continuous"):
            return self.error(400, f"enabled {e}", "Base.1.8.PropertyValueNotInList")
        if m is not None and m not in ("UEFI", "Legacy"):
            return self.error(400, f"mode {m}", "Base.1.8.PropertyValueNotInList")
        if t is None and e is None and m is None:
            return self.error(400, "nothing to change", "Base.1.8.PropertyMissing")
        if t is not None:
            st["target"] = t
        if e is not None:
            st["enabled"] = e
            if e == "Disabled":
                st["target"] = "None"
        if m is not None:
            st["mode"] = m
        self.reply(204)


srv = HTTPServer(("127.0.0.1", PORT), H)
# a client that drops the handshake (a pinned-key mismatch) is a test case, not an error
srv.handle_error = lambda *_a: None  # type: ignore[method-assign]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(CERT, KEY)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
