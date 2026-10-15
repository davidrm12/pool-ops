import { useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { useLoad } from '../lib/hooks'
import { L, digits, mapsLink, money, parseDate, phoneFmt, relDay, today, waLink } from '../lib/format'
import { Empty, ErrorBox, Icon, Loading, OrderStatus, useToast } from '../components/ui'
import OrderForm from '../components/OrderForm'

function groupOf(d) {
  if (d.overdue) return 'Atrasadas'
  const diff = Math.round((parseDate(d.due_date) - parseDate(today())) / 86400000)
  if (diff === 0) return 'Hoy'
  if (diff === 1) return 'Mañana'
  return 'Próximos días'
}

export default function Deliveries() {
  const [editing, setEditing] = useState(null)
  const toast = useToast()
  const { data, error, loading, reload } = useLoad(() => q(supabase.from('v_pending_deliveries').select('*')))

  const update = async (d, patch, msg) => {
    try { await q(supabase.from('orders').update(patch).eq('id', d.id)); toast(msg); reload() }
    catch (e) { toast(e.message, true) }
  }

  if (loading) return <Loading />
  const groups = {}
  for (const d of data || []) (groups[groupOf(d)] ||= []).push(d)
  const toCollect = (data || []).filter((d) => d.payment_status === 'pending' && d.payment_method !== 'card').reduce((s, d) => s + Number(d.total), 0)

  return (
    <>
      <div className="page-head">
        <div>
          <h1>Entregas</h1>
          <p>{data?.length ? `${data.length} por entregar; ${money(toCollect)} por cobrar en efectivo o SPEI.` : 'Pedidos pendientes, confirmados y en ruta.'}</p>
        </div>
      </div>
      <ErrorBox msg={error} />
      {!data?.length ? (
        <div className="panel"><Empty text="No hay entregas pendientes." /></div>
      ) : (
        <div className="deliv">
          {['Atrasadas', 'Hoy', 'Mañana', 'Próximos días'].filter((g) => groups[g]).map((g) => (
            <section key={g} className="deliv">
              <div className="day-head">{g}</div>
              {groups[g].map((d) => {
                const wa = waLink(d.customer_phone, `Hola, soy de Cloro. Vamos en camino con tu pedido #${d.id}.`)
                const map = mapsLink(d.delivery_address, d.zone)
                const unpaid = d.payment_status === 'pending'
                return (
                  <article key={d.id} className={`dcard${d.overdue ? ' overdue' : ''}`}>
                    <div className="top">
                      <div>
                        <div className="who">{d.customer_name}</div>
                        <div className="addr">{[d.delivery_address, d.zone].filter(Boolean).join(', ') || 'Sin dirección: edita el pedido o el cliente'}</div>
                        {d.address_notes && <div className="muted" style={{ fontSize: 13.5 }}>{d.address_notes}</div>}
                      </div>
                      <div className="right">
                        <div style={{ fontWeight: 600 }}>{relDay(d.due_date)}</div>
                        <OrderStatus s={d.status} />
                      </div>
                    </div>
                    <div className="items">{d.items_summary || 'Sin productos'}</div>
                    {d.notes && <div className="muted" style={{ fontSize: 13.5 }}>{d.notes}</div>}
                    <div className="top" style={{ alignItems: 'center' }}>
                      <div>
                        <span className="money">{money(d.total)}</span>{' '}
                        <span className="muted">{L.payMethod[d.payment_method]}, {unpaid ? <b style={{ color: '#6B5200' }}>por cobrar</b> : 'pagado'}</span>
                      </div>
                      <button className="btn sm ghost" onClick={() => setEditing(d.id)}>Editar #{d.id}</button>
                    </div>
                    <div className="btns">
                      {digits(d.customer_phone) && <a className="btn" href={`tel:${digits(d.customer_phone)}`} aria-label={`Llamar a ${phoneFmt(d.customer_phone)}`}><Icon name="phone" />Llamar</a>}
                      {wa && <a className="btn" href={wa} target="_blank" rel="noreferrer"><Icon name="chat" />WhatsApp</a>}
                      {map && <a className="btn" href={map} target="_blank" rel="noreferrer"><Icon name="map" />Mapa</a>}
                    </div>
                    <div className="btns">
                      {d.status !== 'out_for_delivery' && <button className="btn" onClick={() => update(d, { status: 'out_for_delivery' }, 'Marcado en ruta')}><Icon name="truck" />En ruta</button>}
                      {unpaid
                        ? <>
                            <button className="btn primary" onClick={() => update(d, { status: 'delivered', payment_status: 'paid' }, `Pedido #${d.id} entregado y cobrado`)}><Icon name="check" />Entregado y cobrado</button>
                            <button className="btn" onClick={() => update(d, { status: 'delivered' }, `Pedido #${d.id} entregado, queda por cobrar`)}>Entregado sin cobrar</button>
                          </>
                        : <button className="btn primary" onClick={() => update(d, { status: 'delivered' }, `Pedido #${d.id} entregado`)}><Icon name="check" />Entregado</button>}
                    </div>
                  </article>
                )
              })}
            </section>
          ))}
        </div>
      )}
      {editing && <OrderForm orderId={editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); reload() }} />}
    </>
  )
}
