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
