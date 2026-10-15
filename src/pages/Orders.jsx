import { useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { supabase, q } from '../lib/supabase'
import { useLoad } from '../lib/hooks'
import { L, date, money } from '../lib/format'
import { Empty, ErrorBox, Icon, Loading, OrderStatus, PayStatus, Seg } from '../components/ui'
import OrderForm from '../components/OrderForm'
import { ChargeBadge } from '../components/OrderExtras'

const VIEWS = [
  { value: 'open', label: 'Abiertos' },
  { value: 'unpaid', label: 'Por cobrar' },
  { value: 'review', label: 'Revisar' },
  { value: 'delivered', label: 'Entregados' },
  { value: 'all', label: 'Todos' },
]

export default function Orders() {
  const [params, setParams] = useSearchParams()
  const [view, setView] = useState(params.get('vista') === 'revisar' ? 'review' : 'open')
  const [search, setSearch] = useState('')
  const [month, setMonth] = useState('')
  const [editing, setEditing] = useState(params.get('nuevo') ? 'new' : null)

  const { data, error, loading, reload } = useLoad(async () => {
    let qry = supabase.from('v_orders').select('*').order('order_date', { ascending: false }).order('id', { ascending: false })
    if (view === 'open') qry = qry.in('status', ['pending', 'confirmed', 'out_for_delivery'])
    if (view === 'unpaid') qry = qry.eq('payment_status', 'pending').neq('status', 'cancelled')
    if (view === 'delivered') qry = qry.eq('status', 'delivered')
    if (view === 'review') qry = qry.or('needs_review.eq.true,charge_status.in.(failed,requires_approval)').neq('status', 'cancelled')
    if (month) {
      const [y, m] = month.split('-').map(Number)
      const end = m === 12 ? `${y + 1}-01-01` : `${y}-${String(m + 1).padStart(2, '0')}-01`
      qry = qry.gte('order_date', `${month}-01`).lt('order_date', end)
    }
    return q(qry.limit(500))
  }, [view, month])

  const rows = useMemo(() => {
    const t = search.trim().toLowerCase()
    if (!data) return []
    return t ? data.filter((o) => `${o.id} ${o.customer_name} ${o.items_summary} ${o.customer_phone}`.toLowerCase().includes(t)) : data
  }, [data, search])
  const sum = rows.filter((r) => r.status !== 'cancelled').reduce((s, r) => s + Number(r.total), 0)

  const close = () => { setEditing(null); if (params.get('nuevo')) setParams({}) }

  return (
    <>
      <div className="page-head">
        <div><h1>Pedidos</h1><p>Registra, edita y da seguimiento a cada venta.</p></div>
        <button className="btn primary" onClick={() => setEditing('new')}><Icon name="plus" />Nuevo pedido</button>
      </div>
      <div className="toolbar">
        <Seg value={view} onChange={setView} options={VIEWS} />
        <input type="month" value={month} onChange={(e) => setMonth(e.target.value)} aria-label="Mes" style={{ width: 'auto' }} />
        <input type="search" placeholder="Buscar cliente, producto o #" value={search} onChange={(e) => setSearch(e.target.value)} />
      </div>
      <ErrorBox msg={error} />
      <div className="panel">
        {loading ? <Loading /> : rows.length === 0 ? (
          <Empty text={view === 'open' ? 'No hay pedidos abiertos.' : 'No hay pedidos con estos filtros.'} action={<button className="btn primary" onClick={() => setEditing('new')}>Registrar pedido</button>} />
        ) : (
          <div className="table-wrap">
            <table>
              <thead><tr><th>#</th><th>Fecha</th><th>Cliente</th><th className="hide-sm">Productos</th><th className="num">Total</th><th>Estado</th><th>Pago</th></tr></thead>
              <tbody>
                {rows.map((o) => (
                  <tr key={o.id} className="click" onClick={() => setEditing(o.id)} tabIndex={0} onKeyDown={(e) => e.key === 'Enter' && setEditing(o.id)}>
                    <td className="muted">{o.id}</td>
                    <td style={{ whiteSpace: 'nowrap' }}>{date(o.order_date)}{o.channel !== 'manual' && <div className="sub">{L.channel[o.channel]}</div>}</td>
                    <td>{o.customer_name}{o.needs_review && <> <span className="badge b-warn">Revisar</span></>}</td>
                    <td className="hide-sm">{o.items_summary || <span className="muted">Sin productos</span>}</td>
                    <td className="num">{money(o.total)}</td>
                    <td><OrderStatus s={o.status} /></td>
                    <td><PayStatus s={o.payment_status} /><div className="sub">{L.payMethod[o.payment_method]}</div>{['failed', 'requires_approval', 'refunded'].includes(o.charge_status) && <ChargeBadge s={o.charge_status} />}</td>
                  </tr>
                ))}
              </tbody>
              <tfoot><tr><td colSpan={3}>{rows.length} pedidos</td><td className="hide-sm muted" style={{ fontWeight: 400 }}>Total sin cancelados</td><td className="num">{money(sum)}</td><td colSpan={2} /></tr></tfoot>
            </table>
          </div>
        )}
      </div>
      {editing && <OrderForm orderId={editing === 'new' ? null : editing} onClose={close} onSaved={() => { close(); reload() }} />}
    </>
  )
}
