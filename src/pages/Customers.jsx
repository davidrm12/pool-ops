import { useMemo, useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { useLoad } from '../lib/hooks'
import { L, date, mapsLink, money, phoneFmt, relDay, waLink } from '../lib/format'
import { Badge, Empty, ErrorBox, Icon, Loading, Modal, OrderStatus, PayStatus, Seg, statusClass } from '../components/ui'
import CustomerForm from '../components/CustomerForm'
import OrderForm from '../components/OrderForm'

const VIEWS = [
  { value: 'customer', label: 'Clientes' }, { value: 'prospect', label: 'Prospectos' },
  { value: 'inactive', label: 'Inactivos' }, { value: 'all', label: 'Todos' },
]
const SORTS = {
  name: (a, b) => a.name.localeCompare(b.name, 'es'),
  revenue: (a, b) => b.lifetime_revenue - a.lifetime_revenue,
  last: (a, b) => (b.last_order || '').localeCompare(a.last_order || ''),
  overdue: (a, b) => (b.days_overdue || 0) - (a.days_overdue || 0),
}

export default function Customers() {
  const [view, setView] = useState('customer')
  const [search, setSearch] = useState('')
  const [sort, setSort] = useState('name')
  const [detail, setDetail] = useState(null)
  const [editing, setEditing] = useState(null)
  const [newOrderFor, setNewOrderFor] = useState(null)
  const { data, error, loading, reload } = useLoad(() => q(supabase.from('v_customer_summary').select('*')))

  const rows = useMemo(() => {
    if (!data) return []
    const t = search.trim().toLowerCase()
    return data
      .filter((c) => view === 'all' || c.status === view)
      .filter((c) => !t || `${c.name} ${c.phone || ''} ${c.zone || ''} ${c.address || ''}`.toLowerCase().includes(t))
      .sort(SORTS[sort])
  }, [data, view, search, sort])

  return (
    <>
      <div className="page-head">
        <div><h1>Directorio</h1><p>Clientes, prospectos y su historial de compra.</p></div>
        <button className="btn primary" onClick={() => setEditing({})}><Icon name="plus" />Nuevo cliente</button>
      </div>
      <div className="toolbar">
        <Seg value={view} onChange={setView} options={VIEWS} />
        <input type="search" placeholder="Buscar nombre, teléfono o colonia" value={search} onChange={(e) => setSearch(e.target.value)} />
        <select value={sort} onChange={(e) => setSort(e.target.value)} aria-label="Ordenar">
          <option value="name">Orden: nombre</option><option value="revenue">Orden: más compras</option>
          <option value="last">Orden: compra más reciente</option><option value="overdue">Orden: más atrasados</option>
        </select>
      </div>
      <ErrorBox msg={error} />
      <div className="panel">
        {loading ? <Loading /> : rows.length === 0 ? (
          <Empty text={search ? 'Nadie coincide con la búsqueda.' : 'Aún no hay registros en esta lista.'} action={<button className="btn primary" onClick={() => setEditing({})}>Agregar cliente</button>} />
        ) : (
          <div className="table-wrap">
            <table>
              <thead><tr><th>Nombre</th><th>Teléfono</th><th className="num">Pedidos</th><th className="hide-sm">Última compra</th><th className="num hide-sm">Total comprado</th><th className="hide-sm">Siguiente pedido</th><th className="num">Por cobrar</th></tr></thead>
              <tbody>
                {rows.map((c) => (
                  <tr key={c.id} className="click" onClick={() => setDetail(c)} tabIndex={0} onKeyDown={(e) => e.key === 'Enter' && setDetail(c)}>
                    <td><b>{c.name}</b>{c.zone && <div className="sub">{c.zone}</div>}</td>
                    <td style={{ whiteSpace: 'nowrap' }}>{phoneFmt(c.phone)}</td>
                    <td className="num">{c.n_orders}</td>
                    <td className="hide-sm">{c.last_order ? relDay(c.last_order) : '—'}</td>
                    <td className="num hide-sm">{money(c.lifetime_revenue)}</td>
                    <td className="hide-sm">
                      {c.has_subscription ? <Badge cls="b-info">Suscripción</Badge>
                        : c.days_overdue > 0 ? <Badge cls="b-bad">{c.days_overdue} días tarde</Badge>
                        : c.expected_next_order ? date(c.expected_next_order) : <span className="muted">—</span>}
                    </td>
                    <td className="num">{Number(c.unpaid_amount) > 0 ? <b>{money(c.unpaid_amount)}</b> : '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
      {detail && <CustomerDetail c={detail} onClose={() => setDetail(null)}
        onEdit={() => { setEditing(detail); setDetail(null) }}
        onNewOrder={() => { setNewOrderFor(detail.id); setDetail(null) }} />}
      {editing && <CustomerForm customer={editing.id ? editing : null} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); reload() }} />}
      {newOrderFor && <OrderForm presetCustomer={newOrderFor} onClose={() => setNewOrderFor(null)} onSaved={() => { setNewOrderFor(null); reload() }} />}
    </>
  )
}

function CustomerDetail({ c, onClose, onEdit, onNewOrder }) {
  const { data: orders, loading } = useLoad(() =>
    q(supabase.from('v_orders').select('id, order_date, status, payment_status, total, items_summary').eq('customer_id', c.id).order('order_date', { ascending: false }).limit(50)), [c.id])
  const wa = waLink(c.phone)
  const map = mapsLink(c.address, c.zone)
  return (
    <Modal wide title={c.name} onClose={onClose}
      footer={<><button className="btn" onClick={onEdit}>Editar datos</button><button className="btn primary" onClick={onNewOrder}><Icon name="plus" />Nuevo pedido</button></>}>
      <div className="actions">
        <Badge cls={statusClass(c.status)}>{L.customerStatus[c.status]}</Badge>
        <Badge>{L.customerType[c.customer_type]}</Badge>
        {c.has_subscription && <Badge cls="b-info">Con suscripción</Badge>}
        {!c.whatsapp_opt_in && <Badge cls="b-mute">Sin recordatorios</Badge>}
      </div>
      <div className="grid grid-2">
        <div className="stack" style={{ gap: 6 }}>
          <div><span className="muted">Teléfono: </span>{phoneFmt(c.phone)}</div>
          {c.email && <div><span className="muted">Correo: </span>{c.email}</div>}
          <div><span className="muted">Dirección: </span>{[c.address, c.zone].filter(Boolean).join(', ') || '—'}</div>
          {c.address_notes && <div><span className="muted">Referencias: </span>{c.address_notes}</div>}
          {c.source && <div><span className="muted">Origen: </span>{c.source}</div>}
          {c.notes && <div className="note">{c.notes}</div>}
          <div className="actions" style={{ marginTop: 6 }}>
            {wa && <a className="btn sm" href={wa} target="_blank" rel="noreferrer"><Icon name="chat" />WhatsApp</a>}
            {map && <a className="btn sm" href={map} target="_blank" rel="noreferrer"><Icon name="map" />Mapa</a>}
          </div>
        </div>
        <div className="panel" style={{ alignSelf: 'start' }}>
          <ul className="list">
            <li><span className="muted">Pedidos</span><b>{c.n_orders}</b></li>
            <li><span className="muted">Total comprado</span><b>{money(c.lifetime_revenue)}</b></li>
            <li><span className="muted">Ticket promedio</span><b>{money(c.avg_ticket)}</b></li>
            <li><span className="muted">Pide cada</span><b>{c.median_gap_days ? `${Math.round(c.median_gap_days)} días` : 'Faltan datos'}</b></li>
            <li><span className="muted">Siguiente pedido estimado</span><b>{c.expected_next_order ? date(c.expected_next_order) : '—'}</b></li>
            <li><span className="muted">Por cobrar</span><b>{money(c.unpaid_amount)}</b></li>
          </ul>
        </div>
      </div>
      <h3>Historial</h3>
      {loading ? <Loading /> : !orders?.length ? <p className="muted">Todavía no tiene pedidos.</p> : (
        <div className="table-wrap panel">
          <table>
            <thead><tr><th>#</th><th>Fecha</th><th>Productos</th><th className="num">Total</th><th>Estado</th><th>Pago</th></tr></thead>
            <tbody>{orders.map((o) => (
              <tr key={o.id}><td className="muted">{o.id}</td><td style={{ whiteSpace: 'nowrap' }}>{date(o.order_date)}</td><td>{o.items_summary}</td><td className="num">{money(o.total)}</td><td><OrderStatus s={o.status} /></td><td><PayStatus s={o.payment_status} /></td></tr>
            ))}</tbody>
          </table>
        </div>
      )}
    </Modal>
  )
}
