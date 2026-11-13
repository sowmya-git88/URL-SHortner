import postgres from "postgres";

const url = process.env.DATABASE_URL;
if (!url) {
  console.error("FATAL DATABASE_URL is not set");
  process.exit(78);
}

// Supabase transaction pooler (pgbouncer, port 6543) does not support prepared statements.
export const sql = postgres(url, {
  max: Number(process.env.DB_POOL_MAX ?? 3),
  idle_timeout: 30,
  connect_timeout: 10,
  prepare: false,
  ssl: "require",
});
