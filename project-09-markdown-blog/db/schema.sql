-- Cloudflare D1 is SQLite. The API also runs this automatically at startup (idempotent).
CREATE TABLE IF NOT EXISTS posts (
    slug        TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    summary     TEXT NOT NULL DEFAULT '',
    body_md     TEXT NOT NULL,
    cover_key   TEXT,
    published   INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX IF NOT EXISTS idx_posts_created ON posts(created_at);
