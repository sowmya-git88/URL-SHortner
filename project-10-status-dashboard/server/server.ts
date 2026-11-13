// Project 10 — Status dashboard: Bun HTTP server + background checker.
// Two instances (blue :5010 / green :5011) run side by side during a deploy.
import postgres from "postgres";
import Redis from "ioredis";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const PORT = Number(process.env.PORT ?? 5010);
const COLOR = process.env.COLOR ?? "blue";
const VERSION = (() => {
  try { return readFileSync(join(import.meta.dir, "..", "VERSION"), "utf8").trim(); } catch { return "dev"; }
})();
const INTERVAL = Number(process.env.CHECK_INTERVAL_S ?? 60) * 1000;
const TIMEOUT = Number(process.env.CHECK_TIMEOUT_MS ?? 8000);
const WEB_DIST = join(import.meta.dir, "..", "web", "dist");
const startedAt = Date.now();

const sql = postgres(process.env.DATABASE_URL!, { max: 3, idle_timeout: 30, connect_timeout: 10, ssl: "require" });
const redis = new Redis(process.env.REDIS_URL!, { maxRetriesPerRequest: 2, enableReadyCheck: true, lazyConnect: false });
redis.on("error", (e) => console.error(`WARN redis: ${e.message}`));

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json", "x-served-by": `${COLOR}@${VERSION}` } });

// ---------------- background checker ----------------
type Monitor = { id: number; name: string; url: string };

async function checkOne(m: Monitor) {
  const t0 = performance.now();
  try {
    const res = await fetch(m.url, { method: "GET", redirect: "follow", signal: AbortSignal.timeout(TIMEOUT) });
    const latency = Math.round(performance.now() - t0);
    return { ok: res.status < 400, status_code: res.status, latency_ms: latency, error: null as string | null };
  } catch (e) {
    return { ok: false, status_code: null, latency_ms: Math.round(performance.now() - t0), error: (e as Error).message.slice(0, 200) };
  }
}

async function runChecks() {
  // Only ONE instance (blue or green) may run a cycle: Redis lock with expiry.
  const got = await redis.set("statusdash:lock:checker", `${COLOR}:${process.pid}`, "PX", INTERVAL - 1000, "NX").catch(() => null);
  if (got !== "OK") return;
  const monitors = await sql<Monitor[]>`SELECT id, name, url FROM monitors ORDER BY id`;
  const results = await Promise.all(monitors.map(async (m) => ({ m, r: await checkOne(m) })));
  for (const { m, r } of results) {
    await sql`INSERT INTO checks(monitor_id, ok, status_code, latency_ms, error)
              VALUES (${m.id}, ${r.ok}, ${r.status_code}, ${r.latency_ms}, ${r.error})`;
    await redis.set(`statusdash:latest:${m.id}`, JSON.stringify({ ...r, checked_at: new Date().toISOString() }), "EX", 3600);
  }
  // retention: keep 7 days of history (Neon free storage is small)
  await sql`DELETE FROM checks WHERE checked_at < now() - interval '7 days'`;
  console.log(`INFO ${COLOR} checked ${results.length} monitors (${results.filter((x) => !x.r.ok).length} down)`);
}

const timer = setInterval(() => runChecks().catch((e) => console.error(`ERROR checker: ${e.message}`)), INTERVAL);
setTimeout(() => runChecks().catch((e) => console.error(`ERROR checker: ${e.message}`)), 3000);

// ---------------- HTTP API ----------------
async function status() {
  const monitors = await sql<Array<Monitor & { uptime_24h: string | null; avg_latency: string | null }>>`
    SELECT m.id, m.name, m.url,
           round(100.0 * avg(CASE WHEN c.ok THEN 1 ELSE 0 END), 2) AS uptime_24h,
           round(avg(c.latency_ms)) AS avg_latency
    FROM monitors m
    LEFT JOIN checks c ON c.monitor_id = m.id AND c.checked_at > now() - interval '24 hours'
    GROUP BY m.id ORDER BY m.id`;
  const latest = monitors.length ? await redis.mget(...monitors.map((m) => `statusdash:latest:${m.id}`)) : [];
  return monitors.map((m, i) => ({
    ...m,
    uptime_24h: m.uptime_24h === null ? null : Number(m.uptime_24h),
    avg_latency: m.avg_latency === null ? null : Number(m.avg_latency),
    latest: latest[i] ? JSON.parse(latest[i] as string) : null,
  }));
}

