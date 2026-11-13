CREATE TABLE IF NOT EXISTS monitors (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    url         TEXT NOT NULL UNIQUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS checks (
    id          BIGSERIAL PRIMARY KEY,
    monitor_id  INT NOT NULL REFERENCES monitors(id) ON DELETE CASCADE,
    checked_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ok          BOOLEAN NOT NULL,
    status_code INT,
    latency_ms  INT,
    error       TEXT
);
CREATE INDEX IF NOT EXISTS idx_checks_monitor_time ON checks(monitor_id, checked_at DESC);

INSERT INTO monitors(name, url) VALUES
  ('GitHub', 'https://github.com'),
  ('Cloudflare', 'https://www.cloudflare.com'),
  ('Neon status', 'https://neonstatus.com'),
  ('Example.com', 'https://example.com')
ON CONFLICT (url) DO NOTHING;
