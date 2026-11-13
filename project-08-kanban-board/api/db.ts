import postgres from "postgres";

const url = Deno.env.get("DATABASE_URL");
if (!url) {
  console.error("FATAL DATABASE_URL is not set");
  Deno.exit(78);
}

// CockroachDB speaks the Postgres wire protocol, so a normal Postgres driver works.
export const sql = postgres(url, {
  max: Number(Deno.env.get("DB_POOL_MAX") ?? 3),
  idle_timeout: 30,
  connect_timeout: 10,
  // CockroachDB Cloud presents a publicly trusted certificate → full verification.
  // Set DB_SSL=require only for debugging (encrypts but skips certificate checks).
  ssl: (Deno.env.get("DB_SSL") ?? "verify-full") as "verify-full",
});

// CockroachDB uses SERIALIZABLE isolation: concurrent transactions may fail with
// SQLSTATE 40001 and must be retried by the client.
export async function withRetry<T>(fn: () => Promise<T>, attempts = 4): Promise<T> {
  for (let i = 1; ; i++) {
    try {
      return await fn();
    } catch (e) {
      const code = (e as { code?: string }).code;
      if (code !== "40001" || i >= attempts) throw e;
      await new Promise((r) => setTimeout(r, 50 * 2 ** i));
    }
  }
}
