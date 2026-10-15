-- 007: bundles, subscribe per product, order labels, subscription safety. Run on a fresh DB after 001–007.
\set ON_ERROR_STOP 1
\pset footer off
insert into products (name, category, base_unit, unit_cost) values
  ('Cloro granular', 'cloro', 'kg', 49), ('Clarificador', 'clarificador', 'L', 40), ('Kit de prueba', 'prueba', 'pza', 90);
insert into product_variants (product_id, label, pack_qty, price) values
  (1, '1 kg', 1, 100), (1, 'Bolsa 5 kg', 5, 450), (2, '1 L', 1, 100), (3, 'Kit', 1, 180);
update product_variants set subscribable = false where id = 4;
insert into purchases (purchase_date) values (current_date);
insert into purchase_items (purchase_id, product_id, qty, unit_cost) values (1, 1, 100, 49), (1, 2, 10, 40), (1, 3, 5, 90);

-- Bundle: 5 kg bag + 2 L clarifier. Regular 450 + 200 = 650; price 585 (10% off).
insert into bundles (name, price, description) values ('Paquete arranque', 585, 'Para empezar la temporada');
insert into bundle_items values (1, 2, 1), (1, 3, 2);

\echo '--- catalog shows the bundle with regular price and savings'
set role anon;
select jsonb_pretty(store_catalog()->'bundles') as bundles;
reset role;

\echo '--- mixed order: bundle subscribed, 1 kg subscribed ×2, kit once. Discount 5% only on subscribed'
-- subtotal components: 450 + 200 + 2×100 + 180 = 1030; bundle savings 65
-- subscribed base: 585 + 200 = 785 → 5% = 39.25; discount = 65 + 39.25 = 104.25; fee 25 → total 950.75
select place_web_order(jsonb_build_object(
  'name','Beto Ruiz','phone','8715550202','email','beto@test.mx','address','Encinos 300','postal_code','27100',
  'delivery_date', next_delivery_on(current_date + 1),'payment_method','card','frequency_weeks', 2, 'consent', true,
  'items', jsonb_build_array(
     jsonb_build_object('bundle_id',1,'qty',1,'subscribe',true),
     jsonb_build_object('variant_id',1,'qty',2,'subscribe',true),
     jsonb_build_object('variant_id',4,'qty',1,'subscribe',false)))) as r \gset
select o.id, v.subtotal, o.bundle_discount, o.discount, o.delivery_fee, v.total from orders o join v_orders v using (id);
select jsonb_pretty(order_public_items(1)) as public_items, order_public_summary(1) as summary;
select (store_order((:'r'::jsonb->>'token')::uuid))->>'label' as label,
       (store_order((:'r'::jsonb->>'token')::uuid))->>'discount' as shown_discount,
       (store_order((:'r'::jsonb->>'token')::uuid))->>'subtotal' as shown_subtotal;
\echo '--- subscription has only the subscribed items (no kit)'
select variant_id, qty from subscription_items order by 1;
select bundle_id, qty from subscription_bundles;
select items_summary, value_per_delivery from v_subscriptions;

\echo '--- validation: kit cannot be subscribed; subscribing needs a frequency'
\set ON_ERROR_STOP 0
select place_web_order(jsonb_build_object('name','X Y','phone','8715550303','address','Calle 1 2','postal_code','27100',
  'delivery_date', next_delivery_on(current_date + 1),'payment_method','cash','frequency_weeks', 2,
  'items', jsonb_build_array(jsonb_build_object('variant_id',4,'qty',1,'subscribe',true))));
select place_web_order(jsonb_build_object('name','X Y','phone','8715550303','address','Calle 1 2','postal_code','27100',
  'delivery_date', next_delivery_on(current_date + 1),'payment_method','cash',
  'items', jsonb_build_array(jsonb_build_object('variant_id',1,'qty',1,'subscribe',true))));
