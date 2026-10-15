import { useEffect, useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { useLoad } from '../lib/hooks'
import { getStoreUrl, loadBundles, loadCustomers, loadVariants } from '../lib/data'
import { L, date, money, options, parseDate, phoneFmt, relDay, today } from '../lib/format'
import { Badge, Combo, DeleteButton, Empty, ErrorBox, Field, Icon, Loading, Modal, Seg, Select, statusClass, useToast } from '../components/ui'
import LinesEditor, { validLines } from '../components/LinesEditor'

export default function Subscriptions() {
  const [view, setView] = useState('active')
  const [editing, setEditing] = useState(null)
  const toast = useToast()
  const { data: all, error, loading, reload } = useLoad(async () => {
    const [subs, st] = await Promise.all([
      q(supabase.from('v_subscriptions').select('*').order('next_delivery_date')),
      q(supabase.from('settings').select('lead_days').single()),
    ])
    return { subs, lead: st.lead_days }
  })
  const data = all?.subs
  const rows = (data || []).filter((s) => view === 'all' || s.status === view)
  const active = (data || []).filter((s) => s.status === 'active')
  // Same rule as the daily job: due when the delivery is within the lead time.
  const horizon = parseDate(today()); horizon.setDate(horizon.getDate() + (all?.lead ?? 0))
  const due = active.filter((s) => parseDate(s.next_delivery_date) <= horizon)
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
          <button className="btn" onClick={generate} disabled={!due.length}>{due.length ? `Crear ${due.length} pedido${due.length > 1 ? 's' : ''} ahora` : 'Nada que crear ahora'}</button>
          <button className="btn primary" onClick={() => setEditing({})}><Icon name="plus" />Nueva suscripción</button>
        </div>
      </div>
      <div className="toolbar"><Seg value={view} onChange={setView} options={[{ value: 'active', label: 'Activas' }, { value: 'paused', label: 'Pausadas' }, { value: 'cancelled', label: 'Canceladas' }, { value: 'all', label: 'Todas' }]} /></div>
      <ErrorBox msg={error} />
      <div className="panel">
        {loading ? <Loading /> : !rows.length ? <Empty text="Sin suscripciones en esta lista." action={<button className="btn primary" onClick={() => setEditing({})}>Crear suscripción</button>} /> : (
          <div className="table-wrap">
            <table>
              <thead><tr><th>Cliente</th><th>Productos</th><th>Frecuencia</th><th>Siguiente entrega</th><th className="num">Por entrega</th><th className="num hide-sm">Al mes</th><th>Estado</th><th /></tr></thead>
              <tbody>{rows.map((s) => (
                <tr key={s.id} className="click" onClick={() => setEditing(s)} tabIndex={0} onKeyDown={(e) => e.key === 'Enter' && setEditing(s)}>
                  <td><b>{s.customer_name}</b><div className="sub">{phoneFmt(s.customer_phone)}</div></td>
                  <td>{s.items_summary || <span className="muted">Sin productos</span>}</td>
                  <td>{s.frequency_weeks === 1 ? 'Cada semana' : `Cada ${s.frequency_weeks} semanas`}<div className="sub">{L.payMethod[s.payment_method]}</div></td>
                  <td>{s.status === 'active' ? relDay(s.next_delivery_date) : '—'}</td>
                  <td className="num">{money(s.value_per_delivery)}</td>
                  <td className="num hide-sm">{money(s.monthly_value)}</td>
                  <td><Badge cls={statusClass(s.status)}>{L.subStatus[s.status]}</Badge>{s.source === 'web' && <div className="sub">Tienda</div>}</td>
                  <td onClick={(e) => e.stopPropagation()} onKeyDown={(e) => e.stopPropagation()}>{s.status !== 'cancelled' && <CancelSub sub={s} onDone={reload} small />}</td>
                </tr>
              ))}</tbody>
            </table>
          </div>
        )}
      </div>
      <p className="muted" style={{ marginTop: 12, fontSize: 13.5 }}>Los pedidos de suscripción se crean solos cada mañana, unos días antes de la entrega (ver Ajustes). El botón de arriba los crea en el momento si hace falta.</p>
      {editing && <SubForm sub={editing.id ? editing : null} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); reload() }} />}
    </>
  )
}

// Cancelling keeps the history (unlike deleting) and stops charges: the upcoming order is
// cancelled too if it hasn't been charged yet.
function CancelSub({ sub, onDone, small }) {
  const toast = useToast()
  const [ask, setAsk] = useState(false)
  const [busy, setBusy] = useState(false)
  const go = async () => {
    setBusy(true)
    try {
      await q(supabase.from('subscriptions').update({ status: 'cancelled', cancelled_on: today() }).eq('id', sub.id))
      toast('Suscripción cancelada; su próximo pedido sin cobrar también se canceló'); onDone()
    } catch (e) { toast(e.message, true) }
    setBusy(false); setAsk(false)
  }
  if (!ask) return <button type="button" className={`btn ghost danger${small ? ' sm' : ''}`} onClick={() => setAsk(true)}>Cancelar suscripción</button>
  return (
    <span className="inline" style={{ flexWrap: 'wrap' }}>
      <span style={{ fontSize: 13.5 }}>¿Cancelar la de {sub.customer_name}?</span>
      <button type="button" className="btn sm danger" onClick={go} disabled={busy}>Sí, cancelar</button>
      <button type="button" className="btn sm ghost" onClick={() => setAsk(false)}>No</button>
    </span>
  )
}

