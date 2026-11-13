// Project 03 — Habit tracker API (Express + MongoDB Atlas). Managed by a hand-written systemd unit.
import express from "express";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ObjectId } from "mongodb";
import { client, connect, getDb } from "./db.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 5003);
const HOST = process.env.HOST || "127.0.0.1";
const startedAt = Date.now();
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

const app = express();
app.disable("x-powered-by");
app.set("trust proxy", "loopback"); // Caddy is on 127.0.0.1
app.use(express.json({ limit: "16kb" }));

// one structured log line per request -> stdout -> journald
app.use((req, res, next) => {
  const t0 = process.hrtime.bigint();
  res.on("finish", () => {
    const ms = Number(process.hrtime.bigint() - t0) / 1e6;
    const level = res.statusCode >= 500 ? "ERROR" : res.statusCode >= 400 ? "WARN" : "INFO";
    console.log(`${level} ${req.method} ${req.originalUrl} ${res.statusCode} ${ms.toFixed(1)}ms ip=${req.ip}`);
  });
  next();
});

const today = () => new Date().toISOString().slice(0, 10);

function streak(checkins) {
  const set = new Set(checkins);
  let count = 0;
  const d = new Date();
  if (!set.has(today())) d.setUTCDate(d.getUTCDate() - 1); // streak may still be alive from yesterday
  while (set.has(d.toISOString().slice(0, 10))) {
    count += 1;
    d.setUTCDate(d.getUTCDate() - 1);
  }
  return count;
}

function shape(h) {
  const checkins = (h.checkins || []).slice().sort();
  return {
    id: h._id.toString(),
    name: h.name,
    color: h.color,
    createdAt: h.createdAt,
    checkins,
    doneToday: checkins.includes(today()),
    streak: streak(checkins),
    total: checkins.length,
  };
}

function oid(id) {
  return ObjectId.isValid(id) ? new ObjectId(id) : null;
}

app.get("/api/health", async (_req, res) => {
  try {
    await getDb().command({ ping: 1 });
    res.json({ status: "ok", database: "mongodb-atlas", db_ok: true, pid: process.pid,
      uptime_s: Math.round((Date.now() - startedAt) / 1000),
      rss_mb: Math.round(process.memoryUsage().rss / 1048576) });
  } catch (err) {
    console.error(`ERROR health ping failed: ${err.message}`);
    res.status(503).json({ status: "degraded", db_ok: false, error: err.message });
  }
});

app.get("/api/habits", async (_req, res, next) => {
  try {
    const rows = await getDb().collection("habits").find().sort({ createdAt: 1 }).toArray();
    res.json(rows.map(shape));
  } catch (e) { next(e); }
});

app.post("/api/habits", async (req, res, next) => {
  try {
    const name = String(req.body?.name || "").trim();
    const color = /^#[0-9a-fA-F]{6}$/.test(req.body?.color || "") ? req.body.color : "#22c55e";
    if (name.length < 1 || name.length > 60) return res.status(400).json({ error: "name must be 1-60 chars" });
    const doc = { name, color, checkins: [], createdAt: new Date() };
    const r = await getDb().collection("habits").insertOne(doc);
    res.status(201).json(shape({ ...doc, _id: r.insertedId }));
  } catch (e) {
    if (e.code === 11000) return res.status(409).json({ error: "habit already exists" });
    next(e);
  }
});

app.post("/api/habits/:id/toggle", async (req, res, next) => {
  try {
    const _id = oid(req.params.id);
    if (!_id) return res.status(400).json({ error: "bad id" });
    const date = DATE_RE.test(req.body?.date || "") ? req.body.date : today();
    const col = getDb().collection("habits");
    const habit = await col.findOne({ _id });
    if (!habit) return res.status(404).json({ error: "not found" });
    const op = habit.checkins?.includes(date) ? { $pull: { checkins: date } } : { $addToSet: { checkins: date } };
    const updated = await col.findOneAndUpdate({ _id }, op, { returnDocument: "after" });
    res.json(shape(updated));
  } catch (e) { next(e); }
});

app.delete("/api/habits/:id", async (req, res, next) => {
  try {
    const _id = oid(req.params.id);
    if (!_id) return res.status(400).json({ error: "bad id" });
    const r = await getDb().collection("habits").deleteOne({ _id });
    if (r.deletedCount === 0) return res.status(404).json({ error: "not found" });
    res.status(204).end();
  } catch (e) { next(e); }
});

app.use("/api", (_req, res) => res.status(404).json({ error: "no such endpoint" }));
app.use(express.static(path.join(__dirname, "public"), { maxAge: "1h" }));

// eslint-disable-next-line no-unused-vars
app.use((err, _req, res, _next) => {
  console.error(`ERROR unhandled: ${err.stack || err}`);
  res.status(500).json({ error: "internal error" });
});

let server;

async function main() {
  await connect();
  console.log("INFO connected to MongoDB");
  server = app.listen(PORT, HOST, () => console.log(`INFO listening on http://${HOST}:${PORT} pid=${process.pid}`));
}

async function shutdown(signal) {
  console.log(`INFO ${signal} received, closing HTTP server and Mongo pool`);
  const force = setTimeout(() => { console.error("ERROR forced exit after 8s"); process.exit(1); }, 8000);
  force.unref();
  server?.close(async () => {
    await client.close().catch(() => {});
    console.log("INFO shutdown complete");
    process.exit(0);
  });
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

main().catch((err) => {
  console.error(`FATAL startup failed: ${err.message}`);
  process.exit(1); // systemd Restart=on-failure takes over
});
