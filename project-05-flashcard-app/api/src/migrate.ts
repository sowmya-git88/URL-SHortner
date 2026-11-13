import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { sql } from "./db.js";

const dir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "migrations");

await sql`CREATE TABLE IF NOT EXISTS schema_migrations (filename TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())`;
const applied = new Set((await sql`SELECT filename FROM schema_migrations`).map((r) => r.filename as string));

for (const file of (await readdir(dir)).filter((f) => f.endsWith(".sql")).sort()) {
  if (applied.has(file)) {
    console.log(`skip   ${file}`);
    continue;
  }
  const body = await readFile(path.join(dir, file), "utf8");
  await sql.begin(async (tx) => {
    await tx.unsafe(body);
    await tx`INSERT INTO schema_migrations(filename) VALUES (${file})`;
  });
  console.log(`apply  ${file}`);
}
await sql.end();
console.log("migrations complete");
