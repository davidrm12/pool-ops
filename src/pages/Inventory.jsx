import { useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { useLoad } from '../lib/hooks'
import { L, money, qty } from '../lib/format'
import { Badge, Empty, ErrorBox, Field, Loading, Modal, Select, Tabs, useToast } from '../components/ui'

export default function Inventory() {
  const [tab, setTab] = useState('stock')
  const [action, setAction] = useState(null) // { type: 'count' | 'out', product }
  const stock = useLoad(() => q(supabase.from('v_stock').select('*').eq('active', true).order('name')))
  const moves = useLoad(() => tab === 'moves'
    ? q(supabase.from('inventory_movements').select('*, product:products(name, base_unit)').order('moved_at', { ascending: false }).limit(200))
    : Promise.resolve(null), [tab])
  const total = (stock.data || []).reduce((s, r) => s + Number(r.stock_value || 0), 0)

  return (
    <>
      <div className="page-head">
        <div><h1>Inventario</h1><p>Existencias calculadas con compras, ventas y conteos. "Queda" descuenta las entregas de suscripción próximas. Valor total: <b>{money(total)}</b></p></div>
        <div className="actions">
          <button className="btn" onClick={() => setAction({ type: 'out' })}>Registrar merma o uso</button>
          <button className="btn primary" onClick={() => setAction({ type: 'count' })}>Registrar conteo físico</button>
        </div>
      </div>
      <Tabs value={tab} onChange={setTab} tabs={[{ value: 'stock', label: 'Existencias' }, { value: 'moves', label: 'Movimientos' }]} />
      {tab === 'stock' ? (
        <>
          <ErrorBox msg={stock.error} />
          <div className="panel">
            {stock.loading ? <Loading /> : !stock.data?.length ? <Empty text="Agrega productos y registra una compra o un conteo para ver existencias." /> : (
              <div className="table-wrap">
                <table>
                  <thead><tr><th>Producto</th><th className="num">Existencia</th><th className="num hide-sm">Suscripciones próximas</th><th className="num">Queda</th><th className="num hide-sm">Alerta en</th><th className="num hide-sm">Valor</th><th className="num hide-sm">Alcanza para</th><th /></tr></thead>
                  <tbody>{stock.data.map((s) => (
                    <tr key={s.product_id}>
                      <td><b>{s.name}</b>{s.needs_reorder && <> <Badge cls="b-bad">Reabastecer</Badge></>}{s.supplier_name && <div className="sub">{s.supplier_website ? <a href={s.supplier_website} target="_blank" rel="noreferrer">{s.supplier_name}</a> : s.supplier_name}</div>}</td>
                      <td className="num" style={{ color: Number(s.on_hand) < 0 ? 'var(--danger)' : undefined }}>{qty(s.on_hand)} {s.base_unit}</td>
                      <td className="num hide-sm">{Number(s.committed_subscriptions) ? `−${qty(s.committed_subscriptions)}` : '—'}</td>
                      <td className="num" style={{ color: s.needs_reorder ? 'var(--danger)' : undefined }}><b>{qty(s.projected)}</b> {s.base_unit}{s.needs_reorder && <div className="sub">comprar {qty(s.suggested_qty)}</div>}</td>
                      <td className="num hide-sm">{s.alert_threshold != null ? `${qty(s.alert_threshold)} ${s.base_unit}` : <span className="muted">Sin presentaciones</span>}</td>
                      <td className="num hide-sm">{money(s.stock_value)}</td>
                      <td className="num hide-sm">{s.days_of_stock != null ? `${qty(s.days_of_stock)} días` : '—'}</td>
                      <td className="right"><button className="btn sm" onClick={() => setAction({ type: 'count', product: s.product_id })}>Contar</button></td>
                    </tr>
                  ))}</tbody>
                </table>
              </div>
            )}
          </div>
          {stock.data?.some((s) => Number(s.on_hand) < 0) && <p className="note" style={{ marginTop: 12 }}>Hay existencias negativas: se vendió más de lo que se ha registrado como comprado. Registra la compra que falta o un conteo físico.</p>}
        </>
      ) : (
        <div className="panel">
          {moves.loading ? <Loading /> : !moves.data?.length ? <Empty text="Sin movimientos todavía." /> : (
            <div className="table-wrap">
              <table>
                <thead><tr><th>Fecha</th><th>Producto</th><th>Tipo</th><th className="num">Cantidad</th><th className="hide-sm">Referencia</th></tr></thead>
                <tbody>{moves.data.map((m) => (
                  <tr key={m.id}>
                    <td style={{ whiteSpace: 'nowrap' }}>{new Date(m.moved_at).toLocaleDateString('es-MX', { day: 'numeric', month: 'short', year: 'numeric' })}</td>
                    <td>{m.product?.name}</td>
                    <td>{L.movement[m.reason]}</td>
                    <td className="num" style={{ color: m.qty < 0 ? 'var(--danger)' : 'var(--ok)' }}>{m.qty > 0 ? '+' : ''}{qty(m.qty)} {m.product?.base_unit}</td>
                    <td className="hide-sm muted">{m.notes || (m.order_item_id ? 'Pedido' : m.purchase_item_id ? 'Compra' : '')}</td>
                  </tr>
                ))}</tbody>
              </table>
            </div>
          )}
        </div>
      )}
      {action && <StockAction action={action} products={stock.data || []} onClose={() => setAction(null)} onSaved={() => { setAction(null); stock.reload(); moves.reload() }} />}
    </>
  )
}

function StockAction({ action, products, onClose, onSaved }) {
  const [pid, setPid] = useState(action.product || '')
  const [amount, setAmount] = useState('')
  const [reason, setReason] = useState('waste')
  const [notes, setNotes] = useState('')
  const [err, setErr] = useState(null)
  const toast = useToast()
  const p = products.find((x) => String(x.product_id) === String(pid))
  const isCount = action.type === 'count'

  const save = async () => {
    if (!pid || amount === '' || Number(amount) < 0) { setErr('Elige el producto y escribe la cantidad.'); return }
    try {
      if (isCount) {
        const diff = await q(supabase.rpc('record_stock_count', { p_product_id: Number(pid), p_counted: Number(amount), p_notes: notes || null }))
        toast(Number(diff) === 0 ? 'Conteo coincide con el sistema' : `Ajuste de ${diff > 0 ? '+' : ''}${qty(diff)} ${p.base_unit} registrado`)
      } else {
        if (!(Number(amount) > 0)) { setErr('La cantidad debe ser mayor a 0.'); return }
        await q(supabase.from('inventory_movements').insert({ product_id: Number(pid), qty: -Number(amount), reason, notes: notes || null }))
        toast('Salida registrada')
      }
      onSaved()
    } catch (e) { setErr(e.message) }
  }
  return (
    <Modal title={isCount ? 'Conteo físico' : 'Merma o uso interno'} onClose={onClose}
      footer={<><span /><div className="actions"><button className="btn" onClick={onClose}>Cancelar</button><button className="btn primary" onClick={save}>{isCount ? 'Guardar conteo' : 'Registrar salida'}</button></div></>}>
      <Field label="Producto"><Select value={pid} onChange={setPid} placeholder="Elige…" options={products.map((x) => ({ value: x.product_id, label: x.name }))} /></Field>
      {p && <p className="muted">El sistema calcula {qty(p.on_hand)} {p.base_unit}.</p>}
      {!isCount && <Field label="Motivo"><Select value={reason} onChange={setReason} options={[{ value: 'waste', label: 'Merma (se dañó, se derramó)' }, { value: 'internal_use', label: 'Uso interno / regalo' }]} /></Field>}
      <Field label={isCount ? `Cantidad contada${p ? ` (${p.base_unit})` : ''}` : `Cantidad que salió${p ? ` (${p.base_unit})` : ''}`} hint={isCount ? 'Se registra solo la diferencia contra el sistema' : undefined}>
        <input type="number" min="0" step="any" inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} autoFocus />
      </Field>
      <Field label="Nota"><input value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
      <ErrorBox msg={err} />
    </Modal>
  )
}
