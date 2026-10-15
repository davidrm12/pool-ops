-- Cloro Diego · full schema (migrations 001–007 combined). Paste into Supabase SQL Editor and run once on a NEW project.
-- Already ran 001–006? Run only supabase/migrations/007_bundles.sql instead.

-- ===================== migrations/001_tables.sql =====================
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

-- ===================== migrations/002_logic.sql =====================
-- =====================================================================
-- Cloro Diego · Backend v1 · 002 — Business logic (triggers & functions)
-- Everything here runs inside the database, so the admin site, the
-- future WhatsApp bot and Stripe webhooks all get the same behavior.
-- =====================================================================

-- ---------- Orders: timestamps follow status ------------------------
create or replace function orders_status_stamps() returns trigger
language plpgsql as $$
begin
  if new.status = 'delivered' and new.delivered_at is null then new.delivered_at := now(); end if;
  if new.status <> 'delivered' then new.delivered_at := null; end if;
  if new.payment_status = 'paid' and new.paid_at is null then new.paid_at := now(); end if;
  if new.payment_status = 'pending' then new.paid_at := null; end if;
  return new;
end $$;

create trigger orders_status_stamps
before insert or update of status, payment_status on orders
for each row execute function orders_status_stamps();

-- ---------- Order items: default price/cost from the catalog --------
-- The site or a bot only needs to send variant_id + qty.
create or replace function order_items_defaults() returns trigger
language plpgsql as $$
declare v_price numeric; v_cost numeric;
begin
  select v.price, p.unit_cost * v.pack_qty into v_price, v_cost
    from product_variants v join products p on p.id = v.product_id
   where v.id = new.variant_id;
  if new.unit_price is null then new.unit_price := v_price; end if;
  if tg_op = 'INSERT' and new.unit_cost is null then new.unit_cost := v_cost; end if;
  return new;
end $$;

create trigger order_items_defaults
before insert or update of variant_id on order_items
for each row execute function order_items_defaults();

-- ---------- Stock out on sale --------------------------------------
-- Stock is taken when the item is recorded (committed), returned if the
-- order is cancelled. Deleting an item deletes its movement (cascade).
create or replace function order_items_stock() returns trigger
language plpgsql as $$
declare v_status text; v_product bigint; v_pack numeric;
begin
  delete from inventory_movements where order_item_id = new.id;
  select status into v_status from orders where id = new.order_id;
  if v_status = 'cancelled' then return new; end if;
  select product_id, pack_qty into v_product, v_pack from product_variants where id = new.variant_id;
  insert into inventory_movements(product_id, qty, reason, order_item_id)
  values (v_product, -(new.qty * v_pack), 'sale', new.id);
  return new;
end $$;

create trigger order_items_stock
after insert or update of qty, variant_id on order_items
for each row execute function order_items_stock();

create or replace function orders_cancel_stock() returns trigger
language plpgsql as $$
begin
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    delete from inventory_movements m using order_items i
     where m.order_item_id = i.id and i.order_id = new.id;
  elsif old.status = 'cancelled' and new.status <> 'cancelled' then
    insert into inventory_movements(product_id, qty, reason, order_item_id)
    select v.product_id, -(i.qty * v.pack_qty), 'sale', i.id
      from order_items i join product_variants v on v.id = i.variant_id
     where i.order_id = new.id;
  end if;
  return new;
end $$;

create trigger orders_cancel_stock
after update of status on orders
for each row execute function orders_cancel_stock();

-- ---------- Stock in on purchase + moving-average cost --------------
-- New cost = (stock on hand × old cost + qty × purchase cost) / (stock + qty).
-- If there was no stock or no prior cost, the purchase cost is used.
create or replace function purchase_items_stock() returns trigger
language plpgsql as $$
declare v_on_hand numeric; v_cost numeric; v_date date;
begin
  if tg_op = 'INSERT' then
    select coalesce(sum(qty),0) into v_on_hand from inventory_movements where product_id = new.product_id;
    select unit_cost into v_cost from products where id = new.product_id;
    update products
       set unit_cost = case when v_on_hand <= 0 or v_cost is null then new.unit_cost
                            else round((v_on_hand * v_cost + new.qty * new.unit_cost) / (v_on_hand + new.qty), 2) end
     where id = new.product_id;
  end if;
  delete from inventory_movements where purchase_item_id = new.id;
  select purchase_date into v_date from purchases where id = new.purchase_id;
  insert into inventory_movements(product_id, qty, reason, purchase_item_id, moved_at)
  values (new.product_id, new.qty, 'purchase', new.id, v_date::timestamptz);
  return new;
end $$;

create trigger purchase_items_stock
after insert or update of qty, product_id on purchase_items
for each row execute function purchase_items_stock();

-- ---------- Subscriptions → orders ----------------------------------
-- Creates the order for every active subscription due on or before
-- p_until and moves its next date forward. Safe to run repeatedly
-- (a button in the admin site now; a daily scheduled job later).
create or replace function create_due_subscription_orders(p_until date default current_date)
returns int
language plpgsql as $$
declare s record; v_order bigint; n int := 0;
begin
  for s in
    select * from subscriptions
     where status = 'active' and next_delivery_date <= p_until
     for update
  loop
    insert into orders(customer_id, order_date, channel, status, delivery_date,
                       delivery_address, payment_method, subscription_id, notes)
    values (s.customer_id, current_date, 'subscription', 'confirmed', s.next_delivery_date,
            s.delivery_address, s.payment_method, s.id, 'Generado por suscripción')
    returning id into v_order;

    insert into order_items(order_id, variant_id, qty)
    select v_order, variant_id, qty from subscription_items where subscription_id = s.id;

    update subscriptions
       set next_delivery_date = s.next_delivery_date + s.frequency_days
     where id = s.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- Convenience: record a physical stock count --------------
-- Pass the counted quantity; the function writes the difference.
create or replace function record_stock_count(p_product_id bigint, p_counted numeric, p_notes text default null)
returns numeric
language plpgsql as $$
declare v_on_hand numeric; v_diff numeric;
begin
  select coalesce(sum(qty),0) into v_on_hand from inventory_movements where product_id = p_product_id;
  v_diff := p_counted - v_on_hand;
  if v_diff <> 0 then
    insert into inventory_movements(product_id, qty, reason, notes)
    values (p_product_id, v_diff, 'count', coalesce(p_notes, 'Conteo físico'));
  end if;
  return v_diff;
end $$;

-- ===================== migrations/003_security.sql =====================
-- =====================================================================
-- Cloro Diego · Backend v1 · 003 — Access control
--
-- Model: the website is public (GitHub Pages) and ships the Supabase
-- "anon" key, which is designed to be public. That key can do nothing
-- here: every table has Row Level Security, and the only policy lets a
-- logged-in user through if their account is in `admins`.
--   · Not logged in            → sees nothing
--   · Logged in, not in admins → sees nothing (e.g. if sign-ups were left on)
--   · Logged in and in admins  → full read/write
-- Server-side automations (Stripe webhooks, WhatsApp bot, cron) will use
-- the service-role key, which bypasses RLS and never goes in the browser.
-- =====================================================================

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;
revoke all on function is_admin() from public, anon;
grant execute on function is_admin() to authenticated;

do $$
declare t text;
begin
  foreach t in array array[
    'products','product_variants','suppliers','customers','subscriptions','subscription_items',
    'orders','order_items','purchases','purchase_items','expenses','inventory_movements']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (is_admin()) with check (is_admin())', t);
    execute format('revoke all on %I from anon', t);
  end loop;
end $$;

-- admins: an admin can see the list (to show "logged in as"), nobody can edit it from the site.
alter table admins enable row level security;
create policy admin_read on admins for select to authenticated using (is_admin());
revoke all on admins from anon;
revoke insert, update, delete on admins from authenticated;

-- Functions callable from the site (RLS still applies inside them).
revoke all on function create_due_subscription_orders(date) from public, anon;
revoke all on function record_stock_count(bigint, numeric, text) from public, anon;
grant execute on function create_due_subscription_orders(date) to authenticated;
grant execute on function record_stock_count(bigint, numeric, text) to authenticated;

-- ===================== migrations/004_views.sql =====================
-- =====================================================================
-- Cloro Diego · Backend v1 · 004 — Views the admin site reads
-- security_invoker = true → views obey the same admin-only rules as
-- the tables underneath (without it, views would bypass RLS).
-- =====================================================================

-- ---------- Orders with totals, margin and a readable item list ------
create or replace view v_orders with (security_invoker = true) as
select o.id, o.order_date, o.channel, o.status, o.delivery_date, o.delivered_at,
       o.payment_method, o.payment_status, o.paid_at, o.discount, o.delivery_fee,
       o.subscription_id, o.notes, o.created_at, o.updated_at,
       c.id as customer_id, c.name as customer_name, c.phone as customer_phone,
       coalesce(o.delivery_address, c.address) as delivery_address, c.zone, c.address_notes,
       coalesce(i.subtotal, 0)                                   as subtotal,
       coalesce(i.subtotal, 0) - o.discount + o.delivery_fee     as total,
       i.cogs,                                                   -- NULL if any item has no cost
       coalesce(i.subtotal, 0) - o.discount - i.cogs             as gross_profit,
       coalesce(i.n_items, 0)                                    as n_items,
       i.items_summary
  from orders o
  join customers c on c.id = o.customer_id
  left join lateral (
    select sum(oi.line_total)                                          as subtotal,
           case when bool_or(oi.unit_cost is null) then null
                else round(sum(oi.qty * oi.unit_cost), 2) end          as cogs,
           count(*)                                                    as n_items,
           string_agg(trim(to_char(oi.qty, 'FM999990.###')) || ' × ' || p.name || ' ' || v.label,
                      ', ' order by oi.id)                             as items_summary
      from order_items oi
      join product_variants v on v.id = oi.variant_id
      join products p on p.id = v.product_id
     where oi.order_id = o.id
  ) i on true;

-- ---------- Deliveries to do ----------------------------------------
create or replace view v_pending_deliveries with (security_invoker = true) as
select id, coalesce(delivery_date, order_date) as due_date,
       coalesce(delivery_date, order_date) < current_date as overdue,
       status, customer_name, customer_phone, delivery_address, zone, address_notes,
       items_summary, total, payment_method, payment_status, notes
  from v_orders
 where status in ('pending','confirmed','out_for_delivery')
 order by coalesce(delivery_date, order_date), id;

-- ---------- Stock, value and reorder signal -------------------------
create or replace view v_stock with (security_invoker = true) as
with mv as (
  select product_id,
         sum(qty)                                                                as on_hand,
         -sum(qty) filter (where reason = 'sale' and moved_at >= now() - interval '30 days') as sold_30d
    from inventory_movements group by product_id
)
select p.id as product_id, p.name, p.category, p.base_unit, p.active,
       coalesce(mv.on_hand, 0)                                    as on_hand,
       p.unit_cost,
       round(coalesce(mv.on_hand, 0) * p.unit_cost, 2)            as stock_value,
       p.reorder_point, p.reorder_qty,
       (p.reorder_point is not null and coalesce(mv.on_hand, 0) <= p.reorder_point) as needs_reorder,
       coalesce(mv.sold_30d, 0)                                   as sold_last_30d,
       case when coalesce(mv.sold_30d, 0) > 0
            then round(coalesce(mv.on_hand, 0) / (mv.sold_30d / 30.0), 0) end as days_of_stock,
       s.id as supplier_id, s.name as supplier_name, s.phone as supplier_phone
  from products p
  left join mv on mv.product_id = p.id
  left join suppliers s on s.id = p.supplier_id;

-- ---------- Directory with buying behavior --------------------------
-- median_gap_days = typical days between orders; expected_next_order and
-- days_overdue power reminders and churn alerts.
create or replace view v_customer_summary with (security_invoker = true) as
with o as (
  select customer_id, order_date, total, payment_status,
         order_date - lag(order_date) over (partition by customer_id order by order_date) as gap
    from v_orders where status <> 'cancelled'
), agg as (
  select customer_id,
         count(*)                                                        as n_orders,
         min(order_date)                                                 as first_order,
         max(order_date)                                                 as last_order,
         sum(total)                                                      as lifetime_revenue,
         round(avg(total), 2)                                            as avg_ticket,
         sum(total) filter (where payment_status = 'pending')            as unpaid_amount,
         percentile_cont(0.5) within group (order by gap) filter (where gap > 0) as median_gap_days
    from o group by customer_id
)
select c.*,
       coalesce(a.n_orders, 0)            as n_orders,
       a.first_order, a.last_order,
       coalesce(a.lifetime_revenue, 0)    as lifetime_revenue,
       a.avg_ticket,
       coalesce(a.unpaid_amount, 0)       as unpaid_amount,
       a.median_gap_days,
       (a.last_order + a.median_gap_days::int)                         as expected_next_order,
       greatest(current_date - (a.last_order + a.median_gap_days::int), 0) as days_overdue,
       current_date - a.last_order        as days_since_last_order,
       exists (select 1 from subscriptions s where s.customer_id = c.id and s.status = 'active') as has_subscription
  from customers c left join agg a on a.customer_id = c.id;

-- ---------- Subscriptions -------------------------------------------
create or replace view v_subscriptions with (security_invoker = true) as
select s.*, c.name as customer_name, c.phone as customer_phone,
       coalesce(s.delivery_address, c.address) as effective_address,
       i.items_summary, coalesce(i.value_per_delivery, 0) as value_per_delivery,
       round(coalesce(i.value_per_delivery, 0) * 30.0 / s.frequency_days, 2) as monthly_value
  from subscriptions s
  join customers c on c.id = s.customer_id
  left join lateral (
    select sum(si.qty * v.price) as value_per_delivery,
           string_agg(trim(to_char(si.qty, 'FM999990.###')) || ' × ' || p.name || ' ' || v.label, ', ') as items_summary
      from subscription_items si
      join product_variants v on v.id = si.variant_id
      join products p on p.id = v.product_id
     where si.subscription_id = s.id
  ) i on true;

-- ---------- Monthly P&L ---------------------------------------------
-- Accrual basis: an order counts in the month of order_date unless cancelled.
-- Net sales exclude delivery fees, which are shown on their own line.
-- Operating expenses = expenses table + shipping paid on purchases.
create or replace view v_pnl_monthly with (security_invoker = true) as
with sales as (
  select date_trunc('month', order_date)::date              as month,
         count(*)                                            as orders,
         sum(subtotal)                                       as gross_sales,
         sum(discount)                                       as discounts,
         sum(subtotal - discount)                            as net_sales,
         sum(delivery_fee)                                   as delivery_income
    from v_orders where status <> 'cancelled' group by 1
), cogs as (
  select date_trunc('month', o.order_date)::date            as month,
         round(sum(oi.qty * oi.unit_cost), 2)                as cogs,
         coalesce(sum(oi.line_total) filter (where oi.unit_cost is null), 0) as sales_without_cost
    from order_items oi join orders o on o.id = oi.order_id
   where o.status <> 'cancelled' group by 1
), opex as (
  select month, sum(amount) as opex from (
    select date_trunc('month', expense_date)::date as month, amount from expenses
    union all
    select date_trunc('month', purchase_date)::date, shipping_cost from purchases where shipping_cost > 0
  ) x group by 1
), months as (
  select month from sales union select month from opex
)
select m.month,
       coalesce(s.orders, 0)                                              as orders,
       coalesce(s.gross_sales, 0)                                         as gross_sales,
       coalesce(s.discounts, 0)                                           as discounts,
       coalesce(s.net_sales, 0)                                           as net_sales,
       coalesce(s.delivery_income, 0)                                     as delivery_income,
       coalesce(c.cogs, 0)                                                as cogs,
       coalesce(s.net_sales, 0) + coalesce(s.delivery_income, 0) - coalesce(c.cogs, 0) as gross_profit,
       coalesce(o.opex, 0)                                                as operating_expenses,
       coalesce(s.net_sales, 0) + coalesce(s.delivery_income, 0) - coalesce(c.cogs, 0) - coalesce(o.opex, 0) as net_profit,
       case when coalesce(s.net_sales, 0) > 0
            then round((coalesce(s.net_sales, 0) - coalesce(c.cogs, 0)) / s.net_sales, 4) end as gross_margin,
       coalesce(c.sales_without_cost, 0)                                  as sales_without_cost  -- >0 means margin is overstated
  from months m
  left join sales s on s.month = m.month
  left join cogs  c on c.month = m.month
  left join opex  o on o.month = m.month
 order by m.month;

