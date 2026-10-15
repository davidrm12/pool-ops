import { useEffect, useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { chargeAction, getStoreUrl } from '../lib/data'
import { money2 as money } from '../lib/format'
import { Badge, useToast } from './ui'

export const CHARGE = {
  none: null,
  pending: ['Cobro programado', 'b-mute'],
  processing: ['Cobrando…', 'b-warn'],
  succeeded: ['Cobrado', 'b-ok'],
  failed: ['Cobro rechazado', 'b-bad'],
  requires_approval: ['Cobro retenido', 'b-warn'],
  refunded: ['Reembolsado', 'b-mute'],
}
export const ChargeBadge = ({ s }) => (CHARGE[s] ? <Badge cls={CHARGE[s][1]}>{CHARGE[s][0]}</Badge> : null)

// Review flag, customer link and card-charge actions for one order (web / subscription).
export default function OrderExtras({ order, total, onChanged }) {
  const toast = useToast()
  const [busy, setBusy] = useState(null)
  const [confirmRefund, setConfirmRefund] = useState(false)
  const [store, setStore] = useState('')
  useEffect(() => { getStoreUrl().then(setStore).catch(() => {}) }, [])

  const o = order
  const isCard = o.payment_method === 'card'
  const unpaid = o.payment_status !== 'paid' && o.status !== 'cancelled'
  const showCharge = o.charge_status !== 'none' || (isCard && o.subscription_id)
  const link = store && o.public_token ? `${store}/#/pedido/${o.public_token}` : ''
  if (!o.needs_review && !showCharge && !unpaid && !link && o.channel === 'manual') return null

  const run = async (action, ok) => {
    setBusy(action)
    try {
      const r = await chargeAction(action, o.id)
      if (action === 'payment_link') toast(r.emailed ? 'Liga de pago enviada por correo al cliente' : 'Liga creada; el cliente no tiene correo, cópiala y mándala por WhatsApp')
      else if (r.charged === false) toast(r.reason || 'No se pudo cobrar', true)
      else toast(ok)
      if (action === 'payment_link' && !r.emailed && r.url) { try { await navigator.clipboard.writeText(r.url) } catch { /* ignore */ } }
      onChanged()
    } catch (e) { toast(e.message, true) }
    setBusy(null); setConfirmRefund(false)
  }
  const reviewed = async () => {
    try { await q(supabase.from('orders').update({ needs_review: false }).eq('id', o.id)); toast('Marcado como revisado'); onChanged() } catch (e) { toast(e.message, true) }
  }
  const copy = async (text, what) => { try { await navigator.clipboard.writeText(text); toast(`${what} copiada`) } catch { toast(text) } }

  return (
    <div className="stack" style={{ gap: 10 }}>
      {o.needs_review && (
        <div className="note">
          <b>Revisar:</b> {o.review_note || 'Datos distintos a los del cliente.'}
          <div className="sub" style={{ marginTop: 4 }}>El directorio no se cambió solo. Si el cliente se mudó o cambió de correo, actualízalo en Directorio.</div>
          <div style={{ marginTop: 8 }}><button type="button" className="btn sm" onClick={reviewed}>Marcar como revisado</button></div>
        </div>
      )}

      {showCharge && (
        <div className="panel" style={{ padding: 12 }}>
          <div className="inline" style={{ justifyContent: 'space-between', flexWrap: 'wrap' }}>
            <div><b>Tarjeta</b> <ChargeBadge s={o.charge_status} />
              {o.charged_amount != null && <span className="muted"> {money(o.charged_amount)}</span>}
              {o.charge_attempts > 0 && <span className="sub"> · {o.charge_attempts} intento{o.charge_attempts > 1 ? 's' : ''}</span>}
            </div>
            {o.stripe_payment_intent_id && <span className="sub">{o.stripe_payment_intent_id}</span>}
          </div>
          {o.charge_error && o.charge_status !== 'succeeded' && <div className="sub" style={{ marginTop: 4 }}>Motivo: {o.charge_error}</div>}
          {o.charge_status === 'requires_approval' && <div className="sub" style={{ marginTop: 4 }}>No se ha cobrado nada. Revisa los productos y el total ({money(total)}) antes de aprobar.</div>}
          {o.refunded_amount > 0 && <div className="sub" style={{ marginTop: 4 }}>Reembolsado: {money(o.refunded_amount)}</div>}
          <div className="actions" style={{ marginTop: 10 }}>
            {unpaid && ['pending', 'failed'].includes(o.charge_status) && isCard && (
              <button type="button" className="btn sm" disabled={!!busy} onClick={() => run('charge', 'Cobro realizado')}>{busy === 'charge' ? 'Cobrando…' : 'Reintentar cobro'}</button>)}
            {unpaid && o.charge_status === 'requires_approval' && (
              <button type="button" className="btn sm primary" disabled={!!busy} onClick={() => run('approve', 'Cobro aprobado y realizado')}>{busy === 'approve' ? 'Cobrando…' : `Aprobar y cobrar ${money(total)}`}</button>)}
            {unpaid && o.charge_status !== 'processing' && (
              <button type="button" className="btn sm" disabled={!!busy} onClick={() => run('payment_link')}>{busy === 'payment_link' ? 'Creando…' : 'Enviar liga de pago'}</button>)}
            {o.charge_status === 'succeeded' && !confirmRefund && (
              <button type="button" className="btn sm ghost danger" onClick={() => setConfirmRefund(true)}>Reembolsar</button>)}
            {confirmRefund && (
              <>
                <span>¿Reembolsar {money(o.charged_amount)} y cancelar el pedido?</span>
                <button type="button" className="btn sm danger" disabled={!!busy} onClick={() => run('refund', 'Reembolso hecho; el pedido quedó cancelado')}>{busy === 'refund' ? 'Reembolsando…' : 'Sí, reembolsar'}</button>
                <button type="button" className="btn sm ghost" onClick={() => setConfirmRefund(false)}>No</button>
              </>
            )}
          </div>
        </div>
      )}

      {(o.contact_email || o.delivery_postal_code || link || unpaid || o.channel !== 'manual') && (
        <div className="muted inline" style={{ fontSize: 13.5, flexWrap: 'wrap', gap: '4px 14px' }}>
          {!showCharge && unpaid && <button type="button" className="btn sm" disabled={!!busy} onClick={() => run('payment_link')}>{busy === 'payment_link' ? 'Creando…' : 'Enviar liga de pago con tarjeta'}</button>}
          {o.order_date && <span>El cliente lo ve como <b>Pedido {o.order_date.slice(8, 10)}/{o.order_date.slice(5, 7)}/{o.order_date.slice(0, 4)}</b></span>}
          {o.contact_email && <span>Correo del pedido: {o.contact_email}</span>}
          {o.delivery_postal_code && <span>CP {o.delivery_postal_code}</span>}
          {link && <button type="button" className="btn sm ghost" onClick={() => copy(link, 'Liga del pedido')}>Copiar liga del cliente</button>}
          {link && <a href={link} target="_blank" rel="noreferrer">Ver como cliente</a>}
        </div>
      )}
    </div>
  )
}
