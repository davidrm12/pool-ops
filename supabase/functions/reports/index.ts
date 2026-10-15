// Cloro · reports Edge Function
// Sends the route sheet, reorder alert and weekly summary by email (Resend).
//
// Called by:
//   · the scheduler (pg_cron → pg_net) with header  x-cron-secret: <CRON_SECRET>
//   · the admin site ("Enviar ahora") with the logged-in admin's session
// Body: { kind: 'route' | 'reorder' | 'weekly' | 'outbox', date?: 'YYYY-MM-DD', product_ids?: number[] }
//
// Secrets (Edge Functions → Secrets): RESEND_API_KEY, CRON_SECRET
// Optional: MAIL_FROM (default "Cloro <onboarding@resend.dev>"), SITE_URL, CITY
// SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.
import { createClient } from 'npm:@supabase/supabase-js@2'
import { C, CITY, PAY, SUPABASE_URL as URL_, btn, cors, day, env, esc, json, money, num, row, section, shell, table, waLink } from '../_shared/common.ts'
import { processOutbox } from '../_shared/outbox.ts'

const RESEND = env('RESEND_API_URL', 'https://api.resend.com/emails')
const FROM = env('MAIL_FROM', 'Cloro <onboarding@resend.dev>')

// Google Maps directions: 1 destination + up to 9 stops per link (computers / Maps app).
function mapsLinks(stops: any[]): string[] {
  const addrs = stops.map((s) => [s.address, s.zone, CITY].filter(Boolean).join(', ')).filter((a) => a.split(',')[0].trim())
  const links: string[] = []
  for (let i = 0; i < addrs.length; i += 10) {
    const chunk = addrs.slice(i, i + 10)
    const dest = chunk[chunk.length - 1]
    const way = chunk.slice(0, -1).join('|')
    links.push(`https://www.google.com/maps/dir/?api=1&travelmode=driving&destination=${encodeURIComponent(dest)}${way ? `&waypoints=${encodeURIComponent(way)}` : ''}`)
  }
  return links
}

// ---------- emails ----------
function routeEmail(r: any) {
  const stops = r.stops as any[]
  const late = stops.filter((s) => s.late).length
  const sub = `${r.n_stops} entregas · ${money(r.total)} en total · ${money(r.to_collect)} por cobrar`
  let body = ''
  if (r.shortfalls.length) {
    body += `<div style="background:${C.warn};border-radius:10px;padding:12px 16px;margin-top:14px;font-size:14px"><b>Falta inventario para esta ruta:</b> ${r.shortfalls.map((s: any) => `${esc(s.product)} (${num(s.missing)} ${esc(s.base_unit)})`).join(', ')}. Hay que comprar antes del reparto.</div>`
  }
  body += section('Qué cargar', table(r.packing.map((p: any) => row(`${esc(p.product)} · ${esc(p.label)}`, `${num(p.qty)}`, true)).join('')))
  const links = mapsLinks(stops)
  body += section(`Paradas${late ? ` (${late} atrasada${late > 1 ? 's' : ''})` : ''}`,
    stops.map((s, i) => `<div style="padding:10px 0;border-bottom:1px solid ${C.line};font-size:14px">
      <div style="font-weight:bold">${i + 1}. ${esc(s.customer)}${s.late ? ` <span style="color:${C.bad};font-weight:normal">· atrasada (${esc(day(s.delivery_date, { day: 'numeric', month: 'short' }))})</span>` : ''}</div>
      <div>${esc([s.address, s.zone].filter(Boolean).join(', ') || 'Sin dirección')}${s.address_notes ? ` · ${esc(s.address_notes)}` : ''}</div>
      <div style="background:${C.tile};border-radius:6px;padding:6px 8px;margin:6px 0">${esc(s.items)}</div>
      <div>${money(s.total)} · ${PAY[s.payment_method] ?? s.payment_method} · ${s.payment_status === 'paid' ? 'pagado' : '<b>por cobrar</b>'}${s.phone ? ` · <a href="${waLink(s.phone)}" style="color:${C.water}">WhatsApp</a>` : ''}</div>
      ${s.notes ? `<div style="color:${C.muted}">${esc(s.notes)}</div>` : ''}
    </div>`).join('') +
    (links.length ? `<div style="padding-top:10px">${links.map((l, i) => btn(l, links.length > 1 ? `Ruta en Maps (tramo ${i + 1})` : 'Abrir ruta en Maps')).join('')}</div>` : ''))
  return { subject: `Ruta del ${day(r.date)}: ${r.n_stops} entregas`, html: shell(`Ruta del ${day(r.date)}`, sub, body) }
}