-- ---------- Product performance by month ----------------------------
create or replace view v_product_sales_monthly with (security_invoker = true) as
select date_trunc('month', o.order_date)::date as month,
       p.id as product_id, p.name, p.base_unit,
       sum(oi.qty * v.pack_qty)       as qty_base,
       sum(oi.line_total)             as revenue,
       round(sum(oi.qty * oi.unit_cost), 2) as cogs,
       round(sum(oi.line_total) - sum(oi.qty * oi.unit_cost), 2) as gross_profit
  from order_items oi
  join orders o on o.id = oi.order_id and o.status <> 'cancelled'
  join product_variants v on v.id = oi.variant_id
  join products p on p.id = v.product_id
 group by 1, 2, 3, 4;

-- ---------- Dashboard: one row of KPIs ------------------------------
create or replace view v_dashboard with (security_invoker = true) as
with cur as (select date_trunc('month', current_date)::date as m),
pnl as (select * from v_pnl_monthly)
select
  (select net_sales    from pnl, cur where pnl.month = cur.m)                                as sales_this_month,
  (select net_sales    from pnl, cur where pnl.month = (cur.m - interval '1 month')::date)  as sales_last_month,
  (select gross_profit from pnl, cur where pnl.month = cur.m)                                as gross_profit_this_month,
  (select gross_margin from pnl, cur where pnl.month = cur.m)                                as gross_margin_this_month,
  (select net_profit   from pnl, cur where pnl.month = cur.m)                                as net_profit_this_month,
  (select orders       from pnl, cur where pnl.month = cur.m)                                as orders_this_month,
  (select round(avg(total), 2) from v_orders
     where status <> 'cancelled' and order_date >= current_date - 90)                        as avg_ticket_90d,
  (select count(*) from v_pending_deliveries)                                                as pending_deliveries,
  (select count(*) from v_pending_deliveries where overdue)                                  as overdue_deliveries,
  (select coalesce(sum(total), 0) from v_orders
     where status <> 'cancelled' and payment_status = 'pending')                             as unpaid_amount,
  (select count(distinct customer_id) from orders
     where status <> 'cancelled' and order_date >= current_date - 90)                        as active_customers_90d,
  (select count(*) from v_customer_summary, cur where first_order >= cur.m)                  as new_customers_this_month,
  (select count(*) from v_customer_summary
     where status = 'customer' and days_overdue > 14 and not has_subscription)               as customers_overdue,
  (select count(*) from subscriptions where status = 'active')                               as active_subscriptions,
  (select coalesce(sum(monthly_value), 0) from v_subscriptions where status = 'active')      as subscription_mrr,
  (select count(*) from v_stock where active and needs_reorder)                              as products_to_reorder,
  (select coalesce(sum(stock_value), 0) from v_stock where active)                           as inventory_value;

-- Views are for logged-in admins only.
do $$
declare v text;
begin
  foreach v in array array['v_orders','v_pending_deliveries','v_stock','v_customer_summary',
                           'v_subscriptions','v_pnl_monthly','v_product_sales_monthly','v_dashboard']
  loop
    execute format('revoke all on %I from anon', v);
  end loop;
end $$;

-- ===================== migrations/005_automations.sql =====================
-- =====================================================================
-- Cloro Diego · Backend v1 · 005 — Automations
--   · Delivery calendar (delivery weekdays, lead time) + per-order exceptions
--   · Subscriptions every N weeks, always landing on a delivery day
--   · Subscription orders created `lead_days` before delivery
--   · Reorder rule: alert when projected stock ≤ the product's largest size
--   · Route sheet, weekly report, daily job, email hand-off, run log
-- =====================================================================

-- All dates in the business's local time (Torreón has no daylight saving).
do $$ begin
  execute format('alter database %I set timezone to %L', current_database(), 'America/Monterrey');
end $$;
set timezone to 'America/Monterrey';

-- ---------- Settings (one row) ---------------------------------------
create table settings (
  id                   boolean primary key default true check (id),
  delivery_weekdays    smallint[] not null default '{0}'      -- 0 = domingo … 6 = sábado
                         check (array_length(delivery_weekdays, 1) between 1 and 7
                                and delivery_weekdays <@ '{0,1,2,3,4,5,6}'::smallint[]),
  lead_days            int not null default 2  check (lead_days between 0 and 14),     -- create subscription orders N days before delivery
  reorder_horizon_days int not null default 14 check (reorder_horizon_days between 0 and 60),
  unpaid_alert_days    int not null default 7  check (unpaid_alert_days between 1 and 60),
  updated_at           timestamptz not null default now()
);
insert into settings default values;
create trigger t_upd before update on settings for each row execute function set_updated_at();

create table alert_recipients (
  id          bigint generated always as identity primary key,
  email       text not null unique check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
insert into alert_recipients (email) values ('davidrm97@gmail.com');

create table automation_runs (
  id       bigint generated always as identity primary key,
  ran_at   timestamptz not null default now(),
  job      text not null,          -- subscriptions, reorder_check, route_email, weekly_email, reorder_email
  ok       boolean not null default true,
  details  jsonb
);
create index automation_runs_ran_idx on automation_runs(ran_at desc);

alter table suppliers add column website text;                       -- where online orders are placed
alter table products  add column reorder_alerted_at timestamptz;      -- set when an alert is emailed; cleared when stock recovers

-- ---------- Delivery calendar ----------------------------------------
-- First delivery day on or after p_from.
create or replace function next_delivery_on(p_from date default current_date) returns date
language sql stable as $$
  select min(d)::date
    from generate_series(p_from, p_from + 6, interval '1 day') d,
         settings s
   where extract(dow from d)::smallint = any (s.delivery_weekdays);
$$;

-- New orders without a delivery date go to the next delivery day.
-- Any date can still be set by hand for exceptions.
create or replace function orders_default_delivery() returns trigger
language plpgsql as $$
begin
  if new.delivery_date is null then new.delivery_date := next_delivery_on(new.order_date); end if;
  return new;
end $$;
create trigger orders_default_delivery before insert on orders
for each row execute function orders_default_delivery();
update orders set delivery_date = order_date where delivery_date is null;  -- keep existing rows as they were

-- Moves every open order of one delivery date to another (rain, no driver…).
create or replace function move_deliveries(p_from date, p_to date) returns int
language sql as $$
  with m as (
    update orders set delivery_date = p_to
     where delivery_date = p_from and status in ('pending','confirmed','out_for_delivery')
    returning 1)
  select count(*)::int from m;
$$;

-- ---------- Subscriptions: every N weeks ------------------------------
drop view if exists v_dashboard;
drop view if exists v_subscriptions;
drop view if exists v_stock;

alter table subscriptions add column frequency_weeks smallint;
update subscriptions set frequency_weeks = greatest(1, round(frequency_days / 7.0));
alter table subscriptions alter column frequency_weeks set not null,
                          alter column frequency_weeks set default 4,
                          add constraint subscriptions_frequency_weeks_check check (frequency_weeks between 1 and 26);
alter table subscriptions drop column frequency_days;

-- A subscription's next date always lands on a delivery day.
create or replace function subscriptions_snap_date() returns trigger
language plpgsql as $$
begin
  new.next_delivery_date := next_delivery_on(new.next_delivery_date);
  return new;
end $$;
create trigger subscriptions_snap_date before insert or update of next_delivery_date on subscriptions
for each row execute function subscriptions_snap_date();

-- Creates orders for active subscriptions delivering within `lead_days` of p_today.
-- If a date was missed (job down, subscription resumed), the order goes to the
-- next delivery day instead of a past date. Safe to run any number of times.
drop function if exists create_due_subscription_orders(date);
create function create_due_subscription_orders(p_today date default current_date)
returns int
language plpgsql as $$
declare s record; v_order bigint; v_deliver date; n int := 0; v_lead int;
begin
  select lead_days into v_lead from settings;
  for s in
    select * from subscriptions
     where status = 'active' and next_delivery_date <= p_today + v_lead
     for update
  loop
    v_deliver := greatest(s.next_delivery_date, next_delivery_on(p_today));
    if not exists (select 1 from orders where subscription_id = s.id and delivery_date = v_deliver and status <> 'cancelled') then
      insert into orders(customer_id, order_date, channel, status, delivery_date,
                         delivery_address, payment_method, subscription_id, notes)
      values (s.customer_id, p_today, 'subscription', 'confirmed', v_deliver,
              s.delivery_address, s.payment_method, s.id, 'Generado por suscripción')
      returning id into v_order;
      insert into order_items(order_id, variant_id, qty)
      select v_order, variant_id, qty from subscription_items where subscription_id = s.id;
      n := n + 1;
    end if;
    update subscriptions set next_delivery_date = v_deliver + s.frequency_weeks * 7 where id = s.id;
  end loop;
  return n;
end $$;

-- ---------- Stock with the reorder rule -------------------------------
-- projected = stock on hand (already net of recorded orders)
--           − subscription deliveries in the next `reorder_horizon_days` not yet turned into orders
-- alert when projected ≤ the largest active size of the product (e.g. ≤ 10 kg if the biggest bag is 10 kg).
create view v_stock with (security_invoker = true) as
with st as (select reorder_horizon_days as horizon from settings),
mv as (
  select product_id,
         sum(qty)                                                                             as on_hand,
         -sum(qty) filter (where reason = 'sale' and moved_at >= now() - interval '30 days') as sold_30d,
         -sum(qty) filter (where reason = 'sale' and moved_at >= now() - interval '90 days') as sold_90d
    from inventory_movements group by product_id
),
largest as (
  select product_id, max(pack_qty) as largest_size from product_variants where active group by product_id
),
subs as (
  select v.product_id, sum(si.qty * v.pack_qty * c.cycles) as committed
    from subscriptions s
    join subscription_items si on si.subscription_id = s.id
    join product_variants v on v.id = si.variant_id
    cross join st
    cross join lateral (
      select count(*) as cycles from generate_series(0, 60) k
       where s.next_delivery_date + k * 7 * s.frequency_weeks <= current_date + st.horizon
    ) c
   where s.status = 'active'
   group by v.product_id
)
select p.id as product_id, p.name, p.category, p.base_unit, p.active,
       coalesce(mv.on_hand, 0)                                        as on_hand,
       coalesce(subs.committed, 0)                                    as committed_subscriptions,
       coalesce(mv.on_hand, 0) - coalesce(subs.committed, 0)          as projected,
       l.largest_size                                                 as alert_threshold,
       (l.largest_size is not null
        and coalesce(mv.on_hand, 0) - coalesce(subs.committed, 0) <= l.largest_size) as needs_reorder,
       -- Suggested purchase: the product's "cantidad a pedir" if set; otherwise enough to get
       -- back above the threshold plus ~1 month of sales, rounded up to whole largest sizes.
       case when l.largest_size is null then null
            when p.reorder_qty is not null then p.reorder_qty
            else ceil(greatest(l.largest_size,
                               l.largest_size - (coalesce(mv.on_hand, 0) - coalesce(subs.committed, 0))
                               + coalesce(mv.sold_90d, 0) / 3.0) / l.largest_size) * l.largest_size
       end                                                            as suggested_qty,
       p.unit_cost,
       round(coalesce(mv.on_hand, 0) * p.unit_cost, 2)                as stock_value,
       coalesce(mv.sold_30d, 0)                                       as sold_last_30d,
       case when coalesce(mv.sold_30d, 0) > 0
            then round(coalesce(mv.on_hand, 0) / (mv.sold_30d / 30.0), 0) end as days_of_stock,
       p.reorder_qty, p.reorder_alerted_at,
       s.id as supplier_id, s.name as supplier_name, s.phone as supplier_phone, s.website as supplier_website
  from products p
  left join mv      on mv.product_id = p.id
  left join largest l on l.product_id = p.id
  left join subs    on subs.product_id = p.id
  left join suppliers s on s.id = p.supplier_id;

alter table products drop column reorder_point;

create view v_subscriptions with (security_invoker = true) as
select s.*, c.name as customer_name, c.phone as customer_phone,
       coalesce(s.delivery_address, c.address) as effective_address,
       i.items_summary, coalesce(i.value_per_delivery, 0) as value_per_delivery,
       round(coalesce(i.value_per_delivery, 0) * 30.4375 / (s.frequency_weeks * 7), 2) as monthly_value
  from subscriptions s
  join customers c on c.id = s.customer_id
  left join lateral (
    select sum(si.qty * v.price) as value_per_delivery,
           string_agg(trim(to_char(si.qty, 'FM999990.###')) || ' × ' || p.name || ' ' || v.label, ', ') as items_summary
      from subscription_items si
      join product_variants v on v.id = si.variant_id
      join products p on p.id = v.product_id
     where si.subscription_id = s.id
  ) i on true;

create view v_dashboard with (security_invoker = true) as
with cur as (select date_trunc('month', current_date)::date as m),
pnl as (select * from v_pnl_monthly)
select
  (select net_sales    from pnl, cur where pnl.month = cur.m)                                as sales_this_month,
  (select net_sales    from pnl, cur where pnl.month = (cur.m - interval '1 month')::date)  as sales_last_month,
  (select gross_profit from pnl, cur where pnl.month = cur.m)                                as gross_profit_this_month,
  (select gross_margin from pnl, cur where pnl.month = cur.m)                                as gross_margin_this_month,
  (select net_profit   from pnl, cur where pnl.month = cur.m)                                as net_profit_this_month,
  (select orders       from pnl, cur where pnl.month = cur.m)                                as orders_this_month,
  (select round(avg(total), 2) from v_orders
     where status <> 'cancelled' and order_date >= current_date - 90)                        as avg_ticket_90d,
  (select count(*) from v_pending_deliveries)                                                as pending_deliveries,
  (select count(*) from v_pending_deliveries where overdue)                                  as overdue_deliveries,
  (select coalesce(sum(total), 0) from v_orders
     where status <> 'cancelled' and payment_status = 'pending')                             as unpaid_amount,
  (select count(distinct customer_id) from orders
     where status <> 'cancelled' and order_date >= current_date - 90)                        as active_customers_90d,
  (select count(*) from v_customer_summary, cur where first_order >= cur.m)                  as new_customers_this_month,
  (select count(*) from v_customer_summary
     where status = 'customer' and days_overdue > 14 and not has_subscription)               as customers_overdue,
  (select count(*) from subscriptions where status = 'active')                               as active_subscriptions,
  (select coalesce(sum(monthly_value), 0) from v_subscriptions where status = 'active')      as subscription_mrr,
  (select count(*) from v_stock where active and needs_reorder)                              as products_to_reorder,
  (select coalesce(sum(stock_value), 0) from v_stock where active)                           as inventory_value,
  next_delivery_on(current_date)                                                             as next_delivery_date;

-- ---------- Reorder alert state --------------------------------------
-- Returns products that just crossed the threshold (to email once), and
-- re-arms products whose projected stock recovered.
create or replace function check_reorder_alerts() returns jsonb
language plpgsql as $$
declare v_new jsonb;
begin
  update products p set reorder_alerted_at = null
    from v_stock s
   where s.product_id = p.id and p.reorder_alerted_at is not null and not s.needs_reorder;
  with flagged as (
    update products p set reorder_alerted_at = now()
      from v_stock s
     where s.product_id = p.id and p.active and s.needs_reorder and p.reorder_alerted_at is null
    returning p.id
  )
  select coalesce(jsonb_agg(id), '[]'::jsonb) into v_new from flagged;
  return v_new;
end $$;

-- ---------- Route sheet ---------------------------------------------
-- Everything the driver needs for one delivery date. Also includes overdue
-- orders (scheduled before today and still undelivered): they ride along.
create or replace function route_sheet(p_date date default null) returns jsonb
language sql stable as $$
  with d as (select coalesce(p_date, next_delivery_on(current_date)) as day),
  stops as (
    select o.* from v_orders o, d
     where o.status in ('pending','confirmed','out_for_delivery')
       and (o.delivery_date = d.day or o.delivery_date < least(current_date, d.day))
  ),
  items as (
    select p.id as product_id, p.name as product, p.base_unit, v.label, v.pack_qty, sum(oi.qty) as qty
      from order_items oi
      join stops o on o.id = oi.order_id
      join product_variants v on v.id = oi.variant_id
      join products p on p.id = v.product_id
     group by p.id, p.name, p.base_unit, v.label, v.pack_qty
  )
  select jsonb_build_object(
    'date', (select day from d),
    'stops', coalesce((select jsonb_agg(jsonb_build_object(
                 'id', id, 'customer', customer_name, 'phone', customer_phone, 'address', delivery_address,
                 'zone', zone, 'address_notes', address_notes, 'items', items_summary, 'total', total,
                 'payment_method', payment_method, 'payment_status', payment_status, 'notes', notes,
                 'delivery_date', delivery_date, 'late', delivery_date < (select day from d))
               order by coalesce(zone, 'zzz'), customer_name) from stops), '[]'::jsonb),
    'packing', coalesce((select jsonb_agg(jsonb_build_object('product', product, 'label', label, 'qty', qty,
                 'base_qty', qty * pack_qty, 'base_unit', base_unit) order by product, pack_qty desc) from items), '[]'::jsonb),
    'shortfalls', coalesce((select jsonb_agg(jsonb_build_object('product', s.name, 'missing', -s.on_hand, 'base_unit', s.base_unit))
                   from v_stock s where s.on_hand < 0 and s.product_id in (select product_id from items)), '[]'::jsonb),
    'n_stops', (select count(*) from stops),
    'total', (select coalesce(sum(total), 0) from stops),
    'to_collect', (select coalesce(sum(total), 0) from stops where payment_status = 'pending' and payment_method <> 'card')
  );
$$;

-- ---------- Weekly report (previous Monday–Sunday) ---------------------
create or replace function weekly_report(p_today date default current_date) returns jsonb
language sql stable as $$
  with w as (
    select (date_trunc('week', p_today)::date - 7) as s, (date_trunc('week', p_today)::date - 1) as e,
           (date_trunc('week', p_today)::date - 14) as ps, (date_trunc('week', p_today)::date - 8) as pe
  ),
  cur as (select count(*) n, coalesce(sum(subtotal - discount), 0) sales, coalesce(sum(gross_profit), 0) gp,
                 bool_or(cogs is null) missing_cost
            from v_orders, w where status <> 'cancelled' and order_date between w.s and w.e),
  prev as (select count(*) n, coalesce(sum(subtotal - discount), 0) sales, coalesce(sum(gross_profit), 0) gp
            from v_orders, w where status <> 'cancelled' and order_date between w.ps and w.pe),
  st as (select * from settings)
  select jsonb_build_object(
    'week_start', w.s, 'week_end', w.e,
    'orders', cur.n, 'sales', cur.sales, 'gross_profit', cur.gp, 'missing_cost', coalesce(cur.missing_cost, false),
    'prev_orders', prev.n, 'prev_sales', prev.sales, 'prev_gross_profit', prev.gp,
    'delivered', (select count(*) from orders where delivered_at::date between w.s and w.e),
    'new_customers', (select count(*) from v_customer_summary where first_order between w.s and w.e),
    'unpaid', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'customer', o.customer_name, 'phone', o.customer_phone,
                  'total', o.total, 'delivered', o.delivered_at::date, 'method', o.payment_method) order by o.delivered_at)
                from v_orders o, st where o.status = 'delivered' and o.payment_status = 'pending'
                 and o.delivered_at < now() - make_interval(days => st.unpaid_alert_days)), '[]'::jsonb),
    'overdue_customers', coalesce((select jsonb_agg(x) from (
                  select jsonb_build_object('customer', name, 'phone', phone, 'days_overdue', days_overdue,
                         'every_days', round(median_gap_days), 'last_order', last_order) x
                    from v_customer_summary
                   where status = 'customer' and not has_subscription and days_overdue > 0
                   order by days_overdue desc limit 10) t), '[]'::jsonb),
    'reorder', coalesce((select jsonb_agg(jsonb_build_object('product', name, 'projected', projected, 'threshold', alert_threshold,
                  'base_unit', base_unit, 'suggested', suggested_qty, 'supplier', supplier_name, 'website', supplier_website) order by name)
                from v_stock where active and needs_reorder), '[]'::jsonb),
    'next_route', (select jsonb_build_object('date', r->'date', 'n_stops', r->'n_stops', 'total', r->'total')
                     from (select route_sheet(next_delivery_on(p_today)) r) z)
  ) from w, cur, prev;
