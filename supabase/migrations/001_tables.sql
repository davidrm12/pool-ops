-- =====================================================================
-- Cloro Diego · Backend v1 · 001 — Tables
-- Supabase (Postgres 15+). Money in MXN. Quantities in each product's
-- base unit (kg, L, pza). Code identifiers in English; the admin site
-- shows Spanish labels.
-- =====================================================================

-- ---------- Shared helpers -------------------------------------------

create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

-- ---------- Access: admin allowlist ----------------------------------
-- Only users listed here can read or write anything (see 003_security.sql).
-- Add rows from the Supabase SQL editor; the website cannot modify this table.

create table admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  created_at  timestamptz not null default now()
);

-- ---------- Catalog ---------------------------------------------------

create table products (
  id             bigint generated always as identity primary key,
  name           text not null unique,                   -- "Cloro granular"
  category       text not null default 'otro' check (category in
                   ('cloro','alguicida','clarificador','ph','sal','prueba','abrillantador','accesorio','otro')),
  base_unit      text not null check (base_unit in ('kg','L','pza')),
  unit_cost      numeric(10,2),                          -- avg cost per base unit; updated by purchases
  reorder_point  numeric(10,2),                          -- alert when stock <= this
  reorder_qty    numeric(10,2),                          -- suggested purchase size
  supplier_id    bigint,                                 -- preferred supplier (FK added below)
  description    text,                                   -- usage instructions / website copy
  active         boolean not null default true,          -- deactivate instead of deleting once sold
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- Sellable sizes of a product: "1 kg" $100, "Bolsa 5 kg" $450, "Garrafa 4 L"...
create table product_variants (
  id             bigint generated always as identity primary key,
  product_id     bigint not null references products(id) on delete cascade,
  label          text not null,                          -- "Bolsa 5 kg"
  pack_qty       numeric(10,3) not null check (pack_qty > 0),   -- base units per variant (5 for a 5 kg bag)
  price          numeric(10,2) not null check (price >= 0),
  active         boolean not null default true,
  stripe_price_id text unique,                           -- filled when Stripe is connected
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (product_id, label)
);

create table suppliers (
  id             bigint generated always as identity primary key,
  name           text not null unique,                   -- "Sam's", "Distribuidora X"
  contact_name   text,
  phone          text,
  email          text,
  notes          text,
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
alter table products add constraint products_supplier_fk
  foreign key (supplier_id) references suppliers(id) on delete set null;

-- ---------- Directory ------------------------------------------------

create table customers (
  id             bigint generated always as identity primary key,
  name           text not null,
  phone          text,                                   -- WhatsApp number, 10 digits or +52...
  email          text,
  address        text,
  zone           text,                                   -- colonia / fraccionamiento
  address_notes  text,                                   -- references, gate code
  customer_type  text not null default 'residential'
                   check (customer_type in ('residential','pool_service','business')),
  status         text not null default 'customer'
                   check (status in ('prospect','customer','inactive')),
  source         text,                                   -- referido, vecino, web, whatsapp...
  whatsapp_opt_in boolean not null default true,         -- may receive reminders
  notes          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index customers_phone_uq on customers(phone) where phone is not null;

-- ---------- Subscriptions -------------------------------------------

create table subscriptions (
  id                  bigint generated always as identity primary key,
  customer_id         bigint not null references customers(id) on delete restrict,
  status              text not null default 'active' check (status in ('active','paused','cancelled')),
  frequency_days      int not null default 30 check (frequency_days between 7 and 180),
  next_delivery_date  date not null,
  payment_method      text not null default 'cash' check (payment_method in ('card','cash','spei')),
  delivery_address    text,                              -- NULL = customer's address
  notes               text,
  stripe_subscription_id text unique,
  started_on          date not null default current_date,
  cancelled_on        date,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table subscription_items (
  subscription_id  bigint not null references subscriptions(id) on delete cascade,
  variant_id       bigint not null references product_variants(id) on delete restrict,
  qty              numeric(10,3) not null check (qty > 0),
  primary key (subscription_id, variant_id)
);

-- ---------- Orders ---------------------------------------------------

create table orders (
  id               bigint generated always as identity primary key,
  customer_id      bigint not null references customers(id) on delete restrict,
  order_date       date not null default current_date,
  channel          text not null default 'manual'
                     check (channel in ('manual','whatsapp','web','subscription')),
  status           text not null default 'pending'
                     check (status in ('pending','confirmed','out_for_delivery','delivered','cancelled')),
  delivery_date    date,                                 -- scheduled delivery
  delivery_address text,                                 -- NULL = customer's address
  delivered_at     timestamptz,                          -- set automatically when status = delivered
  payment_method   text not null default 'cash' check (payment_method in ('card','cash','spei')),
  payment_status   text not null default 'pending' check (payment_status in ('pending','paid')),
  paid_at          timestamptz,                          -- set automatically when payment_status = paid
  discount         numeric(10,2) not null default 0 check (discount >= 0),
  delivery_fee     numeric(10,2) not null default 0 check (delivery_fee >= 0),
  subscription_id  bigint references subscriptions(id) on delete set null,
  stripe_checkout_id text unique,
  notes            text,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index orders_customer_idx on orders(customer_id, order_date desc);
create index orders_open_idx on orders(status) where status not in ('delivered','cancelled');

create table order_items (
  id               bigint generated always as identity primary key,
  order_id         bigint not null references orders(id) on delete cascade,
  variant_id       bigint not null references product_variants(id) on delete restrict,
  qty              numeric(10,3) not null check (qty > 0),     -- number of variant units (2 bolsas)
  unit_price       numeric(10,2) not null check (unit_price >= 0),  -- defaults to variant price
  unit_cost        numeric(10,2),                              -- defaults to product cost × pack_qty
  line_total       numeric(12,2) generated always as (qty * unit_price) stored
);
create index order_items_order_idx on order_items(order_id);

-- ---------- Purchases, expenses, inventory --------------------------

create table purchases (
  id               bigint generated always as identity primary key,
  supplier_id      bigint references suppliers(id) on delete set null,
  purchase_date    date not null default current_date,
  shipping_cost    numeric(10,2) not null default 0 check (shipping_cost >= 0),  -- counted as expense in P&L
  invoice_ref      text,
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create table purchase_items (
  id               bigint generated always as identity primary key,
  purchase_id      bigint not null references purchases(id) on delete cascade,
  product_id       bigint not null references products(id) on delete restrict,
  qty              numeric(10,3) not null check (qty > 0),     -- base units (50 kg)
  unit_cost        numeric(10,2) not null check (unit_cost >= 0)  -- per base unit ($49/kg)
);

create table expenses (
  id               bigint generated always as identity primary key,
  expense_date     date not null default current_date,
  category         text not null check (category in
                     ('delivery','packaging','fuel','fees','marketing','software','other')),
  amount           numeric(10,2) not null check (amount > 0),
  notes            text,
  created_at       timestamptz not null default now()
);

-- Every stock change. Stock on hand = sum(qty) per product.
-- Sales and purchases write here automatically; the admin site adds
-- 'count' (physical count corrections), 'waste' and 'internal_use'.
create table inventory_movements (
  id               bigint generated always as identity primary key,
  product_id       bigint not null references products(id) on delete restrict,
  moved_at         timestamptz not null default now(),
  qty              numeric(10,3) not null check (qty <> 0),    -- + in, − out (base units)
  reason           text not null check (reason in ('purchase','sale','count','waste','internal_use')),
  order_item_id    bigint references order_items(id) on delete cascade,
  purchase_item_id bigint references purchase_items(id) on delete cascade,
  notes            text,
  created_by       uuid default auth.uid()
);
create index inventory_movements_product_idx on inventory_movements(product_id);

-- ---------- updated_at triggers -------------------------------------
create trigger t_upd before update on products          for each row execute function set_updated_at();
create trigger t_upd before update on product_variants  for each row execute function set_updated_at();
create trigger t_upd before update on suppliers         for each row execute function set_updated_at();
create trigger t_upd before update on customers         for each row execute function set_updated_at();
create trigger t_upd before update on subscriptions     for each row execute function set_updated_at();
create trigger t_upd before update on orders            for each row execute function set_updated_at();
create trigger t_upd before update on purchases         for each row execute function set_updated_at();
