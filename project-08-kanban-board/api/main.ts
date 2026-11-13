// Project 08 — Kanban API: Deno 2 + CockroachDB (Postgres wire protocol). Supervised by PM2.
import { sql, withRetry } from "./db.ts";

const startedAt = Date.now();
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
const UUID = "([0-9a-f-]{36})";

type Handler = (req: Request, params: string[]) => Promise<Response>;
const routes: Array<[string, RegExp, Handler]> = [];
const route = (method: string, pattern: string, h: Handler) => routes.push([method, new RegExp(`^${pattern}$`), h]);

async function body(req: Request): Promise<Record<string, unknown>> {
  try {
    return await req.json();
  } catch {
    return {};
  }
}

route("GET", "/api/health", async () => {
  try {
    const [{ v }] = await sql`SELECT version() AS v`;
    return json({
      status: "ok", database: "cockroachdb", db_ok: true, pid: Deno.pid,
      deno: Deno.version.deno, db_version: String(v).split(" ").slice(0, 3).join(" "),
      uptime_s: Math.round((Date.now() - startedAt) / 1000),
      rss_mb: Math.round(Deno.memoryUsage().rss / 1048576),
    });
  } catch (e) {
    return json({ status: "degraded", db_ok: false, error: (e as Error).message }, 503);
  }
});

route("GET", "/api/boards", async () =>
  json(await sql`SELECT id, name, created_at FROM boards ORDER BY created_at`));

route("POST", "/api/boards", async (req) => {
  const name = String((await body(req)).name ?? "").trim();
  if (!name || name.length > 80) return json({ error: "name must be 1-80 chars" }, 400);
  const board = await withRetry(() =>
    sql.begin(async (tx) => {
      const [b] = await tx`INSERT INTO boards(name) VALUES (${name}) RETURNING id, name, created_at`;
      await tx`INSERT INTO columns(board_id, name, position) VALUES
               (${b.id}, 'To do', 1), (${b.id}, 'In progress', 2), (${b.id}, 'Done', 3)`;
      return b;
    })
  );
  return json(board, 201);
});

route("DELETE", `/api/boards/${UUID}`, async (_req, [id]) => {
  const r = await sql`DELETE FROM boards WHERE id = ${id}`;
  return r.count ? new Response(null, { status: 204 }) : json({ error: "not found" }, 404);
});

route("GET", `/api/boards/${UUID}`, async (_req, [id]) => {
  const [board] = await sql`SELECT id, name FROM boards WHERE id = ${id}`;
  if (!board) return json({ error: "not found" }, 404);
  const columns = await sql`SELECT id, name, position FROM columns WHERE board_id = ${id} ORDER BY position`;
  const cards = await sql`
    SELECT c.id, c.column_id, c.title, c.description, c.position, c.updated_at
    FROM cards c JOIN columns col ON col.id = c.column_id
    WHERE col.board_id = ${id} ORDER BY c.position`;
  return json({
    ...board,
    columns: columns.map((col) => ({ ...col, cards: cards.filter((c) => c.column_id === col.id) })),
  });
});

route("POST", `/api/columns/${UUID}/cards`, async (req, [columnId]) => {
  const b = await body(req);
  const title = String(b.title ?? "").trim();
  if (!title || title.length > 140) return json({ error: "title must be 1-140 chars" }, 400);
  const [{ next }] = await sql`SELECT COALESCE(max(position), 0) + 1 AS next FROM cards WHERE column_id = ${columnId}`;
  try {
    const [card] = await sql`
      INSERT INTO cards(column_id, title, description, position)
      VALUES (${columnId}, ${title}, ${String(b.description ?? "")}, ${Number(next)}) RETURNING *`;
    return json(card, 201);
  } catch {
    return json({ error: "column not found" }, 404);
  }
});

route("PATCH", `/api/cards/${UUID}`, async (req, [id]) => {
  const b = await body(req);
  const [cur] = await sql`SELECT * FROM cards WHERE id = ${id}`;
  if (!cur) return json({ error: "not found" }, 404);
  const title = b.title !== undefined ? String(b.title).trim() : cur.title;
  const description = b.description !== undefined ? String(b.description) : cur.description;
  const columnId = b.column_id !== undefined ? String(b.column_id) : cur.column_id;
  const position = b.position !== undefined ? Number(b.position) : Number(cur.position);
  if (!title || !Number.isFinite(position)) return json({ error: "invalid title/position" }, 400);
  const [card] = await withRetry(() => sql`
    UPDATE cards SET title = ${title}, description = ${description}, column_id = ${columnId},
                     position = ${position}, updated_at = now()
    WHERE id = ${id} RETURNING *`);
  return json(card);
});

route("DELETE", `/api/cards/${UUID}`, async (_req, [id]) => {
  const r = await sql`DELETE FROM cards WHERE id = ${id}`;
  return r.count ? new Response(null, { status: 204 }) : json({ error: "not found" }, 404);
});

async function handler(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const t0 = performance.now();
  let res: Response = json({ error: "no such endpoint" }, 404);
  try {
    for (const [method, re, h] of routes) {
      const m = url.pathname.match(re);
      if (m && method === req.method) {
        res = await h(req, m.slice(1));
        break;
      }
    }
  } catch (e) {
    console.error(`ERROR ${req.method} ${url.pathname}: ${(e as Error).message}`);
    res = json({ error: "internal error" }, 500);
  }
  console.log(`${new Date().toISOString()} ${req.method} ${url.pathname} ${res.status} ${(performance.now() - t0).toFixed(1)}ms`);
  return res;
}

const port = Number(Deno.env.get("PORT") ?? 5008);
const hostname = Deno.env.get("HOST") ?? "127.0.0.1";
const ac = new AbortController();
const server = Deno.serve({ port, hostname, signal: ac.signal, onListen: () =>
  console.log(`INFO listening on http://${hostname}:${port} pid=${Deno.pid}`) }, handler);

// PM2 sends SIGINT by default on stop/restart (kill_timeout later escalates to SIGKILL)
for (const sig of ["SIGINT", "SIGTERM"] as const) {
  Deno.addSignalListener(sig, async () => {
    console.log(`INFO ${sig} received, draining`);
    ac.abort();
    await server.finished;
    await sql.end({ timeout: 5 });
    console.log("INFO bye");
    Deno.exit(0);
  });
}
