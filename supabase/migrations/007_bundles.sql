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
