#!/usr/bin/env python3
"""The demo storefront API: real SQL against real tables, no framework.

What it does, in order:
    1. Reads its identity (track, version, pod, node) from the environment so a
       response can prove WHICH replica answered.
    2. Opens a small connection pool to Postgres, retrying while the database
       finishes its first-boot initdb.
    3. Serves /api/* as JSON and everything else from the static bundle.
    4. Reports liveness without touching the database and readiness only when a
       query actually succeeds.

Why it exists: the previous demo pointed nginx at an empty document root and
called three unrelated pods a "full stack". Nothing queried the database, so
nothing could show that a blue/green cutover preserves data. This is small on
purpose -- the interesting part of the demo is the orchestration, not the app --
but every endpoint does real work against real rows.

I kept it to the standard library plus psycopg. A framework would add a build
step, a lockfile and a CVE feed to a file whose entire job is to SELECT from
four tables.

Inputs (all environment):
    DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD -- connection
    APP_TRACK    -- "blue" or "green"; drives the visible theme
    APP_VERSION  -- version string shown in the banner
    POD_NAME, NODE_NAME -- injected via the downward API
    LISTEN_PORT  -- default 8080
Outputs: JSON on /api/*, files on everything else, log lines on stdout.

Notes:
    - Readiness is a real query, not a TCP connect. A Postgres that is up but
      mid-initdb accepts connections and fails queries; gating on the connect
      alone sends traffic to a backend that 500s, which is precisely the bug a
      blue/green demo must not have.
    - Every query is parameterised. This code is a demo, which is exactly the
      kind of code people paste into something real.
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
from decimal import Decimal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import psycopg
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

STATIC_DIR = Path(__file__).parent / "static"
TRACK = os.environ.get("APP_TRACK", "blue")
VERSION = os.environ.get("APP_VERSION", "1.0.0")
POD = os.environ.get("POD_NAME", "unknown-pod")
NODE = os.environ.get("NODE_NAME", "unknown-node")
PORT = int(os.environ.get("LISTEN_PORT", "8080"))

CONNINFO = (
    f"host={os.environ.get('DB_HOST', 'postgres')} "
    f"port={os.environ.get('DB_PORT', '5432')} "
    f"dbname={os.environ.get('DB_NAME', 'shop')} "
    f"user={os.environ.get('DB_USER', 'shop')} "
    f"password={os.environ.get('DB_PASSWORD', 'shop')} "
    f"application_name=kldload-demo-{TRACK}"
)

# Request counters exposed at /metrics. A plain dict under a lock rather than a
# metrics library: this is four integers, and adding a dependency to the demo
# image to count them would be the wrong trade.
METRICS_LOCK = threading.Lock()
METRICS: dict[str, int] = {"requests": 0, "errors": 0, "orders": 0}


def bump(key: str, n: int = 1) -> None:
    """Increment a counter. Safe to call from any request thread."""
    with METRICS_LOCK:
        METRICS[key] = METRICS.get(key, 0) + n


MIME = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
}


def log(msg: str) -> None:
    """Write one line to stdout, unbuffered, so kubectl logs shows it at once."""
    print(f"[api/{TRACK}] {msg}", flush=True)


class Json(json.JSONEncoder):
    """Encode the types psycopg returns that json refuses on its own.

    Decimal becomes float only at the boundary -- the arithmetic upstream stays
    exact. Anything else unknown becomes its str(), which keeps a new column
    type from turning into a 500 on a demo stage.
    """

    def default(self, o: Any) -> Any:
        if isinstance(o, Decimal):
            return float(o)
        return str(o)


# The pool is created eagerly but opened lazily: Postgres is usually still
# running initdb when the first API pod starts, and a hard failure here would
# CrashLoop the deployment instead of letting readiness hold traffic back.
POOL = ConnectionPool(CONNINFO, min_size=1, max_size=8, open=False, timeout=5.0)


def wait_for_db(deadline_s: float = 300.0) -> bool:
    """Block until the database answers a real query, or the deadline passes.

    Returns True once a SELECT succeeds. Retries on every psycopg error rather
    than only on connection refusal, because "connected but the schema is not
    there yet" is the common case during first boot, not the rare one.
    """
    started = time.monotonic()
    delay = 0.5
    while time.monotonic() - started < deadline_s:
        try:
            with psycopg.connect(CONNINFO, connect_timeout=5) as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT 1 FROM shop.schema_version LIMIT 1")
                    cur.fetchone()
            log(f"database ready after {time.monotonic() - started:.1f}s")
            return True
        except Exception as exc:  # noqa: BLE001 - any failure means "not ready yet"
            log(f"waiting for database: {type(exc).__name__}: {exc}")
            time.sleep(delay)
            delay = min(delay * 1.5, 5.0)
    return False


def query(sql: str, args: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
    """Run one SELECT and return all rows as dicts. Raises on failure."""
    with POOL.connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(sql, args)
            return list(cur.fetchall())


def place_order(customer_id: int, product_id: int, quantity: int) -> dict[str, Any]:
    """Insert an order and its single line item inside ONE transaction.

    Writes exist in this demo for a reason: a cutover that preserves reads is
    unremarkable, while one where an order placed against blue is still there
    after green takes over is the whole point. Stock is decremented in the same
    transaction so a failure cannot leave the two disagreeing.
    """
    with POOL.connection() as conn:
        with conn.cursor(row_factory=dict_row) as cur:
            cur.execute(
                "SELECT price, stock FROM shop.products WHERE id = %s", (product_id,)
            )
            prod = cur.fetchone()
            if prod is None:
                raise ValueError(f"no such product: {product_id}")
            if prod["stock"] < quantity:
                raise ValueError(f"insufficient stock: {prod['stock']} < {quantity}")
            cur.execute(
                "INSERT INTO shop.orders (customer_id, status) VALUES (%s, 'placed') "
                "RETURNING id, placed_at",
                (customer_id,),
            )
            order = cur.fetchone()
            # RETURNING on a successful INSERT always yields a row.
            assert order is not None
            cur.execute(
                "INSERT INTO shop.order_items "
                "(order_id, product_id, quantity, unit_price) "
                "VALUES (%s, %s, %s, %s)",
                (order["id"], product_id, quantity, prod["price"]),
            )
            cur.execute(
                "UPDATE shop.products SET stock = stock - %s WHERE id = %s",
                (quantity, product_id),
            )
            return {"order_id": order["id"], "placed_at": order["placed_at"]}


class Handler(BaseHTTPRequestHandler):
    """One request. Routes /api/* to SQL and everything else to the bundle."""

    server_version = "kldload-demo"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        """Route access logs through log() so every line carries the track."""
        log(f"{self.address_string()} {fmt % args}")

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        # The banner reads these to show which replica served the page, which is
        # what makes a cutover visible in the browser rather than only in kubectl.
        self.send_header("X-Kldload-Track", TRACK)
        self.send_header("X-Kldload-Pod", POD)
        self.end_headers()
        self.wfile.write(body)
        bump("requests")
        if code >= 500:
            bump("errors")

    def _json(self, code: int, payload: Any) -> None:
        body = json.dumps(payload, cls=Json).encode()
        self._send(code, body, "application/json; charset=utf-8")

    def _identity(self) -> dict[str, str]:
        return {"track": TRACK, "version": VERSION, "pod": POD, "node": NODE}

    def do_GET(self) -> None:  # noqa: N802 - name mandated by BaseHTTPRequestHandler
        path = urlparse(self.path).path
        try:
            if path == "/healthz":
                # Deliberately does NOT touch the database: liveness answers
                # "is this process wedged", and killing the app because Postgres
                # is briefly down turns one outage into two.
                return self._send(200, b"ok\n", "text/plain; charset=utf-8")
            if path == "/readyz":
                query("SELECT 1")
                return self._send(200, b"ready\n", "text/plain; charset=utf-8")
            if path == "/api/version":
                rows = query(
                    "SELECT version, note, applied_at FROM shop.schema_version"
                )
                return self._json(200, {**self._identity(), "schema": rows})
            if path == "/api/products":
                return self._json(200, query(
                    "SELECT id, sku, name, category, price, stock FROM shop.products "
                    "ORDER BY category, name"
                ))
            if path == "/api/orders":
                return self._json(200, query(
                    "SELECT order_id, customer, city, status, total, items, placed_at "
                    "FROM shop.order_totals ORDER BY placed_at DESC LIMIT 25"
                ))
            if path == "/api/customers":
                return self._json(200, query(
                    "SELECT id, name, email, city FROM shop.customers ORDER BY id"
                ))
            if path == "/api/stats":
                rows = query(
                    "SELECT (SELECT count(*) FROM shop.products)  AS products, "
                    "       (SELECT count(*) FROM shop.customers) AS customers, "
                    "       (SELECT count(*) FROM shop.orders)    AS orders, "
                    "       (SELECT COALESCE(SUM(quantity * unit_price), 0) "
                    "          FROM shop.order_items)             AS revenue"
                )
                return self._json(200, {**self._identity(), **rows[0]})
            if path == "/metrics":
                # Prometheus text exposition, hand-rolled. The track and pod are
                # labels so a scrape can tell the two tracks apart during a
                # cutover, which is the only interesting thing to graph here.
                lbl = f'{{track="{TRACK}",pod="{POD}",version="{VERSION}"}}'
                with METRICS_LOCK:
                    snapshot = dict(METRICS)
                out = [
                    "# HELP kldload_demo_requests_total Responses served.",
                    "# TYPE kldload_demo_requests_total counter",
                    f"kldload_demo_requests_total{lbl} {snapshot['requests']}",
                    "# HELP kldload_demo_errors_total Responses that were 5xx.",
                    "# TYPE kldload_demo_errors_total counter",
                    f"kldload_demo_errors_total{lbl} {snapshot['errors']}",
                    "# HELP kldload_demo_orders_total Orders written to the database.",
                    "# TYPE kldload_demo_orders_total counter",
                    f"kldload_demo_orders_total{lbl} {snapshot['orders']}",
                    "# HELP kldload_demo_up Always 1 while the track is scraped.",
                    "# TYPE kldload_demo_up gauge",
                    f"kldload_demo_up{lbl} 1",
                ]
                body = ("\n".join(out) + "\n").encode()
                return self._send(200, body, "text/plain; version=0.0.4; charset=utf-8")
            return self._static(path)
        except Exception as exc:  # noqa: BLE001 - one bad request must not kill the server
            log(f"ERROR {path}: {type(exc).__name__}: {exc}")
            self._json(503, {"error": str(exc), "track": TRACK})

    def do_POST(self) -> None:  # noqa: N802 - name mandated by BaseHTTPRequestHandler
        path = urlparse(self.path).path
        if path != "/api/orders":
            return self._json(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(length) or b"{}")
            result = place_order(
                int(body.get("customer_id", 1)),
                int(body.get("product_id", 1)),
                int(body.get("quantity", 1)),
            )
            bump("orders")
            log(f"order {result['order_id']} placed")
            self._json(201, {**result, **self._identity()})
        except ValueError as exc:
            self._json(400, {"error": str(exc)})
        except Exception as exc:  # noqa: BLE001 - see do_GET
            log(f"ERROR POST {path}: {type(exc).__name__}: {exc}")
            self._json(503, {"error": str(exc), "track": TRACK})

    def _static(self, path: str) -> None:
        """Serve the bundle, resolving traversal attempts to a 403 not a leak."""
        rel = "index.html" if path in ("/", "") else path.lstrip("/")
        target = (STATIC_DIR / rel).resolve()
        if not str(target).startswith(str(STATIC_DIR.resolve())):
            return self._send(403, b"forbidden\n", "text/plain; charset=utf-8")
        if not target.is_file():
            return self._send(404, b"not found\n", "text/plain; charset=utf-8")
        ctype = MIME.get(target.suffix, "application/octet-stream")
        body = target.read_bytes()
        if target.suffix == ".html":
            # The theme is decided by the pod's env, so it has to be stamped into
            # the page at serve time; a static bundle cannot know its own track.
            body = body.replace(b"__TRACK__", TRACK.encode())
            body = body.replace(b"__VERSION__", VERSION.encode())
        self._send(200, body, ctype)


class Server(ThreadingHTTPServer):
    """Threaded so one slow query cannot stall the readiness probe.

    ThreadingHTTPServer already mixes in ThreadingMixIn; inheriting both as
    well makes the MRO unsolvable and raises at import time.
    """

    daemon_threads = True
    allow_reuse_address = True


def main() -> int:
    log(f"starting track={TRACK} version={VERSION} pod={POD} node={NODE}")
    if not wait_for_db():
        log("FATAL: database never became ready")
        return 1
    POOL.open()
    # Fail loudly here rather than on the first request: a pool that cannot warm
    # up is a misconfiguration, and CrashLoopBackOff names it far better than a
    # steady trickle of 503s does.
    POOL.wait(timeout=30.0)
    threading.current_thread().name = "main"
    srv = Server(("0.0.0.0", PORT), Handler)
    log(f"listening on :{PORT}")
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