$$;

-- ---------- Email hand-off (pg_net → Edge Function) -------------------
-- Reads the function URL and shared secret from Supabase Vault.
create or replace function send_report(p_kind text, p_payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_url text; v_secret text;
begin
  select decrypted_secret into v_url    from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'cron_secret';
  if v_url is null or v_secret is null then
    insert into automation_runs(job, ok, details) values (p_kind || '_email', false, jsonb_build_object('error', 'Falta project_url o cron_secret en Vault'));
    return;
  end if;
  perform net.http_post(
    url := v_url || '/functions/v1/reports',
    body := jsonb_build_object('kind', p_kind) || p_payload,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', v_secret),
    timeout_milliseconds := 20000);
end $$;

-- ---------- The daily job ----------------------------------------------
-- 1) subscription orders  2) reorder check (email only new alerts)
-- 3) route sheet email when today is `lead_days` before a delivery day
create or replace function automation_daily(p_today date default current_date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_orders int; v_new jsonb; v_route_day date; v_lead int; v_out jsonb;
begin
  select lead_days into v_lead from settings;

  v_orders := create_due_subscription_orders(p_today);
  insert into automation_runs(job, details) values ('subscriptions', jsonb_build_object('orders_created', v_orders));

  v_new := check_reorder_alerts();
  insert into automation_runs(job, details) values ('reorder_check', jsonb_build_object('new_alerts', jsonb_array_length(v_new)));
  if jsonb_array_length(v_new) > 0 then
    perform send_report('reorder', jsonb_build_object('product_ids', v_new));
  end if;

  -- Route sheet once per delivery date, even if the job runs more than once.
  v_route_day := p_today + v_lead;
  if next_delivery_on(v_route_day) = v_route_day
     and not exists (select 1 from automation_runs where job = 'route_requested' and details->>'date' = v_route_day::text) then
    perform send_report('route', jsonb_build_object('date', v_route_day));
    insert into automation_runs(job, details) values ('route_requested', jsonb_build_object('date', v_route_day));
  end if;

  v_out := jsonb_build_object('orders_created', v_orders, 'new_alerts', v_new,
                              'route_day', case when next_delivery_on(v_route_day) = v_route_day then v_route_day end);
  return v_out;
exception when others then
  -- Keep the failure visible in the run log (re-raising would roll the log back too).
  insert into automation_runs(job, ok, details) values ('daily', false, jsonb_build_object('error', sqlerrm));
  return jsonb_build_object('error', sqlerrm);
end $$;

-- ---------- Security ----------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['settings','alert_recipients','automation_runs'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (is_admin()) with check (is_admin())', t);
    execute format('revoke all on %I from anon', t);
  end loop;
end $$;
revoke all on v_stock, v_subscriptions, v_dashboard from anon;

revoke all on function next_delivery_on(date), move_deliveries(date, date), create_due_subscription_orders(date),
                       route_sheet(date), weekly_report(date) from public, anon;
grant execute on function next_delivery_on(date), move_deliveries(date, date), create_due_subscription_orders(date),
                       route_sheet(date), weekly_report(date) to authenticated;
-- Only the scheduler (and the SQL editor) runs these.
revoke all on function check_reorder_alerts(), send_report(text, jsonb), automation_daily(date) from public, anon, authenticated;

-- ===================== migrations/006_store.sql =====================
-- =====================================================================
-- Cloro Diego · 006 — Public store, card payments and safety limits
--   · Store settings (name, delivery fee by ZIP, subscription discount, SPEI data)
--   · Phone rule: exactly 10 digits everywhere
--   · Product photos, store visibility, which sizes can be subscribed
--   · Price changes reach subscribers only from the next delivery ≥ N days away
--   · Web orders (place_web_order) with no-overwrite customer matching
--   · Saved-card charges with preflight limits (per charge, vs. last charge, per day)
--   · Outbox for customer/admin emails; public read functions for the store
-- =====================================================================
set timezone to 'America/Monterrey';

-- ---------- Settings ----------------------------------------------------
alter table settings
  add column store_name            text not null default 'Cloro a Domicilio',
  add column store_open            boolean not null default true,
  add column store_closed_message  text,
  add column store_url             text,                       -- public site, used in emails and Stripe redirects
  add column store_whatsapp        text check (store_whatsapp ~ '^\d{10}$'),
  add column sub_discount_pct      numeric(5,2) not null default 5  check (sub_discount_pct between 0 and 50),
  add column delivery_fee          numeric(10,2) not null default 25 check (delivery_fee >= 0),
  add column free_delivery_zips    text[] not null default '{27105}',
  add column bank_name             text,
  add column bank_clabe            text check (bank_clabe ~ '^\d{18}$'),
  add column bank_beneficiary      text,
  add column max_auto_charge       numeric(10,2) not null default 3000  check (max_auto_charge > 0),
  add column auto_charge_ratio     numeric(4,2)  not null default 1.5   check (auto_charge_ratio >= 1),
  add column daily_auto_charge_cap numeric(12,2) not null default 20000 check (daily_auto_charge_cap > 0),
  add column price_notice_days     int not null default 7 check (price_notice_days between 0 and 60);

-- ---------- Phones: exactly 10 digits -----------------------------------
create or replace function normalize_phone(p text) returns text
language sql immutable as $$
  select case
    when p is null or btrim(p) = '' then null
    when length(regexp_replace(p, '\D', '', 'g')) = 10 then regexp_replace(p, '\D', '', 'g')
    when length(regexp_replace(p, '\D', '', 'g')) = 12 and regexp_replace(p, '\D', '', 'g') like '52%'
      then right(regexp_replace(p, '\D', '', 'g'), 10)
    when length(regexp_replace(p, '\D', '', 'g')) = 13 and regexp_replace(p, '\D', '', 'g') like '521%'
      then right(regexp_replace(p, '\D', '', 'g'), 10)
    else p end;
$$;
update customers set phone = normalize_phone(phone) where phone is not null;
alter table customers add constraint customers_phone_10 check (phone ~ '^\d{10}$') not valid;
do $$ begin
  alter table customers validate constraint customers_phone_10;
exception when check_violation then
  raise notice 'Hay teléfonos que no tienen 10 dígitos; corrígelos en el Directorio: %',
    (select string_agg(name || ' (' || phone || ')', ', ') from customers where phone !~ '^\d{10}$');
end $$;

create or replace function customers_normalize() returns trigger
language plpgsql as $$
begin new.phone := normalize_phone(new.phone); return new; end $$;
create trigger customers_normalize before insert or update of phone on customers
for each row execute function customers_normalize();

alter table customers
  add column postal_code text check (postal_code ~ '^\d{5}$'),
  add column stripe_customer_id text unique;

-- ---------- Catalog: photos and visibility ------------------------------
alter table products
  add column image_url text,
  add column visible   boolean not null default true;          -- shown in the store

alter table product_variants
  add column visible          boolean not null default true,   -- shown in the store
  add column subscribable     boolean not null default true,   -- can be ordered as a subscription
  add column prev_price       numeric(10,2),                   -- price still owed to subscribers during the notice period
  add column price_changed_at date;

-- ---------- Orders: web data and card charges ---------------------------
alter table orders
  add column public_token        uuid not null default gen_random_uuid() unique,
  add column contact_email       text,
  add column delivery_postal_code text check (delivery_postal_code ~ '^\d{5}$'),
  add column needs_review        boolean not null default false,
  add column review_note         text,
  add column charge_status       text not null default 'none' check (charge_status in
                                   ('none','pending','processing','succeeded','failed','requires_approval','refunded')),
  add column charge_error        text,
  add column charge_decline_code text,
  add column charge_attempts     int not null default 0,
  add column last_charge_at      timestamptz,
  add column charged_amount      numeric(12,2),
  add column charge_approved     boolean not null default false,
  add column stripe_payment_intent_id text unique,
  add column refunded_amount     numeric(12,2) not null default 0;

-- ---------- Subscriptions: saved card and self-service ------------------
alter table subscriptions
  add column manage_token            uuid not null default gen_random_uuid() unique,
  add column stripe_payment_method_id text,
  add column card_brand              text,
  add column card_last4              text,
  add column last_charged_amount     numeric(12,2),
  add column consent_at              timestamptz,
  add column consent_text            text,
  add column source                  text not null default 'admin' check (source in ('admin','web')),
  add column delivery_postal_code    text check (delivery_postal_code ~ '^\d{5}$');   -- when it differs from the customer's

-- ---------- Outbox (emails to send) -------------------------------------
create table notifications (
  id              bigint generated always as identity primary key,
  kind            text not null check (kind in
                    ('order_confirmation','admin_new_order','price_change','charge_failed',
                     'charge_needs_approval','payment_link','subscription_change')),
  to_admin        boolean not null default false,
  to_email        text,
  order_id        bigint references orders(id) on delete cascade,
  subscription_id bigint references subscriptions(id) on delete cascade,
  payload         jsonb not null default '{}',
  created_at      timestamptz not null default now(),
  sent_at         timestamptz,
  error           text
);
create index notifications_pending_idx on notifications(created_at) where sent_at is null;

-- ---------- Delivery fee by ZIP ------------------------------------------
create or replace function delivery_fee_for(p_zip text) returns numeric
language sql stable as $$
  select case when p_zip is null then 0
              when p_zip = any (s.free_delivery_zips) then 0
              else s.delivery_fee end
    from settings s;
$$;

-- ---------- Price changes: notice period for subscribers -----------------
-- The price subscribers pay for a delivery: the old price until
-- price_changed_at + price_notice_days, the new one after.
create or replace function subscriber_price(p_variant bigint, p_delivery date) returns numeric
language sql stable as $$
  select case when v.prev_price is not null and v.price_changed_at is not null
                   and p_delivery < v.price_changed_at + s.price_notice_days
              then v.prev_price else v.price end
    from product_variants v, settings s where v.id = p_variant;
$$;

create or replace function variants_price_change() returns trigger
language plpgsql as $$
declare v_notice int;
begin
  if new.price is distinct from old.price then
    select price_notice_days into v_notice from settings;
    -- keep the price subscribers are still entitled to, even after several quick edits
    new.prev_price := case when old.price_changed_at is not null and current_date < old.price_changed_at + v_notice
                           then coalesce(old.prev_price, old.price) else old.price end;
    new.price_changed_at := current_date;
  end if;
  return new;
end $$;
create trigger variants_price_change before update of price on product_variants
for each row execute function variants_price_change();

create or replace function variants_price_notify() returns trigger
language plpgsql as $$
begin
  if new.price is distinct from old.price then
    insert into notifications(kind, to_email, subscription_id, payload)
    select 'price_change', c.email, s.id,
           jsonb_build_object('product', p.name, 'label', new.label, 'old_price', new.prev_price, 'new_price', new.price,
                              'effective_from', new.price_changed_at + st.price_notice_days)
      from subscription_items si
      join subscriptions s on s.id = si.subscription_id and s.status in ('active','paused')
      join customers c on c.id = s.customer_id and c.email is not null
      join products p on p.id = new.product_id
      cross join settings st
     where si.variant_id = new.id;
  end if;
  return new;
end $$;
create trigger variants_price_notify after update of price on product_variants
for each row execute function variants_price_notify();

-- ---------- Subscription orders: discount, fee, notice price, card --------
create or replace function create_due_subscription_orders(p_today date default current_date)
returns int
language plpgsql as $$
declare s record; v_order bigint; v_deliver date; n int := 0; st settings; v_zip text; v_sub numeric;
begin
  select * into st from settings;
  for s in
    select * from subscriptions
     where status = 'active' and next_delivery_date <= p_today + st.lead_days
     for update
  loop
    v_deliver := greatest(s.next_delivery_date, next_delivery_on(p_today));
    if not exists (select 1 from orders where subscription_id = s.id and delivery_date = v_deliver and status <> 'cancelled') then
      select coalesce(s.delivery_postal_code, postal_code) into v_zip from customers where id = s.customer_id;
      insert into orders(customer_id, order_date, channel, status, delivery_date, delivery_address,
                         delivery_postal_code, payment_method, subscription_id, delivery_fee, notes, charge_status)
      values (s.customer_id, p_today, 'subscription', 'confirmed', v_deliver, s.delivery_address, v_zip,
              s.payment_method, s.id, delivery_fee_for(v_zip), 'Generado por suscripción',
              case when s.payment_method = 'card' and s.stripe_payment_method_id is not null then 'pending' else 'none' end)
      returning id into v_order;
      insert into order_items(order_id, variant_id, qty, unit_price)
      select v_order, si.variant_id, si.qty, subscriber_price(si.variant_id, v_deliver)
        from subscription_items si where si.subscription_id = s.id;
      select coalesce(sum(line_total), 0) into v_sub from order_items where order_id = v_order;
      update orders set discount = round(v_sub * st.sub_discount_pct / 100, 2) where id = v_order;
      n := n + 1;
    end if;
    update subscriptions set next_delivery_date = v_deliver + s.frequency_weeks * 7 where id = s.id;
  end loop;
  return n;
end $$;

-- ---------- v_orders: same as 004 plus web/charge columns at the end ------
create or replace view v_orders with (security_invoker = true) as
select o.id, o.order_date, o.channel, o.status, o.delivery_date, o.delivered_at,
       o.payment_method, o.payment_status, o.paid_at, o.discount, o.delivery_fee,
       o.subscription_id, o.notes, o.created_at, o.updated_at,
       c.id as customer_id, c.name as customer_name, c.phone as customer_phone,
       coalesce(o.delivery_address, c.address) as delivery_address, c.zone, c.address_notes,
       coalesce(i.subtotal, 0)                                   as subtotal,
       coalesce(i.subtotal, 0) - o.discount + o.delivery_fee     as total,
       i.cogs,                                                   -- NULL if any item has no cost
       coalesce(i.subtotal, 0) - o.discount - i.cogs             as gross_profit,
       coalesce(i.n_items, 0)                                    as n_items,
       i.items_summary,
       o.needs_review, o.review_note, o.charge_status, o.contact_email, o.public_token   -- added in 006 (store)
  from orders o
  join customers c on c.id = o.customer_id
  left join lateral (
    select sum(oi.line_total)                                          as subtotal,
           case when bool_or(oi.unit_cost is null) then null
                else round(sum(oi.qty * oi.unit_cost), 2) end          as cogs,
           count(*)                                                    as n_items,
           string_agg(trim(to_char(oi.qty, 'FM999990.###')) || ' × ' || p.name || ' ' || v.label,
                      ', ' order by oi.id)                             as items_summary
      from order_items oi
      join product_variants v on v.id = oi.variant_id
      join products p on p.id = v.product_id
     where oi.order_id = o.id
  ) i on true;

-- ---------- Web orders --------------------------------------------------
-- Called only by the `store` Edge Function (service role) after Turnstile.
-- p: {name, phone, email, address, zone, postal_code, address_notes, delivery_date,
--     payment_method, frequency_weeks|null, consent, items:[{variant_id, qty}]}
create or replace function place_web_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  st settings; v_phone text; v_cust customers; v_order bigint; v_token uuid; v_sub bigint; v_manage uuid;
  v_freq int; v_date date; v_zip text; v_addr text; v_name text; v_email text; v_method text;
  v_diff text[] := '{}'; v_items int; v_bad int; v_subtotal numeric; it jsonb; v_total numeric;
begin
  select * into st from settings;
  if not st.store_open then raise exception 'La tienda no está recibiendo pedidos por ahora.'; end if;

  v_name   := btrim(coalesce(p->>'name', ''));
  v_phone  := normalize_phone(p->>'phone');
  v_email  := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  v_addr   := btrim(coalesce(p->>'address', ''));
  v_zip    := btrim(coalesce(p->>'postal_code', ''));
  v_method := p->>'payment_method';
  v_freq   := nullif(p->>'frequency_weeks', '')::int;
  v_date   := (p->>'delivery_date')::date;

  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'Escribe tu nombre.'; end if;
  if v_phone is null or v_phone !~ '^\d{10}$' then raise exception 'El WhatsApp debe tener 10 dígitos.'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Revisa el correo.'; end if;
  if length(v_addr) < 5 then raise exception 'Escribe la dirección de entrega.'; end if;
  if v_zip !~ '^27\d{3}$' then raise exception 'El código postal debe ser de Torreón (5 dígitos, empieza con 27).'; end if;
  if v_method not in ('card','cash','spei') then raise exception 'Elige una forma de pago.'; end if;
  if v_date is null or v_date not in (
       select next_delivery_on(current_date + 1)
       union select next_delivery_on(next_delivery_on(current_date + 1) + 1)) then
    raise exception 'Elige una de las fechas de entrega disponibles.';
  end if;
  if v_freq is not null and v_freq not in (1,2,3,4,6,8) then raise exception 'Frecuencia no válida.'; end if;
  if v_freq is not null and v_method = 'card' and coalesce((p->>'consent')::boolean, false) is not true then
    raise exception 'Para suscribirte con tarjeta acepta el cobro automático en cada entrega.';
  end if;

  v_items := jsonb_array_length(coalesce(p->'items', '[]'));
  if v_items < 1 or v_items > 20 then raise exception 'Tu carrito está vacío.'; end if;
  select count(*) into v_bad
    from jsonb_array_elements(p->'items') i
    left join product_variants v on v.id = (i->>'variant_id')::bigint and v.active and v.visible
    left join products pr on pr.id = v.product_id and pr.active and pr.visible
   where pr.id is null
      or (i->>'qty') !~ '^\d+$' or (i->>'qty')::int not between 1 and 50
      or (v_freq is not null and not v.subscribable);
  if v_bad > 0 then raise exception 'Algún producto ya no está disponible. Actualiza la página e intenta de nuevo.'; end if;

  -- Basic abuse limit: max 5 web orders per phone per hour.
  if (select count(*) from orders o join customers c on c.id = o.customer_id
       where c.phone = v_phone and o.channel in ('web') and o.created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Recibimos varios pedidos de este número. Escríbenos por WhatsApp para ayudarte.';
  end if;

  -- Customer: match by phone, never overwrite saved data.
  select * into v_cust from customers where phone = v_phone;
  if not found then
    insert into customers(name, phone, email, address, zone, postal_code, address_notes, source, status)
    values (v_name, v_phone, v_email, v_addr, nullif(btrim(coalesce(p->>'zone','')), ''), v_zip,
            nullif(btrim(coalesce(p->>'address_notes','')), ''), 'web', 'customer')
    returning * into v_cust;
  else
    if lower(v_cust.name) <> lower(v_name) then v_diff := v_diff || ('nombre: ' || v_name); end if;
    if coalesce(lower(v_cust.address), '') <> lower(v_addr) then v_diff := v_diff || ('dirección: ' || v_addr); end if;
    if coalesce(v_cust.postal_code, '') <> v_zip then v_diff := v_diff || ('CP: ' || v_zip); end if;
    if v_email is not null and coalesce(lower(v_cust.email), '') <> v_email then v_diff := v_diff || ('correo: ' || v_email); end if;
    if v_cust.status <> 'customer' then update customers set status = 'customer' where id = v_cust.id; end if;
  end if;

  insert into orders(customer_id, order_date, channel, status, delivery_date, delivery_address, delivery_postal_code,
                     payment_method, delivery_fee, contact_email, notes, needs_review, review_note, charge_status)
  values (v_cust.id, current_date, 'web', 'pending', v_date,
          case when coalesce(lower(v_cust.address), '') <> lower(v_addr) then v_addr end, v_zip,
          v_method, delivery_fee_for(v_zip), v_email,
          nullif(btrim(concat_ws(' · ', nullif(p->>'address_notes',''), nullif(p->>'notes',''))), ''),
          cardinality(v_diff) > 0,
          case when cardinality(v_diff) > 0 then 'Datos distintos a los guardados del cliente — ' || array_to_string(v_diff, '; ') end,
          case when v_method = 'card' then 'pending' else 'none' end)
  returning id, public_token into v_order, v_token;

  for it in select * from jsonb_array_elements(p->'items') loop
    insert into order_items(order_id, variant_id, qty) values (v_order, (it->>'variant_id')::bigint, (it->>'qty')::int);
  end loop;

  if v_freq is not null then
    select coalesce(sum(line_total), 0) into v_subtotal from order_items where order_id = v_order;
    update orders set discount = round(v_subtotal * st.sub_discount_pct / 100, 2) where id = v_order;
    insert into subscriptions(customer_id, frequency_weeks, next_delivery_date, payment_method, delivery_address,
                              delivery_postal_code, notes, source, consent_at, consent_text)
    values (v_cust.id, v_freq, v_date + v_freq * 7, v_method,
            case when coalesce(lower(v_cust.address), '') <> lower(v_addr) then v_addr end,
            case when coalesce(v_cust.postal_code, '') <> v_zip then v_zip end,
            'Creada en la tienda', 'web',
            case when v_method = 'card' then now() end, nullif(p->>'consent_text', ''))
    returning id, manage_token into v_sub, v_manage;
    insert into subscription_items(subscription_id, variant_id, qty)
    select v_sub, (i->>'variant_id')::bigint, sum((i->>'qty')::int)
      from jsonb_array_elements(p->'items') i group by 1, 2;
    update orders set subscription_id = v_sub where id = v_order;
  end if;

  select total into v_total from v_orders where id = v_order;
  insert into notifications(kind, to_admin, order_id) values ('admin_new_order', true, v_order);
  if v_email is not null and v_method <> 'card' then        -- card orders confirm after payment
    insert into notifications(kind, to_email, order_id) values ('order_confirmation', v_email, v_order);
  end if;

  return jsonb_build_object('order_id', v_order, 'token', v_token, 'total', v_total, 'payment_method', v_method,
                            'subscription_id', v_sub, 'manage_token', v_manage, 'customer_id', v_cust.id);
end $$;

-- ---------- Card charges: preflight and result --------------------------
-- Every automatic charge goes through here. Returns {ok:true, amount, key, ...}
-- or {ok:false, reason}. Out-of-limit charges become 'requires_approval'.
create or replace function charge_preflight(p_order bigint, p_approved boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o orders; s subscriptions; c customers; st settings; v_amount numeric; v_today numeric; v_reason text;
begin
  select * into st from settings;
  select * into o from orders where id = p_order for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'Pedido no existe'); end if;
  if o.status = 'cancelled' then return jsonb_build_object('ok', false, 'reason', 'Pedido cancelado'); end if;
  if o.payment_status = 'paid' then return jsonb_build_object('ok', false, 'reason', 'Ya está pagado'); end if;
  if o.payment_method <> 'card' then return jsonb_build_object('ok', false, 'reason', 'El pedido no es con tarjeta'); end if;
  if o.charge_status = 'processing' then return jsonb_build_object('ok', false, 'reason', 'Hay un cobro en curso'); end if;
  if o.charge_status = 'requires_approval' and not p_approved then
    return jsonb_build_object('ok', false, 'reason', 'Requiere aprobación');
  end if;
  select * into s from subscriptions where id = o.subscription_id;
  if s.id is null or s.stripe_payment_method_id is null then
    return jsonb_build_object('ok', false, 'reason', 'No hay tarjeta guardada para este pedido');
  end if;
  select * into c from customers where id = o.customer_id;
  if c.stripe_customer_id is null then return jsonb_build_object('ok', false, 'reason', 'Cliente sin registro en Stripe'); end if;

  select total into v_amount from v_orders where id = p_order;      -- always recomputed, never typed
  if v_amount is null or v_amount <= 0 then return jsonb_build_object('ok', false, 'reason', 'Total inválido'); end if;

  if not p_approved then
    select coalesce(sum(charged_amount), 0) into v_today from orders
     where charge_status in ('processing','succeeded') and last_charge_at >= date_trunc('day', now());
    if v_amount > st.max_auto_charge then
      v_reason := format('El cobro de %s supera el máximo por cobro (%s)', v_amount, st.max_auto_charge);
    elsif s.last_charged_amount is not null and v_amount > s.last_charged_amount * st.auto_charge_ratio then
      v_reason := format('El cobro de %s es más de %s× el último cobro de esta suscripción (%s)', v_amount, st.auto_charge_ratio, s.last_charged_amount);
    elsif v_today + v_amount > st.daily_auto_charge_cap then
      v_reason := format('Se alcanzó el límite diario de cobros automáticos (%s)', st.daily_auto_charge_cap);
    end if;
    if v_reason is not null then
      update orders set charge_status = 'requires_approval', charge_error = v_reason where id = p_order;
      insert into notifications(kind, to_admin, order_id, payload)
      values ('charge_needs_approval', true, p_order, jsonb_build_object('reason', v_reason, 'amount', v_amount));
      return jsonb_build_object('ok', false, 'reason', v_reason, 'requires_approval', true);
    end if;
  end if;

  update orders set charge_status = 'processing', charge_attempts = charge_attempts + 1, last_charge_at = now(),
                    charged_amount = v_amount, charge_error = null, charge_decline_code = null,
                    charge_approved = charge_approved or p_approved
   where id = p_order;
  return jsonb_build_object('ok', true, 'amount', v_amount, 'order_id', p_order,
                            'key', format('order-%s-try-%s', p_order, o.charge_attempts + 1),
                            'customer', c.stripe_customer_id, 'payment_method', s.stripe_payment_method_id,
                            'description', format('Pedido #%s · %s', p_order, st.store_name));
end $$;

create or replace function charge_result(p_order bigint, p_ok boolean, p_intent text default null,
                                         p_error text default null, p_code text default null) returns void
language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  select * into o from orders where id = p_order for update;
  if p_ok then
    update orders set charge_status = 'succeeded', payment_status = 'paid', stripe_payment_intent_id = coalesce(p_intent, stripe_payment_intent_id),
                      charge_error = null, charge_decline_code = null
     where id = p_order;
    update subscriptions set last_charged_amount = o.charged_amount where id = o.subscription_id;
  else
    update orders set charge_status = 'failed', charge_error = p_error, charge_decline_code = p_code,
                      stripe_payment_intent_id = coalesce(p_intent, stripe_payment_intent_id)
     where id = p_order;
    -- Customer: link to pay with another card (first failure). Admin: when no automatic retry is left.
    insert into notifications(kind, to_email, order_id, payload)
    select 'charge_failed', coalesce(o.contact_email, c.email), p_order,
           jsonb_build_object('error', p_error, 'retry', coalesce(p_code, '') not in ('lost_card','stolen_card','fraudulent','pickup_card','restricted_card','unknown_outcome'))
      from customers c where c.id = o.customer_id and coalesce(o.contact_email, c.email) is not null
       and o.charge_attempts = 1;
    if o.charge_attempts >= 2 or coalesce(p_code, '') in ('lost_card','stolen_card','fraudulent','pickup_card','restricted_card') then
      insert into notifications(kind, to_admin, order_id, payload)
      values ('charge_failed', true, p_order, jsonb_build_object('error', p_error, 'code', p_code, 'attempts', o.charge_attempts));
    end if;
  end if;
end $$;

-- Orders the scheduler should charge now: subscription card orders due within
-- the lead window, plus one automatic retry the day after a soft decline.
create or replace function orders_to_charge(p_today date default current_date) returns setof bigint
language sql stable security definer set search_path = public as $$
  select o.id from orders o
    join subscriptions s on s.id = o.subscription_id and s.stripe_payment_method_id is not null
   where o.channel = 'subscription' and o.payment_method = 'card' and o.payment_status = 'pending'
     and o.status <> 'cancelled'
     and o.delivery_date <= p_today + (select lead_days from settings)
     and (o.charge_status = 'pending'
          or (o.charge_status = 'failed' and o.charge_attempts = 1 and o.last_charge_at < date_trunc('day', now())
              and coalesce(o.charge_decline_code, '') not in ('lost_card','stolen_card','fraudulent','pickup_card','restricted_card','unknown_outcome')))
   order by o.id;
$$;

-- Card payment received in Checkout (first order, or a payment link).
create or replace function mark_order_paid_online(p_order bigint, p_intent text, p_amount numeric,
                                                  p_pm text default null, p_brand text default null, p_last4 text default null,
                                                  p_stripe_customer text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o orders; v_total numeric;
begin
  select * into o from orders where id = p_order for update;
  if not found then return jsonb_build_object('ok', false); end if;
  if o.stripe_payment_intent_id = p_intent and o.payment_status = 'paid' then return jsonb_build_object('ok', true, 'duplicate', true); end if;
  select total into v_total from v_orders where id = p_order;
  update orders set payment_status = 'paid', charge_status = 'succeeded', stripe_payment_intent_id = p_intent,
                    charged_amount = p_amount, last_charge_at = now(),
                    needs_review = needs_review or abs(p_amount - v_total) > 0.009,
                    review_note = case when abs(p_amount - v_total) > 0.009
                                       then concat_ws(' · ', review_note, format('Se cobraron %s y el total es %s', p_amount, v_total))
                                       else review_note end
   where id = p_order;
  if p_stripe_customer is not null then
    update customers set stripe_customer_id = p_stripe_customer where id = o.customer_id and stripe_customer_id is null;
  end if;
  if o.subscription_id is not null and p_pm is not null then
    update subscriptions set stripe_payment_method_id = p_pm, card_brand = p_brand, card_last4 = p_last4,
                             last_charged_amount = p_amount, payment_method = 'card'
     where id = o.subscription_id;
  end if;
  if o.contact_email is not null and o.channel = 'web' then
    insert into notifications(kind, to_email, order_id) values ('order_confirmation', o.contact_email, p_order);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Public read functions (anon) ---------------------------------
create or replace function store_catalog() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'store', (select jsonb_build_object('name', store_name, 'open', store_open, 'closed_message', store_closed_message,
                     'whatsapp', store_whatsapp, 'sub_discount_pct', sub_discount_pct, 'delivery_fee', delivery_fee,
                     'free_delivery_zips', free_delivery_zips, 'delivery_weekdays', delivery_weekdays,
                     'price_notice_days', price_notice_days)
                from settings),
    'delivery_dates', jsonb_build_array(next_delivery_on(current_date + 1),
                                        next_delivery_on(next_delivery_on(current_date + 1) + 1)),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'name', p.name, 'category', p.category, 'description', p.description,
               'image_url', p.image_url, 'base_unit', p.base_unit,
               'variants', (select jsonb_agg(jsonb_build_object(
                                  'id', v.id, 'label', v.label, 'price', v.price, 'pack_qty', v.pack_qty,
                                  'subscribable', v.subscribable,
                                  'available', coalesce(st.on_hand, 0) >= v.pack_qty)
                                order by v.pack_qty)
                              from product_variants v
                             where v.product_id = p.id and v.active and v.visible))
             order by p.category, p.name)
        from products p
        left join v_stock st on st.product_id = p.id
       where p.active and p.visible
         and exists (select 1 from product_variants v where v.product_id = p.id and v.active and v.visible)
    ), '[]'::jsonb));
