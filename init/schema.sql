-- =====================================================================
-- Grocery Operations Intelligence Platform — schema
-- =====================================================================

CREATE TABLE IF NOT EXISTS shelves (
    shelf_id      SERIAL PRIMARY KEY,
    name          TEXT NOT NULL,
    aisle         TEXT NOT NULL,
    linear_feet   NUMERIC(8,2) NOT NULL,        -- shelf space allocation
    category      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS vendors (
    vendor_id        SERIAL PRIMARY KEY,
    name             TEXT NOT NULL,
    category         TEXT NOT NULL,
    lead_time_days   INT NOT NULL DEFAULT 3,
    reliability      NUMERIC(4,3) NOT NULL DEFAULT 0.95
);

CREATE TABLE IF NOT EXISTS products (
    product_id     SERIAL PRIMARY KEY,
    sku            TEXT UNIQUE NOT NULL,
    name           TEXT NOT NULL,
    category       TEXT NOT NULL,
    shelf_id       INT REFERENCES shelves(shelf_id),
    vendor_id      INT REFERENCES vendors(vendor_id),
    unit_cost      NUMERIC(10,2) NOT NULL,       -- cost of goods
    unit_price     NUMERIC(10,2) NOT NULL,       -- retail price
    par_level      INT NOT NULL DEFAULT 40,      -- reorder threshold
    shelf_life_days INT NOT NULL DEFAULT 30
);

CREATE TABLE IF NOT EXISTS sales (
    sale_id        BIGSERIAL PRIMARY KEY,
    product_id     INT REFERENCES products(product_id),
    sale_date      DATE NOT NULL,
    units          INT NOT NULL,
    unit_price     NUMERIC(10,2) NOT NULL,       -- price at time of sale
    discount_pct   NUMERIC(5,2) NOT NULL DEFAULT 0,
    revenue        NUMERIC(12,2) NOT NULL,
    cogs           NUMERIC(12,2) NOT NULL,
    discount_program_id INT
);

CREATE TABLE IF NOT EXISTS inventory (
    inventory_id   BIGSERIAL PRIMARY KEY,
    product_id     INT REFERENCES products(product_id),
    on_hand        INT NOT NULL,
    received_date  DATE NOT NULL,
    expire_date    DATE NOT NULL,                -- expire dates on inventory
    snapshot_date  DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE IF NOT EXISTS vendor_deliveries (
    delivery_id    BIGSERIAL PRIMARY KEY,
    vendor_id      INT REFERENCES vendors(vendor_id),
    product_id     INT REFERENCES products(product_id),
    ordered_units  INT NOT NULL,
    received_units INT NOT NULL,
    order_date     DATE NOT NULL,
    delivery_date  DATE NOT NULL,
    on_time        BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS customer_feedback (
    feedback_id    BIGSERIAL PRIMARY KEY,
    feedback_date  DATE NOT NULL,
    category       TEXT,
    rating         INT NOT NULL,                 -- 1..5
    sentiment      NUMERIC(4,3) NOT NULL,        -- -1..1
    theme          TEXT,                         -- price/freshness/service/availability
    comment        TEXT
);

CREATE TABLE IF NOT EXISTS ad_programs (
    ad_id          SERIAL PRIMARY KEY,
    name           TEXT NOT NULL,
    channel        TEXT NOT NULL,                -- circular/digital/instore/radio
    category       TEXT,
    start_date     DATE NOT NULL,
    end_date       DATE NOT NULL,
    spend          NUMERIC(12,2) NOT NULL
);

CREATE TABLE IF NOT EXISTS discount_programs (
    discount_program_id SERIAL PRIMARY KEY,
    name           TEXT NOT NULL,
    category       TEXT,
    discount_pct   NUMERIC(5,2) NOT NULL,
    start_date     DATE NOT NULL,
    end_date       DATE NOT NULL
);

CREATE TABLE IF NOT EXISTS loss_events (
    loss_id        BIGSERIAL PRIMARY KEY,
    product_id     INT REFERENCES products(product_id),
    loss_date      DATE NOT NULL,
    units          INT NOT NULL,
    cause          TEXT NOT NULL,                -- expiry/damage/theft/markdown
    cost_value     NUMERIC(12,2) NOT NULL
);

-- Raw message log (everything the message-api produces lands here too)
CREATE TABLE IF NOT EXISTS message_log (
    msg_id         BIGSERIAL PRIMARY KEY,
    received_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    dataset        TEXT NOT NULL,
    msg_type       TEXT NOT NULL,                -- text/json/binary
    topic          TEXT NOT NULL,
    payload        JSONB,
    object_key     TEXT                          -- MinIO key for binaries
);

CREATE INDEX IF NOT EXISTS idx_sales_date ON sales(sale_date);
CREATE INDEX IF NOT EXISTS idx_sales_product ON sales(product_id);
CREATE INDEX IF NOT EXISTS idx_inventory_expire ON inventory(expire_date);
CREATE INDEX IF NOT EXISTS idx_feedback_date ON customer_feedback(feedback_date);
CREATE INDEX IF NOT EXISTS idx_loss_date ON loss_events(loss_date);
