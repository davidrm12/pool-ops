// Sends queued notifications (table `notifications`): order confirmations, new-order
// alerts, price-change notices, failed/held charges, payment links, subscription changes.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { ADMIN_URL, PAY, adminRecipients, btn, day, esc, money, para, row, section, sendEmail, shell, storeLink, table, waLink } from './common.ts'

type N = { id: number; kind: string; to_admin: boolean; to_email: string | null; order_id: number | null; subscription_id: number | null; payload: Record<string, any> }

const customerFooter = (store: any) =>
  `${esc(store.store_name)}${store.store_whatsapp ? ` · <a href="${waLink(store.store_whatsapp)}" style="color:#00798A">WhatsApp</a>` : ''}${STORE ? ` · <a href="${STORE}" style="color:#00798A">Tienda</a>` : ''}`
const STORE = storeLink('/')

async function loadOrder(db: SupabaseClient, id: number) {
  const { data: o } = await db.from('orders').select('*, customer:customers(name, phone, email, address, postal_code), subscription:subscriptions(manage_token, frequency_weeks)').eq('id', id).single()
  const { data: v } = await db.from('v_orders').select('subtotal, total, items_summary').eq('id', id).single()
  return o ? { ...o, ...v } : null
}

function orderSummary(o: any) {
  return table(
    row('Productos', esc(o.items_summary)) +
    (Number(o.discount) > 0 ? row('Descuento', `−${money(o.discount)}`) : '') +
    row('Envío', Number(o.delivery_fee) > 0 ? money(o.delivery_fee) : 'Gratis') +
    row('Total', money(o.total), true) +
    row('Entrega', esc(day(o.delivery_date))) +
    row('Pago', `${PAY[o.payment_method]} · ${o.payment_status === 'paid' ? 'pagado' : 'por pagar'}`))
}

