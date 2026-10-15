import { useEffect, useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { useLoad } from '../lib/hooks'
import { loadCustomers, loadVariants } from '../lib/data'
import { L, date, money, options, parseDate, phoneFmt, relDay, today } from '../lib/format'
import { Badge, Combo, DeleteButton, Empty, ErrorBox, Field, Icon, Loading, Modal, Seg, Select, statusClass, useToast } from '../components/ui'
import LinesEditor, { validLines } from '../components/LinesEditor'

export default function Subscriptions() {
  const [view, setView] = useState('active')
  const [editing, setEditing] = useState(null)
  const toast = useToast()
  const { data, error, loading, reload } = useLoad(() => q(supabase.from('v_subscriptions').select('*').order('next_delivery_date')))
  const rows = (data || []).filter((s) => view === 'all' || s.status === view)
  const active = (data || []).filter((s) => s.status === 'active')
  const due = active.filter((s) => parseDate(s.next_delivery_date) <= parseDate(today()))
  const mrr = active.reduce((s, x) => s + Number(x.monthly_value), 0)

  const generate = async () => {
    try {
      const n = await q(supabase.rpc('create_due_subscription_orders'))
      toast(n ? `${n} pedido${n > 1 ? 's' : ''} creado${n > 1 ? 's' : ''}; ya aparecen en Entregas` : 'No había suscripciones pendientes de hoy')
      reload()
    } catch (e) { toast(e.message, true) }
  }

  return (
    <>
      <div className="page-head">
        <div><h1>Suscripciones</h1><p>{active.length} activas, {money(mrr)} al mes en ventas recurrentes.</p></div>
        <div className="actions">
          <button className="btn" onClick={generate} disabled={!due.length}>{due.length ? `Crear ${due.length} pedido${due.length > 1 ? 's' : ''} de hoy` : 'Nada que crear hoy'}</button>
          <button className="btn primary" onClick={() => setEditing({})}><Icon name="plus" />Nueva suscripción</button>
        </div>
      </div>
      <div className="toolbar"><Seg value={view} onChange={setView} options={[{ value: 'active', label: 'Activas' }, { value: 'paused', label: 'Pausadas' }, { value: 'cancelled', label: 'Canceladas' }, { value: 'all', label: 'Todas' }]} /></div>
      <ErrorBox msg={error} />
      <div className="panel">
        {loading ? <Loading /> : !rows.length ? <Empty text="Sin suscripciones en esta lista." action={<button className="btn primary" onClick={() => setEditing({})}>Crear suscripción</button>} /> : (
          <div className="table-wrap">
            <table>
              <thead><tr><th>Cliente</th><th>Productos</th><th>Frecuencia</th><th>Siguiente entrega</th><th className="num">Por entrega</th><th className="num hide-sm">Al mes</th><th>Estado</th></tr></thead>
              <tbody>{rows.map((s) => (
                <tr key={s.id} className="click" onClick={() => setEditing(s)} tabIndex={0} onKeyDown={(e) => e.key === 'Enter' && setEditing(s)}>
                  <td><b>{s.customer_name}</b><div className="sub">{phoneFmt(s.customer_phone)}</div></td>
                  <td>{s.items_summary || <span className="muted">Sin productos</span>}</td>
                  <td>Cada {s.frequency_days} días<div className="sub">{L.payMethod[s.payment_method]}</div></td>
                  <td>{s.status === 'active' ? relDay(s.next_delivery_date) : '—'}</td>
                  <td className="num">{money(s.value_per_delivery)}</td>
                  <td className="num hide-sm">{money(s.monthly_value)}</td>
                  <td><Badge cls={statusClass(s.status)}>{L.subStatus[s.status]}</Badge></td>
                </tr>
              ))}</tbody>
            </table>
          </div>
        )}
      </div>
      <p className="muted" style={{ marginTop: 12, fontSize: 13.5 }}>Los pedidos de suscripción se crean al presionar el botón de arriba. Más adelante se crearán solos cada mañana.</p>
      {editing && <SubForm sub={editing.id ? editing : null} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); reload() }} />}
    </>
  )
}

