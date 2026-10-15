// Sends queued notifications (table `notifications`): order confirmations, new-order
// alerts, price-change notices, failed/held charges, payment links, subscription changes.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { ADMIN_URL, PAY, adminRecipients, btn, day, esc, money, orderLabel, para, row, section, sendEmail, shell, storeLink, table, waLink } from './common.ts'

type N = { id: number; kind: string; to_admin: boolean; to_email: string | null; order_id: number | null; subscription_id: number | null; payload: Record<string, any> }

const customerFooter = (store: any) =>
  `${esc(store.store_name)}${store.store_whatsapp ? ` · <a href="${waLink(store.store_whatsapp)}" style="color:#00798A">WhatsApp</a>` : ''}${STORE ? ` · <a href="${STORE}" style="color:#00798A">Tienda</a>` : ''}`
const STORE = storeLink('/')

async function loadOrder(db: SupabaseClient, id: number) {
  const { data: o } = await db.from('orders').select('*, customer:customers(name, phone, email, address, postal_code), subscription:subscriptions(manage_token, frequency_weeks)').eq('id', id).single()
  const { data: v } = await db.from('v_orders').select('subtotal, total, items_summary').eq('id', id).single()
  const { data: pub } = await db.rpc('order_public_summary', { p_order: id })
  return o ? { ...o, ...v, public_summary: pub, label: orderLabel(o.order_date) } : null
}

