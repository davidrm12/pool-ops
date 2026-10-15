import { Link } from 'react-router-dom'
import { supabase, q } from '../lib/supabase'
import { useLoad } from '../lib/hooks'
import { money, pct, qty, relDay, shortDate, today, waLink } from '../lib/format'
import { Empty, ErrorBox, Icon, Loading, PayStatus } from '../components/ui'
import MonthChart from '../components/MonthChart'

export default function Dashboard() {
  const { data, error, loading } = useLoad(async () => {
    const [kpi, pnl, deliveries, stock, overdue, attention] = await Promise.all([
      q(supabase.from('v_dashboard').select('*').single()),
      q(supabase.from('v_pnl_monthly').select('*').order('month', { ascending: false }).limit(6)),
      q(supabase.from('v_pending_deliveries').select('*').limit(6)),
      q(supabase.from('v_stock').select('*').eq('needs_reorder', true).eq('active', true)),
      q(supabase.from('v_customer_summary').select('id, name, phone, last_order, days_overdue, median_gap_days')
        .eq('status', 'customer').eq('has_subscription', false).gt('days_overdue', 0)
        .order('days_overdue', { ascending: false }).limit(6)),
      q(supabase.from('orders').select('id, needs_review, charge_status').neq('status', 'cancelled')
        .or('needs_review.eq.true,charge_status.in.(failed,requires_approval)')),
    ])
    return { kpi, pnl: pnl.reverse(), deliveries, stock, overdue, attention }
  })

  if (loading) return <Loading />
  if (error) return <ErrorBox msg={error} />
  const { kpi, pnl, deliveries, stock, overdue, attention } = data
  const held = attention.filter((o) => o.charge_status === 'requires_approval').length
  const failed = attention.filter((o) => o.charge_status === 'failed').length
  const review = attention.filter((o) => o.needs_review).length
  const thisMonth = pnl.find((r) => r.month.slice(0, 7) === today().slice(0, 7))
  const delta = kpi.sales_last_month > 0 ? (kpi.sales_this_month || 0) / kpi.sales_last_month - 1 : null
  const monthName = new Date().toLocaleDateString('es-MX', { month: 'long' })

  return (
    <>
      <div className="page-head">
        <div><h1>Resumen</h1><p>{new Date().toLocaleDateString('es-MX', { weekday: 'long', day: 'numeric', month: 'long' })}</p></div>
        <Link to="/pedidos?nuevo=1" className="btn primary"><Icon name="plus" />Nuevo pedido</Link>
      </div>

      <section className="waterline" aria-label="Ventas del mes">
        <div className="row">
          <div>
            <div className="big-num">{money(kpi.sales_this_month || 0)}</div>
            <div className="lbl">Ventas de {monthName}</div>
            <div className="delta">
              {delta === null ? 'Sin ventas el mes pasado para comparar' : `${delta >= 0 ? '+' : ''}${(delta * 100).toFixed(0)}% vs. ${money(kpi.sales_last_month)} el mes pasado`}
            </div>
          </div>
          <div><div className="mid-num">{money(kpi.gross_profit_this_month || 0)}</div><div className="lbl">Utilidad bruta</div></div>
          <div><div className="mid-num">{pct(kpi.gross_margin_this_month)}</div><div className="lbl">Margen bruto</div></div>
          <div><div className="mid-num">{kpi.orders_this_month || 0}</div><div className="lbl">Pedidos del mes</div></div>
        </div>
      </section>

      {attention.length > 0 && (
        <div className="note" style={{ marginBottom: 16, display: 'flex', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap', alignItems: 'center' }}>
          <span>{[held && `${held} cobro${held > 1 ? 's' : ''} retenido${held > 1 ? 's' : ''} esperando tu aprobación`, failed && `${failed} cobro${failed > 1 ? 's' : ''} con tarjeta rechazado${failed > 1 ? 's' : ''}`, review && `${review} pedido${review > 1 ? 's' : ''} web con datos por revisar`].filter(Boolean).join(' · ')}</span>
          <Link to="/pedidos?vista=revisar" className="btn sm">Revisar</Link>
        </div>
      )}

      {thisMonth?.sales_without_cost > 0 && (
        <div className="note" style={{ marginBottom: 16 }}>
          {money(thisMonth.sales_without_cost)} de ventas este mes son de productos sin costo registrado, así que la utilidad y el margen salen más altos de lo real. <Link to="/productos">Agrega el costo</Link> o registra una compra.
        </div>
      )}

      <div className="panel" style={{ marginBottom: 16 }}>
        <div className="kpis">
          <div><div className="v">{kpi.pending_deliveries}</div><div className="l">Entregas pendientes, próxima ruta {shortDate(kpi.next_delivery_date)}{kpi.overdue_deliveries > 0 && <>; <b style={{ color: 'var(--danger)' }}>{kpi.overdue_deliveries} atrasadas</b></>}</div></div>
          <div><div className="v">{money(kpi.unpaid_amount)}</div><div className="l">Por cobrar</div></div>
          <div><div className="v">{kpi.active_customers_90d}</div><div className="l">Clientes activos (90 días){kpi.new_customers_this_month > 0 && `, ${kpi.new_customers_this_month} nuevos`}</div></div>
          <div><div className="v">{money(kpi.subscription_mrr)}</div><div className="l">Ingreso mensual por suscripciones ({kpi.active_subscriptions} {kpi.active_subscriptions === 1 ? 'activa' : 'activas'})</div></div>
        </div>
      </div>

      <div className="grid grid-2" style={{ marginBottom: 16 }}>
        <section className="panel">
          <div className="panel-head"><h2>Últimos 6 meses</h2><Link to="/finanzas">Ver finanzas</Link></div>
          <div className="panel-body">
            {pnl.length ? (
              <MonthChart rows={pnl} series={[
                { key: 'net_sales', label: 'Ventas netas', color: 'var(--chart-sales)' },
                { key: 'gross_profit', label: 'Utilidad bruta', color: 'var(--chart-profit)' },
              ]} />
            ) : <Empty text="Las ventas aparecerán aquí cuando registres el primer pedido." />}
          </div>
        </section>

        <section className="panel">
          <div className="panel-head"><h2>Próximas entregas</h2><Link to="/entregas">Ver todas</Link></div>
          {deliveries.length ? (
            <ul className="list">
              {deliveries.map((d) => (
                <li key={d.id}>
                  <div>
                    <div style={{ fontWeight: 600 }}>{d.customer_name}</div>
                    <div className="muted" style={{ fontSize: 13 }}>{d.items_summary}</div>
                  </div>
                  <div className="right">
                    <div style={{ fontWeight: 600, color: d.overdue ? 'var(--danger)' : undefined }}>{relDay(d.due_date)}</div>
                    <div style={{ fontSize: 13 }}>{money(d.total)} <PayStatus s={d.payment_status} /></div>
                  </div>
                </li>
              ))}
            </ul>
          ) : <Empty text="No hay entregas pendientes." />}
        </section>
      </div>

      <div className="grid grid-2">
        <section className="panel">
          <div className="panel-head"><h2>Por reabastecer</h2><Link to="/inventario">Inventario</Link></div>
          {stock.length ? (
            <ul className="list">
              {stock.map((s) => (
                <li key={s.product_id}>
                  <div>
                    <div style={{ fontWeight: 600 }}>{s.name}</div>
                    <div className="muted" style={{ fontSize: 13 }}>Comprar {qty(s.suggested_qty)} {s.base_unit}{s.supplier_name ? ` en ${s.supplier_name}` : ''}</div>
                  </div>
                  <div className="right">
                    <div style={{ fontWeight: 600, color: 'var(--danger)' }}>Quedan {qty(s.projected)} {s.base_unit}</div>
                    {s.supplier_website
                      ? <a href={s.supplier_website} target="_blank" rel="noreferrer" style={{ fontSize: 13 }}>Abrir tienda</a>
                      : <div className="muted" style={{ fontSize: 13 }}>alerta en {qty(s.alert_threshold)}</div>}
                  </div>
                </li>
              ))}
            </ul>
          ) : <Empty text="Todo el inventario está arriba de su punto de reorden." />}
        </section>

        <section className="panel">
          <div className="panel-head"><h2>Clientes que ya deberían haber pedido</h2><Link to="/directorio">Directorio</Link></div>
          {overdue.length ? (
            <ul className="list">
              {overdue.map((c) => {
                const wa = waLink(c.phone, `Hola ${c.name.split(' ')[0]}, ¿cómo va la alberca? ¿Te llevamos cloro esta semana?`)
                return (
                  <li key={c.id}>
                    <div><div style={{ fontWeight: 600 }}>{c.name}</div><div className="muted" style={{ fontSize: 13 }}>Suele pedir cada {Math.round(c.median_gap_days)} días; lleva {c.days_overdue} de retraso</div></div>
                    {wa && <a className="btn sm" href={wa} target="_blank" rel="noreferrer"><Icon name="chat" />WhatsApp</a>}
                  </li>
                )
              })}
            </ul>
          ) : <Empty text="Nadie atrasado. Aparecen aquí cuando un cliente con al menos dos pedidos pasa su frecuencia habitual." />}
        </section>
      </div>
    </>
  )
}
