import { useMemo, useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { useLoad } from '../lib/hooks'
import { money, monthLabel, pct, qty, today } from '../lib/format'
import { Empty, ErrorBox, Loading, Tabs } from '../components/ui'
import MonthChart from '../components/MonthChart'

const LINES = [
  ['gross_sales', 'Ventas brutas'],
  ['discounts', 'Descuentos', -1],
  ['net_sales', 'Ventas netas', 0, true],
  ['delivery_income', 'Cargos por envío'],
  ['cogs', 'Costo de lo vendido', -1],
  ['gross_profit', 'Utilidad bruta', 0, true],
  ['operating_expenses', 'Gastos de operación', -1],
  ['net_profit', 'Utilidad neta', 0, true],
]

export default function Finance() {
  const [year, setYear] = useState(today().slice(0, 4))
  const [tab, setTab] = useState('pnl')
  const { data, error, loading } = useLoad(async () => {
    const [pnl, prod] = await Promise.all([
      q(supabase.from('v_pnl_monthly').select('*').gte('month', `${year}-01-01`).lte('month', `${year}-12-01`).order('month')),
      q(supabase.from('v_product_sales_monthly').select('*').gte('month', `${year}-01-01`).lte('month', `${year}-12-01`)),
    ])
    return { pnl, prod }
  }, [year])

  const products = useMemo(() => {
    const m = {}
    for (const r of data?.prod || []) {
      const x = (m[r.product_id] ||= { name: r.name, unit: r.base_unit, qty: 0, revenue: 0, cogs: 0, missing: false })
      x.qty += Number(r.qty_base); x.revenue += Number(r.revenue)
      if (r.cogs == null) x.missing = true; else x.cogs += Number(r.cogs)
    }
    return Object.values(m).sort((a, b) => b.revenue - a.revenue)
  }, [data])

  const years = Array.from({ length: 4 }, (_, i) => String(Number(today().slice(0, 4)) - i))
  const pnl = data?.pnl || []
  const sum = (k) => pnl.reduce((s, r) => s + Number(r[k] || 0), 0)
  const noCost = sum('sales_without_cost')

  const exportCsv = () => {
    const head = ['Concepto', ...pnl.map((r) => r.month.slice(0, 7)), 'Total']
    const rows = LINES.map(([k, label]) => [label, ...pnl.map((r) => r[k]), sum(k)])
    const csv = [head, ...rows].map((r) => r.map((c) => `"${String(c ?? '').replace(/"/g, '""')}"`).join(',')).join('\n')
    const a = document.createElement('a')
    a.href = URL.createObjectURL(new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8' }))
    a.download = `estado-de-resultados-${year}.csv`
    a.click()
  }

  return (
    <>
      <div className="page-head">
        <div><h1>Finanzas</h1><p>Estado de resultados por mes, con base en la fecha de cada pedido (sin cancelados).</p></div>
        <div className="actions">
          <select value={year} onChange={(e) => setYear(e.target.value)} aria-label="Año" style={{ width: 'auto' }}>{years.map((y) => <option key={y}>{y}</option>)}</select>
          <button className="btn" onClick={exportCsv} disabled={!pnl.length}>Descargar CSV</button>
        </div>
      </div>
      <Tabs value={tab} onChange={setTab} tabs={[{ value: 'pnl', label: 'Estado de resultados' }, { value: 'products', label: 'Por producto' }]} />
      <ErrorBox msg={error} />
      {loading ? <Loading /> : tab === 'pnl' ? (
        !pnl.length ? <div className="panel"><Empty text={`Sin movimientos en ${year}.`} /></div> : (
          <div className="stack">
            {noCost > 0 && <div className="note">{money(noCost)} de ventas en {year} son de productos sin costo registrado; la utilidad está sobreestimada en esa parte.</div>}
            <section className="panel panel-body">
              <MonthChart rows={pnl} series={[
                { key: 'net_sales', label: 'Ventas netas', color: 'var(--chart-sales)' },
                { key: 'gross_profit', label: 'Utilidad bruta', color: 'var(--chart-profit)' },
              ]} />
            </section>
            <div className="panel table-wrap">
              <table>
                <thead><tr><th>Concepto</th>{pnl.map((r) => <th key={r.month} className="num">{monthLabel(r.month)}</th>)}<th className="num">Total {year}</th></tr></thead>
                <tbody>
                  {LINES.map(([k, label, sign, strong]) => (
                    <tr key={k} style={strong ? { fontWeight: 700, background: 'var(--tile)' } : undefined}>
                      <td>{label}</td>
                      {pnl.map((r) => <td key={r.month} className="num">{sign === -1 && Number(r[k]) ? `(${money(r[k])})` : money(r[k])}</td>)}
                      <td className="num">{sign === -1 && sum(k) ? `(${money(sum(k))})` : money(sum(k))}</td>
                    </tr>
                  ))}
                  <tr><td className="muted">Margen bruto</td>{pnl.map((r) => <td key={r.month} className="num muted">{pct(r.gross_margin)}</td>)}<td className="num muted">{sum('net_sales') ? pct((sum('net_sales') - sum('cogs')) / sum('net_sales')) : '—'}</td></tr>
                  <tr><td className="muted">Pedidos</td>{pnl.map((r) => <td key={r.month} className="num muted">{r.orders}</td>)}<td className="num muted">{sum('orders')}</td></tr>
                </tbody>
              </table>
            </div>
          </div>
        )
      ) : (
        <div className="panel">
          {!products.length ? <Empty text={`Sin ventas en ${year}.`} /> : (
            <div className="table-wrap">
              <table>
                <thead><tr><th>Producto</th><th className="num">Cantidad</th><th className="num">Ventas</th><th className="num">Costo</th><th className="num">Utilidad</th><th className="num">Margen</th><th className="num hide-sm">% de ventas</th></tr></thead>
                <tbody>{products.map((p) => {
                  const tot = products.reduce((s, x) => s + x.revenue, 0)
                  return (
                    <tr key={p.name}>
                      <td><b>{p.name}</b></td>
                      <td className="num">{qty(p.qty)} {p.unit}</td>
                      <td className="num">{money(p.revenue)}</td>
                      <td className="num">{p.missing ? <span className="muted">Incompleto</span> : money(p.cogs)}</td>
                      <td className="num">{p.missing ? '—' : money(p.revenue - p.cogs)}</td>
                      <td className="num">{p.missing || !p.revenue ? '—' : pct((p.revenue - p.cogs) / p.revenue)}</td>
                      <td className="num hide-sm">{pct(p.revenue / tot)}</td>
                    </tr>
                  )
                })}</tbody>
              </table>
            </div>
          )}
        </div>
      )}
    </>
  )
}
