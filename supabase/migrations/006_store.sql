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
