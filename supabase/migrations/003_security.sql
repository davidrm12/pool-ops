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