function SubForm({ sub, onClose, onSaved }) {
  const [f, setF] = useState({ customer_id: sub?.customer_id ?? '', frequency_weeks: sub?.frequency_weeks ?? 4, next_delivery_date: sub?.next_delivery_date ?? today(), payment_method: sub?.payment_method ?? 'cash', status: sub?.status ?? 'active', delivery_address: sub?.delivery_address ?? '', notes: sub?.notes ?? '' })
  const [lines, setLines] = useState([])
  const [customers, setCustomers] = useState([])
  const [variants, setVariants] = useState([])
  const [err, setErr] = useState(null)
  const [busy, setBusy] = useState(false)
  const [bundles, setBundles] = useState([])        // [{ bundle_id, qty }]
  const [allBundles, setAllBundles] = useState([])
  const [extra, setExtra] = useState(null)     // card, self-service link, source (not in the list view)
  const toast = useToast()
  useEffect(() => {
    Promise.all([loadCustomers(), loadVariants(), loadBundles()]).then(([c, v, b]) => { setCustomers(c); setVariants(v); setAllBundles(b) })
    if (sub) q(supabase.from('subscription_bundles').select('bundle_id, qty').eq('subscription_id', sub.id)).then(setBundles).catch(() => {})
    if (sub) Promise.all([q(supabase.from('subscriptions').select('source, card_brand, card_last4, stripe_payment_method_id, manage_token, delivery_postal_code, consent_at, last_charged_amount').eq('id', sub.id).single()), getStoreUrl()])
      .then(([x, store]) => setExtra({ ...x, link: store ? `${store}/#/suscripcion/${x.manage_token}` : '' })).catch(() => {})
    if (sub) q(supabase.from('subscription_items').select('*').eq('subscription_id', sub.id)).then((r) => setLines(r.map((i) => ({ ...i, id: i.variant_id, key: i.variant_id }))))
    else setLines([{ key: 1, variant_id: '', qty: 1 }])
  }, [sub])
  const set = (k) => (e) => setF({ ...f, [k]: e?.target ? e.target.value : e })

  const save = async () => {
    const good = validLines(lines)
    if (!f.customer_id) { setErr('Elige un cliente.'); return }
    const goodB = bundles.filter((b) => b.bundle_id && Number(b.qty) > 0)
    if (!good.length && !goodB.length) { setErr('Agrega al menos un producto o paquete.'); return }
    if (new Set(good.map((l) => String(l.variant_id))).size !== good.length) { setErr('Hay un producto repetido; junta las cantidades en un solo renglón.'); return }
    setBusy(true); setErr(null)
    const row = { customer_id: Number(f.customer_id), frequency_weeks: Number(f.frequency_weeks), next_delivery_date: f.next_delivery_date, payment_method: f.payment_method, status: f.status, delivery_address: f.delivery_address.trim() || null, notes: f.notes.trim() || null, cancelled_on: f.status === 'cancelled' ? (sub?.cancelled_on || today()) : null }
    try {
      let id = sub?.id
      if (id) await q(supabase.from('subscriptions').update(row).eq('id', id))
      else id = (await q(supabase.from('subscriptions').insert(row).select('id').single())).id
      // subscription_items is keyed by (subscription, product size): replace the set.
      await q(supabase.from('subscription_items').delete().eq('subscription_id', id))
      if (good.length) await q(supabase.from('subscription_items').insert(good.map((l) => ({ subscription_id: id, variant_id: Number(l.variant_id), qty: Number(l.qty) }))))
      await q(supabase.from('subscription_bundles').delete().eq('subscription_id', id))
      if (goodB.length) await q(supabase.from('subscription_bundles').insert(goodB.map((b) => ({ subscription_id: id, bundle_id: Number(b.bundle_id), qty: Math.round(Number(b.qty)) }))))
      toast(sub ? 'Suscripción actualizada' : 'Suscripción creada')
      onSaved()
    } catch (e) { setErr(e.message); setBusy(false) }
  }
  const remove = async () => {
    try { await q(supabase.from('subscriptions').delete().eq('id', sub.id)); toast('Suscripción eliminada'); onSaved() } catch (e) { setErr(e.message) }
  }
  const perDelivery = validLines(lines).reduce((s, l) => s + Number(l.qty) * Number(variants.find((v) => String(v.id) === String(l.variant_id))?.price || 0), 0)
    + bundles.reduce((s, b) => s + Number(b.qty || 0) * Number(allBundles.find((x) => x.id === Number(b.bundle_id))?.price || 0), 0)
  const bundleOpts = allBundles.filter((b) => b.active || bundles.some((x) => Number(x.bundle_id) === b.id)).map((b) => ({ value: b.id, label: `${b.name} · ${money(b.price)}` }))

  return (
    <Modal wide title={sub ? `Suscripción de ${sub.customer_name}` : 'Nueva suscripción'} onClose={onClose}
      footer={<><div className="actions">{sub && sub.status !== 'cancelled' && <CancelSub sub={sub} onDone={onSaved} />}{sub && <DeleteButton onConfirm={remove} />}</div><div className="actions"><button className="btn" onClick={onClose}>Cancelar</button><button className="btn primary" onClick={save} disabled={busy}>Guardar suscripción</button></div></>}>
      <Field label="Cliente"><Combo value={f.customer_id} onChange={set('customer_id')} options={customers.map((c) => ({ value: c.id, label: c.name, sub: phoneFmt(c.phone) }))} placeholder="Buscar cliente…" /></Field>
      <LinesEditor lines={lines} setLines={setLines} variants={variants} showPrice={false} />
      {(allBundles.length > 0 || bundles.length > 0) && (
        <div className="lines">
          <div className="line line-head"><div>Paquete</div><div>Cantidad</div><div /><div className="tot" /><div /></div>
          {bundles.map((b, i) => (
            <div className="line" key={i}>
              <Select value={b.bundle_id} onChange={(v) => setBundles(bundles.map((x, j) => (j === i ? { ...x, bundle_id: v } : x)))} placeholder="Elige un paquete…" options={bundleOpts} aria-label="Paquete" />
              <input type="number" min="1" step="1" value={b.qty} onChange={(e) => setBundles(bundles.map((x, j) => (j === i ? { ...x, qty: e.target.value } : x)))} aria-label="Cantidad de paquetes" />
              <div /><div className="tot" />
              <button type="button" className="btn ghost sm" onClick={() => setBundles(bundles.filter((_, j) => j !== i))} aria-label="Quitar paquete"><Icon name="x" /></button>
            </div>
          ))}
          <div className="line" style={{ display: 'block' }}><button type="button" className="btn sm" onClick={() => setBundles([...bundles, { bundle_id: '', qty: 1 }])}><Icon name="plus" />Agregar paquete</button></div>
        </div>
      )}
      <p className="muted" style={{ fontSize: 13.5 }}>Cada pedido usa el precio vigente del catálogo. Hoy serían {money(perDelivery)} por entrega.</p>
      <div className="form-grid">
        <Field label="Frecuencia"><Select value={String(f.frequency_weeks)} onChange={set('frequency_weeks')} options={[1, 2, 3, 4, 5, 6, 8, 10, 12].map((w) => ({ value: String(w), label: w === 1 ? 'Cada semana' : `Cada ${w} semanas` }))} /></Field>
        <Field label="Siguiente entrega" hint="Se ajusta al siguiente día de reparto"><input type="date" value={f.next_delivery_date} onChange={set('next_delivery_date')} /></Field>
        <Field label="Forma de pago"><Select value={f.payment_method} onChange={set('payment_method')} options={options(L.payMethod)} /></Field>
        <Field label="Estado"><Select value={f.status} onChange={set('status')} options={options(L.subStatus)} /></Field>
        <Field label="Dirección de entrega" className="full" hint="Vacía = dirección del cliente"><input value={f.delivery_address} onChange={set('delivery_address')} /></Field>
        <Field label="Notas" className="full"><textarea value={f.notes} onChange={set('notes')} /></Field>
      </div>
      {extra && (
        <div className="muted stack" style={{ fontSize: 13.5, gap: 4 }}>
          <div>
            {extra.source === 'web' ? 'Creada por el cliente en la tienda' : 'Creada en la administración'}
            {sub?.started_on && `, activa desde ${date(sub.started_on)}`}.
            {extra.delivery_postal_code && ` Se entrega en CP ${extra.delivery_postal_code}.`}
          </div>
          <div>
            {extra.card_last4 ? `Tarjeta guardada: ${(extra.card_brand || '').toUpperCase()} terminación ${extra.card_last4}. Se cobra sola cada entrega${extra.last_charged_amount ? ` (último cobro ${money(extra.last_charged_amount)})` : ''}.`
              : f.payment_method === 'card' ? 'Sin tarjeta guardada: el cliente debe agregarla desde su liga, o se cobra con liga de pago en cada pedido.' : null}
          </div>
          {extra.link && (
            <div className="inline">
              <span>Liga para que el cliente salte, pause, cancele o cambie su tarjeta:</span>
              <button type="button" className="btn sm" onClick={async () => { try { await navigator.clipboard.writeText(extra.link); toast('Liga copiada') } catch { toast(extra.link) } }}>Copiar liga</button>
            </div>
          )}
        </div>
      )}
      <ErrorBox msg={err} />
    </Modal>
  )
}
