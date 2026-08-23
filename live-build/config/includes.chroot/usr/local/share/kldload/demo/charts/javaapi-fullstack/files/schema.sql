-- ---------------------------------------------------------------------------
-- schema.sql — the demo's database: real tables, real rows, real constraints.
--
-- What it does, in order:
--   1. Creates the storefront tables (products, customers, orders, order_items).
--   2. Adds the constraints and indexes a real schema would carry, so EXPLAIN
--      and \d show something worth looking at during a demo.
--   3. Seeds enough rows that every page renders with content and the stats
--      endpoint returns numbers that move when you place an order.
--   4. Records a schema_version row so the API can prove which migration ran.
--
-- WHY: the previous demo shipped Postgres with an empty data directory and a
-- web tier with no content, so "full stack" was three pods that talked to
-- nobody. A demo whose database has no schema cannot show a blue/green cutover
-- preserving data, which is the single most convincing thing about one.
--
-- Inputs:  none. Runs from /docker-entrypoint-initdb.d on first start only —
--          Postgres skips this entirely if the PVC already holds a cluster,
--          which is what makes the data survive a redeploy.
-- Outputs: schema `shop`, seeded and queryable.
--
-- Notes:
--   - Money is NUMERIC(10,2), never float. Float money is how you end up with
--     an order totalling 19.999999997.
--   - The seed is deterministic: same rows, same ids, every install. A demo
--     that shows different numbers each run makes people doubt the mechanism.
-- ---------------------------------------------------------------------------
BEGIN;

CREATE SCHEMA IF NOT EXISTS shop;
SET search_path TO shop, public;

-- Tracks which migration produced this database. The API surfaces it at
-- /api/version so a cutover can be shown to keep the SAME data underneath.
CREATE TABLE schema_version (
    version     integer     PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now(),
    note        text        NOT NULL
);

CREATE TABLE products (
    id          serial       PRIMARY KEY,
    sku         text         NOT NULL UNIQUE,
    name        text         NOT NULL,
    category    text         NOT NULL,
    price       numeric(10,2) NOT NULL CHECK (price >= 0),
    stock       integer      NOT NULL DEFAULT 0 CHECK (stock >= 0),
    created_at  timestamptz  NOT NULL DEFAULT now()
);
CREATE INDEX products_category_idx ON products (category);

CREATE TABLE customers (
    id          serial      PRIMARY KEY,
    name        text        NOT NULL,
    email       text        NOT NULL UNIQUE,
    city        text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE orders (
    id          serial      PRIMARY KEY,
    customer_id integer     NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    status      text        NOT NULL DEFAULT 'placed'
                            CHECK (status IN ('placed','shipped','delivered','cancelled')),
    placed_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX orders_customer_idx ON orders (customer_id);
CREATE INDEX orders_placed_idx   ON orders (placed_at DESC);

-- Line items carry their own unit_price: the price AT THE TIME OF SALE. Joining
-- to products.price for a historical order would silently rewrite past revenue
-- every time somebody edits a price.
CREATE TABLE order_items (
    id          serial       PRIMARY KEY,
    order_id    integer      NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    product_id  integer      NOT NULL REFERENCES products(id),
    quantity    integer      NOT NULL CHECK (quantity > 0),
    unit_price  numeric(10,2) NOT NULL CHECK (unit_price >= 0)
);
CREATE INDEX order_items_order_idx ON order_items (order_id);

-- A view so the API's hottest query is one plain SELECT rather than a join it
-- has to re-derive on every request.
CREATE VIEW order_totals AS
SELECT o.id            AS order_id,
       o.status,
       o.placed_at,
       c.name          AS customer,
       c.city,
       COALESCE(SUM(i.quantity * i.unit_price), 0)::numeric(10,2) AS total,
       COALESCE(SUM(i.quantity), 0)                               AS items
FROM orders o
JOIN customers c ON c.id = o.customer_id
LEFT JOIN order_items i ON i.order_id = o.id
GROUP BY o.id, o.status, o.placed_at, c.name, c.city;

-- ── Seed ────────────────────────────────────────────────────────────────────
INSERT INTO products (sku, name, category, price, stock) VALUES
  ('KLD-NAS-001', 'Mirrored NAS Bay',        'storage',   899.00, 12),
  ('KLD-NAS-002', 'RAIDZ2 Shelf, 8-bay',     'storage',  1749.50,  5),
  ('KLD-SSD-016', 'NVMe Cache Module 1TB',   'storage',   219.99, 40),
  ('KLD-NET-010', 'Ten-Gig Switch, 8-port',  'network',   549.00,  9),
  ('KLD-NET-011', 'Fibre Transceiver Pair',  'network',    89.00, 60),
  ('KLD-CPU-100', 'Compute Node, 32-core',   'compute',  2399.00,  3),
  ('KLD-CPU-101', 'Compute Node, 16-core',   'compute',  1299.00,  7),
  ('KLD-MEM-064', 'ECC Memory Kit 64GB',     'compute',   412.75, 25),
  ('KLD-PWR-002', 'Redundant PSU, 800W',     'power',     279.00, 18),
  ('KLD-RCK-042', 'Rack Rail Kit, 42U',      'power',      95.25, 30);

INSERT INTO customers (name, email, city) VALUES
  ('Ada Lovelace',    'ada@example.net',    'London'),
  ('Grace Hopper',    'grace@example.net',  'Arlington'),
  ('Ken Thompson',    'ken@example.net',    'Berkeley'),
  ('Radia Perlman',   'radia@example.net',  'Boston'),
  ('Barbara Liskov',  'barbara@example.net','Cambridge');

INSERT INTO orders (customer_id, status, placed_at) VALUES
  (1, 'delivered', now() - interval '9 days'),
  (2, 'shipped',   now() - interval '5 days'),
  (3, 'placed',    now() - interval '2 days'),
  (4, 'delivered', now() - interval '14 days'),
  (5, 'placed',    now() - interval '1 day'),
  (1, 'cancelled', now() - interval '20 days');

INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
  (1, 1, 1,  899.00), (1, 3, 2,  219.99),
  (2, 4, 1,  549.00), (2, 5, 4,   89.00),
  (3, 6, 1, 2399.00), (3, 8, 2,  412.75),
  (4, 2, 1, 1749.50), (4, 9, 2,  279.00),
  (5, 7, 3, 1299.00), (5,10, 1,   95.25),
  (6, 3, 1,  219.99);

INSERT INTO schema_version (version, note)
  VALUES (1, 'storefront baseline: products, customers, orders, order_items');

COMMIT;