$$;

create or replace function store_order(p_token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', o.id, 'status', o.status, 'payment_status', o.payment_status, 'payment_method', o.payment_method,
    'charge_status', o.charge_status, 'delivery_date', o.delivery_date, 'order_date', o.order_date,
    'customer', split_part(c.name, ' ', 1),
    'address', coalesce(o.delivery_address, c.address), 'postal_code', coalesce(o.delivery_postal_code, c.postal_code),
    'items', (select jsonb_agg(jsonb_build_object('name', p.name, 'label', v.label, 'qty', oi.qty,
                                                  'unit_price', oi.unit_price, 'line_total', oi.line_total) order by oi.id)
                from order_items oi join product_variants v on v.id = oi.variant_id join products p on p.id = v.product_id
               where oi.order_id = o.id),
    'subtotal', vo.subtotal, 'discount', o.discount, 'delivery_fee', o.delivery_fee, 'total', vo.total,
    'subscription', case when s.id is not null then jsonb_build_object('frequency_weeks', s.frequency_weeks,
                     'manage_token', s.manage_token, 'card_last4', s.card_last4) end,
    'spei', case when o.payment_method = 'spei' then (select jsonb_build_object('bank', bank_name, 'clabe', bank_clabe,
                     'beneficiary', bank_beneficiary, 'reference', 'Pedido ' || o.id) from settings) end,
    'store', (select jsonb_build_object('name', store_name, 'whatsapp', store_whatsapp) from settings))
  from orders o
  join customers c on c.id = o.customer_id
  join v_orders vo on vo.id = o.id
  left join subscriptions s on s.id = o.subscription_id
  where o.public_token = p_token;
