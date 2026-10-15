# Cloro · Administración

Admin site for the business. Vite + React, hosted on GitHub Pages, data in Supabase. UI in Spanish.

```
cloro-admin/
├─ src/                    the site
├─ supabase/schema.sql     the whole database (run once in Supabase)
├─ supabase/migrations/    the same schema split in 4 parts
├─ supabase/tests/         local tests for the database
└─ .github/workflows/      automatic deploy to GitHub Pages
```

## 1. Database (Supabase)
1. Create a Supabase project. Open **SQL Editor**, paste `supabase/schema.sql`, and run it.
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
| Entregas | Pending orders grouped into overdue / today / tomorrow / later. Buttons to call, WhatsApp, open map, mark "En ruta", "Entregado y cobrado" or "Entregado sin cobrar". Built for the phone |
| Pedidos | Create, edit and delete orders. Price and cost fill in from the catalog. Filters: open, unpaid, delivered, month, search |
| Directorio | Customers and prospects: contact info, address with references, order history, total spent, how often they order, expected next order, unpaid amount |
| Suscripciones | Recurring orders. One button creates the orders that are due today |
| Productos | Catalog with sizes, prices, margin per size, cost, reorder point and supplier |
| Inventario | Stock on hand, value, how many days it will last, physical counts, waste or internal use, movement history |
| Compras | Restocking (adds stock and updates average cost) and suppliers |
| Gastos | Operating expenses by category |
| Finanzas | Monthly income statement by year, with CSV download, and sales/margin by product |

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
