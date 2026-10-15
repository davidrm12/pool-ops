# Cloro · Administración

Admin site for the business. Vite + React, hosted on GitHub Pages, data in Supabase. UI in Spanish.

```
cloro-admin/
├─ src/                    the site
├─ supabase/schema.sql     the whole database (run once in Supabase)
├─ supabase/migrations/    the same schema split in 5 parts (005 = automations)
├─ supabase/functions/     `reports` Edge Function (sends the emails)
├─ supabase/schedule.sql   daily/weekly jobs (run once, after step 3)
├─ supabase/tests/         local tests for the database
└─ .github/workflows/      automatic deploy to GitHub Pages
```

## 1. Database (Supabase)
1. Create a Supabase project. Open **SQL Editor**, paste `supabase/schema.sql`, and run it.
   If you already ran the earlier version, run only `supabase/migrations/005_automations.sql`.
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
5. **Test.** In the site, go to **Automatizaciones → Enviar ahora**. Each send appears in the Historial table.

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

## Security
- The anon key ends up in the public site. That's expected and safe: the database rejects every request unless the user is logged in **and** listed in `admins`.
- To revoke someone's access, delete their row from `admins`, or delete the user in Supabase.
- Never put the `service_role` key in the site or in these secrets.
- The site has `noindex` so search engines don't index it.

## Screens
| Screen | What it does |
|---|---|
| Resumen | Sales, profit and margin this month vs. last month, pending deliveries, unpaid amount, active customers, subscriptions, last 6 months chart, products to restock, customers past their usual reorder date (with a WhatsApp button) |
| Entregas | Route prep for a delivery date: what to load, stops by zone, cash to collect, shortfalls, Maps route, move the whole route to another day, email it. Order cards grouped by date, each with call / WhatsApp / map buttons, change date, "En ruta", "Entregado y cobrado" and "Entregado sin cobrar". Built for the phone |
| Pedidos | Create, edit and delete orders. Price and cost fill in from the catalog. Filters: open, unpaid, delivered, month, search |
| Directorio | Customers and prospects: contact info, address with references, order history, total spent, how often they order, expected next order, unpaid amount |
| Suscripciones | Recurring orders every N weeks. Created automatically; a button creates due ones right away |
| Productos | Catalog with sizes, prices, margin per size, cost, optional restock quantity and supplier |
| Inventario | Stock, upcoming subscription deliveries, what remains, alert level, value, days left, physical counts, waste or internal use, movement history |
| Compras | Restocking (adds stock and updates average cost) and suppliers |
| Gastos | Operating expenses by category |
| Finanzas | Monthly income statement by year, with CSV download, and sales/margin by product |
| Automatizaciones | Delivery days and lead time, email recipients, "send now" buttons, run history |

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