async function build(db: SupabaseClient, n: N, store: any): Promise<{ to: string[]; subject: string; html: string } | null> {
  const admins = n.to_admin ? await adminRecipients(db) : []
  const to = n.to_admin ? admins : n.to_email ? [n.to_email] : []
  if (!to.length) return null
  const o = n.order_id ? await loadOrder(db, n.order_id) : null
  const foot = customerFooter(store)

  switch (n.kind) {
    case 'order_confirmation': {
      let pay = ''
      if (o.payment_method === 'spei' && o.payment_status !== 'paid') {
        pay = section('Datos para tu transferencia SPEI', table(
          row('Banco', esc(store.bank_name ?? '')) + row('CLABE', `<b>${esc(store.bank_clabe ?? '')}</b>`) +
          row('Beneficiario', esc(store.bank_beneficiary ?? '')) + row('Concepto', `Pedido ${o.id}`) + row('Monto', money(o.total), true)))
      } else if (o.payment_method === 'cash') pay = para('Pagas en efectivo al recibir tu pedido.')
      const sub = o.subscription ? section('Tu suscripción', para(`Te llevamos lo mismo cada ${o.subscription.frequency_weeks === 1 ? 'semana' : `${o.subscription.frequency_weeks} semanas`}. Puedes saltar una entrega, pausar o cancelar cuando quieras.`) +
        btn(storeLink(`/suscripcion/${o.subscription.manage_token}`), 'Administrar mi suscripción')) : ''
      return { to, subject: `Pedido #${o.id} recibido: entrega el ${day(o.delivery_date, { weekday: 'long', day: 'numeric', month: 'short' })}`,
        html: shell(`¡Gracias, ${o.customer.name.split(' ')[0]}!`, `Pedido #${o.id}`, section('Tu pedido', orderSummary(o)) + pay + sub +
          para(btn(storeLink(`/pedido/${o.public_token}`), 'Ver mi pedido')), foot) }
    }
    case 'admin_new_order':
      return { to, subject: `Nuevo pedido web #${o.id}: ${o.customer.name}, ${money(o.total)}`,
        html: shell(`Nuevo pedido #${o.id}`, `${o.customer.name} · ${PAY[o.payment_method]}${o.subscription ? ' · suscripción' : ''}`,
          section('Pedido', orderSummary(o) + table(row('WhatsApp', o.customer.phone ? `<a href="${waLink(o.customer.phone)}">${esc(o.customer.phone)}</a>` : '—') +
            row('Dirección', esc(o.delivery_address ?? o.customer.address ?? '')))) +
          (o.needs_review ? `<div style="background:#FCF0C6;border-radius:10px;padding:12px 16px;margin-top:14px;font-size:14px"><b>Revisar:</b> ${esc(o.review_note)}</div>` : '') +
          (ADMIN_URL ? para(btn(ADMIN_URL, 'Abrir administración')) : '')) }
    case 'price_change': {
      const { data: s } = await db.from('subscriptions').select('manage_token').eq('id', n.subscription_id).single()
      const p = n.payload
      return { to, subject: `Cambio de precio en tu suscripción: ${p.product} ${p.label}`,
        html: shell('Aviso de cambio de precio', `${p.product} · ${p.label}`,
          section('Qué cambia', table(row('Precio anterior', money(p.old_price)) + row('Precio nuevo', money(p.new_price), true) +
            row('Aplica a entregas desde', esc(day(p.effective_from))))) +
          para('Tu descuento de suscriptor se sigue aplicando. Si prefieres, puedes saltar entregas, pausar o cancelar sin costo.') +
          (s ? para(btn(storeLink(`/suscripcion/${s.manage_token}`), 'Administrar mi suscripción')) : ''), foot) }
    }
    case 'charge_failed':
      if (n.to_admin) return { to, subject: `No se pudo cobrar el pedido #${o.id} (${o.customer.name})`,
        html: shell('Cobro con tarjeta fallido', `Pedido #${o.id} · ${money(o.total)}`,
          section('Detalle', table(row('Cliente', esc(o.customer.name)) + row('Motivo', esc(n.payload.error ?? '')) + row('Intentos', String(n.payload.attempts ?? 1)) + row('Entrega', esc(day(o.delivery_date))))) +
          para('El pedido sigue en la ruta como "por cobrar". En la administración puedes reintentar el cobro o enviar una liga de pago.') +
          (ADMIN_URL ? para(btn(ADMIN_URL, 'Abrir administración')) : '')) }
      return { to, subject: `No pudimos cobrar tu pedido #${o.id}`,
        html: shell('No pudimos cobrar tu tarjeta', `Pedido #${o.id} · ${money(o.total)}`,
          para(`Tu banco rechazó el cobro de tu entrega del ${esc(day(o.delivery_date))}. ${n.payload.retry === false ? '' : 'Lo intentaremos una vez más mañana. '}Si prefieres, paga ahora con otra tarjeta o paga al recibir (efectivo o SPEI).`) +
          para(btn(storeLink(`/pedido/${o.public_token}`), 'Pagar con otra tarjeta')), foot) }
    case 'charge_needs_approval':
      return { to, subject: `Cobro retenido: pedido #${o.id} (${money(n.payload.amount)})`,
        html: shell('Cobro retenido para tu aprobación', `Pedido #${o.id} · ${o.customer.name}`,
          section('Por qué', para(esc(n.payload.reason)) + orderSummary(o)) +
          para('No se cobró nada. Revisa el pedido y, si es correcto, usa "Aprobar y cobrar" en la administración.') +
          (ADMIN_URL ? para(btn(ADMIN_URL, 'Abrir administración')) : '')) }
    case 'payment_link':
      return { to, subject: `Liga de pago: pedido #${o.id}`,
        html: shell('Paga tu pedido', `Pedido #${o.id} · ${money(o.total)}`, section('Tu pedido', orderSummary(o)) +
          para(btn(n.payload.url ?? storeLink(`/pedido/${o.public_token}`), 'Pagar con tarjeta')), foot) }
    case 'subscription_change': {
      const { data: s } = await db.from('subscriptions').select('id, status, frequency_weeks, next_delivery_date, customer:customers(name)').eq('id', n.subscription_id).single() as { data: any }
      const what: Record<string, string> = { skip: 'saltó la siguiente entrega', pause: 'pausó su suscripción', resume: 'reactivó su suscripción', cancel: 'canceló su suscripción', frequency: `cambió la frecuencia a cada ${n.payload.value} semana(s)` }
      return { to, subject: `${s?.customer?.name}: ${what[n.payload.action] ?? n.payload.action}`,
        html: shell('Cambio en una suscripción', `${s?.customer?.name}`,
          para(`${esc(s?.customer?.name)} ${what[n.payload.action] ?? esc(n.payload.action)}. Siguiente entrega: ${s?.status === 'active' ? esc(day(s.next_delivery_date)) : '—'}.`)) }
    }
  }
  return null
}

export async function processOutbox(db: SupabaseClient, limit = 50) {
  const { data: store } = await db.from('settings').select('store_name, store_whatsapp, bank_name, bank_clabe, bank_beneficiary').single()
  const { data: pending } = await db.from('notifications').select('*').is('sent_at', null).order('id').limit(limit)
  const results = []
  for (const n of (pending ?? []) as N[]) {
    try {
      const mail = await build(db, n, store)
      if (!mail) { await db.from('notifications').update({ sent_at: new Date().toISOString(), error: 'Sin destinatario' }).eq('id', n.id); continue }
      const sent = await sendEmail(mail.to, mail.subject, mail.html)
      const ok = sent.every((s) => s.ok)
      await db.from('notifications').update({ sent_at: new Date().toISOString(), error: ok ? null : sent.filter((s) => !s.ok).map((s) => `${s.email}: ${s.error}`).join('; ') }).eq('id', n.id)
      results.push({ id: n.id, kind: n.kind, ok })
    } catch (e) {
      await db.from('notifications').update({ sent_at: new Date().toISOString(), error: String((e as Error).message ?? e) }).eq('id', n.id)
      results.push({ id: n.id, kind: n.kind, ok: false })
    }
  }
  // Only log runs with failures; successful sends would flood the history.
  if (results.some((r) => !r.ok)) await db.from('automation_runs').insert({ job: 'outbox', ok: results.every((r) => r.ok), details: { sent: results.length, failed: results.filter((r) => !r.ok).length } })
  return results
}
