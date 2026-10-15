import { useEffect, useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { useLoad } from '../lib/hooks'
import { describeSend, sendReport } from '../lib/data'
import { L, digits, longDate, mapsLink, money, parseDate, phoneFmt, qty, routeLinks, shortDate, today, waLink } from '../lib/format'
import { Empty, ErrorBox, Field, Icon, Loading, Modal, OrderStatus, useToast } from '../components/ui'
import OrderForm from '../components/OrderForm'

export default function Deliveries() {
  const [editing, setEditing] = useState(null)
  const [routeDate, setRouteDate] = useState(null)
  const [moving, setMoving] = useState(false)
  const toast = useToast()

  const list = useLoad(async () => {
    const [rows, next] = await Promise.all([
      q(supabase.from('v_pending_deliveries').select('*')),
      q(supabase.rpc('next_delivery_on', {})),
    ])
    return { rows, next }
  })
  useEffect(() => { if (list.data && !routeDate) setRouteDate(list.data.next) }, [list.data, routeDate])
  const route = useLoad(() => (routeDate ? q(supabase.rpc('route_sheet', { p_date: routeDate })) : Promise.resolve(null)), [routeDate])
  const reload = () => { list.reload(); route.reload() }

  const update = async (id, patch, msg) => {
    try { await q(supabase.from('orders').update(patch).eq('id', id)); toast(msg); reload() }
    catch (e) { toast(e.message, true) }
  }
  const email = async () => {
    try { toast(describeSend(await sendReport('route', { date: routeDate }))) } catch (e) { toast(e.message, true) }
  }

  if (list.loading && !list.data) return <Loading />
  const rows = list.data?.rows || []
  const t = today()
  // Delivery dates to choose from: the next delivery day plus any date with pending orders.
  const dates = [...new Set([list.data?.next, ...rows.map((r) => r.due_date).filter((d) => d >= t)])].filter(Boolean).sort()
  const groups = {}
  for (const d of rows) (groups[d.due_date < t ? 'late' : d.due_date] ||= []).push(d)
  const groupKeys = Object.keys(groups).sort((a, b) => (a === 'late' ? -1 : b === 'late' ? 1 : a.localeCompare(b)))
  const r = route.data

  return (
    <>
      <div className="page-head">
        <div><h1>Entregas</h1><p>{rows.length ? `${rows.length} pedidos por entregar.` : 'Pedidos pendientes, confirmados y en ruta.'}</p></div>
      </div>
      <ErrorBox msg={list.error || route.error} />

      {/* ---------- Route prep for one delivery date ---------- */}
      <section className="panel" style={{ marginBottom: 18 }}>
        <div className="panel-head" style={{ flexWrap: 'wrap' }}>
          <div className="inline" style={{ flexWrap: 'wrap' }}>
            <h2>Ruta del</h2>
            <select value={routeDate || ''} onChange={(e) => setRouteDate(e.target.value)} aria-label="Fecha de la ruta" style={{ width: 'auto' }}>
              {dates.map((d) => <option key={d} value={d}>{longDate(d)}</option>)}
            </select>
          </div>
          <div className="actions">
            <button className="btn sm" onClick={() => setMoving(true)} disabled={!r?.n_stops}><Icon name="calendar" />Mover ruta a otro día</button>
            <button className="btn sm" onClick={email} disabled={!r?.n_stops}><Icon name="mail" />Enviar por correo</button>
          </div>
        </div>
        {route.loading && !r ? <Loading /> : !r?.n_stops ? <Empty text="No hay entregas para esta fecha." /> : (
          <div className="panel-body stack" style={{ gap: 14 }}>
            <div className="kpis panel" style={{ border: '1px solid var(--line)' }}>
              <div><div className="v">{r.n_stops}</div><div className="l">Paradas{r.stops.some((s) => s.late) && `, ${r.stops.filter((s) => s.late).length} atrasadas`}</div></div>
              <div><div className="v">{money(r.total)}</div><div className="l">Total de la ruta</div></div>
              <div><div className="v">{money(r.to_collect)}</div><div className="l">Por cobrar (efectivo o SPEI)</div></div>
              <div><div className="v">{r.packing.reduce((s, p) => s + Number(p.qty), 0)}</div><div className="l">Piezas a cargar</div></div>
            </div>
            {r.shortfalls.length > 0 && (
              <div className="note"><b>Falta inventario:</b> {r.shortfalls.map((s) => `${s.product} (${qty(s.missing)} ${s.base_unit})`).join(', ')}. Compra antes del reparto.</div>
            )}
            <div className="grid grid-2">
              <div>
                <h3 style={{ marginBottom: 6 }}>Qué cargar</h3>
                <table><tbody>{r.packing.map((p, i) => (
                  <tr key={i}><td>{p.product} · {p.label}</td><td className="num"><b>{qty(p.qty)}</b></td></tr>
                ))}</tbody></table>
              </div>
              <div>
                <h3 style={{ marginBottom: 6 }}>Orden por zona</h3>
                <ol style={{ margin: 0, paddingLeft: 20 }}>{r.stops.map((s) => (
                  <li key={s.id} style={{ padding: '3px 0' }}>{s.customer} <span className="muted">{s.zone || 'sin zona'}</span></li>
                ))}</ol>
                <div className="actions" style={{ marginTop: 10 }}>
                  {routeLinks(r.stops).map((l, i, all) => (
                    <a key={l} className="btn sm primary" href={l} target="_blank" rel="noreferrer"><Icon name="map" />{all.length > 1 ? `Ruta en Maps, tramo ${i + 1}` : 'Abrir ruta en Maps'}</a>
                  ))}
                </div>
              </div>
            </div>
          </div>
        )}
      </section>

      {/* ---------- Delivery cards ---------- */}
      {!rows.length ? <div className="panel"><Empty text="No hay entregas pendientes." /></div> : (
        <div className="deliv">
          {groupKeys.map((g) => (
            <section key={g} className="deliv">
              <div className="day-head">{g === 'late' ? 'Atrasadas' : longDate(g)}</div>
              {groups[g].map((d) => <Card key={d.id} d={d} onUpdate={update} onEdit={() => setEditing(d.id)} />)}
            </section>
          ))}
        </div>
      )}

      {editing && <OrderForm orderId={editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); reload() }} />}
      {moving && <MoveRoute from={routeDate} onClose={() => setMoving(false)} onMoved={(to) => { setMoving(false); setRouteDate(to); reload() }} />}
    </>
  )
}

