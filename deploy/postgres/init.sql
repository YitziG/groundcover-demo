CREATE TABLE products (
    sku TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    price_cents INT NOT NULL,
    stock INT NOT NULL
);

CREATE TABLE orders (
    id TEXT PRIMARY KEY,
    sku TEXT NOT NULL,
    qty INT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO products (sku, name, price_cents, stock) VALUES
    ('mug', 'Ceramic mug', 1200, 40),
    ('notebook', 'Grid notebook', 800, 25),
    ('pen', 'Black pen', 250, 100);