$$;

create or replace function store_subscription(p_token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'status', s.status, 'frequency_weeks', s.frequency_weeks, 'next_delivery_date', s.next_delivery_date,
    'payment_method', s.payment_method, 'card_brand', s.card_brand, 'card_last4', s.card_last4,
    'customer', split_part(c.name, ' ', 1), 'address', coalesce(s.delivery_address, c.address),
    'items', (select jsonb_agg(jsonb_build_object('name', p.name, 'label', v.label, 'qty', si.qty,
                                                  'price', subscriber_price(v.id, s.next_delivery_date)))
                from subscription_items si join product_variants v on v.id = si.variant_id join products p on p.id = v.product_id
               where si.subscription_id = s.id),
    'discount_pct', st.sub_discount_pct,
    'delivery_fee', delivery_fee_for(coalesce(s.delivery_postal_code, c.postal_code)),
    'pending_order', (select jsonb_build_object('token', o.public_token, 'id', o.id, 'delivery_date', o.delivery_date,
                                                'charge_status', o.charge_status, 'payment_status', o.payment_status)
                        from orders o where o.subscription_id = s.id and o.status in ('pending','confirmed','out_for_delivery')
                       order by o.delivery_date limit 1),
    'store', jsonb_build_object('name', st.store_name, 'whatsapp', st.store_whatsapp))
  from subscriptions s join customers c on c.id = s.customer_id cross join settings st
  where s.manage_token = p_token;
$$;

