-- Cloro Diego · Backend v1 · full schema (001–004 combined). Paste into Supabase SQL Editor and run once.

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
