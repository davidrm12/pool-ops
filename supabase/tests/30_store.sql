-- Store + payments scenario. "Today" is the real current date; dates are relative.
\set ON_ERROR_STOP 1
\pset footer off
insert into auth.users values ('11111111-1111-1111-1111-111111111111', 'admin@test.mx') on conflict do nothing;
insert into admins values ('11111111-1111-1111-1111-111111111111', 'admin@test.mx') on conflict do nothing;

insert into products (name, category, base_unit, unit_cost) values ('Cloro granular', 'cloro', 'kg', 49), ('Kit de prueba', 'prueba', 'pza', 90);
insert into product_variants (product_id, label, pack_qty, price) values (1, '1 kg', 1, 100), (1, 'Bolsa 5 kg', 5, 450), (2, 'Kit', 1, 180);
update product_variants set subscribable = false where id = 3;
insert into purchases (purchase_date) values (current_date);
insert into purchase_items (purchase_id, product_id, qty, unit_cost) values (1, 1, 100, 49), (1, 2, 5, 90);

\echo '--- anon can read the catalog (no costs, no stock numbers)'
set role anon;
select jsonb_pretty(store_catalog() - 'products') as store, jsonb_path_query_array(store_catalog(), '$.products[*].variants[*] ? (@.id == 2)') as variant2;
\set ON_ERROR_STOP 0
\echo '--- anon cannot place orders directly or read tables'
select place_web_order('{}');
select * from customers;
\set ON_ERROR_STOP 1
reset role;

\echo '--- web order, cash, new customer, phone with spaces/+52, delivery fee outside 27105'
select place_web_order(jsonb_build_object(
  'name','Ana López','phone','+52 871 555 0101','email','ana@test.mx','address','Palmas 120','zone','Las Quintas',
  'postal_code','27100','delivery_date', next_delivery_on(current_date + 1),'payment_method','cash',
  'items', jsonb_build_array(jsonb_build_object('variant_id',2,'qty',1)))) as r1 \gset
select phone, postal_code, source from customers;
select o.id, o.channel, o.delivery_fee, o.discount, v.total, o.needs_review from orders o join v_orders v using (id) order by o.id;

\echo '--- same phone, different address and ZIP 27105: customer NOT overwritten, order flagged, no fee'
select place_web_order(jsonb_build_object(
  'name','Ana López','phone','8715550101','address','Otra calle 9','postal_code','27105',
  'delivery_date', next_delivery_on(current_date + 1),'payment_method','spei',
  'items', jsonb_build_array(jsonb_build_object('variant_id',1,'qty',2))));
select name, address, postal_code from customers;
select id, delivery_address, delivery_fee, needs_review, review_note from orders order by id;

\echo '--- validation errors'
\set ON_ERROR_STOP 0
select place_web_order(jsonb_build_object('name','X Y','phone','12345','address','Calle 1','postal_code','27100','delivery_date',next_delivery_on(current_date+1),'payment_method','cash','items','[{"variant_id":1,"qty":1}]'::jsonb));
select place_web_order(jsonb_build_object('name','X Y','phone','8710000000','address','Calle 1','postal_code','64000','delivery_date',next_delivery_on(current_date+1),'payment_method','cash','items','[{"variant_id":1,"qty":1}]'::jsonb));
select place_web_order(jsonb_build_object('name','X Y','phone','8710000000','address','Calle 1','postal_code','27100','delivery_date',current_date + 30,'payment_method','cash','items','[{"variant_id":1,"qty":1}]'::jsonb));
select place_web_order(jsonb_build_object('name','X Y','phone','8710000000','address','Calle 1','postal_code','27100','delivery_date',next_delivery_on(current_date+1),'payment_method','card','frequency_weeks',2,'consent',true,'items','[{"variant_id":3,"qty":1}]'::jsonb));
select place_web_order(jsonb_build_object('name','X Y','phone','8710000000','address','Calle 1','postal_code','27100','delivery_date',next_delivery_on(current_date+1),'payment_method','card','frequency_weeks',2,'items','[{"variant_id":2,"qty":1}]'::jsonb));
\set ON_ERROR_STOP 1

\echo '--- card subscription every 2 weeks: 5% off, fee, subscription + first order'
select place_web_order(jsonb_build_object(
  'name','Beto Garza','phone','871-555-0102','email','beto@test.mx','address','Linces 45','postal_code','27110',
  'delivery_date', next_delivery_on(current_date + 1),'payment_method','card','frequency_weeks',2,'consent',true,
  'consent_text','Autorizo…','items', jsonb_build_array(jsonb_build_object('variant_id',2,'qty',2)))) as r3 \gset
select id, subtotal, discount, delivery_fee, total from v_orders where id = 3;
select id, frequency_weeks, next_delivery_date - (select delivery_date from orders where id = 3) as days_after_first, payment_method, consent_at is not null as consent from subscriptions;

