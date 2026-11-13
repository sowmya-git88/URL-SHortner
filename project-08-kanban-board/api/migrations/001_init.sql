CREATE TABLE IF NOT EXISTS boards (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        STRING NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS columns (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    board_id  UUID NOT NULL REFERENCES boards(id) ON DELETE CASCADE,
    name      STRING NOT NULL,
    position  INT NOT NULL,
    INDEX idx_columns_board (board_id, position)
);

-- position is a FLOAT so a card can be moved between two others without renumbering
CREATE TABLE IF NOT EXISTS cards (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    column_id    UUID NOT NULL REFERENCES columns(id) ON DELETE CASCADE,
    title        STRING NOT NULL,
    description  STRING NOT NULL DEFAULT '',
    position     FLOAT8 NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    INDEX idx_cards_column (column_id, position)
);
