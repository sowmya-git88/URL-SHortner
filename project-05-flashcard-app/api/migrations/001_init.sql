CREATE TABLE IF NOT EXISTS decks (
    id          BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 80),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- SM-2 spaced repetition fields: ease, interval_days, repetitions, due_at
CREATE TABLE IF NOT EXISTS cards (
    id             BIGSERIAL PRIMARY KEY,
    deck_id        BIGINT NOT NULL REFERENCES decks(id) ON DELETE CASCADE,
    front          TEXT NOT NULL,
    back           TEXT NOT NULL,
    ease           REAL NOT NULL DEFAULT 2.5,
    interval_days  INT  NOT NULL DEFAULT 0,
    repetitions    INT  NOT NULL DEFAULT 0,
    due_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_cards_due ON cards(deck_id, due_at);
