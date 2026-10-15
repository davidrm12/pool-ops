# Cloro · Administración

Admin site for the business. Vite + React, hosted on GitHub Pages, data in Supabase. UI in Spanish.

```
cloro-admin/
├─ src/                    the site
├─ supabase/schema.sql     the whole database (run once in Supabase)
├─ supabase/migrations/    the same schema split in 7 parts (005 = automations, 006 = store + payments, 007 = bundles + per-item subscriptions)
├─ supabase/functions/     Edge Functions: reports, store, stripe-webhook, charges (+ _shared code)
├─ supabase/config.toml    marks the functions that check auth themselves
├─ supabase/schedule.sql   daily/weekly jobs (run once, after step 3)
├─ supabase/tests/         local tests for the database
└─ .github/workflows/      automatic deploy to GitHub Pages
```

## 1. Database (Supabase)
1. Create a Supabase project. Open **SQL Editor**, paste `supabase/schema.sql`, and run it.
   **Already ran 001–006 (you have): run only `supabase/migrations/007_bundles.sql`.** Then redeploy the functions
   (`supabase functions deploy reports store stripe-webhook charges --no-verify-jwt`) and push both sites.

   Earlier note for 006: It adds the store, payments and the
   product-photo bucket, and doesn't touch existing data except to normalize phones to 10 digits. If any saved phone
   can't be normalized it shows a notice listing them; fix those in Directorio (new edits already require 10 digits).
2. In the authentication settings, turn off new user sign-ups.
3. Go to **Authentication → Users → Add user** and create each person's email and password.
4. Give each user admin access in the SQL Editor:
   ```sql
   insert into admins (user_id, email)
   select id, email from auth.users where email = 'tu@correo.com';
   ```
5. In **Project Settings → API**, copy the **Project URL** and the **anon public** key.

## 2. Site (GitHub Pages)
1. Create a GitHub repository and push this folder to `main`.
2. Go to **Settings → Secrets and variables → Actions → New repository secret** and add two secrets:
   - `VITE_SUPABASE_URL` = Project URL
   - `VITE_SUPABASE_ANON_KEY` = anon public key
3. Go to **Settings → Pages → Build and deployment → Source** and choose **GitHub Actions**.
4. Every push to `main` builds and publishes the site. You can also run the workflow from the **Actions** tab. The URL shows up in Settings → Pages.

## 3. Automations (emails + schedule)
1. **Resend.** Create an account at resend.com with **davidrm97@gmail.com**. Then go to **API Keys → Create** and copy the key.
   Until you verify your own domain in Resend, emails only reach the address of the Resend account.
2. **Deploy the function.** With the Supabase CLI, from this folder:
   ```bash
   supabase login
   supabase link --project-ref <your-project-ref>
   supabase functions deploy reports --no-verify-jwt
   ```
   `--no-verify-jwt` is required: the scheduler authenticates with a shared secret, and the function checks admin logins itself.
3. **Set the function's secrets** (Dashboard → Edge Functions → Secrets, or `supabase secrets set NAME=value`):
   - `RESEND_API_KEY` = the Resend key
   - `CRON_SECRET` = any long random string (it must match the value in step 4)
   - `SITE_URL` = the GitHub Pages URL (optional; adds an "Abrir administración" link to the emails)
4. **Schedule.** Open `supabase/schedule.sql`, replace `⟨PROJECT_URL⟩` and `⟨CRON_SECRET⟩`, and run it in the SQL Editor.
5. **Test.** In the site, go to **Ajustes → Enviar ahora**. Each send appears in the Historial table.

| When | What |
|---|---|
| Every day, 7:00 a.m. | Creates subscription orders delivering within `lead_days` (default 2); checks stock and emails **new** reorder alerts once |
| `lead_days` before each delivery day (Friday for Sunday) | Emails the route sheet: what to load, stops by zone, cash to collect, stock shortfalls, Google Maps route |
| Mondays, 7:05 a.m. | Weekly summary of the previous Monday–Sunday |

**Rules**
- **Calendar:** new orders without a date go to the next delivery day (Sunday by default; change it in Automatizaciones). Any order can be moved by itself, or a whole route can be moved, from Entregas.
- **Subscriptions:** every N weeks, always on a delivery day. If a date was missed, the order goes to the next delivery day instead of a past date.
- **Reorder:** remaining = stock − subscription deliveries in the next `reorder_horizon_days` (default 14). The alert fires when the remaining stock only covers the product's largest size, e.g. ≤ 10 kg if the biggest is a 10 kg bucket. The suggested purchase is the product's "cantidad a comprar", or about a month of sales rounded up to whole largest sizes. It links to the supplier's online store.

**Local development:** `npm install`, copy `.env.example` to `.env.local` and fill in the two values, then run `npm run dev`.

## 4. Store and card payments (step 4)
The public store is a separate repo (`cloro-tienda`) that reads the same database. Do these once:

