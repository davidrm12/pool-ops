-- Automations scenario with fixed dates. "Today" = Wed 2026-10-14; delivery day = Sunday.
\set ON_ERROR_STOP 1
\pset footer off
insert into auth.users values ('11111111-1111-1111-1111-111111111111', 'admin@test.mx') on conflict do nothing;
insert into admins values ('11111111-1111-1111-1111-111111111111', 'admin@test.mx') on conflict do nothing;
insert into vault.secrets_tbl values ('project_url', 'https://demo.supabase.co'), ('cron_secret', 's3cret');

set role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

\echo '--- calendar: next delivery day from Wed 14, Sun 18, Mon 19 (expect 18, 18, 25)'
select next_delivery_on('2026-10-14'), next_delivery_on('2026-10-18'), next_delivery_on('2026-10-19');

insert into suppliers (name, website) values ('Tienda en línea', 'https://proveedor.example.com');
insert into products (name, category, base_unit, supplier_id) values ('Cloro granular', 'cloro', 'kg', 1);
insert into product_variants (product_id, label, pack_qty, price) values (1, '1 kg', 1, 100), (1, 'Bolsa 5 kg', 5, 450), (1, 'Cubeta 10 kg', 10, 850);
insert into purchases (purchase_date) values ('2026-10-10');
insert into purchase_items (purchase_id, product_id, qty, unit_cost) values (1, 1, 30, 49);
insert into customers (name, phone, address, zone) values ('Ana', '8711110001', 'Palmas 1', 'Las Quintas'), ('Beto', '8711110002', 'Linces 2', 'Campestre'), ('Caro', '8711110003', 'Sol 3', 'Viñedos');

\echo '--- order without delivery date goes to Sunday 18; explicit date is kept'
insert into orders (customer_id, order_date) values (1, '2026-10-14');
insert into order_items (order_id, variant_id, qty) values (1, 2, 1);
insert into orders (customer_id, order_date, delivery_date) values (3, '2026-10-14', '2026-10-15');
insert into order_items (order_id, variant_id, qty) values (2, 1, 2);
select id, delivery_date from orders order by id;

\echo '--- weekly subscription for Beto starting Thu 15 snaps to Sun 18'
insert into subscriptions (customer_id, frequency_weeks, next_delivery_date) values (2, 1, '2026-10-15');
insert into subscription_items values (1, 3, 1);
select id, frequency_weeks, next_delivery_date from subscriptions;

\echo '--- stock: on hand 30-5-2 = 23; subs committed in 14 days (18, 25) = 20; projected 3 <= threshold 10 → reorder'
select name, on_hand, committed_subscriptions, projected, alert_threshold, needs_reorder, suggested_qty, supplier_website from v_stock;

reset role;
\echo '--- daily job Wed 14: no subscription orders (Sunday is 4 days out), 1 new reorder alert, no route email'
select automation_daily('2026-10-14');
select job, ok, details from automation_runs order by id;
select body->>'kind' as kind, body from net.calls order by id;

\echo '--- daily job Fri 16: creates Beto''s order for Sun 18, route email for Sunday, no repeat reorder email'
select automation_daily('2026-10-16');
select automation_daily('2026-10-16');
select id, customer_id, channel, delivery_date from orders order by id;
select next_delivery_date from subscriptions;
select body->>'kind' as kind, body->>'date' as date from net.calls order by id;

\echo '--- route sheet for Sunday 18 (Caro''s order is for Thu 15, so it belongs to that day, not to Sunday''s route)'
select jsonb_pretty(route_sheet('2026-10-18'));

\echo '--- missed date: subscription last due Oct 4 → order goes to next Sunday, not the past'
insert into subscriptions (customer_id, frequency_weeks, next_delivery_date) values (1, 4, '2026-10-04');
insert into subscription_items values (2, 1, 1);
select create_due_subscription_orders('2026-10-14');
select id, customer_id, delivery_date from orders where subscription_id = 2;
select next_delivery_date from subscriptions where id = 2;

\echo '--- move Sunday deliveries to Monday (driver unavailable)'
select move_deliveries('2026-10-18', '2026-10-19');
select id, delivery_date from orders order by id;

\echo '--- second delivery day (Wednesday): next from Mon 19 = Wed 21'
update settings set delivery_weekdays = '{0,3}';
select next_delivery_on('2026-10-19');
update settings set delivery_weekdays = '{0}';

\echo '--- stock recovers after a purchase → alert re-arms'
insert into purchases (purchase_date) values ('2026-10-16');
insert into purchase_items (purchase_id, product_id, qty, unit_cost) values (2, 1, 50, 50);
select check_reorder_alerts();
select reorder_alerted_at is null as rearmed from products where id = 1;

\echo '--- weekly report Monday 19 (week Oct 12–18)'
select jsonb_pretty(weekly_report('2026-10-19') - 'overdue_customers');

\echo '--- permissions: admin cannot call scheduler-only functions'
set role authenticated;
\set ON_ERROR_STOP 0
select automation_daily();
select send_report('weekly');
reset role;
