-- Mounted into /docker-entrypoint-initdb.d by the Postgres StatefulSet (runs once, on an empty volume)
CREATE TABLE IF NOT EXISTS jobs (
    id            BIGSERIAL PRIMARY KEY,
    input         TEXT NOT NULL,
    status        TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','done','failed')),
    result        JSONB,
    error         TEXT,
    attempts      INT  NOT NULL DEFAULT 0,
    submitted_by  TEXT,
    processed_by  TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    started_at    TIMESTAMPTZ,
    finished_at   TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_jobs_queue ON jobs (status, id);

INSERT INTO jobs (input, submitted_by) VALUES
  ('Kubernetes schedules pods onto nodes and restarts them when probes fail', 'seed'),
  ('Ansible makes the laptop setup repeatable and idempotent', 'seed');