1. **Run** `supabase/migrations/006_store.sql` (see section 1).
2. **Stripe (test mode for now).** In the Stripe Dashboard, switch on **Test mode**.
   - **Developers → API keys:** copy the **Secret key** (`sk_test_…`). The store never needs the publishable key.
   - **Developers → Webhooks → Add endpoint:**
     URL `https://<project-ref>.supabase.co/functions/v1/stripe-webhook`, events
     `checkout.session.completed`, `payment_intent.succeeded`, `payment_intent.payment_failed`, `charge.refunded`.
     Copy its **Signing secret** (`whsec_…`).
   - **Settings → Payment methods:** keep **Cards** on. Nothing else is used (SPEI and cash are handled by you).
3. **Cloudflare Turnstile** (free, the anti-bot check on the order form): dash.cloudflare.com → **Turnstile → Add widget**,
   add your store's domain (and `localhost` for testing), mode **Managed**. Copy the **Site key** (goes in the store repo)
   and the **Secret key** (goes here).
4. **Function secrets** (add to the ones from step 3):
   - `STRIPE_SECRET_KEY` = `sk_test_…`
   - `STRIPE_WEBHOOK_SECRET` = `whsec_…`
   - `TURNSTILE_SECRET` = Turnstile secret key
   - `STORE_URL` = the store's address, e.g. `https://tudominio.mx` (links in customer emails and Stripe return pages)
   - `MAIL_FROM` = e.g. `Cloro a Domicilio <pedidos@tudominio.mx>` once the domain is verified in Resend
5. **Deploy** all functions (the store and webhook must be public, they check Turnstile / Stripe signatures themselves):
   ```bash
   supabase functions deploy reports store stripe-webhook charges --no-verify-jwt
   ```
   The daily job already scheduled in step 3 now also charges saved cards and sends customer emails; no new schedule.
6. **Ajustes → Tienda en línea:** store name, WhatsApp, store address (same as `STORE_URL`), delivery fee and free ZIPs,
   subscription discount, SPEI bank data, and the automatic-charge limits. Turn **Recibiendo pedidos** off to pause the store.

**Test cards (test mode):** `4242 4242 4242 4242` works; `4000 0000 0000 0341` saves fine but is declined when charged
later (good for testing the decline → email → retry → "Reintentar cobro" flow). Any future date and CVC.

**Moving to the other person's Stripe account later.** Nothing in the database is tied to your account except saved
customers and cards, which belong to the account that created them. When their account is ready (with their RFC):
1. In their account create the same webhook (step 2) and copy their `sk_live_…` (or `sk_test_…` first) and `whsec_…`.
2. Replace `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` (`supabase secrets set …`). No redeploy needed.
3. Clear the test-mode IDs so customers get created fresh in the new account:
   ```sql
   update customers set stripe_customer_id = null;
   update subscriptions set stripe_payment_method_id = null, card_brand = null, card_last4 = null;
   ```
   Subscribers who paid by card will need to add their card again from their subscription link (Cambiar tarjeta).
   Do this before you have real subscribers and it costs nothing.
4. Delete the webhook in your account.

**How charging works**
- **One-time card orders:** the customer pays in Stripe Checkout right after ordering. The order is marked paid when Stripe confirms (webhook).
- **Card subscriptions:** the first order is paid in Checkout and the card is saved in Stripe (we only keep brand and last 4).
  Each later order is created `lead_days` before delivery and charged that same morning.
- **The amount** is always computed by the database from the order's items, discount and delivery fee. Each attempt has
  its own Stripe idempotency key, so a retry can never charge twice.
- **Limits:** a charge is held (not made) if it is over **$3,000**, over **1.5×** the subscription's last charge, or would push
  today's automatic charges over **$20,000**. You get an email; open the order and use **Aprobar y cobrar**. All three are editable in Ajustes.
- **Declines:** the customer gets an email with a link to pay with another card; one automatic retry the next day
  (none for stolen/lost/fraud declines); you get an email when no retry is left. The order stays in the route as "por cobrar".
- **Price changes:** subscribers get an email, and the new price applies only to deliveries at least 7 days after the change
  (Ajustes → Aviso de cambio de precio). Changing a price by more than 30% asks you to confirm.
- **Refunds:** **Reembolsar** in the order refunds in full through Stripe and cancels the order.
- **Subscribe per product:** in the cart each product has its own "Suscribirme" box, with one frequency for all of them.
  The first order charges everything; later deliveries bring (and charge) only the subscribed ones. The subscription
  discount applies only to subscribed items, also in the first order.
- **Bundles (paquetes):** made in Productos → Paquetes with fixed contents and a fixed price (the form suggests 10% off and
  shows the savings). They show first in the store, one-time or by subscription; subscribers get the subscription discount
  on top. In orders they're stored as their component sizes, so stock, cost and margins keep working.