// Customers see bundles as one line at the bundle price (so only the subscription discount shows);
// the admin sees every size (what to load) and the full discount.
function orderSummary(o: any, customer = true) {
  const disc = customer ? Number(o.discount) - Number(o.bundle_discount ?? 0) : Number(o.discount)
  return table(
    row('Productos', esc(customer ? (o.public_summary ?? o.items_summary) : o.items_summary)) +
    (disc > 0 ? row(customer ? 'Descuento suscripción' : 'Descuentos', `−${money(disc)}`) : '') +
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
          row('Beneficiario', esc(store.bank_beneficiary ?? '')) + row('Concepto', o.label) + row('Monto', money(o.total), true)))
      } else if (o.payment_method === 'cash') pay = para('Pagas en efectivo al recibir tu pedido.')
      const { data: vs } = o.subscription_id ? await db.from('v_subscriptions').select('items_summary').eq('id', o.subscription_id).single() : { data: null }
      const every = o.subscription?.frequency_weeks === 1 ? 'Cada semana' : `Cada ${o.subscription?.frequency_weeks} semanas`
      const sub = o.subscription ? section('Tu suscripción', para(`${every} te llevamos: ${esc(vs?.items_summary ?? '')}. Puedes saltar una entrega, pausar o cancelar cuando quieras.`) +
        btn(storeLink(`/suscripcion/${o.subscription.manage_token}`), 'Administrar mi suscripción')) : ''
      return { to, subject: `${o.label} recibido: entrega el ${day(o.delivery_date, { weekday: 'long', day: 'numeric', month: 'short' })}`,
        html: shell(`¡Gracias, ${o.customer.name.split(' ')[0]}!`, o.label, section('Tu pedido', orderSummary(o)) + pay + sub +
          para(btn(storeLink(`/pedido/${o.public_token}`), 'Ver mi pedido')), foot) }
    }
    case 'admin_new_order':
      return { to, subject: `Nuevo pedido web #${o.id}: ${o.customer.name}, ${money(o.total)}`,
        html: shell(`Nuevo pedido #${o.id}`, `${o.customer.name} · ${PAY[o.payment_method]}${o.subscription ? ' · suscripción' : ''}`,
          section('Pedido', orderSummary(o, false) + table(row('WhatsApp', o.customer.phone ? `<a href="${waLink(o.customer.phone)}">${esc(o.customer.phone)}</a>` : '—') +
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
      return { to, subject: `No pudimos cobrar tu ${o.label.toLowerCase()}`,
        html: shell('No pudimos cobrar tu tarjeta', `${o.label} · ${money(o.total)}`,
          para(`Tu banco rechazó el cobro de tu entrega del ${esc(day(o.delivery_date))}. ${n.payload.retry === false ? '' : 'Lo intentaremos una vez más mañana. '}Si prefieres, paga ahora con otra tarjeta o paga al recibir (efectivo o SPEI).`) +
          para(btn(storeLink(`/pedido/${o.public_token}`), 'Pagar con otra tarjeta')), foot) }
    case 'charge_needs_approval':
      return { to, subject: `Cobro retenido: pedido #${o.id} (${money(n.payload.amount)})`,
        html: shell('Cobro retenido para tu aprobación', `Pedido #${o.id} · ${o.customer.name}`,
          section('Por qué', para(esc(n.payload.reason)) + orderSummary(o, false)) +
          para('No se cobró nada. Revisa el pedido y, si es correcto, usa "Aprobar y cobrar" en la administración.') +
          (ADMIN_URL ? para(btn(ADMIN_URL, 'Abrir administración')) : '')) }
    case 'payment_link':
      return { to, subject: `Liga de pago: ${o.label}`,
        html: shell('Paga tu pedido', `${o.label} · ${money(o.total)}`, section('Tu pedido', orderSummary(o)) +
          para(btn(n.payload.url ?? storeLink(`/pedido/${o.public_token}`), 'Pagar con tarjeta')), foot) }
    case 'subscription_change': {
      const { data: s } = await db.from('subscriptions').select('id, status, frequency_weeks, next_delivery_date, customer:customers(name)').eq('id', n.subscription_id).single() as { data: any }
      const what: Record<string, string> = { skip: n.payload.skipped_date ? `saltó la entrega del ${day(n.payload.skipped_date)} (pedido cancelado)` : 'saltó la siguiente entrega', pause: 'pausó su suscripción', resume: 'reactivó su suscripción', cancel: 'canceló su suscripción', frequency: `cambió la frecuencia a cada ${n.payload.value} semana(s)` }
      return { to, subject: `${s?.customer?.name}: ${what[n.payload.action] ?? n.payload.action}`,
        html: shell('Cambio en una suscripción', `${s?.customer?.name}`,
          para(`${esc(s?.customer?.name)} ${what[n.payload.action] ?? esc(n.payload.action)}. Siguiente entrega: ${s?.status === 'active' ? esc(day(s.next_delivery_date)) : '—'}.`)) }
    }
    case 'delivery_adjusted': {
      const p = n.payload
      const list = (p.skipped ?? []).map((x: string) => `<li>${esc(x)}</li>`).join('')
      const { data: s } = await db.from('subscriptions').select('manage_token, customer:customers(name)').eq('id', n.subscription_id).single() as { data: any }
      if (n.to_admin) return { to, subject: `Sin existencia para la suscripción de ${s?.customer?.name}: ${p.empty ? 'no se creó pedido' : 'pedido ajustado'}`,
        html: shell('Entrega de suscripción ajustada', `${s?.customer?.name} · ${esc(day(p.date))}`,
          para(`No había existencia suficiente para:`) + `<ul>${list}</ul>` +
          para(p.empty ? 'No se creó pedido ni se cobró nada para esta entrega.' : `El pedido #${n.order_id} se creó y se cobra solo por lo que sí se entrega.`) +
          (ADMIN_URL ? para(btn(ADMIN_URL, 'Abrir administración')) : '')) }
      return { to, subject: p.empty ? `Esta vez no pudimos preparar tu entrega del ${day(p.date)}` : `Tu entrega del ${day(p.date)} viene incompleta`,
        html: shell(p.empty ? 'Esta entrega no sale' : 'Ajustamos tu entrega', esc(day(p.date, { weekday: 'long', day: 'numeric', month: 'long' })),
          para('Se nos agotó lo siguiente y no alcanzamos a tenerlo para esta entrega:') + `<ul>${list}</ul>` +
          para(p.empty ? 'No te cobramos nada por esta entrega. Tu suscripción sigue igual para la siguiente.'
                       : 'Solo te cobramos lo que sí te llevamos. Tu suscripción sigue igual para la siguiente entrega.') +
          (s ? para(btn(storeLink(`/suscripcion/${s.manage_token}`), 'Ver mi suscripción')) : ''), foot) }
    }
    case 'subscription_item_removed': {
      const p = n.payload
      const list = (p.removed ?? []).map((x: string) => `<li>${esc(x)}</li>`).join('')
      const { data: s } = await db.from('subscriptions').select('manage_token, customer:customers(name)').eq('id', n.subscription_id).single() as { data: any }
      if (n.to_admin) return { to, subject: `Suscripción de ${s?.customer?.name}: producto retirado${p.paused ? ', quedó en pausa' : ''}`,
        html: shell('Producto retirado de una suscripción', `${s?.customer?.name}`,
          `<ul>${list}</ul>` + para(p.paused ? 'La suscripción quedó vacía y se pausó; su próximo pedido sin cobrar se canceló.' : 'Se quitó de la suscripción y de su próximo pedido sin cobrar.')) }
      return { to, subject: 'Cambio en tu suscripción',
        html: shell('Ya no tenemos un producto de tu suscripción', '',
          para('Dejamos de vender lo siguiente, así que lo quitamos de tu suscripción y no se te cobrará:') + `<ul>${list}</ul>` +
          para(p.paused ? 'Como era lo único en tu suscripción, la pausamos. Si quieres algo distinto, escríbenos.' : 'El resto de tu suscripción sigue igual.') +
          (s ? para(btn(storeLink(`/suscripcion/${s.manage_token}`), 'Ver mi suscripción')) : ''), foot) }
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
