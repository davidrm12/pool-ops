import { useEffect, useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { useLoad } from '../lib/hooks'
import { loadSuppliers } from '../lib/data'
import { L, money, options, pct, qty } from '../lib/format'
import { Badge, DeleteButton, Empty, ErrorBox, Field, Icon, Loading, Modal, Select, Seg, useToast } from '../components/ui'

export default function Products() {
  const [view, setView] = useState('active')
  const [editing, setEditing] = useState(null)
  const { data, error, loading, reload } = useLoad(async () => {
    const [products, stock] = await Promise.all([
      q(supabase.from('products').select('*, product_variants(*), supplier:suppliers(name)').order('name')),
      q(supabase.from('v_stock').select('product_id, on_hand')),
    ])
    const s = Object.fromEntries(stock.map((x) => [x.product_id, x.on_hand]))
    return products.map((p) => ({ ...p, on_hand: s[p.id] ?? 0, product_variants: p.product_variants.sort((a, b) => a.pack_qty - b.pack_qty) }))
  })
  const rows = (data || []).filter((p) => view === 'all' || (view === 'active' ? p.active : !p.active))

  return (
    <>
      <div className="page-head">
        <div><h1>Productos</h1><p>Catálogo, presentaciones, precios y costos.</p></div>
        <button className="btn primary" onClick={() => setEditing({})}><Icon name="plus" />Nuevo producto</button>
      </div>
      <div className="toolbar"><Seg value={view} onChange={setView} options={[{ value: 'active', label: 'Activos' }, { value: 'inactive', label: 'Inactivos' }, { value: 'all', label: 'Todos' }]} /></div>
      <ErrorBox msg={error} />
      <div className="panel">
        {loading ? <Loading /> : rows.length === 0 ? (
          <Empty text="Agrega tu primer producto con sus presentaciones (por ejemplo, Cloro granular: 1 kg y bolsa de 5 kg)." action={<button className="btn primary" onClick={() => setEditing({})}>Agregar producto</button>} />
        ) : (
          <div className="table-wrap">
            <table>
              <thead><tr><th>Producto</th><th>Presentaciones y precio</th><th className="num">Costo</th><th className="num">Existencia</th><th className="hide-sm">Proveedor</th></tr></thead>
              <tbody>
                {rows.map((p) => (
                  <tr key={p.id} className="click" onClick={() => setEditing(p)} tabIndex={0} onKeyDown={(e) => e.key === 'Enter' && setEditing(p)}>
                    <td><b>{p.name}</b> {!p.active && <Badge cls="b-mute">Inactivo</Badge>}<div className="sub">{L.category[p.category]}</div></td>
                    <td>
                      {p.product_variants.length === 0 ? <span className="muted">Sin presentaciones: no se puede vender</span> :
                        p.product_variants.map((v) => {
                          const m = p.unit_cost != null && v.price > 0 ? (v.price - p.unit_cost * v.pack_qty) / v.price : null
                          return <div key={v.id} style={{ opacity: v.active ? 1 : .5 }}>{v.label}: <b>{money(v.price)}</b> <span className="sub">{m !== null ? `margen ${pct(m)}` : ''}</span></div>
                        })}
                    </td>
                    <td className="num">{p.unit_cost != null ? `${money(p.unit_cost)}/${p.base_unit}` : <Badge cls="b-warn">Sin costo</Badge>}</td>
                    <td className="num" style={{ color: p.reorder_point != null && p.on_hand <= p.reorder_point ? 'var(--danger)' : undefined }}>{qty(p.on_hand)} {p.base_unit}</td>
                    <td className="hide-sm">{p.supplier?.name || <span className="muted">—</span>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
      {editing && <ProductForm product={editing.id ? editing : null} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); reload() }} />}
    </>
  )
}

const blank = { name: '', category: 'cloro', base_unit: 'kg', unit_cost: '', reorder_point: '', reorder_qty: '', supplier_id: '', description: '', active: true }

function ProductForm({ product, onClose, onSaved }) {
  const [f, setF] = useState(() => {
    const p = { ...blank, ...(product || {}) }
    for (const k of ['unit_cost', 'reorder_point', 'reorder_qty', 'supplier_id', 'description']) p[k] = p[k] ?? ''
    return p
  })
  const [variants, setVariants] = useState(product?.product_variants?.map((v) => ({ ...v })) || [{ key: 1, label: '', pack_qty: 1, price: '', active: true }])
  const [suppliers, setSuppliers] = useState([])
  const [err, setErr] = useState(null)
  const [busy, setBusy] = useState(false)
  const toast = useToast()
  useEffect(() => { loadSuppliers().then(setSuppliers).catch(() => {}) }, [])
  const set = (k) => (e) => setF({ ...f, [k]: e?.target ? (e.target.type === 'checkbox' ? e.target.checked : e.target.value) : e })
  const updV = (i, patch) => setVariants(variants.map((v, j) => (j === i ? { ...v, ...patch } : v)))
  const num = (v) => (v === '' || v === null ? null : Number(v))

  const save = async () => {
    if (!f.name.trim()) { setErr('Escribe el nombre del producto.'); return }
    const vs = variants.filter((v) => v.label.trim() || v.price !== '')
    if (vs.some((v) => !v.label.trim() || v.price === '' || !(Number(v.pack_qty) > 0))) { setErr('Cada presentación necesita nombre, contenido mayor a 0 y precio.'); return }
    setBusy(true); setErr(null)
    const row = { name: f.name.trim(), category: f.category, base_unit: f.base_unit, unit_cost: num(f.unit_cost), reorder_point: num(f.reorder_point), reorder_qty: num(f.reorder_qty), supplier_id: num(f.supplier_id), description: f.description.trim() || null, active: f.active }
    try {
      let id = product?.id
      if (id) await q(supabase.from('products').update(row).eq('id', id))
      else id = (await q(supabase.from('products').insert(row).select('id').single())).id
      const keep = new Set(vs.filter((v) => v.id).map((v) => v.id))
      for (const old of product?.product_variants || []) {
        if (!keep.has(old.id)) {
          try { await q(supabase.from('product_variants').delete().eq('id', old.id)) }
          catch { await q(supabase.from('product_variants').update({ active: false }).eq('id', old.id)); toast(`"${old.label}" ya tiene ventas: se desactivó en lugar de borrarse`) }
        }
      }
      for (const v of vs) {
        const vr = { label: v.label.trim(), pack_qty: Number(v.pack_qty), price: Number(v.price), active: v.active }
        if (v.id) await q(supabase.from('product_variants').update(vr).eq('id', v.id))
        else await q(supabase.from('product_variants').insert({ ...vr, product_id: id }))
      }
      toast(product ? 'Producto actualizado' : 'Producto agregado')
      onSaved()
    } catch (e) { setErr(e.message); setBusy(false) }
  }
  const remove = async () => {
    try { await q(supabase.from('products').delete().eq('id', product.id)); toast('Producto eliminado'); onSaved() }
    catch { setErr('Este producto ya tiene ventas, compras o movimientos. Desmarca "Activo" para ocultarlo.') }
  }

  const cost = num(f.unit_cost)
  return (
    <Modal wide title={product ? product.name : 'Nuevo producto'} onClose={onClose}
      footer={<><div>{product && <DeleteButton onConfirm={remove} />}</div><div className="actions"><button className="btn" onClick={onClose}>Cancelar</button><button className="btn primary" onClick={save} disabled={busy}>Guardar producto</button></div></>}>
      <div className="form-grid">
        <Field label="Nombre" className="full"><input value={f.name} onChange={set('name')} placeholder="Cloro granular" autoFocus /></Field>
        <Field label="Categoría"><Select value={f.category} onChange={set('category')} options={options(L.category)} /></Field>
        <Field label="Unidad de inventario" hint="El inventario y el costo se llevan en esta unidad"><Select value={f.base_unit} onChange={set('base_unit')} options={options(L.unit)} /></Field>
        <Field label={`Costo por ${f.base_unit}`} hint="Se actualiza solo con cada compra (costo promedio)"><input type="number" min="0" step="any" inputMode="decimal" value={f.unit_cost} onChange={set('unit_cost')} /></Field>
        <Field label="Proveedor habitual"><Select value={f.supplier_id} onChange={set('supplier_id')} placeholder="—" options={suppliers.map((s) => ({ value: s.id, label: s.name }))} /></Field>
        <Field label={`Punto de reorden (${f.base_unit})`} hint="Avisa cuando la existencia baje de aquí"><input type="number" min="0" step="any" inputMode="decimal" value={f.reorder_point} onChange={set('reorder_point')} /></Field>
        <Field label={`Cantidad a pedir (${f.base_unit})`}><input type="number" min="0" step="any" inputMode="decimal" value={f.reorder_qty} onChange={set('reorder_qty')} /></Field>
        <Field label="Descripción / modo de uso" className="full"><textarea value={f.description} onChange={set('description')} /></Field>
        <label className="check"><input type="checkbox" checked={f.active} onChange={set('active')} />Activo (aparece al registrar pedidos)</label>
      </div>
      <div>
        <h3 style={{ marginBottom: 8 }}>Presentaciones</h3>
        <div className="lines">
          <div className="line line-head" style={{ gridTemplateColumns: 'minmax(0,2fr) 110px 110px 90px 36px' }}><div>Nombre</div><div>Contenido ({f.base_unit})</div><div>Precio</div><div className="tot">Margen</div><div /></div>
          {variants.map((v, i) => {
            const m = cost != null && Number(v.price) > 0 ? (Number(v.price) - cost * Number(v.pack_qty || 0)) / Number(v.price) : null
            return (
              <div className="line" key={v.id ?? v.key} style={{ gridTemplateColumns: 'minmax(0,2fr) 110px 110px 90px 36px' }}>
                <input value={v.label} onChange={(e) => updV(i, { label: e.target.value })} placeholder="Bolsa 5 kg" aria-label="Nombre de presentación" />
                <input type="number" min="0.001" step="any" value={v.pack_qty} onChange={(e) => updV(i, { pack_qty: e.target.value })} aria-label="Contenido" />
                <input type="number" min="0" step="any" value={v.price} onChange={(e) => updV(i, { price: e.target.value })} aria-label="Precio" />
                <div className="tot" style={{ color: m !== null && m < 0.2 ? 'var(--danger)' : undefined }}>{m !== null ? pct(m) : '—'}</div>
                <button type="button" className="btn ghost sm" onClick={() => setVariants(variants.filter((_, j) => j !== i))} aria-label="Quitar"><Icon name="x" /></button>
              </div>
            )
          })}
          <div className="line" style={{ display: 'block' }}><button type="button" className="btn sm" onClick={() => setVariants([...variants, { key: Math.random(), label: '', pack_qty: 1, price: '', active: true }])}><Icon name="plus" />Agregar presentación</button></div>
        </div>
      </div>
      <ErrorBox msg={err} />
    </Modal>
  )
}
