"use strict";

// Shop API. Logs are plain stdout lines. No tracing or metrics library.

const http = require("http");
const crypto = require("crypto");
const { Pool } = require("pg");
const { createClient } = require("redis");

const port = Number(process.env.PORT || 8080);
const catalogURL = (process.env.CATALOG_URL || "http://catalog:8080").replace(/\/$/, "");
const databaseURL = process.env.DATABASE_URL;
const redisURL = process.env.REDIS_URL || "redis://redis:6379";

function log(level, fields) {
  const parts = [`level=${level}`, "service=shop"];
  for (const [key, value] of Object.entries(fields)) {
    const cleaned = String(value).replace(/[^A-Za-z0-9_.:/=-]/g, "_");
    parts.push(`${key}=${cleaned}`);
  }
  console.log(parts.join(" "));
}

function flagOn(name) {
  return ["1", "true", "on", "yes"].includes(String(process.env[name] || "").toLowerCase());
}

function send(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

async function readJSON(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  if (chunks.length === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

if (!databaseURL) {
  log("error", { msg: "startup_failed", error: "DATABASE_URL is required" });
  process.exit(1);
}

const db = new Pool({ connectionString: databaseURL });
const cache = createClient({
  url: redisURL,
  socket: { connectTimeout: 2000 },
});
cache.on("error", (err) => log("error", { msg: "redis", error: err.message }));

async function waitForPostgres() {
  for (let attempt = 1; attempt <= 60; attempt += 1) {
    try {
      await db.query("SELECT 1");
      return;
    } catch (err) {
      log("warn", { msg: "waiting_for_postgres", attempt, error: err.message });
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
  }
  throw new Error("postgres did not become ready");
}

async function cacheGet(key) {
  try {
    if (!cache.isOpen) return null;
    return await cache.get(key);
  } catch (err) {
    log("warn", { msg: "redis_get_failed", error: err.message });
    return null;
  }
}

async function cacheSet(key, value) {
  try {
    if (!cache.isOpen) return;
    await cache.set(key, value, { EX: 600 });
  } catch (err) {
    log("warn", { msg: "redis_set_failed", error: err.message });
  }
}

async function handle(req, res) {
  const started = Date.now();
  const url = new URL(req.url, "http://shop");
  let status = 500;

  try {
    if (req.method === "GET" && url.pathname === "/health") {
      status = 200;
      send(res, 200, { ok: true });
      return;
    }

    if (req.method === "GET" && url.pathname === "/products") {
      const upstream = await fetch(`${catalogURL}/products`, { signal: AbortSignal.timeout(10000) });
      const body = await upstream.json();
      status = upstream.status;
      send(res, status, body);
      return;
    }

    if (req.method === "POST" && url.pathname === "/orders") {
      if (flagOn("FORCE_ERROR")) {
        status = 500;
        send(res, 500, { error: "checkout failed" });
        return;
      }

      let input;
      try {
        input = await readJSON(req);
      } catch {
        status = 400;
        send(res, 400, { error: "invalid json" });
        return;
      }

      const sku = String(input.sku || "");
      const qty = Number(input.qty);
      if (!/^[a-z0-9-]{1,32}$/.test(sku) || !Number.isInteger(qty) || qty < 1 || qty > 10) {
        status = 400;
        send(res, 400, { error: "sku and qty (1-10) are required" });
        return;
      }

      const upstream = await fetch(`${catalogURL}/products/${sku}`, { signal: AbortSignal.timeout(10000) });
      if (upstream.status === 404) {
        status = 404;
        send(res, 404, { error: "unknown sku" });
        return;
      }
      if (!upstream.ok) {
        status = 502;
        send(res, 502, { error: "catalog unavailable" });
        return;
      }

      const product = await upstream.json();
      const id = crypto.randomUUID();
      await db.query("INSERT INTO orders (id, sku, qty) VALUES ($1, $2, $3)", [id, sku, qty]);
      const order = {
        id,
        sku,
        qty,
        name: product.name,
        total_cents: product.price_cents * qty,
      };
      await cacheSet(`order:${id}`, JSON.stringify(order));
      status = 201;
      send(res, 201, order);
      return;
    }

    const orderMatch = url.pathname.match(/^\/orders\/([0-9a-f-]{36})$/);
    if (req.method === "GET" && orderMatch) {
      const id = orderMatch[1];
      const cached = await cacheGet(`order:${id}`);
      if (cached) {
        status = 200;
        send(res, 200, JSON.parse(cached));
        return;
      }
      const result = await db.query(
        `SELECT o.id, o.sku, o.qty, p.name, p.price_cents
         FROM orders o
         JOIN products p ON p.sku = o.sku
         WHERE o.id = $1`,
        [id],
      );
      if (result.rowCount === 0) {
        status = 404;
        send(res, 404, { error: "unknown order" });
        return;
      }
      const row = result.rows[0];
      status = 200;
      send(res, 200, {
        id: row.id,
        sku: row.sku,
        qty: row.qty,
        name: row.name,
        total_cents: row.price_cents * row.qty,
      });
      return;
    }

    status = 404;
    send(res, 404, { error: "not found" });
  } catch (err) {
    status = 502;
    log("error", { msg: "request_failed", error: err.message });
    if (!res.headersSent) send(res, 502, { error: "upstream failed" });
  } finally {
    if (!(req.method === "GET" && url.pathname === "/health" && status === 200)) {
      const level = status >= 500 ? "error" : status >= 400 ? "warn" : "info";
      log(level, {
        method: req.method,
        path: url.pathname,
        status,
        duration_ms: Date.now() - started,
      });
    }
  }
}

async function main() {
  await waitForPostgres();
  try {
    await cache.connect();
  } catch (err) {
    log("warn", { msg: "redis_unavailable", error: err.message });
  }
  const server = http.createServer((req, res) => {
    handle(req, res).catch((err) => log("error", { msg: "unhandled", error: err.message }));
  });
  server.listen(port, "0.0.0.0", () => log("info", { msg: "listening", port }));
}

main().catch((err) => {
  log("error", { msg: "startup_failed", error: err.message });
  process.exit(1);
});
