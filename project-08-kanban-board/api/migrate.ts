import { sql } from "./db.ts";

const dir = new URL("./migrations/", import.meta.url);
await sql`CREATE TABLE IF NOT EXISTS schema_migrations (filename STRING PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())`;
const applied = new Set((await sql`SELECT filename FROM schema_migrations`).map((r) => r.filename as string));

const files: string[] = [];
for await (const e of Deno.readDir(dir)) if (e.isFile && e.name.endsWith(".sql")) files.push(e.name);
files.sort();

for (const f of files) {
  if (applied.has(f)) {
    console.log(`skip   ${f}`);
    continue;
  }
  const body = await Deno.readTextFile(new URL(f, dir));
  for (const stmt of body.split(";").map((s) => s.trim()).filter(Boolean)) {
    await sql.unsafe(stmt);
  }
  await sql`INSERT INTO schema_migrations(filename) VALUES (${f})`;
  console.log(`apply  ${f}`);
}

const [{ n }] = await sql`SELECT count(*)::INT AS n FROM boards`;
if (n === 0) {
  const [b] = await sql`INSERT INTO boards(name) VALUES ('DevOps Roadmap (demo)') RETURNING id`;
  const cols = await sql`
    INSERT INTO columns(board_id, name, position)
    VALUES (${b.id}, 'Backlog', 1), (${b.id}, 'Doing', 2), (${b.id}, 'Done', 3)
    RETURNING id, name`;
  const byName = Object.fromEntries(cols.map((c) => [c.name, c.id]));
  await sql`
    INSERT INTO cards(column_id, title, description, position) VALUES
      (${byName.Backlog}, 'Learn PM2 cluster mode', 'pm2 start ecosystem.config.js', 1),
      (${byName.Backlog}, 'Encrypt .env backups', 'openssl enc -aes-256-cbc -pbkdf2', 2),
      (${byName.Doing},   'Configure logrotate', 'copytruncate vs create', 1),
      (${byName.Done},    'Install Deno', 'single binary in /usr/local/bin', 1)`;
  console.log("seeded demo board");
}
await sql.end();
console.log("migrations complete");
