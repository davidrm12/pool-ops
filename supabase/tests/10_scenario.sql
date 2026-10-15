-- End-to-end test: access control + business logic. Run on a fresh local DB after the stub and migrations.
\set ON_ERROR_STOP 1
\pset footer off

insert into auth.users values ('11111111-1111-1111-1111-111111111111', 'admin@test.mx'),
                              ('22222222-2222-2222-2222-222222222222', 'intruso@test.mx');
insert into admins (user_id, email) values ('11111111-1111-1111-1111-111111111111', 'admin@test.mx');

-- ================= As the admin =================
set role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

insert into suppliers (name, phone) values ('Proveedor Cloro', '8711111111');
insert into products (name, category, base_unit, reorder_qty, supplier_id)
values ('Cloro granular', 'cloro', 'kg', 50, 1),
       ('Clarificador', 'clarificador', 'L', 20, null);
insert into product_variants (product_id, label, pack_qty, price) values
  (1, '1 kg', 1, 100), (1, 'Bolsa 5 kg', 5, 450), (2, '1 L', 1, 100), (2, 'Garrafa 4 L', 4, 360);

-- Two purchases at different costs → moving average
insert into purchases (supplier_id, purchase_date, shipping_cost) values (1, current_date - 40, 150);
insert into purchase_items (purchase_id, product_id, qty, unit_cost) values (1, 1, 50, 49), (1, 2, 20, 60);
insert into purchases (supplier_id, purchase_date) values (1, current_date - 5);
insert into purchase_items (purchase_id, product_id, qty, unit_cost) values (2, 1, 50, 53);
\echo '--- cost after 2 purchases (expect 51.00) and stock 100 kg'
select name, unit_cost from products where id = 1;

insert into customers (name, phone, address, zone) values
  ('Cliente Uno', '8712222222', 'Calle 1 #10', 'Las Quintas'),
  ('Cliente Dos', '8713333333', 'Calle 2 #20', 'Linces');

-- Order 1: delivered & paid. Only variant + qty sent; price/cost come from catalog.
insert into orders (customer_id, order_date, payment_method) values (1, current_date - 30, 'cash');
insert into order_items (order_id, variant_id, qty) values (1, 2, 2), (1, 3, 1);
update orders set status = 'delivered', payment_status = 'paid' where id = 1;
-- Order 2: pending delivery, SPEI, with discount
insert into orders (customer_id, payment_method, discount, delivery_date) values (2, 'spei', 20, current_date + 1);
insert into order_items (order_id, variant_id, qty) values (2, 1, 3);
-- Order 3: repeat customer, then cancelled → stock returns
insert into orders (customer_id, order_date) values (1, current_date);
insert into order_items (order_id, variant_id, qty) values (3, 2, 1);
update orders set status = 'cancelled' where id = 3;

\echo '--- orders (expect #1 total 1000 paid+delivered stamped, #2 total 280, #3 cancelled)'
select id, status, payment_status, delivered_at is not null as delivered_stamp, paid_at is not null as paid_stamp,
       subtotal, total, cogs, gross_profit, items_summary from v_orders order by id;

\echo '--- stock (expect granular 100-10-3 = 87, clarificador 20-1 = 19)'
select name, on_hand, unit_cost, stock_value, alert_threshold, needs_reorder, sold_last_30d from v_stock order by product_id;

\echo '--- physical count: granular counted 85 → movement -2'
select record_stock_count(1, 85);
select name, on_hand from v_stock where product_id = 1;

\echo '--- subscription created on a Wednesday snaps to Sunday; 4 days out is beyond the 2-day lead, so 0 orders yet'
insert into subscriptions (customer_id, frequency_weeks, next_delivery_date, payment_method) values (2, 4, current_date, 'card');
insert into subscription_items values (1, 2, 1);
select create_due_subscription_orders();
select create_due_subscription_orders();   -- second run creates nothing
select id, customer_name, next_delivery_date, value_per_delivery, monthly_value from v_subscriptions;

insert into expenses (category, amount, notes) values ('fuel', 200, 'Gasolina entregas');

\echo '--- pending deliveries'
select id, due_date, status, customer_name, items_summary, total, payment_method from v_pending_deliveries;
\echo '--- P&L'
select * from v_pnl_monthly;
\echo '--- customers'
select name, n_orders, lifetime_revenue, unpaid_amount, median_gap_days, expected_next_order, has_subscription from v_customer_summary order by id;
\echo '--- dashboard'
\x on
select * from v_dashboard;
\x off

-- ================= Non-admin logged-in user =================
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);
\echo '--- non-admin: expect 0 rows everywhere'
select (select count(*) from customers) customers, (select count(*) from orders) orders,
       (select count(*) from v_orders) v_orders, (select count(*) from v_dashboard where sales_this_month is not null) dash,
       (select count(*) from admins) admins;
\set ON_ERROR_STOP 0
\echo '--- non-admin insert (expect RLS error)'
insert into customers (name) values ('hack');
\echo '--- non-admin adding himself as admin (expect permission denied)'
insert into admins values ('22222222-2222-2222-2222-222222222222', 'intruso@test.mx');

-- ================= Not logged in =================
reset role;
set role anon;
select set_config('request.jwt.claim.sub', '', false);
\echo '--- anon (expect permission denied)'
select count(*) from customers;
select * from v_dashboard;
select create_due_subscription_orders();
reset role;