-- Self-service actions (called by the `store` Edge Function).
create or replace function subscription_self_service(p_token uuid, p_action text, p_value int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s subscriptions;
begin
  select * into s from subscriptions where manage_token = p_token for update;
  if not found then raise exception 'Liga no válida.'; end if;
  if s.status = 'cancelled' and p_action <> 'resume' then raise exception 'Esta suscripción ya está cancelada.'; end if;
  if p_action = 'skip' then
    update subscriptions set next_delivery_date = next_delivery_date + frequency_weeks * 7 where id = s.id;
  elsif p_action = 'pause' then
    update subscriptions set status = 'paused' where id = s.id;
  elsif p_action = 'resume' then
    update subscriptions set status = 'active', cancelled_on = null,
                             next_delivery_date = greatest(next_delivery_date, next_delivery_on(current_date + 3)) where id = s.id;
  elsif p_action = 'cancel' then
    update subscriptions set status = 'cancelled', cancelled_on = current_date where id = s.id;
  elsif p_action = 'frequency' then
    if p_value not in (1,2,3,4,6,8) then raise exception 'Frecuencia no válida.'; end if;
    update subscriptions set frequency_weeks = p_value where id = s.id;
  else raise exception 'Acción no válida.';
  end if;
  insert into notifications(kind, to_admin, subscription_id, payload)
  values ('subscription_change', true, s.id, jsonb_build_object('action', p_action, 'value', p_value));
  return store_subscription(p_token);
end $$;

-- ---------- Daily job: add card charges and email outbox -----------------
create or replace function send_function(p_name text, p_body jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_url text; v_secret text;
begin
  select decrypted_secret into v_url    from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'cron_secret';
  if v_url is null or v_secret is null then
    insert into automation_runs(job, ok, details) values (p_name, false, jsonb_build_object('error', 'Falta project_url o cron_secret en Vault'));
    return;
  end if;
  perform net.http_post(url := v_url || '/functions/v1/' || p_name, body := p_body,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', v_secret),
    timeout_milliseconds := 60000);
end $$;

create or replace function automation_daily(p_today date default current_date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_orders int; v_new jsonb; v_route_day date; v_lead int; v_charge int;
begin
  select lead_days into v_lead from settings;

  v_orders := create_due_subscription_orders(p_today);
  insert into automation_runs(job, details) values ('subscriptions', jsonb_build_object('orders_created', v_orders));

  select count(*) into v_charge from orders_to_charge(p_today);
  if v_charge > 0 then perform send_function('charges', jsonb_build_object('action', 'run')); end if;

  v_new := check_reorder_alerts();
  insert into automation_runs(job, details) values ('reorder_check', jsonb_build_object('new_alerts', jsonb_array_length(v_new)));
  if jsonb_array_length(v_new) > 0 then
    perform send_report('reorder', jsonb_build_object('product_ids', v_new));
  end if;

  v_route_day := p_today + v_lead;
  if next_delivery_on(v_route_day) = v_route_day
     and not exists (select 1 from automation_runs where job = 'route_requested' and details->>'date' = v_route_day::text) then
    perform send_report('route', jsonb_build_object('date', v_route_day));
    insert into automation_runs(job, details) values ('route_requested', jsonb_build_object('date', v_route_day));
  end if;

  if exists (select 1 from notifications where sent_at is null) then
    perform send_report('outbox');
  end if;

  return jsonb_build_object('orders_created', v_orders, 'charges', v_charge, 'new_alerts', v_new,
                            'route_day', case when next_delivery_on(v_route_day) = v_route_day then v_route_day end);
exception when others then
  insert into automation_runs(job, ok, details) values ('daily', false, jsonb_build_object('error', sqlerrm));
  return jsonb_build_object('error', sqlerrm);
end $$;

-- ---------- Security ------------------------------------------------------
alter table notifications enable row level security;
create policy admin_all on notifications for all to authenticated using (is_admin()) with check (is_admin());
revoke all on notifications from anon;

-- Public store: read-only functions, nothing else.
revoke all on function store_catalog(), store_order(uuid), store_subscription(uuid) from public;
grant execute on function store_catalog(), store_order(uuid), store_subscription(uuid) to anon, authenticated;

-- Server-only (service role / scheduler).
revoke all on function place_web_order(jsonb), charge_preflight(bigint, boolean), charge_result(bigint, boolean, text, text, text),
                       orders_to_charge(date), mark_order_paid_online(bigint, text, numeric, text, text, text, text),
                       subscription_self_service(uuid, text, int), send_function(text, jsonb), automation_daily(date)
  from public, anon, authenticated;

revoke all on function delivery_fee_for(text), subscriber_price(bigint, date), normalize_phone(text) from public, anon;
grant execute on function delivery_fee_for(text), subscriber_price(bigint, date), normalize_phone(text) to authenticated;

-- ---------- Product photos (Supabase Storage) ----------------------------
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public) values ('product-images', 'product-images', true)
    on conflict (id) do update set public = true;
    execute $p$create policy "admin insert product images" on storage.objects for insert to authenticated
             with check (bucket_id = 'product-images' and public.is_admin())$p$;
    execute $p$create policy "admin update product images" on storage.objects for update to authenticated
             using (bucket_id = 'product-images' and public.is_admin())$p$;
    execute $p$create policy "admin delete product images" on storage.objects for delete to authenticated
             using (bucket_id = 'product-images' and public.is_admin())$p$;
  end if;
end $$;

-- ===================== migrations/007_bundles.sql =====================
-- =====================================================================
-- Cloro Diego · 007: bundles, subscribe per product, customer-facing
-- order names, and subscription safety. Run once, after 006.
--   • Bundles (paquetes): fixed contents, fixed price, one-time or subscription.
--   • Per-product subscription in one order, one frequency; 5% only on subscribed items.
--   • Customers see "Pedido dd/mm/yyyy"; the internal counter stays as is.
--   • Pausing, cancelling or deleting a subscription cancels its upcoming,
--     not-yet-charged order. Skipping cancels that order if it already exists.
--   • Sold out at order time: that item is dropped from the delivery (and the charge);
--     customer and admin are emailed.
--   • Deactivating a size, product or bundle removes it from subscriptions,
--     emails the customer, and pauses subscriptions left empty.
-- =====================================================================

-- ---------- Customer-facing order name -----------------------------------
create or replace function order_label(p_date date) returns text
language sql immutable as $$ select 'Pedido ' || to_char(p_date, 'DD/MM/YYYY') $$;

-- ---------- Bundles -------------------------------------------------------
create table bundles (
  id               bigint generated always as identity primary key,
  name             text not null unique,
  description      text,
  image_url        text,
  price            numeric(10,2) not null check (price > 0),   -- fixed bundle price
  active           boolean not null default true,
  visible          boolean not null default true,              -- shown in the store
  subscribable     boolean not null default true,
  sort             int not null default 0,                     -- order in the store (lower first)
  prev_price       numeric(10,2),                              -- subscribers' price during the notice period
  price_changed_at date,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create trigger t_upd before update on bundles for each row execute function set_updated_at();

create table bundle_items (
  bundle_id   bigint not null references bundles(id) on delete cascade,
  variant_id  bigint not null references product_variants(id) on delete restrict,
  qty         int not null check (qty between 1 and 50),
  primary key (bundle_id, variant_id)
);

create table subscription_bundles (
  subscription_id bigint not null references subscriptions(id) on delete cascade,
  bundle_id       bigint not null references bundles(id) on delete restrict,
  qty             int not null check (qty between 1 and 50),
  primary key (subscription_id, bundle_id)
);

-- A bundle in an order is stored as its component sizes (so stock, cost and margin
-- keep working), tagged with the bundle. The savings go into orders.discount.
alter table order_items
  add column bundle_id         bigint references bundles(id) on delete set null,
  add column bundle_qty        int,              -- bundles bought; same on each component row
  add column bundle_unit_price numeric(10,2);    -- bundle price at the time of the order
alter table orders
  add column bundle_discount numeric(10,2) not null default 0;   -- the part of `discount` that is bundle savings

alter table bundles enable row level security;
alter table bundle_items enable row level security;
alter table subscription_bundles enable row level security;
create policy admin_all on bundles for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all on bundle_items for all to authenticated using (is_admin()) with check (is_admin());
create policy admin_all on subscription_bundles for all to authenticated using (is_admin()) with check (is_admin());
grant select, insert, update, delete on bundles, bundle_items, subscription_bundles to authenticated;
revoke all on bundles, bundle_items, subscription_bundles from anon;

-- New email kinds.
alter table notifications drop constraint notifications_kind_check;
alter table notifications add constraint notifications_kind_check check (kind in
  ('order_confirmation','admin_new_order','price_change','charge_failed','charge_needs_approval',
   'payment_link','subscription_change','delivery_adjusted','subscription_item_removed'));

-- ---------- Where to email a subscriber -----------------------------------
-- The customer's saved email, or the one they typed on their store orders (the directory is
-- never overwritten from the store, so a customer may only have it there).
create or replace function subscription_email(p_sub bigint) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(c.email, (select o.contact_email from orders o where o.subscription_id = s.id and o.contact_email is not null
                             order by o.id desc limit 1))
    from subscriptions s join customers c on c.id = s.customer_id where s.id = p_sub;
$$;

-- Size price changes: same email, now also to customers whose email is only on their orders.
create or replace function variants_price_notify() returns trigger
language plpgsql as $$
begin
  if new.price is distinct from old.price then
    insert into notifications(kind, to_email, subscription_id, payload)
    select 'price_change', subscription_email(s.id), s.id,
           jsonb_build_object('product', p.name, 'label', new.label, 'old_price', new.prev_price, 'new_price', new.price,
                              'effective_from', new.price_changed_at + st.price_notice_days)
      from subscription_items si
      join subscriptions s on s.id = si.subscription_id and s.status in ('active','paused')
      join products p on p.id = new.product_id
      cross join settings st
     where si.variant_id = new.id and subscription_email(s.id) is not null;
  end if;
  return new;
end $$;

-- ---------- Bundle helpers ------------------------------------------------
create or replace function bundle_regular_price(p_bundle bigint) returns numeric
language sql stable as $$
  select coalesce(sum(bi.qty * v.price), 0)
    from bundle_items bi join product_variants v on v.id = bi.variant_id where bi.bundle_id = p_bundle;
$$;

-- Sellable: the bundle and every component size/product are active.
create or replace function bundle_sellable(p_bundle bigint) returns boolean
language sql stable as $$
  select b.active and exists (select 1 from bundle_items where bundle_id = b.id)
         and not exists (select 1 from bundle_items bi join product_variants v on v.id = bi.variant_id
                           join products p on p.id = v.product_id
                          where bi.bundle_id = b.id and not (v.active and p.active))
    from bundles b where b.id = p_bundle;
$$;

create or replace function product_on_hand(p_product bigint) returns numeric
language sql stable as $$ select coalesce(sum(qty), 0) from inventory_movements where product_id = p_product $$;

-- Enough stock for p_qty bundles (components grouped by product).
create or replace function bundle_in_stock(p_bundle bigint, p_qty int default 1) returns boolean
language sql stable as $$
  select coalesce(bool_and(product_on_hand(n.product_id) >= n.need), false)
    from (select v.product_id, sum(bi.qty * v.pack_qty * p_qty) as need
            from bundle_items bi join product_variants v on v.id = bi.variant_id
           where bi.bundle_id = p_bundle group by v.product_id) n;
$$;

create or replace function bundle_subscriber_price(p_bundle bigint, p_delivery date) returns numeric
language sql stable as $$
  select case when b.prev_price is not null and b.price_changed_at is not null
                   and p_delivery < b.price_changed_at + s.price_notice_days
              then b.prev_price else b.price end
    from bundles b, settings s where b.id = p_bundle;
$$;

-- Bundle price changes: same notice rule and email as sizes.
create or replace function bundles_price_change() returns trigger
language plpgsql as $$
declare v_notice int;
begin
  if new.price is distinct from old.price then
    select price_notice_days into v_notice from settings;
    new.prev_price := case when old.price_changed_at is not null and current_date < old.price_changed_at + v_notice
                           then coalesce(old.prev_price, old.price) else old.price end;
    new.price_changed_at := current_date;
  end if;
  return new;
end $$;
create trigger bundles_price_change before update of price on bundles
for each row execute function bundles_price_change();

create or replace function bundles_price_notify() returns trigger
language plpgsql as $$
begin
  if new.price is distinct from old.price then
    insert into notifications(kind, to_email, subscription_id, payload)
    select 'price_change', subscription_email(s.id), s.id,
           jsonb_build_object('product', new.name, 'label', 'paquete', 'old_price', new.prev_price, 'new_price', new.price,
                              'effective_from', new.price_changed_at + st.price_notice_days)
      from subscription_bundles sb
      join subscriptions s on s.id = sb.subscription_id and s.status in ('active','paused')
      cross join settings st
     where sb.bundle_id = new.id and subscription_email(s.id) is not null;
  end if;
  return new;
end $$;
create trigger bundles_price_notify after update of price on bundles
for each row execute function bundles_price_notify();

-- ---------- Order lines ---------------------------------------------------
-- Adds a size or a bundle to an order. p_bundle_price: the bundle price to use
-- (subscriber price for subscription orders); sizes take p_unit_price or the catalog price.
create or replace function add_order_line(p_order bigint, p_variant bigint, p_bundle bigint, p_qty int,
                                          p_unit_price numeric default null, p_bundle_price numeric default null)
returns void language plpgsql as $$
begin
  if p_bundle is null then
    insert into order_items(order_id, variant_id, qty, unit_price) values (p_order, p_variant, p_qty, p_unit_price);
  else
    insert into order_items(order_id, variant_id, qty, bundle_id, bundle_qty, bundle_unit_price)
    select p_order, bi.variant_id, bi.qty * p_qty, p_bundle, p_qty,
           coalesce(p_bundle_price, (select price from bundles where id = p_bundle))
      from bundle_items bi where bi.bundle_id = p_bundle;
  end if;
end $$;

-- Savings of the bundles in an order: components at catalog price − bundle price (never negative).
create or replace function order_bundle_savings(p_order bigint) returns numeric
language sql stable as $$
  select coalesce(sum(greatest(g.lines - g.bprice, 0)), 0)
    from (select bundle_id, sum(line_total) as lines, max(bundle_unit_price * bundle_qty) as bprice
            from order_items where order_id = p_order and bundle_id is not null group by bundle_id) g;
$$;

-- Subscription orders: everything in them is subscribed. Recomputes the discount;
-- cancels the order if nothing is left in it.
create or replace function recalc_subscription_order(p_order bigint) returns void
language plpgsql as $$
declare v_sub numeric; v_save numeric; st settings;
begin
  select * into st from settings;
  if not exists (select 1 from order_items where order_id = p_order) then
    update orders set status = 'cancelled', charge_status = 'none', discount = 0, bundle_discount = 0,
                      notes = concat_ws(' · ', notes, 'Cancelado: no quedó nada que entregar')
     where id = p_order;
    return;
  end if;
  select coalesce(sum(line_total), 0) into v_sub from order_items where order_id = p_order;
  v_save := order_bundle_savings(p_order);
  update orders set bundle_discount = v_save,
                    discount = v_save + round((v_sub - v_save) * st.sub_discount_pct / 100, 2)
   where id = p_order;
end $$;

-- Customer-facing lines: bundles collapsed into one line at the bundle price.
create or replace function order_public_items(p_order bigint) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(x.j order by x.first_id), '[]'::jsonb) from (
    select min(oi.id) as first_id,
           jsonb_build_object('name', p.name, 'label', v.label, 'qty', oi.qty, 'unit_price', oi.unit_price, 'line_total', oi.line_total) as j
      from order_items oi join product_variants v on v.id = oi.variant_id join products p on p.id = v.product_id
     where oi.order_id = p_order and oi.bundle_id is null
     group by oi.id, p.name, v.label
    union all
    select min(oi.id),
           jsonb_build_object('name', b.name, 'label', 'Paquete', 'qty', max(oi.bundle_qty), 'unit_price', max(oi.bundle_unit_price),
                              'line_total', least(sum(oi.line_total), max(oi.bundle_unit_price * oi.bundle_qty)), 'bundle', true,
                              'contents', string_agg(trim(to_char(oi.qty, 'FM999990.###')) || ' × ' || p.name || ' ' || v.label, ', ' order by oi.id))
      from order_items oi join bundles b on b.id = oi.bundle_id
      join product_variants v on v.id = oi.variant_id join products p on p.id = v.product_id
     where oi.order_id = p_order and oi.bundle_id is not null
     group by b.id, b.name
  ) x;
$$;

create or replace function order_public_summary(p_order bigint) returns text
language sql stable as $$
  select string_agg(trim(to_char((j->>'qty')::numeric, 'FM999990.###')) || ' × ' || (j->>'name')
                    || case when j->>'label' = 'Paquete' then ' (paquete)' else ' ' || (j->>'label') end, ', ')
    from jsonb_array_elements(order_public_items(p_order)) j;
$$;

-- ---------- Subscriptions: stop upcoming orders on pause / cancel / delete -----
create or replace function subscriptions_stop_orders() returns trigger
language plpgsql as $$
declare v_why text;
begin
  if tg_op = 'DELETE' then v_why := 'suscripción eliminada';
  elsif old.status = 'active' and new.status = 'paused' then v_why := 'suscripción pausada';
  elsif old.status <> 'cancelled' and new.status = 'cancelled' then v_why := 'suscripción cancelada';
  else return new; end if;
  -- Orders already charged or being charged are left alone (refund from the order if needed).
  update orders set status = 'cancelled', charge_status = 'none', notes = concat_ws(' · ', notes, 'Cancelado: ' || v_why)
   where subscription_id = old.id and channel = 'subscription'
     and payment_status = 'pending' and status in ('pending','confirmed')
     and charge_status in ('none','pending','failed','requires_approval');
  return case when tg_op = 'DELETE' then old else new end;
end $$;
create trigger subscriptions_stop_orders_upd after update of status on subscriptions
for each row execute function subscriptions_stop_orders();
create trigger subscriptions_stop_orders_del before delete on subscriptions
for each row execute function subscriptions_stop_orders();

-- ---------- Deactivated sizes / products / bundles leave subscriptions ----
create or replace function drop_from_subscriptions(p_variants bigint[], p_bundles bigint[]) returns void
language plpgsql security definer set search_path = public as $$
declare r record; o record; v_names text[]; v_empty boolean;
begin
  p_variants := coalesce(p_variants, '{}'); p_bundles := coalesce(p_bundles, '{}');
  -- A bundle with a removed size can't be delivered: deactivate it (this runs again for it).
  if cardinality(p_variants) > 0 then
    update bundles set active = false
     where active and id in (select bundle_id from bundle_items where variant_id = any (p_variants));
  end if;

  for r in
    select s.id, s.status, subscription_email(s.id) as email
      from subscriptions s
     where s.status <> 'cancelled'
       and (exists (select 1 from subscription_items si where si.subscription_id = s.id and si.variant_id = any (p_variants))
            or exists (select 1 from subscription_bundles sb where sb.subscription_id = s.id and sb.bundle_id = any (p_bundles)))
  loop
    select array_agg(n) into v_names from (
      select p.name || ' ' || v.label as n from subscription_items si
        join product_variants v on v.id = si.variant_id join products p on p.id = v.product_id
       where si.subscription_id = r.id and si.variant_id = any (p_variants)
      union all
      select b.name from subscription_bundles sb join bundles b on b.id = sb.bundle_id
       where sb.subscription_id = r.id and sb.bundle_id = any (p_bundles)) t;
    delete from subscription_items where subscription_id = r.id and variant_id = any (p_variants);
    delete from subscription_bundles where subscription_id = r.id and bundle_id = any (p_bundles);
    v_empty := not exists (select 1 from subscription_items where subscription_id = r.id)
           and not exists (select 1 from subscription_bundles where subscription_id = r.id);
    if v_empty and r.status = 'active' then
      update subscriptions set status = 'paused' where id = r.id;    -- also cancels its upcoming order
    end if;
    if r.email is not null then
      insert into notifications(kind, to_email, subscription_id, payload)
      values ('subscription_item_removed', r.email, r.id, jsonb_build_object('removed', v_names, 'paused', v_empty));
    end if;
    insert into notifications(kind, to_admin, subscription_id, payload)
    values ('subscription_item_removed', true, r.id, jsonb_build_object('removed', v_names, 'paused', v_empty));
  end loop;

  -- Upcoming subscription orders not charged yet: take those lines out (cancel if empty).
  for o in
    select distinct oi.order_id from order_items oi join orders od on od.id = oi.order_id
     where od.channel = 'subscription' and od.payment_status = 'pending' and od.status in ('pending','confirmed')
       and od.charge_status in ('none','pending','failed','requires_approval')
       and (oi.variant_id = any (p_variants) or oi.bundle_id = any (p_bundles))
  loop
    delete from order_items where order_id = o.order_id and (variant_id = any (p_variants) or bundle_id = any (p_bundles));
    perform recalc_subscription_order(o.order_id);
  end loop;
end $$;

create or replace function variants_deactivated() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.active and not new.active then perform drop_from_subscriptions(array[new.id], '{}'); end if;
  return new;
end $$;
create trigger variants_deactivated after update of active on product_variants
for each row execute function variants_deactivated();

create or replace function products_deactivated() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.active and not new.active then
    perform drop_from_subscriptions(array(select id from product_variants where product_id = new.id), '{}');
  end if;
  return new;
end $$;
create trigger products_deactivated after update of active on products
for each row execute function products_deactivated();

create or replace function bundles_deactivated() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.active and not new.active then perform drop_from_subscriptions('{}', array[new.id]); end if;
  return new;
end $$;
create trigger bundles_deactivated after update of active on bundles
for each row execute function bundles_deactivated();

-- ---------- Subscription orders: bundles, sold-out items dropped ----------
create or replace function create_due_subscription_orders(p_today date default current_date)
returns int
language plpgsql as $$
declare s record; it record; v_order bigint; v_deliver date; n int := 0; st settings; v_zip text;
        v_skipped text[]; v_email text;
begin
  select * into st from settings;
  for s in
    select * from subscriptions
     where status = 'active' and next_delivery_date <= p_today + st.lead_days
     for update
  loop
    v_deliver := greatest(s.next_delivery_date, next_delivery_on(p_today));
    if not exists (select 1 from orders where subscription_id = s.id and delivery_date = v_deliver and status <> 'cancelled') then
      select coalesce(s.delivery_postal_code, postal_code) into v_zip from customers where id = s.customer_id;
      v_email := subscription_email(s.id);
      insert into orders(customer_id, order_date, channel, status, delivery_date, delivery_address,
                         delivery_postal_code, payment_method, subscription_id, delivery_fee, notes, charge_status)
      values (s.customer_id, p_today, 'subscription', 'confirmed', v_deliver, s.delivery_address, v_zip,
              s.payment_method, s.id, delivery_fee_for(v_zip), 'Generado por suscripción',
              case when s.payment_method = 'card' and s.stripe_payment_method_id is not null then 'pending' else 'none' end)
      returning id into v_order;

      -- Only what can be delivered goes in the order (and the charge). Stock is checked
      -- line by line, so earlier lines and other orders already count against it.
      v_skipped := '{}';
      for it in
        select si.variant_id, si.qty, v.pack_qty, v.product_id, (v.active and p.active) as ok, p.name || ' ' || v.label as name
          from subscription_items si join product_variants v on v.id = si.variant_id join products p on p.id = v.product_id
         where si.subscription_id = s.id order by si.variant_id
      loop
        if it.ok and product_on_hand(it.product_id) >= it.qty * it.pack_qty then
          perform add_order_line(v_order, it.variant_id, null, it.qty::int, subscriber_price(it.variant_id, v_deliver));
        else
          v_skipped := v_skipped || it.name;
        end if;
      end loop;
      for it in
        select sb.bundle_id, sb.qty, b.name from subscription_bundles sb join bundles b on b.id = sb.bundle_id
         where sb.subscription_id = s.id order by sb.bundle_id
      loop
        if bundle_sellable(it.bundle_id) and bundle_in_stock(it.bundle_id, it.qty) then
          perform add_order_line(v_order, null, it.bundle_id, it.qty, null, bundle_subscriber_price(it.bundle_id, v_deliver));
        else
          v_skipped := v_skipped || (it.name || ' (paquete)');
        end if;
      end loop;

      if not exists (select 1 from order_items where order_id = v_order) then
        delete from orders where id = v_order;      -- nothing to deliver or charge this time
        v_order := null;
      else
        perform recalc_subscription_order(v_order);
        n := n + 1;
      end if;

      if cardinality(v_skipped) > 0 then
        if v_email is not null then
          insert into notifications(kind, to_email, order_id, subscription_id, payload)
          values ('delivery_adjusted', v_email, v_order, s.id,
                  jsonb_build_object('date', v_deliver, 'skipped', v_skipped, 'empty', v_order is null));
        end if;
        insert into notifications(kind, to_admin, order_id, subscription_id, payload)
        values ('delivery_adjusted', true, v_order, s.id,
                jsonb_build_object('date', v_deliver, 'skipped', v_skipped, 'empty', v_order is null));
      end if;
    end if;
    update subscriptions set next_delivery_date = v_deliver + s.frequency_weeks * 7 where id = s.id;
  end loop;
  return n;
end $$;

-- Never charge an order whose subscription is no longer active.
create or replace function orders_to_charge(p_today date default current_date) returns setof bigint
language sql stable security definer set search_path = public as $$
  select o.id from orders o
    join subscriptions s on s.id = o.subscription_id and s.stripe_payment_method_id is not null and s.status = 'active'
   where o.channel = 'subscription' and o.payment_method = 'card' and o.payment_status = 'pending'
     and o.status <> 'cancelled'
     and o.delivery_date <= p_today + (select lead_days from settings)
     and (o.charge_status = 'pending'
          or (o.charge_status = 'failed' and o.charge_attempts = 1 and o.last_charge_at < date_trunc('day', now())
              and coalesce(o.charge_decline_code, '') not in ('lost_card','stolen_card','fraudulent','pickup_card','restricted_card','unknown_outcome')))
   order by o.id;
$$;

-- ---------- Web orders: subscribe per product, bundles --------------------
-- Items: [{variant_id | bundle_id, qty, subscribe}]. One frequency for the subscribed ones.
-- The first order charges everything; later deliveries bring only the subscribed items.
-- Subscription discount: only on subscribed items (bundles: on the bundle price).
create or replace function place_web_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  st settings; v_phone text; v_cust customers; v_order bigint; v_token uuid; v_sub bigint; v_manage uuid;
  v_freq int; v_date date; v_zip text; v_addr text; v_name text; v_email text; v_method text;
  v_diff text[] := '{}'; v_n int; v_bad int; it record; v_total numeric; v_items jsonb;
  v_any_sub boolean; v_sub_base numeric; v_save numeric;
begin
  select * into st from settings;
  if not st.store_open then raise exception 'La tienda no está recibiendo pedidos por ahora.'; end if;

  v_name   := btrim(coalesce(p->>'name', ''));
  v_phone  := normalize_phone(p->>'phone');
  v_email  := nullif(lower(btrim(coalesce(p->>'email', ''))), '');
  v_addr   := btrim(coalesce(p->>'address', ''));
  v_zip    := btrim(coalesce(p->>'postal_code', ''));
  v_method := p->>'payment_method';
  v_freq   := nullif(p->>'frequency_weeks', '')::int;
  v_date   := (p->>'delivery_date')::date;

  -- Normalize items. Older store versions sent frequency_weeks without per-item flags: all subscribed.
  v_items := coalesce(p->'items', '[]');
  if jsonb_typeof(v_items) <> 'array' then raise exception 'Tu carrito está vacío.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'variant_id', nullif(i->>'variant_id', '')::bigint, 'bundle_id', nullif(i->>'bundle_id', '')::bigint,
           'qty', i->>'qty',
           'subscribe', case when i ? 'subscribe' then coalesce((i->>'subscribe')::boolean, false) else v_freq is not null end)), '[]')
    into v_items from jsonb_array_elements(v_items) i;
  v_any_sub := exists (select 1 from jsonb_array_elements(v_items) i where (i->>'subscribe')::boolean);
  if not v_any_sub then v_freq := null; end if;

  if length(v_name) < 2 or length(v_name) > 80 then raise exception 'Escribe tu nombre.'; end if;
  if v_phone is null or v_phone !~ '^\d{10}$' then raise exception 'El WhatsApp debe tener 10 dígitos.'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Revisa el correo.'; end if;
  if length(v_addr) < 5 then raise exception 'Escribe la dirección de entrega.'; end if;
  if v_zip !~ '^27\d{3}$' then raise exception 'El código postal debe ser de Torreón (5 dígitos, empieza con 27).'; end if;
  if v_method not in ('card','cash','spei') then raise exception 'Elige una forma de pago.'; end if;
  if v_date is null or v_date not in (
       select next_delivery_on(current_date + 1)
       union select next_delivery_on(next_delivery_on(current_date + 1) + 1)) then
    raise exception 'Elige una de las fechas de entrega disponibles.';
  end if;
  if v_any_sub and (v_freq is null or v_freq not in (1,2,3,4,6,8)) then raise exception 'Elige cada cuánto quieres recibir tu suscripción.'; end if;
  if v_any_sub and v_method = 'card' and coalesce((p->>'consent')::boolean, false) is not true then
    raise exception 'Para suscribirte con tarjeta acepta el cobro automático en cada entrega.';
  end if;

  v_n := jsonb_array_length(v_items);
  if v_n < 1 or v_n > 20 then raise exception 'Tu carrito está vacío.'; end if;
  select count(*) into v_bad
    from jsonb_array_elements(v_items) i
    left join product_variants v on v.id = (i->>'variant_id')::bigint and v.active and v.visible
    left join products pr on pr.id = v.product_id and pr.active and pr.visible
    left join bundles b on b.id = (i->>'bundle_id')::bigint and b.visible and bundle_sellable(b.id)
   where ((i->>'variant_id') is null) = ((i->>'bundle_id') is null)                 -- exactly one of the two
      or ((i->>'variant_id') is not null and pr.id is null)
      or ((i->>'bundle_id') is not null and b.id is null)
      or (i->>'qty') !~ '^\d+$' or (i->>'qty')::int not between 1 and 50
      or ((i->>'subscribe')::boolean and not coalesce(v.subscribable, b.subscribable, false));
  if v_bad > 0 then raise exception 'Algún producto ya no está disponible. Actualiza la página e intenta de nuevo.'; end if;

  -- Basic abuse limit: max 5 web orders per phone per hour.
  if (select count(*) from orders o join customers c on c.id = o.customer_id
       where c.phone = v_phone and o.channel in ('web') and o.created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Recibimos varios pedidos de este número. Escríbenos por WhatsApp para ayudarte.';
  end if;

  -- Customer: match by phone, never overwrite saved data.
  select * into v_cust from customers where phone = v_phone;
  if not found then
    insert into customers(name, phone, email, address, zone, postal_code, address_notes, source, status)
    values (v_name, v_phone, v_email, v_addr, nullif(btrim(coalesce(p->>'zone','')), ''), v_zip,
            nullif(btrim(coalesce(p->>'address_notes','')), ''), 'web', 'customer')
    returning * into v_cust;
  else
    if lower(v_cust.name) <> lower(v_name) then v_diff := v_diff || ('nombre: ' || v_name); end if;
    if coalesce(lower(v_cust.address), '') <> lower(v_addr) then v_diff := v_diff || ('dirección: ' || v_addr); end if;
    if coalesce(v_cust.postal_code, '') <> v_zip then v_diff := v_diff || ('CP: ' || v_zip); end if;
    if v_email is not null and coalesce(lower(v_cust.email), '') <> v_email then v_diff := v_diff || ('correo: ' || v_email); end if;
    if v_cust.status <> 'customer' then update customers set status = 'customer' where id = v_cust.id; end if;
  end if;

  insert into orders(customer_id, order_date, channel, status, delivery_date, delivery_address, delivery_postal_code,
                     payment_method, delivery_fee, contact_email, notes, needs_review, review_note, charge_status)
  values (v_cust.id, current_date, 'web', 'pending', v_date,
          case when coalesce(lower(v_cust.address), '') <> lower(v_addr) then v_addr end, v_zip,
          v_method, delivery_fee_for(v_zip), v_email,
          nullif(btrim(concat_ws(' · ', nullif(p->>'address_notes',''), nullif(p->>'notes',''))), ''),
          cardinality(v_diff) > 0,
          case when cardinality(v_diff) > 0 then 'Datos distintos a los guardados del cliente — ' || array_to_string(v_diff, '; ') end,
          case when v_method = 'card' then 'pending' else 'none' end)
  returning id, public_token into v_order, v_token;

  -- Lines, merged by item. Only the subscribed quantity counts for the subscription discount.
  v_sub_base := 0;
  for it in
    select (i->>'variant_id')::bigint as variant_id, (i->>'bundle_id')::bigint as bundle_id,
           sum((i->>'qty')::int)::int as qty,
           coalesce(sum((i->>'qty')::int) filter (where (i->>'subscribe')::boolean), 0)::int as sub_qty
      from jsonb_array_elements(v_items) i group by 1, 2
  loop
    perform add_order_line(v_order, it.variant_id, it.bundle_id, it.qty);
    v_sub_base := v_sub_base + it.sub_qty * coalesce((select price from product_variants where id = it.variant_id),
                                                     (select least(price, bundle_regular_price(id)) from bundles where id = it.bundle_id));
  end loop;
  v_save := order_bundle_savings(v_order);
  update orders set bundle_discount = v_save,
                    discount = v_save + round(v_sub_base * st.sub_discount_pct / 100, 2)
   where id = v_order;

  if v_any_sub then
    insert into subscriptions(customer_id, frequency_weeks, next_delivery_date, payment_method, delivery_address,
                              delivery_postal_code, notes, source, consent_at, consent_text)
    values (v_cust.id, v_freq, v_date + v_freq * 7, v_method,
            case when coalesce(lower(v_cust.address), '') <> lower(v_addr) then v_addr end,
            case when coalesce(v_cust.postal_code, '') <> v_zip then v_zip end,
            'Creada en la tienda', 'web',
            case when v_method = 'card' then now() end, nullif(p->>'consent_text', ''))
    returning id, manage_token into v_sub, v_manage;
    insert into subscription_items(subscription_id, variant_id, qty)
    select v_sub, (i->>'variant_id')::bigint, sum((i->>'qty')::int)
      from jsonb_array_elements(v_items) i
     where (i->>'subscribe')::boolean and (i->>'variant_id') is not null group by 1, 2;
    insert into subscription_bundles(subscription_id, bundle_id, qty)
    select v_sub, (i->>'bundle_id')::bigint, sum((i->>'qty')::int)
      from jsonb_array_elements(v_items) i
     where (i->>'subscribe')::boolean and (i->>'bundle_id') is not null group by 1, 2;
    update orders set subscription_id = v_sub where id = v_order;
  end if;

  select total into v_total from v_orders where id = v_order;
  insert into notifications(kind, to_admin, order_id) values ('admin_new_order', true, v_order);
  if v_email is not null and v_method <> 'card' then        -- card orders confirm after payment
    insert into notifications(kind, to_email, order_id) values ('order_confirmation', v_email, v_order);
  end if;
  return jsonb_build_object('order_id', v_order, 'token', v_token, 'total', v_total, 'payment_method', v_method,
                            'subscription_id', v_sub, 'manage_token', v_manage, 'customer_id', v_cust.id);
end $$;

-- ---------- Customer-facing name in Stripe; bundles in the catalog -----------
create or replace function charge_preflight(p_order bigint, p_approved boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o orders; s subscriptions; c customers; st settings; v_amount numeric; v_today numeric; v_reason text;
begin
  select * into st from settings;
  select * into o from orders where id = p_order for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'Pedido no existe'); end if;
  if o.status = 'cancelled' then return jsonb_build_object('ok', false, 'reason', 'Pedido cancelado'); end if;
  if o.payment_status = 'paid' then return jsonb_build_object('ok', false, 'reason', 'Ya está pagado'); end if;
  if o.payment_method <> 'card' then return jsonb_build_object('ok', false, 'reason', 'El pedido no es con tarjeta'); end if;
  if o.charge_status = 'processing' then return jsonb_build_object('ok', false, 'reason', 'Hay un cobro en curso'); end if;
  if o.charge_status = 'requires_approval' and not p_approved then
    return jsonb_build_object('ok', false, 'reason', 'Requiere aprobación');
  end if;
  select * into s from subscriptions where id = o.subscription_id;
  if s.id is null or s.stripe_payment_method_id is null then
    return jsonb_build_object('ok', false, 'reason', 'No hay tarjeta guardada para este pedido');
  end if;
  select * into c from customers where id = o.customer_id;
  if c.stripe_customer_id is null then return jsonb_build_object('ok', false, 'reason', 'Cliente sin registro en Stripe'); end if;

  select total into v_amount from v_orders where id = p_order;      -- always recomputed, never typed
  if v_amount is null or v_amount <= 0 then return jsonb_build_object('ok', false, 'reason', 'Total inválido'); end if;

  if not p_approved then
    select coalesce(sum(charged_amount), 0) into v_today from orders
     where charge_status in ('processing','succeeded') and last_charge_at >= date_trunc('day', now());
    if v_amount > st.max_auto_charge then
      v_reason := format('El cobro de %s supera el máximo por cobro (%s)', v_amount, st.max_auto_charge);
    elsif s.last_charged_amount is not null and v_amount > s.last_charged_amount * st.auto_charge_ratio then
      v_reason := format('El cobro de %s es más de %s× el último cobro de esta suscripción (%s)', v_amount, st.auto_charge_ratio, s.last_charged_amount);
    elsif v_today + v_amount > st.daily_auto_charge_cap then
      v_reason := format('Se alcanzó el límite diario de cobros automáticos (%s)', st.daily_auto_charge_cap);
    end if;
    if v_reason is not null then
      update orders set charge_status = 'requires_approval', charge_error = v_reason where id = p_order;
      insert into notifications(kind, to_admin, order_id, payload)
      values ('charge_needs_approval', true, p_order, jsonb_build_object('reason', v_reason, 'amount', v_amount));
      return jsonb_build_object('ok', false, 'reason', v_reason, 'requires_approval', true);
    end if;
  end if;

  update orders set charge_status = 'processing', charge_attempts = charge_attempts + 1, last_charge_at = now(),
                    charged_amount = v_amount, charge_error = null, charge_decline_code = null,
                    charge_approved = charge_approved or p_approved
   where id = p_order;
  return jsonb_build_object('ok', true, 'amount', v_amount, 'order_id', p_order,
                            'key', format('order-%s-try-%s', p_order, o.charge_attempts + 1),
                            'customer', c.stripe_customer_id, 'payment_method', s.stripe_payment_method_id,
                            'description', format('%s · %s', order_label(o.order_date), st.store_name));
end $$;

create or replace function store_catalog() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'store', (select jsonb_build_object('name', store_name, 'open', store_open, 'closed_message', store_closed_message,
                     'whatsapp', store_whatsapp, 'sub_discount_pct', sub_discount_pct, 'delivery_fee', delivery_fee,
                     'free_delivery_zips', free_delivery_zips, 'delivery_weekdays', delivery_weekdays,
                     'price_notice_days', price_notice_days)
                from settings),
    'delivery_dates', jsonb_build_array(next_delivery_on(current_date + 1),
                                        next_delivery_on(next_delivery_on(current_date + 1) + 1)),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'name', p.name, 'category', p.category, 'description', p.description,
               'image_url', p.image_url, 'base_unit', p.base_unit,
               'variants', (select jsonb_agg(jsonb_build_object(
                                  'id', v.id, 'label', v.label, 'price', v.price, 'pack_qty', v.pack_qty,
                                  'subscribable', v.subscribable,
                                  'available', coalesce(st.on_hand, 0) >= v.pack_qty)
                                order by v.pack_qty)
                              from product_variants v
                             where v.product_id = p.id and v.active and v.visible))
             order by p.category, p.name)
        from products p
        left join v_stock st on st.product_id = p.id
       where p.active and p.visible
         and exists (select 1 from product_variants v where v.product_id = p.id and v.active and v.visible)
    ), '[]'::jsonb),
    'bundles', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', b.id, 'name', b.name, 'description', b.description, 'image_url', b.image_url,
               'price', least(b.price, r.regular), 'regular_price', r.regular,
               'savings_pct', case when r.regular > 0 then round((1 - least(b.price, r.regular) / r.regular) * 100) else 0 end,
               'subscribable', b.subscribable, 'available', bundle_in_stock(b.id, 1),
               'items', (select jsonb_agg(jsonb_build_object('name', p.name, 'label', v.label, 'qty', bi.qty) order by p.name, v.pack_qty)
                           from bundle_items bi join product_variants v on v.id = bi.variant_id join products p on p.id = v.product_id
                          where bi.bundle_id = b.id))
             order by b.sort, b.name)
        from bundles b cross join lateral (select bundle_regular_price(b.id) as regular) r
       where b.visible and bundle_sellable(b.id)
    ), '[]'::jsonb));
