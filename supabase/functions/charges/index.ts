// Cloro · charges Edge Function. Deploy with --no-verify-jwt (checks scheduler secret or admin login itself).
// Actions:
//   run                       scheduler: charge due subscription orders (+ one automatic retry)
//   charge   {order_id}       admin: "Reintentar cobro" (limits still apply)
//   approve  {order_id}       admin: "Aprobar y cobrar" a held charge (limits bypassed, logged)
//   refund   {order_id}       admin: full refund through Stripe; cancels the order
//   payment_link {order_id}   admin: Checkout link; emailed to the customer if they have an email
import { authorize, cors, json, serviceClient } from '../_shared/common.ts'
import { chargeOrder, orderCheckout, refundOrder } from '../_shared/payments.ts'
import { processOutbox } from '../_shared/outbox.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const who = await authorize(req)
  if (!who) return json({ error: 'No autorizado' }, 401)
  const db = serviceClient()
  const body = await req.json().catch(() => ({}))
  const orderId = Number(body.order_id)

  try {
    let result: unknown
    switch (body.action) {
      case 'run': {
        const { data: ids, error } = await db.rpc('orders_to_charge', {})
        if (error) throw error
        const results = []
        for (const id of (ids ?? []) as number[]) results.push(await chargeOrder(db, Number(id)))
        await db.from('automation_runs').insert({ job: 'charges', ok: true, details: {
          attempted: results.length, charged: results.filter((r: any) => r.charged).length,
          held: results.filter((r: any) => r.requires_approval).length, failed: results.filter((r: any) => !r.charged && !r.requires_approval).length } })
        result = { results }
        break
      }
      case 'charge':
        result = await chargeOrder(db, orderId, false)
        break
      case 'approve':
        if (who !== 'admin') return json({ error: 'Solo un administrador puede aprobar' }, 403)
        result = await chargeOrder(db, orderId, true)
        break
      case 'refund':
        if (who !== 'admin') return json({ error: 'Solo un administrador puede reembolsar' }, 403)
        result = await refundOrder(db, orderId)
        break
      case 'payment_link': {
        const url = await orderCheckout(db, orderId)
        const { data: o } = await db.from('orders').select('contact_email, customer:customers(email)').eq('id', orderId).single()
        const email = o?.contact_email ?? (o as any)?.customer?.email
        if (email) await db.from('notifications').insert({ kind: 'payment_link', to_email: email, order_id: orderId, payload: { url } })
        result = { url, emailed: !!email }
        break
      }
      default:
        return json({ error: 'Acción desconocida' }, 400)
    }
    await processOutbox(db).catch((e) => console.error('outbox', e))
    return json(result)
  } catch (e) {
    console.error(e)
    return json({ error: String((e as Error).message ?? e) }, 500)
  }
})
