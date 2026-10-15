import { Combo, Icon } from './ui'
import { money } from '../lib/format'

// Editable list of { variant_id, qty, unit_price } rows.
// showPrice=false hides price (subscriptions use catalog price at delivery time).
export default function LinesEditor({ lines, setLines, variants, showPrice = true }) {
  const opts = variants.map((v) => ({ value: v.id, label: v.name, sub: money(v.price) }))
  const upd = (i, patch) => setLines(lines.map((l, j) => (j === i ? { ...l, ...patch } : l)))
  const pickVariant = (i, id) => {
    const v = variants.find((x) => String(x.id) === String(id))
    upd(i, { variant_id: id ? Number(id) : '', unit_price: v ? v.price : '' })
  }
  return (
    <div className="lines">
      <div className="line line-head">
        <div>Producto</div><div>Cantidad</div>{showPrice ? <><div>Precio</div><div className="tot">Importe</div></> : <><div /><div className="tot" /></>}<div />
      </div>
      {lines.map((l, i) => (
        <div className="line" key={l.key ?? l.id ?? i}>
          <Combo value={l.variant_id} onChange={(id) => pickVariant(i, id)} options={opts} placeholder="Buscar producto…" aria-label="Producto" />
          <input type="number" min="0.001" step="any" inputMode="decimal" value={l.qty} onChange={(e) => upd(i, { qty: e.target.value })} aria-label="Cantidad" />
          {showPrice
            ? <><input type="number" min="0" step="any" inputMode="decimal" value={l.unit_price} onChange={(e) => upd(i, { unit_price: e.target.value })} aria-label="Precio unitario" />
                <div className="tot">{money((Number(l.qty) || 0) * (Number(l.unit_price) || 0))}</div></>
            : <><div /><div className="tot" /></>}
          <button type="button" className="btn ghost sm" onClick={() => setLines(lines.filter((_, j) => j !== i))} aria-label="Quitar renglón"><Icon name="x" /></button>
        </div>
      ))}
      <div className="line" style={{ display: 'block' }}>
        <button type="button" className="btn sm" onClick={() => setLines([...lines, { key: Math.random(), variant_id: '', qty: 1, unit_price: '' }])}><Icon name="plus" />Agregar producto</button>
      </div>
    </div>
  )
}

export const validLines = (lines) => lines.filter((l) => l.variant_id && Number(l.qty) > 0)
