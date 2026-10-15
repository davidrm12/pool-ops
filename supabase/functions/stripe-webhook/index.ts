// Cloro · Stripe webhook. Deploy with --no-verify-jwt. Register in Stripe → Developers → Webhooks:
//   URL: https://<project>.supabase.co/functions/v1/stripe-webhook
//   Events: checkout.session.completed, payment_intent.succeeded, payment_intent.payment_failed, charge.refunded
// Secrets: STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET
import { env, json, serviceClient } from '../_shared/common.ts'
import { stripe, verifyWebhook } from '../_shared/stripe.ts'
import { processOutbox } from '../_shared/outbox.ts'

Deno.serve(async (req) => {
  const raw = await req.text()
  if (!(await verifyWebhook(raw, req.headers.get('stripe-signature'), env('STRIPE_WEBHOOK_SECRET')))) return json({ error: 'invalid signature' }, 400)
  const event = JSON.parse(raw)
  const obj = event.data?.object ?? {}
  const db = serviceClient()

  try {
    if (event.type === 'checkout.session.completed') {
      if (obj.mode === 'payment' && obj.metadata?.kind === 'order' && obj.payment_status === 'paid') {
        const pi = await stripe('GET', `payment_intents/${obj.payment_intent}`, { expand: ['payment_method'] })
        const pm = pi.payment_method ?? {}
        const saved = pi.setup_future_usage === 'off_session'
        const { error } = await db.rpc('mark_order_paid_online', {
          p_order: Number(obj.metadata.order_id), p_intent: pi.id, p_amount: obj.amount_total / 100,
          p_pm: saved ? pm.id ?? null : null, p_brand: saved ? pm.card?.brand ?? null : null, p_last4: saved ? pm.card?.last4 ?? null : null,
          p_stripe_customer: obj.customer ?? null,
        })
        if (error) throw error
      }
      if (obj.mode === 'setup' && obj.metadata?.kind === 'card_update') {
        const si = await stripe('GET', `setup_intents/${obj.setup_intent}`, { expand: ['payment_method'] })
        const pm = si.payment_method ?? {}
        const subId = Number(obj.metadata.subscription_id)
        await db.from('subscriptions').update({ stripe_payment_method_id: pm.id, card_brand: pm.card?.brand ?? null, card_last4: pm.card?.last4 ?? null, payment_method: 'card' }).eq('id', subId)
        // Unpaid card orders of this subscription get a fresh attempt with the new card.
        // charge_attempts is NOT reset: it is part of the Stripe idempotency key, so reusing a
        // number would make Stripe replay the previous (declined) result.
        await db.from('orders').update({ charge_status: 'pending', charge_error: null, charge_decline_code: null })
          .eq('subscription_id', subId).eq('payment_status', 'pending').in('charge_status', ['failed', 'none']).neq('status', 'cancelled').eq('payment_method', 'card')
      }
    }
    if (event.type === 'payment_intent.succeeded' && obj.metadata?.kind === 'auto') {
      const { data: o } = await db.from('orders').select('charge_status').eq('id', Number(obj.metadata.order_id)).single()
      if (o?.charge_status === 'processing') await db.rpc('charge_result', { p_order: Number(obj.metadata.order_id), p_ok: true, p_intent: obj.id })
    }
    if (event.type === 'payment_intent.payment_failed' && obj.metadata?.kind === 'auto') {
      const { data: o } = await db.from('orders').select('charge_status').eq('id', Number(obj.metadata.order_id)).single()
      if (o?.charge_status === 'processing') {
        const err = obj.last_payment_error ?? {}
        await db.rpc('charge_result', { p_order: Number(obj.metadata.order_id), p_ok: false, p_intent: obj.id, p_error: err.message ?? 'Pago rechazado', p_code: err.decline_code ?? err.code ?? 'card_error' })
      }
    }
    if (event.type === 'charge.refunded' && obj.payment_intent) {
      await db.from('orders').update({ charge_status: 'refunded', refunded_amount: obj.amount_refunded / 100 })
        .eq('stripe_payment_intent_id', obj.payment_intent).neq('charge_status', 'refunded')
    }
    await processOutbox(db).catch((e) => console.error('outbox', e))
    return json({ received: true })
  } catch (e) {
    console.error(e)
    return json({ error: String((e as Error).message ?? e) }, 500)   // Stripe retries on 5xx
  }
})
