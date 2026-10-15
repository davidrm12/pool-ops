// Cloro · store Edge Function (public, no login). Deploy with --no-verify-jwt.
// Actions:
//   place_order   {order, turnstile_token}       → {token, checkout_url?}
//   pay_order     {token}                         → {checkout_url}      (card payment for an unpaid order)
//   subscription  {token, op, value?}             → subscription data   (skip | pause | resume | cancel | frequency)
//   update_card   {token}                         → {checkout_url}      (replace saved card)
// Secrets: TURNSTILE_SECRET, STRIPE_SECRET_KEY, STORE_URL (+ RESEND_API_KEY for emails)
import { cors, env, json, serviceClient } from '../_shared/common.ts'
import { cardUpdateCheckout, orderCheckout } from '../_shared/payments.ts'
import { processOutbox } from '../_shared/outbox.ts'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

async function turnstileOk(token: string, ip: string | null) {
  const secret = env('TURNSTILE_SECRET')
  if (!secret) return false
  const form = new URLSearchParams({ secret, response: token ?? '' })
  if (ip) form.set('remoteip', ip)
  const r = await fetch(env('TURNSTILE_VERIFY_URL', 'https://challenges.cloudflare.com/turnstile/v0/siteverify'), { method: 'POST', body: form })
  const b = await r.json().catch(() => ({}))
  return b.success === true
}

// Postgres raises Spanish messages for validation; pass those through, hide anything else.
const friendly = (e: any) => {
  const m = String(e?.message ?? e)
  return e?.code === 'P0001' || /^[A-ZÁÉÍÓÚ¡¿]/.test(m) && !/violates|syntax|relation|column|function/i.test(m) ? m : 'No pudimos procesar tu solicitud. Intenta de nuevo o escríbenos por WhatsApp.'
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Método no permitido' }, 405)
  const db = serviceClient()
  const body = await req.json().catch(() => ({}))

  try {
    switch (body.action) {
      case 'place_order': {
        const ip = req.headers.get('cf-connecting-ip') ?? req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? null
        if (!(await turnstileOk(body.turnstile_token, ip))) return json({ error: 'No pudimos verificar que no eres un robot. Recarga la página e intenta de nuevo.' }, 400)
        const { data, error } = await db.rpc('place_web_order', { p: body.order ?? {} })
        if (error) return json({ error: friendly(error) }, 400)
        let checkout_url: string | undefined
        if (data.payment_method === 'card') {
          try { checkout_url = await orderCheckout(db, data.order_id) }
          catch (e) { console.error('checkout', e); return json({ token: data.token, error: 'Tu pedido quedó registrado, pero no pudimos abrir el pago con tarjeta. Intenta desde la página del pedido.' }) }
        }
        await processOutbox(db).catch((e) => console.error('outbox', e))
        return json({ token: data.token, checkout_url })
      }
      case 'pay_order': {
        if (!UUID.test(body.token ?? '')) return json({ error: 'Liga no válida.' }, 400)
        const { data: o } = await db.from('orders').select('id').eq('public_token', body.token).single()
        if (!o) return json({ error: 'Pedido no encontrado.' }, 404)
        return json({ checkout_url: await orderCheckout(db, o.id) })
      }
      case 'subscription': {
        if (!UUID.test(body.token ?? '')) return json({ error: 'Liga no válida.' }, 400)
        const { data, error } = await db.rpc('subscription_self_service', { p_token: body.token, p_action: body.op, p_value: body.value ?? null })
        if (error) return json({ error: friendly(error) }, 400)
        await processOutbox(db).catch((e) => console.error('outbox', e))
        return json(data)
      }
      case 'update_card': {
        if (!UUID.test(body.token ?? '')) return json({ error: 'Liga no válida.' }, 400)
        const { data: s } = await db.from('subscriptions').select('id, status').eq('manage_token', body.token).single()
        if (!s || s.status === 'cancelled') return json({ error: 'Suscripción no encontrada.' }, 404)
        return json({ checkout_url: await cardUpdateCheckout(db, s.id, body.token) })
      }
      default:
        return json({ error: 'Acción desconocida' }, 400)
    }
  } catch (e) {
    console.error(e)
    return json({ error: friendly(e) }, 500)
  }
})
