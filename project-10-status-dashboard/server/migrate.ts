import postgres from "postgres";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const sql = postgres(process.env.DATABASE_URL!, { max: 1, ssl: "require", connect_timeout: 15 });
const dir = join(import.meta.dir, "migrations");

await sql`CREATE TABLE IF NOT EXISTS schema_migrations (filename TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())`;
const done = new Set((await sql`SELECT filename FROM schema_migrations`).map((r) => r.filename));
for (const f of readdirSync(dir).filter((x) => x.endsWith(".sql")).sort()) {
  if (done.has(f)) { console.log(`skip   ${f}`); continue; }
  await sql.begin(async (tx) => {
    await tx.unsafe(readFileSync(join(dir, f), "utf8"));
    await tx`INSERT INTO schema_migrations(filename) VALUES (${f})`;
  });
  console.log(`apply  ${f}`);
}
await sql.end();
console.log("migrations complete");
