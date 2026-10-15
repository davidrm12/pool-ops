import { useEffect, useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { loadCustomers, loadVariants, syncLines } from '../lib/data'
import { L, money, options, phoneFmt, today } from '../lib/format'
import { Combo, DeleteButton, ErrorBox, Field, Loading, Modal, Select, useToast } from './ui'
import LinesEditor, { validLines } from './LinesEditor'
import CustomerForm from './CustomerForm'

const blank = () => ({
  customer_id: '', order_date: today(), delivery_date: '', delivery_address: '', channel: 'manual', status: 'pending',
  payment_method: 'cash', payment_status: 'pending', discount: 0, delivery_fee: 0, notes: '',
})

// orderId: edit existing; otherwise create (optionally preset customer).
export default function OrderForm({ orderId, presetCustomer, onClose, onSaved }) {
  const [f, setF] = useState(null)
  const [lines, setLines] = useState([])
  const [customers, setCustomers] = useState([])
  const [variants, setVariants] = useState([])
  const [err, setErr] = useState(null)
  const [busy, setBusy] = useState(false)
  const [newCustomer, setNewCustomer] = useState(false)
  const toast = useToast()

  useEffect(() => {
    (async () => {
      try {
        const [cs, vs] = await Promise.all([loadCustomers(), loadVariants({ includeInactive: !!orderId })])
        setCustomers(cs); setVariants(vs)
        if (orderId) {
          const o = await q(supabase.from('orders').select('*, order_items(*)').eq('id', orderId).single())
          const { order_items, ...rest } = o
          setF({ ...rest, delivery_date: rest.delivery_date || '', delivery_address: rest.delivery_address || '', notes: rest.notes || '' })
          setLines(order_items.sort((a, b) => a.id - b.id).map((i) => ({ ...i, key: i.id })))
        } else {
          setF({ ...blank(), customer_id: presetCustomer || '' })
          setLines([{ key: 1, variant_id: '', qty: 1, unit_price: '' }])
        }
      } catch (e) { setErr(e.message) }
    })()
  }, [orderId, presetCustomer])

  if (!f) return <Modal title="Pedido" onClose={onClose}>{err ? <ErrorBox msg={err} /> : <Loading />}</Modal>

  const set = (k) => (e) => setF({ ...f, [k]: e?.target ? e.target.value : e })
  const cust = customers.find((c) => String(c.id) === String(f.customer_id))
  const good = validLines(lines)
  const subtotal = good.reduce((s, l) => s + Number(l.qty) * Number(l.unit_price || 0), 0)
  const total = subtotal - Number(f.discount || 0) + Number(f.delivery_fee || 0)

  const save = async () => {
    if (!f.customer_id) { setErr('Elige un cliente.'); return }
    if (!good.length) { setErr('Agrega al menos un producto con cantidad.'); return }
    setBusy(true); setErr(null)
    const row = {
      customer_id: Number(f.customer_id), order_date: f.order_date, delivery_date: f.delivery_date || null,
      delivery_address: f.delivery_address.trim() || null, channel: f.channel, status: f.status,
      payment_method: f.payment_method, payment_status: f.payment_status,
      discount: Number(f.discount) || 0, delivery_fee: Number(f.delivery_fee) || 0, notes: f.notes.trim() || null,
    }
    const toRow = (l) => ({ variant_id: Number(l.variant_id), qty: Number(l.qty), unit_price: l.unit_price === '' ? null : Number(l.unit_price) })
    try {
      let id = orderId
      if (id) await q(supabase.from('orders').update(row).eq('id', id))
      else id = (await q(supabase.from('orders').insert(row).select('id').single())).id
      await syncLines('order_items', 'order_id', id, good, toRow)
      toast(orderId ? `Pedido #${id} actualizado` : `Pedido #${id} registrado`)
      onSaved()
    } catch (e) { setErr(e.message); setBusy(false) }
  }
  const remove = async () => {
    try { await q(supabase.from('orders').delete().eq('id', orderId)); toast(`Pedido #${orderId} eliminado`); onSaved() }
    catch (e) { setErr(e.message) }
  }

  return (
    <>
      <Modal wide title={orderId ? `Pedido #${orderId}` : 'Nuevo pedido'} onClose={onClose}
        footer={<>
          <div>{orderId && <DeleteButton onConfirm={remove} label="Eliminar pedido" />}</div>
          <div className="actions"><button className="btn" onClick={onClose}>Cancelar</button><button className="btn primary" onClick={save} disabled={busy}>{orderId ? 'Guardar cambios' : 'Registrar pedido'}</button></div>
        </>}>
        <div className="form-grid">
          <Field label="Cliente" className="full">
            <div className="inline">
              <div style={{ flex: 1 }}>
                <Combo value={f.customer_id} onChange={set('customer_id')} placeholder="Buscar por nombre o teléfono…"
                  options={customers.map((c) => ({ value: c.id, label: c.name, sub: [phoneFmt(c.phone), c.zone].filter((x) => x && x !== '—').join(', ') }))} />
              </div>
              <button type="button" className="btn" onClick={() => setNewCustomer(true)}>Nuevo cliente</button>
            </div>
          </Field>
          {cust && <div className="full muted" style={{ marginTop: -6, fontSize: 13.5 }}>{[cust.address, cust.zone].filter(Boolean).join(', ') || 'Sin dirección registrada'}</div>}
        </div>

        <LinesEditor lines={lines} setLines={setLines} variants={variants} />

        <div className="form-grid">
          <Field label="Fecha del pedido"><input type="date" value={f.order_date} onChange={set('order_date')} /></Field>
          <Field label="Fecha de entrega" hint="Vacío = el mismo día del pedido"><input type="date" value={f.delivery_date} onChange={set('delivery_date')} /></Field>
          <Field label="Dirección de entrega" className="full" hint="Déjala vacía para usar la dirección del cliente"><input value={f.delivery_address} onChange={set('delivery_address')} placeholder={cust?.address || ''} /></Field>
          <Field label="Estado"><Select value={f.status} onChange={set('status')} options={options(L.orderStatus)} /></Field>
          <Field label="Canal"><Select value={f.channel} onChange={set('channel')} options={options(L.channel)} /></Field>
          <Field label="Forma de pago"><Select value={f.payment_method} onChange={set('payment_method')} options={options(L.payMethod)} /></Field>
          <Field label="Pago"><Select value={f.payment_status} onChange={set('payment_status')} options={options(L.payStatus)} /></Field>
          <Field label="Descuento ($)"><input type="number" min="0" step="any" inputMode="decimal" value={f.discount} onChange={set('discount')} /></Field>
          <Field label="Cargo por envío ($)"><input type="number" min="0" step="any" inputMode="decimal" value={f.delivery_fee} onChange={set('delivery_fee')} /></Field>
          <Field label="Notas" className="full"><textarea value={f.notes} onChange={set('notes')} /></Field>
        </div>

        <div className="totals">
          <span>Subtotal</span><span className="right">{money(subtotal)}</span>
          {Number(f.discount) > 0 && <><span>Descuento</span><span className="right">−{money(f.discount)}</span></>}
          {Number(f.delivery_fee) > 0 && <><span>Envío</span><span className="right">{money(f.delivery_fee)}</span></>}
          <span className="grand">Total</span><span className="grand right">{money(total)}</span>
        </div>
        <ErrorBox msg={err} />
      </Modal>
      {newCustomer && (
        <CustomerForm onClose={() => setNewCustomer(false)} onSaved={(c) => {
          setNewCustomer(false)
          if (c) { setCustomers([...customers, c].sort((a, b) => a.name.localeCompare(b.name, 'es'))); setF((x) => ({ ...x, customer_id: c.id })) }
        }} />
      )}
    </>
  )
}
