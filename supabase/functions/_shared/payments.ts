// Card payments: Checkout for on-session payments (first order, payment links,
// card updates) and off-session charges of saved cards with DB-enforced limits.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { orderLabel, storeLink } from './common.ts'
import { stripe, StripeError, toCents } from './stripe.ts'

async function ensureStripeCustomer(db: SupabaseClient, customerId: number, email?: string | null): Promise<string> {
  const { data: c, error } = await db.from('customers').select('id, name, phone, email, stripe_customer_id').eq('id', customerId).single()
  if (error) throw error
  if (c.stripe_customer_id) return c.stripe_customer_id
  const cus = await stripe('POST', 'customers', {
    name: c.name, phone: c.phone ? `+52${c.phone}` : undefined, email: c.email ?? email ?? undefined,
    metadata: { customer_id: String(c.id) },
  }, `customer-${c.id}`)
  await db.from('customers').update({ stripe_customer_id: cus.id }).eq('id', c.id)
  return cus.id
}

// Checkout Session for paying an order now. Saves the card if the order belongs to a subscription.
export async function orderCheckout(db: SupabaseClient, orderId: number): Promise<string> {
  const { data: o, error } = await db.from('orders')
    .select('id, customer_id, status, payment_status, public_token, subscription_id, contact_email, order_date').eq('id', orderId).single()
  if (error) throw error
  if (o.status === 'cancelled') throw new Error('Este pedido está cancelado.')
  if (o.payment_status === 'paid') throw new Error('Este pedido ya está pagado.')
  const { data: v } = await db.from('v_orders').select('total').eq('id', orderId).single()
  const { data: summary } = await db.rpc('order_public_summary', { p_order: orderId })
  if (!v || Number(v.total) <= 0) throw new Error('El total del pedido no es válido.')
  const { data: st } = await db.from('settings').select('store_name').single()
  const customer = await ensureStripeCustomer(db, o.customer_id, o.contact_email)
  const session = await stripe('POST', 'checkout/sessions', {
    mode: 'payment',
    customer,
    locale: 'es-419',
    line_items: [{
      quantity: 1,
      price_data: {
        currency: 'mxn', unit_amount: toCents(v.total),
        product_data: { name: `${orderLabel(o.order_date)} · ${st?.store_name ?? ''}`.trim(), description: String(summary ?? '').slice(0, 500) || undefined },
      },
    }],
    payment_method_types: ['card'],
    payment_intent_data: {
      metadata: { order_id: String(o.id), kind: 'checkout' },
      setup_future_usage: o.subscription_id ? 'off_session' : undefined,
      description: orderLabel(o.order_date),
    },
    metadata: { kind: 'order', order_id: String(o.id) },
    success_url: storeLink(`/pedido/${o.public_token}?pago=ok`),
    cancel_url: storeLink(`/pedido/${o.public_token}`),
  })
  await db.from('orders').update({ stripe_checkout_id: session.id, payment_method: 'card' }).eq('id', o.id)
  return session.url
}

// Checkout in setup mode: replaces the subscription's saved card without charging.
export async function cardUpdateCheckout(db: SupabaseClient, subscriptionId: number, token: string): Promise<string> {
  const { data: s, error } = await db.from('subscriptions').select('id, customer_id').eq('id', subscriptionId).single()
  if (error) throw error
  const customer = await ensureStripeCustomer(db, s.customer_id)
  const session = await stripe('POST', 'checkout/sessions', {
    mode: 'setup', customer, currency: 'mxn', locale: 'es-419', payment_method_types: ['card'],
    metadata: { kind: 'card_update', subscription_id: String(s.id) },
    setup_intent_data: { metadata: { kind: 'card_update', subscription_id: String(s.id) } },
    success_url: storeLink(`/suscripcion/${token}?tarjeta=ok`),
    cancel_url: storeLink(`/suscripcion/${token}`),
  })
  return session.url
}

// Off-session charge of the subscription's saved card. All limits live in charge_preflight().
export async function chargeOrder(db: SupabaseClient, orderId: number, approved = false) {
  const { data: pre, error } = await db.rpc('charge_preflight', { p_order: orderId, p_approved: approved })
  if (error) throw error
  if (!pre.ok) return { order_id: orderId, charged: false, reason: pre.reason, requires_approval: !!pre.requires_approval }
  try {
    const pi = await stripe('POST', 'payment_intents', {
      amount: toCents(pre.amount), currency: 'mxn', customer: pre.customer, payment_method: pre.payment_method,
      off_session: true, confirm: true, description: pre.description,
      metadata: { order_id: String(orderId), kind: 'auto' },
    }, pre.key)
    if (pi.status === 'succeeded') {
      await db.rpc('charge_result', { p_order: orderId, p_ok: true, p_intent: pi.id })
      return { order_id: orderId, charged: true, amount: pre.amount }
    }
    if (pi.status === 'processing') return { order_id: orderId, charged: false, processing: true }   // webhook finishes it
    await db.rpc('charge_result', { p_order: orderId, p_ok: false, p_intent: pi.id, p_error: `Estado ${pi.status}`, p_code: pi.status })
    return { order_id: orderId, charged: false, reason: pi.status }
  } catch (e) {
    if (e instanceof StripeError && e.status < 500) {
      const msg = e.decline_code === 'insufficient_funds' ? 'Fondos insuficientes'
        : e.code === 'authentication_required' ? 'El banco pidió autenticación al cliente'
        : e.code === 'expired_card' ? 'Tarjeta vencida' : e.message
      await db.rpc('charge_result', { p_order: orderId, p_ok: false, p_intent: e.payment_intent?.id ?? null,
                                      p_error: msg, p_code: e.decline_code ?? e.code ?? 'card_error' })
      return { order_id: orderId, charged: false, reason: msg }
    }
    // Network/5xx: the outcome is unknown. Never retried automatically; check in Stripe.
    await db.rpc('charge_result', { p_order: orderId, p_ok: false, p_intent: null,
                                    p_error: 'Resultado desconocido (revisar en Stripe antes de reintentar)', p_code: 'unknown_outcome' })
    return { order_id: orderId, charged: false, reason: 'unknown_outcome' }
  }
}

export async function refundOrder(db: SupabaseClient, orderId: number) {
  const { data: o, error } = await db.from('orders').select('id, stripe_payment_intent_id, charged_amount, payment_status, charge_status').eq('id', orderId).single()
  if (error) throw error
  if (!o.stripe_payment_intent_id || o.charge_status !== 'succeeded') throw new Error('Este pedido no tiene un cobro con tarjeta para reembolsar.')
  const r = await stripe('POST', 'refunds', { payment_intent: o.stripe_payment_intent_id, metadata: { order_id: String(o.id) } }, `refund-order-${o.id}`)
  await db.from('orders').update({ charge_status: 'refunded', refunded_amount: o.charged_amount, payment_status: 'pending', status: 'cancelled' }).eq('id', o.id)
  return { refund: r.id, amount: o.charged_amount }
}
