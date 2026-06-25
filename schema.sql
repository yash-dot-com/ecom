-- =========================================================
-- E-COMMERCE DATABASE SCHEMA (PostgreSQL)
-- =========================================================
-- Scope: catalog, cart, orders, payments, auth, reviews, coupons
-- Indexing is intentionally left mostly for YOU to add as practice.
-- Look for "-- IDX:" comments — they mark columns that will be hit
-- hard by real queries (filters, sorts, FK lookups) and are good
-- candidates for indexes once you start tuning.
-- =========================================================

-- ---------- EXTENSIONS ----------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ---------- ENUMS ----------
-- Using real ENUM types instead of free-text VARCHAR for fixed value sets.
-- Tradeoff to know: adding a new value later requires ALTER TYPE ... ADD VALUE
-- (cheap, but can't run inside the same transaction as other DDL in old PG
-- versions). For values that legitimately grow over time (e.g. currency),
-- a lookup table is usually safer than an enum — included a note below.

CREATE TYPE product_status AS ENUM ('active', 'draft', 'archived');
CREATE TYPE cart_status AS ENUM ('active', 'converted', 'abandoned');
CREATE TYPE order_status_enum AS ENUM (
    'pending', 'paid', 'processing', 'shipped', 'delivered', 'cancelled', 'refunded'
);
CREATE TYPE payment_status AS ENUM ('pending', 'succeeded', 'failed', 'refunded');
CREATE TYPE shipment_status AS ENUM ('pending', 'shipped', 'in_transit', 'delivered');

-- Currency: enum works fine if you only ever support a handful of currencies
-- (which is true for most projects). If you expect to add many over time,
-- use a `currencies` lookup table instead — ISO 4217 has ~180 codes and an
-- enum makes "support a new currency" a schema migration instead of a row insert.
CREATE TYPE currency_code AS ENUM ('USD', 'EUR', 'GBP', 'INR');

-- ---------- USERS & AUTH ----------

CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name            VARCHAR(150) NOT NULL,
    email           VARCHAR(255) NOT NULL UNIQUE,   -- IDX: lookup on login
    password_hash   VARCHAR(255) NOT NULL,
    role            VARCHAR(20) NOT NULL DEFAULT 'customer', -- customer | admin | seller
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- For JWT refresh-token rotation / revocation practice
CREATE TABLE refresh_tokens (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE, -- IDX
    token_hash      VARCHAR(255) NOT NULL UNIQUE,
    revoked         BOOLEAN NOT NULL DEFAULT FALSE,
    expires_at      TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE addresses (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE, -- IDX
    type            VARCHAR(20) NOT NULL DEFAULT 'shipping', -- shipping | billing
    line1           VARCHAR(255) NOT NULL,
    line2           VARCHAR(255),
    city            VARCHAR(100) NOT NULL,
    state           VARCHAR(100),
    country         VARCHAR(100) NOT NULL,
    postal_code     VARCHAR(20) NOT NULL,
    is_default      BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- CATALOG ----------

CREATE TABLE categories (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name            VARCHAR(150) NOT NULL,
    slug            VARCHAR(170) NOT NULL UNIQUE,    -- IDX: used in product listing URLs
    parent_id       UUID REFERENCES categories(id) ON DELETE SET NULL, -- IDX: tree traversal
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE products (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    category_id     UUID NOT NULL REFERENCES categories(id), -- IDX: "list by category"
    name            VARCHAR(255) NOT NULL,
    slug            VARCHAR(280) NOT NULL UNIQUE,
    description     TEXT,
    brand           VARCHAR(150),
    status          product_status NOT NULL DEFAULT 'active',
    base_price      NUMERIC(10,2) NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- IDX: status is filtered on almost every storefront query (status='active')
-- IDX: created_at/base_price used for sorting ("newest", "price low-high")

-- Variants let you model size/color without duplicating product rows
CREATE TABLE product_variants (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id      UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE, -- IDX
    sku             VARCHAR(64) NOT NULL UNIQUE,     -- SKU = Stock Keeping Unit, a unique
                                                       -- code per sellable variant (e.g.
                                                       -- "TSHIRT-RED-M") used in warehouse/
                                                       -- inventory systems. IDX: lookup by SKU
    attributes      JSONB NOT NULL DEFAULT '{}',     -- e.g. {"size":"M","color":"Red"}
    price           NUMERIC(10,2) NOT NULL,
    compare_at_price NUMERIC(10,2),
    weight_grams    INTEGER,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE inventory (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    variant_id      UUID NOT NULL UNIQUE REFERENCES product_variants(id) ON DELETE CASCADE,
    quantity        INTEGER NOT NULL DEFAULT 0,      -- physically in stock
    reserved_qty    INTEGER NOT NULL DEFAULT 0,      -- held against in-progress checkouts
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT qty_non_negative CHECK (quantity >= 0),
    CONSTRAINT reserved_not_exceed_qty CHECK (reserved_qty <= quantity)
);

-- Tracks individual stock reservations so a background job can release
-- expired ones (e.g. checkout abandoned, payment never completed).
CREATE TABLE stock_reservations (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    variant_id      UUID NOT NULL REFERENCES product_variants(id), -- IDX
    order_id        UUID REFERENCES orders(id),                    -- set once order is created
    quantity        INTEGER NOT NULL CHECK (quantity > 0),
    status          VARCHAR(20) NOT NULL DEFAULT 'active', -- active | committed | released
    expires_at      TIMESTAMPTZ NOT NULL,             -- IDX: queue worker scans this
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE product_images (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id      UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE, -- IDX
    variant_id      UUID REFERENCES product_variants(id) ON DELETE CASCADE,
    url             VARCHAR(500) NOT NULL,
    position        SMALLINT NOT NULL DEFAULT 0
);

-- ---------- CART ----------

CREATE TABLE carts (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID REFERENCES users(id) ON DELETE CASCADE,  -- NULL for guest carts
    session_id      VARCHAR(255),                     -- IDX: lookup guest cart by session
    status          cart_status NOT NULL DEFAULT 'active',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE cart_items (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    cart_id         UUID NOT NULL REFERENCES carts(id) ON DELETE CASCADE, -- IDX
    variant_id      UUID NOT NULL REFERENCES product_variants(id),
    quantity        INTEGER NOT NULL CHECK (quantity > 0),
    price_snapshot  NUMERIC(10,2) NOT NULL,           -- price at time of adding
    added_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (cart_id, variant_id)
);

-- ---------- ORDERS ----------

CREATE TABLE orders (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id         UUID NOT NULL REFERENCES users(id), -- IDX: "my orders" lookup
    order_number    VARCHAR(30) NOT NULL UNIQUE,         -- human-friendly, IDX
    status          order_status_enum NOT NULL DEFAULT 'pending',
    subtotal        NUMERIC(10,2) NOT NULL,
    discount_total   NUMERIC(10,2) NOT NULL DEFAULT 0,
    tax_total        NUMERIC(10,2) NOT NULL DEFAULT 0,
    shipping_total   NUMERIC(10,2) NOT NULL DEFAULT 0,
    grand_total      NUMERIC(10,2) NOT NULL,
    currency         currency_code NOT NULL DEFAULT 'USD',
    shipping_address_id UUID REFERENCES addresses(id),
    billing_address_id  UUID REFERENCES addresses(id),
    placed_at        TIMESTAMPTZ NOT NULL DEFAULT now(),  -- IDX: sort/filter by date
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- IDX: status is filtered constantly (admin dashboards, "my pending orders")

CREATE TABLE order_items (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id        UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE, -- IDX
    variant_id      UUID NOT NULL REFERENCES product_variants(id),
    product_name_snapshot VARCHAR(255) NOT NULL, -- denormalized: survives product edits
    sku_snapshot    VARCHAR(64) NOT NULL,
    unit_price      NUMERIC(10,2) NOT NULL,
    quantity        INTEGER NOT NULL CHECK (quantity > 0),
    line_total      NUMERIC(10,2) NOT NULL
);

CREATE TABLE order_status_history (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id        UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE, -- IDX
    status          order_status_enum NOT NULL,
    note            VARCHAR(500),
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- PAYMENTS & SHIPMENTS ----------

CREATE TABLE payments (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id        UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE, -- IDX
    provider        VARCHAR(50) NOT NULL,             -- stripe | razorpay | paypal ...
    provider_payment_id VARCHAR(255) UNIQUE,          -- IDX: webhook reconciliation
    amount          NUMERIC(10,2) NOT NULL,
    currency        currency_code NOT NULL DEFAULT 'USD',
    status          payment_status NOT NULL DEFAULT 'pending',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE shipments (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id        UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE, -- IDX
    carrier         VARCHAR(100),
    tracking_number VARCHAR(100),
    status          shipment_status NOT NULL DEFAULT 'pending',
    shipped_at      TIMESTAMPTZ,
    delivered_at    TIMESTAMPTZ
);

-- ---------- COUPONS ----------

CREATE TABLE coupons (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    code            VARCHAR(50) NOT NULL UNIQUE,      -- IDX: lookup at checkout
    type            VARCHAR(20) NOT NULL,             -- percentage | fixed
    value           NUMERIC(10,2) NOT NULL,
    min_order_amount NUMERIC(10,2) DEFAULT 0,
    max_uses        INTEGER,
    used_count      INTEGER NOT NULL DEFAULT 0,
    starts_at       TIMESTAMPTZ,
    ends_at         TIMESTAMPTZ,
    active          BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE order_coupons (
    order_id        UUID NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
    coupon_id       UUID NOT NULL REFERENCES coupons(id),
    discount_amount NUMERIC(10,2) NOT NULL,
    PRIMARY KEY (order_id, coupon_id)
);

-- ---------- REVIEWS & WISHLIST ----------

CREATE TABLE reviews (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    product_id      UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE, -- IDX
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    rating          SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment         TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (product_id, user_id)   -- one review per user per product
);

CREATE TABLE wishlists (
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    variant_id      UUID NOT NULL REFERENCES product_variants(id) ON DELETE CASCADE,
    added_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, variant_id)
);