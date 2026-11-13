// Project 05 — Flashcards API: Hono (TypeScript) on Node + Supabase Postgres.
import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { logger } from "hono/logger";
import { sql } from "./db.js";
import { review } from "./srs.js";

const app = new Hono();
const startedAt = Date.now();

app.use("/api/*", logger());

const mb = (n: number) => Math.round(n / 1048576);

app.get("/api/health", async (c) => {
  const mem = process.memoryUsage();
  try {
    await sql`SELECT 1`;
    return c.json({
      status: "ok", database: "supabase-postgres", db_ok: true, pid: process.pid,
      uptime_s: Math.round((Date.now() - startedAt) / 1000),
      memory_mb: { rss: mb(mem.rss), heap_used: mb(mem.heapUsed), heap_total: mb(mem.heapTotal) },
    });
  } catch (e) {
    return c.json({ status: "degraded", db_ok: false, error: (e as Error).message }, 503);
  }
});

app.get("/api/decks", async (c) => {
  const rows = await sql`
    SELECT d.id, d.name, d.created_at,
           count(cd.id)::int AS total,
           count(cd.id) FILTER (WHERE cd.due_at <= now())::int AS due
    FROM decks d LEFT JOIN cards cd ON cd.deck_id = d.id
    GROUP BY d.id ORDER BY d.id`;
  return c.json(rows);
});

app.post("/api/decks", async (c) => {
  const body = await c.req.json().catch(() => ({}));
  const name = String(body.name ?? "").trim();
  if (!name || name.length > 80) return c.json({ error: "name must be 1-80 chars" }, 400);
  const [deck] = await sql`INSERT INTO decks(name) VALUES (${name}) RETURNING *`;
  return c.json(deck, 201);
});

app.delete("/api/decks/:id", async (c) => {
  const r = await sql`DELETE FROM decks WHERE id = ${Number(c.req.param("id"))}`;
  return r.count ? c.body(null, 204) : c.json({ error: "not found" }, 404);
});

app.get("/api/decks/:id/cards", async (c) => {
  const rows = await sql`SELECT * FROM cards WHERE deck_id = ${Number(c.req.param("id"))} ORDER BY id`;
  return c.json(rows);
});

app.get("/api/decks/:id/due", async (c) => {
  const rows = await sql`
    SELECT * FROM cards WHERE deck_id = ${Number(c.req.param("id"))} AND due_at <= now()
    ORDER BY due_at LIMIT 20`;
  return c.json(rows);
});

app.post("/api/decks/:id/cards", async (c) => {
  const body = await c.req.json().catch(() => ({}));
  const front = String(body.front ?? "").trim();
  const back = String(body.back ?? "").trim();
  if (!front || !back) return c.json({ error: "front and back are required" }, 400);
  try {
    const [card] = await sql`
      INSERT INTO cards(deck_id, front, back) VALUES (${Number(c.req.param("id"))}, ${front}, ${back}) RETURNING *`;
    return c.json(card, 201);
  } catch {
    return c.json({ error: "deck not found" }, 404);
  }
});

app.post("/api/cards/:id/review", async (c) => {
  const id = Number(c.req.param("id"));
  const body = await c.req.json().catch(() => ({}));
  const grade = Number(body.grade);
  if (!Number.isInteger(grade) || grade < 0 || grade > 5) return c.json({ error: "grade must be 0-5" }, 400);
  const [card] = await sql`SELECT ease, interval_days, repetitions FROM cards WHERE id = ${id}`;
  if (!card) return c.json({ error: "not found" }, 404);
  const next = review(card as { ease: number; interval_days: number; repetitions: number }, grade);
  const dueExpr = next.interval_days === 0 ? sql`now() + interval '10 minutes'` : sql`now() + make_interval(days => ${next.interval_days})`;
  const [updated] = await sql`
    UPDATE cards SET ease = ${next.ease}, interval_days = ${next.interval_days},
                     repetitions = ${next.repetitions}, due_at = ${dueExpr}
    WHERE id = ${id} RETURNING *`;
  return c.json(updated);
});

app.delete("/api/cards/:id", async (c) => {
  const r = await sql`DELETE FROM cards WHERE id = ${Number(c.req.param("id"))}`;
  return r.count ? c.body(null, 204) : c.json({ error: "not found" }, 404);
});

// Teaching endpoint for the OOM lab: allocate N MB and hold it for 30 s. Disabled unless explicitly enabled.
app.post("/api/lab/allocate", async (c) => {
  if (process.env.ENABLE_MEMORY_LAB !== "1") return c.json({ error: "lab disabled" }, 403);
  const n = Math.min(Number(c.req.query("mb") ?? 50), 1024);
  const hog = Buffer.alloc(n * 1048576, 1);
  setTimeout(() => hog.length, 30000);
  return c.json({ allocated_mb: n, rss_mb: mb(process.memoryUsage().rss) });
});

app.onError((err, c) => {
  console.error(`ERROR ${c.req.method} ${c.req.path}: ${err.message}`);
  return c.json({ error: "internal error" }, 500);
});

const port = Number(process.env.PORT ?? 5005);
const hostname = process.env.HOST ?? "127.0.0.1";
const server = serve({ fetch: app.fetch, port, hostname }, (info) =>
  console.log(`INFO listening on http://${hostname}:${info.port} pid=${process.pid}`),
);

for (const sig of ["SIGTERM", "SIGINT"] as const) {
  process.on(sig, () => {
    console.log(`INFO ${sig} received, shutting down`);
    server.close(async () => {
      await sql.end({ timeout: 5 });
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 8000).unref();
  });
}