function SubForm({ sub, onClose, onSaved }) {
  const [f, setF] = useState({ customer_id: sub?.customer_id ?? '', frequency_days: sub?.frequency_days ?? 30, next_delivery_date: sub?.next_delivery_date ?? today(), payment_method: sub?.payment_method ?? 'cash', status: sub?.status ?? 'active', delivery_address: sub?.delivery_address ?? '', notes: sub?.notes ?? '' })
  const [lines, setLines] = useState([])
  const [customers, setCustomers] = useState([])
  const [variants, setVariants] = useState([])
  const [err, setErr] = useState(null)
  const [busy, setBusy] = useState(false)
  const toast = useToast()
  useEffect(() => {
    Promise.all([loadCustomers(), loadVariants()]).then(([c, v]) => { setCustomers(c); setVariants(v) })
    if (sub) q(supabase.from('subscription_items').select('*').eq('subscription_id', sub.id)).then((r) => setLines(r.map((i) => ({ ...i, id: i.variant_id, key: i.variant_id }))))
    else setLines([{ key: 1, variant_id: '', qty: 1 }])
  }, [sub])
  const set = (k) => (e) => setF({ ...f, [k]: e?.target ? e.target.value : e })

  const save = async () => {
    const good = validLines(lines)
    if (!f.customer_id) { setErr('Elige un cliente.'); return }
    if (!good.length) { setErr('Agrega al menos un producto.'); return }
    if (new Set(good.map((l) => String(l.variant_id))).size !== good.length) { setErr('Hay un producto repetido; junta las cantidades en un solo renglón.'); return }
    setBusy(true); setErr(null)
    const row = { customer_id: Number(f.customer_id), frequency_days: Number(f.frequency_days), next_delivery_date: f.next_delivery_date, payment_method: f.payment_method, status: f.status, delivery_address: f.delivery_address.trim() || null, notes: f.notes.trim() || null, cancelled_on: f.status === 'cancelled' ? (sub?.cancelled_on || today()) : null }
    try {
      let id = sub?.id
      if (id) await q(supabase.from('subscriptions').update(row).eq('id', id))
      else id = (await q(supabase.from('subscriptions').insert(row).select('id').single())).id
      // subscription_items is keyed by (subscription, product size): replace the set.
      await q(supabase.from('subscription_items').delete().eq('subscription_id', id))
      await q(supabase.from('subscription_items').insert(good.map((l) => ({ subscription_id: id, variant_id: Number(l.variant_id), qty: Number(l.qty) }))))
      toast(sub ? 'Suscripción actualizada' : 'Suscripción creada')
      onSaved()
    } catch (e) { setErr(e.message); setBusy(false) }
  }
  const remove = async () => {
    try { await q(supabase.from('subscriptions').delete().eq('id', sub.id)); toast('Suscripción eliminada'); onSaved() } catch (e) { setErr(e.message) }
  }
  const perDelivery = validLines(lines).reduce((s, l) => s + Number(l.qty) * Number(variants.find((v) => String(v.id) === String(l.variant_id))?.price || 0), 0)

  return (
    <Modal wide title={sub ? `Suscripción de ${sub.customer_name}` : 'Nueva suscripción'} onClose={onClose}
      footer={<><div>{sub && <DeleteButton onConfirm={remove} />}</div><div className="actions"><button className="btn" onClick={onClose}>Cancelar</button><button className="btn primary" onClick={save} disabled={busy}>Guardar suscripción</button></div></>}>
      <Field label="Cliente"><Combo value={f.customer_id} onChange={set('customer_id')} options={customers.map((c) => ({ value: c.id, label: c.name, sub: phoneFmt(c.phone) }))} placeholder="Buscar cliente…" /></Field>
      <LinesEditor lines={lines} setLines={setLines} variants={variants} showPrice={false} />
      <p className="muted" style={{ fontSize: 13.5 }}>Cada pedido usa el precio vigente del catálogo. Hoy serían {money(perDelivery)} por entrega.</p>
      <div className="form-grid">
        <Field label="Cada cuántos días"><input type="number" min="7" max="180" value={f.frequency_days} onChange={set('frequency_days')} /></Field>
        <Field label="Siguiente entrega"><input type="date" value={f.next_delivery_date} onChange={set('next_delivery_date')} /></Field>
        <Field label="Forma de pago"><Select value={f.payment_method} onChange={set('payment_method')} options={options(L.payMethod)} /></Field>
        <Field label="Estado"><Select value={f.status} onChange={set('status')} options={options(L.subStatus)} /></Field>
        <Field label="Dirección de entrega" className="full" hint="Vacía = dirección del cliente"><input value={f.delivery_address} onChange={set('delivery_address')} /></Field>
        <Field label="Notas" className="full"><textarea value={f.notes} onChange={set('notes')} /></Field>
      </div>
      {sub?.started_on && <p className="muted" style={{ fontSize: 13.5 }}>Activa desde {date(sub.started_on)}.</p>}
      <ErrorBox msg={err} />
    </Modal>
  )
}