\set ON_ERROR_STOP 1
\echo '--- one-time only order with frequency sent: no subscription created'
select (place_web_order(jsonb_build_object('name','Caro Paz','phone','8715550404','address','Calle 1 2','postal_code','27105',
  'delivery_date', next_delivery_on(current_date + 1),'payment_method','cash','frequency_weeks', 2,
  'items', jsonb_build_array(jsonb_build_object('variant_id',1,'qty',1,'subscribe',false)))))->>'subscription_id' as sub_id;

\echo '--- next cycle: bundle at bundle price, 5% on everything, no kit'
update subscriptions set stripe_payment_method_id = 'pm_ok' where id = 1;
select create_due_subscription_orders(next_delivery_on(current_date + 1) + 12) as created;
-- 450+200+200 = 850 components; savings 65; (850−65)×5% = 39.25 → discount 104.25; +25 → 770.75
select o.id, o.channel, v.subtotal, o.bundle_discount, o.discount, v.total, o.charge_status from orders o join v_orders v using (id) where o.channel = 'subscription';

\echo '--- skip: cancels the created, uncharged order'
select (subscription_self_service((select manage_token from subscriptions where id = 1), 'skip'))->>'skip_date' as next_skip;
select id, status, charge_status from orders where channel = 'subscription';

\echo '--- sold out: bundle needs 5 kg but only 4 left → bundle dropped from this delivery, 1 kg kept; customer + admin emailed'
insert into inventory_movements(product_id, qty, reason) values (1, -(select product_on_hand(1)) + 4, 'count');   -- leave 4 kg (bundle needs 5)
select product_on_hand(1) as cloro_kg;
select create_due_subscription_orders((select next_delivery_date from subscriptions where id = 1) - 2) as created;
select o.id, v.items_summary, o.discount, v.total from orders o join v_orders v using (id) where o.channel = 'subscription' and o.status <> 'cancelled';
select kind, to_admin, to_email, payload from notifications where kind = 'delivery_adjusted' order by id;

\echo '--- pause cancels the upcoming uncharged order; cannot be charged'
update subscriptions set status = 'paused' where id = 1;
select id, status, charge_status, notes from orders where channel = 'subscription' order by id;
select count(*) as to_charge from orders_to_charge(current_date + 30);
update subscriptions set status = 'active' where id = 1;

\echo '--- deactivating the clarifier: bundle deactivated, removed from subscription, upcoming order cleaned'
insert into inventory_movements(product_id, qty, reason) values (1, 50, 'count');
select create_due_subscription_orders((select next_delivery_date from subscriptions where id = 1) - 2) as created;
select o.id, v.items_summary, v.total from orders o join v_orders v using (id) where o.channel = 'subscription' and o.status <> 'cancelled';
update product_variants set active = false where id = 3;
select id, active from bundles;
select variant_id, qty from subscription_items; select count(*) as sub_bundles from subscription_bundles;
select o.id, o.status, v.items_summary, o.discount, v.total from orders o join v_orders v using (id) where o.channel = 'subscription' order by o.id desc limit 1;
select kind, to_admin, payload from notifications where kind = 'subscription_item_removed' order by id;

\echo '--- deactivating the last product left: subscription paused, its order cancelled'
update products set active = false where id = 1;
select status from subscriptions where id = 1;
select o.id, o.status from orders o where o.channel = 'subscription' order by o.id desc limit 1;

\echo '--- deleting a subscription cancels its upcoming order'
update products set active = true where id = 1; update product_variants set active = true where id = 3;
insert into subscriptions (customer_id, frequency_weeks, next_delivery_date, payment_method, stripe_payment_method_id)
values (1, 1, next_delivery_on(current_date + 1), 'card', 'pm_x');
insert into subscription_items values (2, 1, 1);
select create_due_subscription_orders(next_delivery_on(current_date + 1) - 2) as created;
select id, status, charge_status from orders where subscription_id = 2;
select id as order_id from orders where subscription_id = 2 \gset
delete from subscriptions where id = 2;
select id, status, charge_status, subscription_id from orders where id = :order_id;
