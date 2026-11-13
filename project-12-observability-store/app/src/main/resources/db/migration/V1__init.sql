CREATE TABLE products (
    sku          TEXT PRIMARY KEY,
    name         TEXT NOT NULL,
    price_cents  INT  NOT NULL CHECK (price_cents > 0),
    stock        INT  NOT NULL CHECK (stock >= 0)
);

CREATE TABLE orders (
    id            BIGSERIAL PRIMARY KEY,
    customer      TEXT NOT NULL,
    sku           TEXT NOT NULL REFERENCES products(sku),
    quantity      INT  NOT NULL CHECK (quantity > 0),
    total_cents   INT  NOT NULL,
    status        TEXT NOT NULL DEFAULT 'CREATED',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    fulfilled_at  TIMESTAMPTZ
);
CREATE INDEX idx_orders_status ON orders(status);