function reorderEmail(items: any[], newIds: number[]) {
  const body = section('Productos por reabastecer', items.map((p) => `<div style="padding:10px 0;border-bottom:1px solid ${C.line};font-size:14px">
      <div style="font-weight:bold">${esc(p.name)}${newIds.includes(p.product_id) ? ` <span style="background:${C.warn};border-radius:99px;padding:1px 8px;font-size:12px">nuevo</span>` : ''}</div>
      <div>Existencia ${num(p.on_hand)} ${esc(p.base_unit)} · comprometido en suscripciones ${num(p.committed_subscriptions)} · quedan <b>${num(p.projected)} ${esc(p.base_unit)}</b> (alerta en ${num(p.alert_threshold)})</div>
      <div style="margin-top:4px">Comprar: <b>${num(p.suggested_qty)} ${esc(p.base_unit)}</b>${p.unit_cost ? ` · aprox. ${money(Number(p.suggested_qty) * Number(p.unit_cost))} al último costo` : ''}</div>
      ${p.supplier_name ? `<div style="color:${C.muted}">Proveedor: ${esc(p.supplier_name)}</div>` : ''}
      ${p.supplier_website ? btn(p.supplier_website, 'Ir a la tienda del proveedor') : ''}
    </div>`).join(''))
  return { subject: `Reabastecer: ${items.map((p) => p.name).join(', ')}`, html: shell('Hay que reabastecer', `${items.length} producto${items.length > 1 ? 's' : ''} con inventario bajo`, body) }
}

function weeklyEmail(w: any) {
  const pct = (a: number, b: number) => (b ? `${a >= b ? '+' : ''}${(((a / b) - 1) * 100).toFixed(0)}%` : '—')
  let body = section('La semana', table(
    row('Ventas netas', `${money(w.sales)} <span style="color:${C.muted}">(${pct(w.sales, w.prev_sales)} vs. ${money(w.prev_sales)})</span>`, true) +
    row('Utilidad bruta', `${money(w.gross_profit)} <span style="color:${C.muted}">(${pct(w.gross_profit, w.prev_gross_profit)})</span>`) +
    row('Pedidos', `${w.orders} <span style="color:${C.muted}">(${w.prev_orders} la anterior)</span>`) +
    row('Entregas realizadas', `${w.delivered}`) +
    row('Clientes nuevos', `${w.new_customers}`)) +
    (w.missing_cost ? `<p style="font-size:13px;color:${C.muted}">Algunas ventas son de productos sin costo registrado; la utilidad está sobreestimada.</p>` : ''))
  if (w.next_route?.n_stops) body += section('Próxima ruta', table(row(day(w.next_route.date), `${w.next_route.n_stops} entregas · ${money(w.next_route.total)}`)))
  if (w.unpaid.length) body += section('Entregados sin cobrar', table(w.unpaid.map((u: any) =>
    row(`#${u.id} ${esc(u.customer)} <span style="color:${C.muted}">· entregado ${esc(day(u.delivered, { day: 'numeric', month: 'short' }))} · ${PAY[u.method] ?? ''}</span>`, `${money(u.total)}${u.phone ? ` <a href="${waLink(u.phone)}" style="color:${C.water}">WhatsApp</a>` : ''}`)).join('')))
  if (w.overdue_customers.length) body += section('Clientes que ya deberían haber pedido', table(w.overdue_customers.map((c: any) =>
    row(`${esc(c.customer)} <span style="color:${C.muted}">· pide cada ${c.every_days} días</span>`, `${c.days_overdue} días tarde${c.phone ? ` <a href="${waLink(c.phone)}" style="color:${C.water}">WhatsApp</a>` : ''}`)).join('')))
  if (w.reorder.length) body += section('Por reabastecer', table(w.reorder.map((p: any) =>
    row(`${esc(p.product)} <span style="color:${C.muted}">· quedan ${num(p.projected)} ${esc(p.base_unit)}</span>`, `comprar ${num(p.suggested)} ${esc(p.base_unit)}`)).join('')))
  const range = `${day(w.week_start, { day: 'numeric', month: 'short' })} al ${day(w.week_end, { day: 'numeric', month: 'short' })}`
  return { subject: `Resumen semanal: ${money(w.sales)} en ventas (${range})`, html: shell('Resumen semanal', range, body) }
}

