CREATE TABLE IF NOT EXISTS groups (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 80),
    currency    CHAR(3) NOT NULL DEFAULT 'INR',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS members (
    id        BIGSERIAL PRIMARY KEY,
    group_id  BIGINT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    name      TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 60),
    UNIQUE (group_id, name)
);

CREATE TABLE IF NOT EXISTS expenses (
    id            BIGSERIAL PRIMARY KEY,
    group_id      BIGINT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    paid_by       BIGINT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    description   TEXT NOT NULL,
    amount_cents  BIGINT NOT NULL CHECK (amount_cents > 0),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS expense_shares (
    expense_id   BIGINT NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
    member_id    BIGINT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    share_cents  BIGINT NOT NULL CHECK (share_cents >= 0),
    PRIMARY KEY (expense_id, member_id)
);

CREATE INDEX IF NOT EXISTS idx_expenses_group ON expenses(group_id);
CREATE INDEX IF NOT EXISTS idx_members_group  ON members(group_id);