$$;
create or replace function store_order(p_token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', o.id, 'label', order_label(o.order_date),
    'status', o.status, 'payment_status', o.payment_status, 'payment_method', o.payment_method,
    'charge_status', o.charge_status, 'delivery_date', o.delivery_date, 'order_date', o.order_date,
    'customer', split_part(c.name, ' ', 1),
    'address', coalesce(o.delivery_address, c.address), 'postal_code', coalesce(o.delivery_postal_code, c.postal_code),
    'items', order_public_items(o.id),
    -- bundles are shown at their price, so only the subscription discount is shown as a discount
    'subtotal', vo.subtotal - o.bundle_discount, 'discount', o.discount - o.bundle_discount,
    'delivery_fee', o.delivery_fee, 'total', vo.total,
    'subscription', case when s.id is not null then jsonb_build_object('frequency_weeks', s.frequency_weeks,
                     'manage_token', s.manage_token, 'card_last4', s.card_last4) end,
    'spei', case when o.payment_method = 'spei' then (select jsonb_build_object('bank', bank_name, 'clabe', bank_clabe,
                     'beneficiary', bank_beneficiary, 'reference', order_label(o.order_date)) from settings) end,
    'store', (select jsonb_build_object('name', store_name, 'whatsapp', store_whatsapp) from settings))
  from orders o
  join customers c on c.id = o.customer_id
  join v_orders vo on vo.id = o.id
  left join subscriptions s on s.id = o.subscription_id
  where o.public_token = p_token;