function Card({ d, onUpdate, onEdit }) {
  const [changing, setChanging] = useState(false)
  const wa = waLink(d.customer_phone, `Hola, soy de Cloro. Vamos en camino con tu pedido #${d.id}.`)
  const map = mapsLink(d.delivery_address, d.zone)
  const unpaid = d.payment_status === 'pending'
  return (
    <article className={`dcard${d.overdue ? ' overdue' : ''}`}>
      <div className="top">
        <div>
          <div className="who">{d.customer_name}</div>
          <div className="addr">{[d.delivery_address, d.zone].filter(Boolean).join(', ') || 'Sin dirección: edita el pedido o el cliente'}</div>
          {d.address_notes && <div className="muted" style={{ fontSize: 13.5 }}>{d.address_notes}</div>}
        </div>
        <div className="right"><OrderStatus s={d.status} /></div>
      </div>
      <div className="items">{d.items_summary || 'Sin productos'}</div>
      {d.notes && <div className="muted" style={{ fontSize: 13.5 }}>{d.notes}</div>}
      <div className="top" style={{ alignItems: 'center' }}>
        <div><span className="money">{money(d.total)}</span>{' '}<span className="muted">{L.payMethod[d.payment_method]}, {unpaid ? <b style={{ color: '#6B5200' }}>por cobrar</b> : 'pagado'}</span></div>
        <div className="actions">
          {changing
            ? <input type="date" defaultValue={d.due_date} autoFocus aria-label="Nueva fecha de entrega" style={{ width: 'auto', minHeight: 30 }}
                onChange={(e) => e.target.value && onUpdate(d.id, { delivery_date: e.target.value }, `Pedido #${d.id} movido al ${shortDate(e.target.value)}`)}
                onBlur={() => setChanging(false)} />
            : <button className="btn sm ghost" onClick={() => setChanging(true)}><Icon name="calendar" />Cambiar fecha</button>}
          <button className="btn sm ghost" onClick={onEdit}>Editar #{d.id}</button>
        </div>
      </div>
      <div className="btns">
        {digits(d.customer_phone) && <a className="btn" href={`tel:${digits(d.customer_phone)}`} aria-label={`Llamar a ${phoneFmt(d.customer_phone)}`}><Icon name="phone" />Llamar</a>}
        {wa && <a className="btn" href={wa} target="_blank" rel="noreferrer"><Icon name="chat" />WhatsApp</a>}
        {map && <a className="btn" href={map} target="_blank" rel="noreferrer"><Icon name="map" />Mapa</a>}
      </div>
      <div className="btns">
        {d.status !== 'out_for_delivery' && <button className="btn" onClick={() => onUpdate(d.id, { status: 'out_for_delivery' }, 'Marcado en ruta')}><Icon name="truck" />En ruta</button>}
        {unpaid
          ? <>
              <button className="btn primary" onClick={() => onUpdate(d.id, { status: 'delivered', payment_status: 'paid' }, `Pedido #${d.id} entregado y cobrado`)}><Icon name="check" />Entregado y cobrado</button>
              <button className="btn" onClick={() => onUpdate(d.id, { status: 'delivered' }, `Pedido #${d.id} entregado, queda por cobrar`)}>Entregado sin cobrar</button>
            </>
          : <button className="btn primary" onClick={() => onUpdate(d.id, { status: 'delivered' }, `Pedido #${d.id} entregado`)}><Icon name="check" />Entregado</button>}
      </div>
    </article>
  )
}

function MoveRoute({ from, onClose, onMoved }) {
  const f = parseDate(from)
  const plus = (n) => { const d = new Date(f); d.setDate(d.getDate() + n); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` }
  const [to, setTo] = useState(plus(1))
  const [err, setErr] = useState(null)
  const toast = useToast()
  const go = async () => {
    try {
      const n = await q(supabase.rpc('move_deliveries', { p_from: from, p_to: to }))
      toast(`${n} pedido${n === 1 ? '' : 's'} movido${n === 1 ? '' : 's'} al ${longDate(to)}`)
      onMoved(to)
    } catch (e) { setErr(e.message) }
  }
  return (
    <Modal title="Mover la ruta a otro día" onClose={onClose}
      footer={<><span /><div className="actions"><button className="btn" onClick={onClose}>Cancelar</button><button className="btn primary" onClick={go}>Mover pedidos</button></div></>}>
      <p>Todos los pedidos abiertos del <b>{longDate(from)}</b> pasan a la nueva fecha. Los atrasados de días anteriores no se mueven.</p>
      <div className="actions">
        <button className="btn sm" onClick={() => setTo(plus(-1))}>Un día antes</button>
        <button className="btn sm" onClick={() => setTo(plus(1))}>Un día después</button>
      </div>
      <Field label="Nueva fecha"><input type="date" value={to} onChange={(e) => setTo(e.target.value)} /></Field>
      <ErrorBox msg={err} />
    </Modal>
  )
}
