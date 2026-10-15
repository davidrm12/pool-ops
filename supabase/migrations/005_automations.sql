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