$$;

-- The upcoming order of a subscription that can still be skipped (created, not charged).
create or replace function subscription_skippable_order(p_sub bigint) returns bigint
language sql stable as $$
  select id from orders
   where subscription_id = p_sub and channel = 'subscription' and payment_status = 'pending'
     and status in ('pending','confirmed') and charge_status in ('none','pending','failed','requires_approval')
     and delivery_date >= current_date
   order by delivery_date limit 1;
$$;

create or replace function store_subscription(p_token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'status', s.status, 'frequency_weeks', s.frequency_weeks, 'next_delivery_date', s.next_delivery_date,
    -- the delivery "Saltar" applies to: an order already created and not charged, else the next one
    'skip_date', coalesce((select delivery_date from orders where id = subscription_skippable_order(s.id)), s.next_delivery_date),
    'upcoming_date', least(s.next_delivery_date, (select min(delivery_date) from orders o where o.subscription_id = s.id
                                                     and o.channel = 'subscription' and o.status in ('pending','confirmed','out_for_delivery')
                                                     and o.delivery_date >= current_date)),
    'payment_method', s.payment_method, 'card_brand', s.card_brand, 'card_last4', s.card_last4,
    'customer', split_part(c.name, ' ', 1), 'address', coalesce(s.delivery_address, c.address),
    'items', coalesce((select jsonb_agg(x) from (
                select jsonb_build_object('name', p.name, 'label', v.label, 'qty', si.qty,
                                          'price', subscriber_price(v.id, s.next_delivery_date)) as x
                  from subscription_items si join product_variants v on v.id = si.variant_id join products p on p.id = v.product_id
                 where si.subscription_id = s.id
                union all
                select jsonb_build_object('name', b.name, 'label', 'Paquete', 'qty', sb.qty, 'bundle', true,
                                          'price', least(bundle_subscriber_price(b.id, s.next_delivery_date), bundle_regular_price(b.id)))
                  from subscription_bundles sb join bundles b on b.id = sb.bundle_id
                 where sb.subscription_id = s.id) t), '[]'::jsonb),
    'discount_pct', st.sub_discount_pct,
    'delivery_fee', delivery_fee_for(coalesce(s.delivery_postal_code, c.postal_code)),
    'pending_order', (select jsonb_build_object('token', o.public_token, 'id', o.id, 'label', order_label(o.order_date),
                                                'delivery_date', o.delivery_date,
                                                'charge_status', o.charge_status, 'payment_status', o.payment_status)
                        from orders o where o.subscription_id = s.id and o.status in ('pending','confirmed','out_for_delivery')
                       order by o.delivery_date limit 1),
    'store', jsonb_build_object('name', st.store_name, 'whatsapp', st.store_whatsapp))
  from subscriptions s join customers c on c.id = s.customer_id cross join settings st
  where s.manage_token = p_token;
$$;

-- Skip: cancels the upcoming order if it exists and isn't charged; otherwise moves the next date.
create or replace function subscription_self_service(p_token uuid, p_action text, p_value int default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s subscriptions; v_order bigint;
begin
  select * into s from subscriptions where manage_token = p_token for update;
  if not found then raise exception 'Liga no válida.'; end if;
  if s.status = 'cancelled' and p_action <> 'resume' then raise exception 'Esta suscripción ya está cancelada.'; end if;
  if p_action = 'skip' then
    v_order := subscription_skippable_order(s.id);
    if v_order is not null then
      update orders set status = 'cancelled', charge_status = 'none',
                        notes = concat_ws(' · ', notes, 'Cancelado: el cliente saltó esta entrega')
       where id = v_order;
    else
      update subscriptions set next_delivery_date = next_delivery_date + frequency_weeks * 7 where id = s.id;
    end if;
  elsif p_action = 'pause' then
    update subscriptions set status = 'paused' where id = s.id;
  elsif p_action = 'resume' then
    if not exists (select 1 from subscription_items where subscription_id = s.id)
       and not exists (select 1 from subscription_bundles where subscription_id = s.id) then
      raise exception 'Tu suscripción ya no tiene productos. Escríbenos por WhatsApp para armarla de nuevo.';
    end if;
    update subscriptions set status = 'active', cancelled_on = null,
                             next_delivery_date = greatest(next_delivery_date, next_delivery_on(current_date + 3)) where id = s.id;
  elsif p_action = 'cancel' then
    update subscriptions set status = 'cancelled', cancelled_on = current_date where id = s.id;
  elsif p_action = 'frequency' then
    if p_value not in (1,2,3,4,6,8) then raise exception 'Frecuencia no válida.'; end if;
    update subscriptions set frequency_weeks = p_value where id = s.id;
  else raise exception 'Acción no válida.';
  end if;
  insert into notifications(kind, to_admin, subscription_id, payload)
  values ('subscription_change', true, s.id, jsonb_build_object('action', p_action, 'value', p_value,
          'skipped_date', (select delivery_date from orders where id = v_order)));
  return store_subscription(p_token);
end $$;

-- ---------- Views: bundles count in subscriptions and stock ----------------
create or replace view v_subscriptions with (security_invoker = true) as
select s.id, s.customer_id, s.status, s.next_delivery_date, s.payment_method, s.delivery_address, s.notes,
       s.stripe_subscription_id, s.started_on, s.cancelled_on, s.created_at, s.updated_at, s.frequency_weeks,
       c.name as customer_name, c.phone as customer_phone,
       coalesce(s.delivery_address, c.address) as effective_address,
       i.items_summary, coalesce(i.value_per_delivery, 0) as value_per_delivery,
       round(coalesce(i.value_per_delivery, 0) * 30.4375 / (s.frequency_weeks * 7), 2) as monthly_value,
       s.source, s.card_brand, s.card_last4, s.manage_token, s.delivery_postal_code, s.last_charged_amount
  from subscriptions s
  join customers c on c.id = s.customer_id
  left join lateral (
    select round(sum(x.value), 2) as value_per_delivery, string_agg(x.label, ', ') as items_summary
      from (select si.qty * v.price as value,
                   trim(to_char(si.qty, 'FM999990.###')) || ' × ' || p.name || ' ' || v.label as label
              from subscription_items si
              join product_variants v on v.id = si.variant_id
              join products p on p.id = v.product_id
             where si.subscription_id = s.id
            union all
            select sb.qty * least(b.price, bundle_regular_price(b.id)), sb.qty || ' × ' || b.name || ' (paquete)'
              from subscription_bundles sb join bundles b on b.id = sb.bundle_id
             where sb.subscription_id = s.id) x
  ) i on true;

create or replace view v_stock with (security_invoker = true) as
with st as (select reorder_horizon_days as horizon from settings),
mv as (
  select product_id,
         sum(qty)                                                                             as on_hand,
         -sum(qty) filter (where reason = 'sale' and moved_at >= now() - interval '30 days') as sold_30d,
         -sum(qty) filter (where reason = 'sale' and moved_at >= now() - interval '90 days') as sold_90d
    from inventory_movements group by product_id
),
largest as (
  select product_id, max(pack_qty) as largest_size from product_variants where active group by product_id
),
sub_lines as (   -- sizes per subscription, including the contents of subscribed bundles
  select si.subscription_id, si.variant_id, si.qty from subscription_items si
  union all
  select sb.subscription_id, bi.variant_id, sb.qty * bi.qty
    from subscription_bundles sb join bundle_items bi on bi.bundle_id = sb.bundle_id
),
subs as (
  select v.product_id, sum(sl.qty * v.pack_qty * c.cycles) as committed
    from subscriptions s
    join sub_lines sl on sl.subscription_id = s.id
    join product_variants v on v.id = sl.variant_id
    cross join st
    cross join lateral (
      select count(*) as cycles from generate_series(0, 60) k
       where s.next_delivery_date + k * 7 * s.frequency_weeks <= current_date + st.horizon
    ) c
   where s.status = 'active'
   group by v.product_id
)
select p.id as product_id, p.name, p.category, p.base_unit, p.active,
       coalesce(mv.on_hand, 0)                                        as on_hand,
       coalesce(subs.committed, 0)                                    as committed_subscriptions,
       coalesce(mv.on_hand, 0) - coalesce(subs.committed, 0)          as projected,
       l.largest_size                                                 as alert_threshold,
       (l.largest_size is not null
        and coalesce(mv.on_hand, 0) - coalesce(subs.committed, 0) <= l.largest_size) as needs_reorder,
       case when l.largest_size is null then null
            when p.reorder_qty is not null then p.reorder_qty
            else ceil(greatest(l.largest_size,
                               l.largest_size - (coalesce(mv.on_hand, 0) - coalesce(subs.committed, 0))
                               + coalesce(mv.sold_90d, 0) / 3.0) / l.largest_size) * l.largest_size
       end                                                            as suggested_qty,
       p.unit_cost,
       round(coalesce(mv.on_hand, 0) * p.unit_cost, 2)                as stock_value,
       coalesce(mv.sold_30d, 0)                                       as sold_last_30d,
       case when coalesce(mv.sold_30d, 0) > 0
            then round(coalesce(mv.on_hand, 0) / (mv.sold_30d / 30.0), 0) end as days_of_stock,
       p.reorder_qty, p.reorder_alerted_at,
       s.id as supplier_id, s.name as supplier_name, s.phone as supplier_phone, s.website as supplier_website
  from products p
  left join mv      on mv.product_id = p.id
  left join largest l on l.product_id = p.id
  left join subs    on subs.product_id = p.id
  left join suppliers s on s.id = p.supplier_id;

-- ---------- Security --------------------------------------------------------
revoke all on function drop_from_subscriptions(bigint[], bigint[]), place_web_order(jsonb), charge_preflight(bigint, boolean),
                       orders_to_charge(date), subscription_self_service(uuid, text, int)
  from public, anon, authenticated;
revoke all on function order_public_items(bigint), order_public_summary(bigint), bundle_regular_price(bigint),
                       bundle_sellable(bigint), bundle_in_stock(bigint, int), bundle_subscriber_price(bigint, date),
                       product_on_hand(bigint), subscription_skippable_order(bigint), order_label(date), subscription_email(bigint)
  from public, anon;
grant execute on function order_public_items(bigint), order_public_summary(bigint), bundle_regular_price(bigint),
                          bundle_sellable(bigint), bundle_in_stock(bigint, int), bundle_subscriber_price(bigint, date),
                          product_on_hand(bigint), subscription_skippable_order(bigint), order_label(date)
  to authenticated;
revoke all on function store_catalog(), store_order(uuid), store_subscription(uuid) from public;
grant execute on function store_catalog(), store_order(uuid), store_subscription(uuid) to anon, authenticated;
grant execute on function order_public_items(bigint), order_public_summary(bigint), order_label(date) to service_role;
-- Used by "Crear pedidos ahora" (admin) through create_due_subscription_orders; they run as the
-- caller, so row-level security still limits them to admins.
revoke all on function add_order_line(bigint, bigint, bigint, int, numeric, numeric), recalc_subscription_order(bigint) from public, anon;
grant execute on function add_order_line(bigint, bigint, bigint, int, numeric, numeric), recalc_subscription_order(bigint) to authenticated;