async function api(req: Request, url: URL): Promise<Response> {
  const p = url.pathname;
  if (p === "/api/health") {
    const [db, rd] = await Promise.allSettled([sql`SELECT 1`, redis.ping()]);
    const ok = db.status === "fulfilled" && rd.status === "fulfilled";
    return json({
      status: ok ? "ok" : "degraded", color: COLOR, version: VERSION, pid: process.pid, bun: Bun.version,
      db_ok: db.status === "fulfilled", redis_ok: rd.status === "fulfilled",
      uptime_s: Math.round((Date.now() - startedAt) / 1000),
      rss_mb: Math.round(process.memoryUsage().rss / 1048576),
    }, ok ? 200 : 503);
  }
  if (p === "/api/status" && req.method === "GET") return json(await status());
  if (p === "/api/monitors" && req.method === "POST") {
    const b = await req.json().catch(() => ({}));
    const name = String(b.name ?? "").trim();
    const target = String(b.url ?? "").trim();
    if (!name || !/^https?:\/\/[^\s]+$/.test(target)) return json({ error: "name and http(s) url required" }, 400);
    try {
      const [m] = await sql`INSERT INTO monitors(name, url) VALUES (${name}, ${target}) RETURNING *`;
      return json(m, 201);
    } catch { return json({ error: "url already monitored" }, 409); }
  }
  let m = p.match(/^\/api\/monitors\/(\d+)$/);
  if (m && req.method === "DELETE") {
    const r = await sql`DELETE FROM monitors WHERE id = ${Number(m[1])}`;
    await redis.del(`statusdash:latest:${m[1]}`);
    return r.count ? new Response(null, { status: 204 }) : json({ error: "not found" }, 404);
  }
  m = p.match(/^\/api\/monitors\/(\d+)\/history$/);
  if (m && req.method === "GET") {
    return json(await sql`SELECT checked_at, ok, status_code, latency_ms, error FROM checks
                          WHERE monitor_id = ${Number(m[1])} ORDER BY checked_at DESC LIMIT 60`);
  }
  return json({ error: "no such endpoint" }, 404);
}

const server = Bun.serve({
  port: PORT,
  hostname: "127.0.0.1",
  async fetch(req) {
    const url = new URL(req.url);
    try {
      if (url.pathname.startsWith("/api/")) return await api(req, url);
      // Static frontend is versioned WITH the release (blue/green serve their own build)
      const file = url.pathname === "/" ? "index.html" : url.pathname.replace(/^\/+/, "");
      const path = join(WEB_DIST, file);
      if (!path.startsWith(WEB_DIST)) return new Response("forbidden", { status: 403 });
      if (existsSync(path) && !path.endsWith("/")) return new Response(Bun.file(path));
      return new Response(Bun.file(join(WEB_DIST, "index.html")));
    } catch (e) {
      console.error(`ERROR ${req.method} ${url.pathname}: ${(e as Error).message}`);
      return json({ error: "internal error" }, 500);
    }
  },
});
console.log(`INFO ${COLOR} v${VERSION} listening on http://127.0.0.1:${server.port} pid=${process.pid}`);

async function shutdown(sig: string) {
  console.log(`INFO ${COLOR} ${sig}: stop accepting, finish in-flight requests`);
  clearInterval(timer);
  await server.stop(false);           // false = let in-flight requests complete
  await Promise.allSettled([sql.end({ timeout: 5 }), redis.quit()]);
  console.log(`INFO ${COLOR} bye`);
  process.exit(0);
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