// ---------- handler ----------
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Método no permitido' }, 405)

  // Auth: scheduler secret, or a logged-in admin.
  const viaCron = !!env('CRON_SECRET') && req.headers.get('x-cron-secret') === env('CRON_SECRET')
  if (!viaCron) {
    const auth = req.headers.get('Authorization') ?? ''
    if (!auth.startsWith('Bearer ')) return json({ error: 'No autorizado' }, 401)
    const user = createClient(URL_, env('SUPABASE_ANON_KEY'), { global: { headers: { Authorization: auth } }, auth: { persistSession: false } })
    const { data, error } = await user.rpc('is_admin')
    if (error || data !== true) return json({ error: 'No autorizado' }, 403)
  }

  const db = createClient(URL_, env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } })
  const body = await req.json().catch(() => ({}))
  const kind = body.kind as string
  const log = (ok: boolean, details: unknown) => db.from('automation_runs').insert({ job: `${kind}_email`, ok, details })

  try {
    let mail: { subject: string; html: string } | null = null
    if (kind === 'outbox') {
      const sent = await processOutbox(db)
      return json({ ok: true, sent: sent.length })
    }
    if (kind === 'route') {
      const { data, error } = await db.rpc('route_sheet', { p_date: body.date ?? null })
      if (error) throw error
      if (data.n_stops === 0 && viaCron) { await log(true, { skipped: 'Sin entregas para la ruta', date: data.date }); return json({ skipped: true }) }
      mail = routeEmail(data)
    } else if (kind === 'reorder') {
      const { data, error } = await db.from('v_stock').select('*').eq('active', true).eq('needs_reorder', true).order('name')
      if (error) throw error
      if (!data.length) { await log(true, { skipped: 'Nada por reabastecer' }); return json({ skipped: true }) }
      mail = reorderEmail(data, body.product_ids ?? [])
    } else if (kind === 'weekly') {
      const { data, error } = await db.rpc('weekly_report', {})
      if (error) throw error
      mail = weeklyEmail(data)
    } else return json({ error: `Tipo desconocido: ${kind}` }, 400)

    const { data: rec, error: rerr } = await db.from('alert_recipients').select('email').eq('active', true)
    if (rerr) throw rerr
    if (!rec.length) { await log(false, { error: 'No hay destinatarios activos' }); return json({ error: 'No hay destinatarios activos' }, 400) }

    // One email per recipient, so one rejected address doesn't block the others.
    const results = []
    for (const { email } of rec) {
      const r = await fetch(RESEND, {
        method: 'POST',
        headers: { Authorization: `Bearer ${env('RESEND_API_KEY')}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ from: FROM, to: [email], subject: mail.subject, html: mail.html }),
      })
      const out = await r.json().catch(() => ({}))
      results.push({ email, ok: r.ok, ...(r.ok ? { id: out.id } : { error: out.message ?? r.statusText }) })
    }
    const ok = results.every((r) => r.ok)
    await log(ok, { subject: mail.subject, results, by: viaCron ? 'programado' : 'manual' })
    return json({ ok, results }, ok ? 200 : 502)
  } catch (e) {
    await log(false, { error: String((e as Error).message ?? e) })
    return json({ error: String((e as Error).message ?? e) }, 500)
  }
})
