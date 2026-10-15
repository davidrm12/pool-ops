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