- **Order names:** customers see "Pedido dd/mm/aaaa" (order date) in the store, emails, Stripe and the SPEI reference. The admin
  keeps the internal number (#N) and shows the customer-facing name in the order detail.
- **Nothing charged that won't be delivered:**
  - Pausing, cancelling (button in Suscripciones) or deleting a subscription cancels its upcoming order if it hasn't been charged.
    Skipping from the customer link cancels that order if it was already created. A charged order stays; refund it if needed.
  - When the subscription order is created, anything without enough stock is left out of that delivery and its charge;
    customer and admin get an email. If nothing is left, no order is created for that date.
  - Deactivating a size, product or bundle removes it from every subscription (and from upcoming uncharged orders),
    emails the customer, and pauses subscriptions left empty. Unticking "Suscr." only stops new subscriptions.
- Prefer **Cancelar suscripción** over deleting: it keeps the history and the churn numbers.

## Security
- The anon key ends up in the public site. That's expected and safe: the database rejects every request unless the user is logged in **and** listed in `admins`.
- To revoke someone's access, delete their row from `admins`, or delete the user in Supabase.
- Never put the `service_role` key in the site or in these secrets.
- The public store can only call four read functions (catalog, an order by its secret link, a subscription by its secret link)
  and the `store` function. Orders are created by the database function `place_web_order`, which validates everything and
  never overwrites a saved customer: differences are flagged for review.
- The site has `noindex` so search engines don't index it.

## Screens
| Screen | What it does |
|---|---|
| Resumen | Sales, profit and margin this month vs. last month, pending deliveries, unpaid amount, active customers, subscriptions, last 6 months chart, products to restock, customers past their usual reorder date (with a WhatsApp button) |
| Entregas | Route prep for a delivery date: what to load, stops by zone, cash to collect, shortfalls, Maps route, move the whole route to another day, email it. Order cards grouped by date, each with call / WhatsApp / map buttons, change date, "En ruta", "Entregado y cobrado" and "Entregado sin cobrar". Built for the phone |
| Pedidos | Create, edit and delete orders. Price and cost fill in from the catalog. Filters: open, unpaid, **Revisar** (web orders with different data, declined or held charges), delivered, month, search. Each order shows the card-charge panel (Reintentar cobro, Aprobar y cobrar, Enviar liga de pago, Reembolsar) and the customer's order link |
| Directorio | Customers and prospects: contact info, address with references, order history, total spent, how often they order, expected next order, unpaid amount |
| Suscripciones | Recurring orders every N weeks. Created automatically; a button creates due ones right away. Shows the saved card and copies the customer's self-service link |
| Productos | Bundles (paquetes) on top; catalog with sizes, prices, margin per size, cost, optional restock quantity, supplier, photo, and what shows in the store (per product and per size, and which sizes allow subscription) |
| Inventario | Stock, upcoming subscription deliveries, what remains, alert level, value, days left, physical counts, waste or internal use, movement history |
| Compras | Restocking: quantity and amount paid per line (cost per unit is calculated); adds stock and updates average cost. Suppliers |
| Gastos | Operating expenses by category |
| Finanzas | Monthly income statement by year, with CSV download, and sales/margin by product |
| Ajustes | Store settings, SPEI data, charge limits, delivery days and lead time, email recipients, "send now" buttons, run history |

## Testing
The full flow was tested in a headless browser against a local copy of the backend:
- login and access denial
- products, purchase and customers
- orders, including editing and cancelling
- delivery and payment
- subscription
- expense and physical count
- finance and dashboard, on desktop and mobile

Totals, stock and margins were checked against hand calculations.

The automations were tested with fixed dates (`supabase/tests/20_automations.sql`):
- Sunday calendar and moving a route to another day
- a subscription snapping to Sunday, and its order created on Friday (once, even if the job runs twice)
- a missed subscription date, and the route email sent once
- the reorder alert firing at the largest-size threshold and re-arming after a purchase
- the weekly report and permissions

The email function ran locally against a mock Resend: all three emails, scheduler-secret and admin auth, rejection of non-admins, and one rejected recipient not blocking the others.

Step 4 (`supabase/tests/30_store.sql`, plus browser tests with a mock Stripe, Resend and Turnstile):
- catalog visible to the public, everything else blocked
- cash, SPEI and card orders, delivery fee by ZIP, validation messages, phone normalization, customer data never overwritten
- card subscription: Checkout, card saved, order created and charged on schedule, no double charge, decline → email → retry
  next day, no retry for a stolen card, card update then successful charge, held charge → approve, refund, payment link
- price change notice, self-service skip / pause / resume / cancel / frequency / change card
- admin: review list, charge panel, price-change guard, photo upload, store settings

October changes (`supabase/tests/40_bundles.sql` plus browser tests): bundle pricing and savings, mixed order with only some
items subscribed (discount on those only), subscription orders at bundle price, skip cancelling the created order, sold-out
bundle dropped from a delivery with emails, pause/cancel/delete cancelling the uncharged order and blocking its charge,
deactivation removing items and bundles from subscriptions and pausing empty ones, purchases entered by total, bundle form.