\echo '--- first order paid in Checkout → card saved'
select mark_order_paid_online(3, 'pi_first', 880.00, 'pm_ok', 'visa', '4242', 'cus_beto');
select payment_status, charge_status from orders where id = 3;
select stripe_payment_method_id, card_last4, last_charged_amount from subscriptions where id = 1;
select stripe_customer_id from customers where phone = '8715550102';

\echo '--- next cycle: order created with discount; charge preflight OK'
update orders set delivery_date = current_date - 7 where id = 3;   -- pretend the first delivery already happened
update subscriptions set next_delivery_date = next_delivery_on(current_date + 1) where id = 1;
select create_due_subscription_orders(next_delivery_on(current_date + 1) - 2);   -- run as on Friday
select o.id, o.channel, o.charge_status, v.total from orders o join v_orders v using (id) where o.subscription_id = 1 order by o.id;
select * from orders_to_charge(next_delivery_on(current_date + 1) - 2);
select charge_preflight(4);
select charge_preflight(4) as second_attempt_blocked;
select charge_result(4, false, 'pi_x', 'Fondos insuficientes', 'insufficient_funds');
select charge_status, charge_attempts from orders where id = 4;
select kind, to_email, to_admin from notifications where order_id = 4;
\echo '--- retry is NOT due the same day; due next day (simulate by backdating)'
select count(*) as due_today from orders_to_charge(next_delivery_on(current_date + 1) - 2) where orders_to_charge = 4;
update orders set last_charge_at = now() - interval '1 day' where id = 4;
select count(*) as due_after_a_day from orders_to_charge(next_delivery_on(current_date + 1) - 1) where orders_to_charge = 4;
select charge_preflight(4) ->> 'key' as retry_key;
select charge_result(4, true, 'pi_retry');
select payment_status, charge_status from orders where id = 4;

\echo '--- price change: subscribers keep old price for 7 days'
update product_variants set price = 600 where id = 2;
select price, prev_price, price_changed_at = current_date as today from product_variants where id = 2;
select subscriber_price(2, current_date + 3) as within_notice, subscriber_price(2, current_date + 8) as after_notice;
select kind, to_email, payload->>'old_price' as old, payload->>'new_price' as new from notifications where kind = 'price_change';

\echo '--- limits: order above 1.5× last charge → requires approval (no charge)'
update product_variants set price = 800 where id = 2;   -- another jump: 2 × 800 > 1.5 × last charge
update subscriptions set next_delivery_date = current_date + 9 where id = 1;
update settings set lead_days = 14;
select create_due_subscription_orders();
select o.id, v.total from orders o join v_orders v using (id) where o.subscription_id = 1 and o.id > 4;
select charge_preflight((select max(id) from orders where subscription_id = 1));
select charge_status, charge_error from orders where id = (select max(id) from orders where subscription_id = 1);
select charge_preflight((select max(id) from orders where subscription_id = 1), true) ->> 'ok' as approved_ok;
update settings set lead_days = 2;

\echo '--- max per charge and daily cap'
update settings set max_auto_charge = 100;
update orders set charge_status = 'pending' where id = 3;  -- pretend unpaid for test
update orders set payment_status = 'pending' where id = 3;
select charge_preflight(3) ->> 'reason' as reason_max;
update settings set max_auto_charge = 3000, daily_auto_charge_cap = 1000;
update orders set charge_status = 'pending' where id = 3;
select charge_preflight(3) ->> 'reason' as reason_daily;
update settings set daily_auto_charge_cap = 20000;

\echo '--- self-service: skip, frequency, pause, resume, cancel'
select store_subscription(gen_random_uuid()) is null as wrong_token_hidden;
select store_subscription((select manage_token from subscriptions where id = 1)) -> 'items' as items;
select subscription_self_service((select manage_token from subscriptions where id = 1), 'skip') ->> 'next_delivery_date';
select subscription_self_service((select manage_token from subscriptions where id = 1), 'frequency', 4) ->> 'frequency_weeks';
select subscription_self_service((select manage_token from subscriptions where id = 1), 'pause') ->> 'status';
select subscription_self_service((select manage_token from subscriptions where id = 1), 'resume') ->> 'status';
select subscription_self_service((select manage_token from subscriptions where id = 1), 'cancel') ->> 'status';

\echo '--- public order page by token'
select store_order((select public_token from orders where id = 2)) - 'items' as order_page;

\echo '--- admin inserts phone with dashes: normalized; bad phone rejected'
insert into customers(name, phone) values ('Caro', '871-111-2222');
select phone from customers where name = 'Caro';
\set ON_ERROR_STOP 0
insert into customers(name, phone) values ('Malo', '12345');
\set ON_ERROR_STOP 1
