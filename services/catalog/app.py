#!/usr/bin/env python3
"""Product catalog. Stdout logs only. No tracing or metrics library."""

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg
import redis

PORT = int(os.environ.get("PORT", "8080"))
DATABASE_URL = os.environ.get("DATABASE_URL", "")
REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379/0")
# Stay under a small node if the cgroup limit is not enforced.
OOM_CAP_BYTES = 384 * 1024 * 1024
OOM_BLOCK_BYTES = 8 * 1024 * 1024


def log(level, **fields):
    parts = [f"level={level}", "service=catalog"]
    for key, value in fields.items():
        cleaned = "".join(ch if ch.isalnum() or ch in "_.:/=-" else "_" for ch in str(value))
        parts.append(f"{key}={cleaned}")
    print(" ".join(parts), flush=True)


def slow_ms():
    try:
        return max(0, int(os.environ.get("SLOW_DB_MS", "0")))
    except ValueError:
        return 0


def oom_requested():
    return os.environ.get("OOM", "0").lower() in {"1", "true", "on", "yes"}


def leak_until_killed():
    log("warn", msg="oom_mode", note="allocating_until_killed")
    chunks = []
    used = 0
    while used < OOM_CAP_BYTES:
        chunks.append(b"x" * OOM_BLOCK_BYTES)
        used += OOM_BLOCK_BYTES
    log("error", msg="oom_cap_reached", note="memory_limit_not_enforced_exiting")
    os._exit(137)


def query(sql, params=()):
    with psycopg.connect(DATABASE_URL, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            if cur.description is None:
                return []
            cols = [col.name for col in cur.description]
            return [dict(zip(cols, row)) for row in cur.fetchall()]


def wait_for_postgres():
    last = None
    for attempt in range(1, 61):
        try:
            query("SELECT 1")
            return
        except psycopg.Error as err:
            last = err
            log("warn", msg="waiting_for_postgres", attempt=attempt, error=err)
            time.sleep(2)
    raise last


cache = redis.Redis.from_url(
    REDIS_URL,
    decode_responses=True,
    socket_connect_timeout=1,
    socket_timeout=1,
)


def cache_get(key):
    try:
        return cache.get(key)
    except redis.RedisError as err:
        log("warn", msg="redis_get_failed", error=err)
        return None


def cache_set(key, value):
    try:
        cache.setex(key, 30, value)
    except redis.RedisError as err:
        log("warn", msg="redis_set_failed", error=err)


def read_products(sku=None):
    delay = slow_ms()
    if delay:
        query("SELECT pg_sleep(%s)", (delay / 1000,))
        log("warn", msg="slow_query", slow_db_ms=delay)

    if sku is None:
        cached = cache_get("products:all")
        if cached:
            return json.loads(cached)
        rows = query("SELECT sku, name, price_cents, stock FROM products ORDER BY sku")
        cache_set("products:all", json.dumps(rows))
        return rows

    cached = cache_get(f"product:{sku}")
    if cached:
        return json.loads(cached)
    rows = query(
        "SELECT sku, name, price_cents, stock FROM products WHERE sku = %s",
        (sku,),
    )
    if not rows:
        return None
    cache_set(f"product:{sku}", json.dumps(rows[0]))
    return rows[0]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _send(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        return status

    def do_GET(self):
        started = time.monotonic()
        path = self.path.split("?", 1)[0]
        status = 500
        try:
            if path == "/health":
                status = self._send(200, {"ok": True})
                return
            if path == "/products":
                status = self._send(200, {"products": read_products()})
                return
            if path.startswith("/products/"):
                sku = path[len("/products/") :]
                if not sku or "/" in sku:
                    status = self._send(400, {"error": "bad sku"})
                    return
                product = read_products(sku)
                if product is None:
                    status = self._send(404, {"error": "unknown sku"})
                    return
                status = self._send(200, product)
                return
            status = self._send(404, {"error": "not found"})
        except Exception as err:
            log("error", msg="request_failed", error=err)
            try:
                status = self._send(500, {"error": "catalog failed"})
            except Exception:
                status = 500
        finally:
            if not (path == "/health" and status == 200):
                level = "error" if status >= 500 else "warn" if status >= 400 else "info"
                log(
                    level,
                    method="GET",
                    path=path,
                    status=status,
                    duration_ms=int((time.monotonic() - started) * 1000),
                )


def main():
    if not DATABASE_URL:
        log("error", msg="startup_failed", error="DATABASE_URL is required")
        sys.exit(1)
    wait_for_postgres()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    if oom_requested():
        threading.Thread(target=leak_until_killed, daemon=True).start()
    log("info", msg="listening", port=PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
