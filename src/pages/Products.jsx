import { useEffect, useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { useLoad } from '../lib/hooks'
import { loadSuppliers, uploadProductImage } from '../lib/data'
import { L, money, options, pct, qty } from '../lib/format'
import BundlesPanel from './Bundles'
import { Badge, DeleteButton, Empty, ErrorBox, Field, Icon, Loading, Modal, Select, Seg, useToast } from '../components/ui'

const VGRID = 'minmax(0,2fr) 100px 100px 70px 50px 50px 36px'

export default function Products() {
  const [view, setView] = useState('active')
  const [editing, setEditing] = useState(null)
  const { data, error, loading, reload } = useLoad(async () => {
    const [products, stock] = await Promise.all([
      q(supabase.from('products').select('*, product_variants(*), supplier:suppliers(name)').order('name')),
      q(supabase.from('v_stock').select('product_id, on_hand, needs_reorder')),
    ])
    const s = Object.fromEntries(stock.map((x) => [x.product_id, x]))
    return products.map((p) => ({ ...p, on_hand: s[p.id]?.on_hand ?? 0, low: s[p.id]?.needs_reorder, product_variants: p.product_variants.sort((a, b) => a.pack_qty - b.pack_qty) }))
  })
  const rows = (data || []).filter((p) => view === 'all' || (view === 'active' ? p.active : !p.active))

  return (
    <>
      <div className="page-head">
        <div><h1>Productos</h1><p>Paquetes, catálogo, presentaciones, precios y costos.</p></div>
        <button className="btn primary" onClick={() => setEditing({})}><Icon name="plus" />Nuevo producto</button>
      </div>
      <BundlesPanel />
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
                    <td><div className="inline" style={{ alignItems: 'flex-start' }}>{p.image_url && <img src={p.image_url} alt="" width="40" height="40" style={{ borderRadius: 6, objectFit: 'cover', flex: 'none' }} />}<div><b>{p.name}</b> {!p.active && <Badge cls="b-mute">Inactivo</Badge>}{p.active && !p.visible && <Badge cls="b-mute">Oculto en tienda</Badge>}<div className="sub">{L.category[p.category]}</div></div></div></td>
                    <td>
                      {p.product_variants.length === 0 ? <span className="muted">Sin presentaciones: no se puede vender</span> :
                        p.product_variants.map((v) => {
                          const m = p.unit_cost != null && v.price > 0 ? (v.price - p.unit_cost * v.pack_qty) / v.price : null
                          return <div key={v.id} style={{ opacity: v.active && v.visible ? 1 : .5 }}>{v.label}: <b>{money(v.price)}</b> <span className="sub">{m !== null ? `margen ${pct(m)}` : ''}{v.active && !v.visible ? ' · oculta' : ''}{!v.subscribable ? ' · sin suscripción' : ''}</span></div>
                        })}
                    </td>
                    <td className="num">{p.unit_cost != null ? `${money(p.unit_cost)}/${p.base_unit}` : <Badge cls="b-warn">Sin costo</Badge>}</td>
                    <td className="num" style={{ color: p.low ? 'var(--danger)' : undefined }}>{qty(p.on_hand)} {p.base_unit}</td>
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

const blank = { name: '', category: 'cloro', base_unit: 'kg', unit_cost: '', reorder_qty: '', supplier_id: '', description: '', active: true, visible: true, image_url: null }
const newVariant = () => ({ key: Math.random(), label: '', pack_qty: 1, price: '', active: true, visible: true, subscribable: true })

function ProductForm({ product, onClose, onSaved }) {
  const [f, setF] = useState(() => {
    const p = { ...blank, ...(product || {}) }
    for (const k of ['unit_cost', 'reorder_qty', 'supplier_id', 'description']) p[k] = p[k] ?? ''
    return p
  })
  const [variants, setVariants] = useState(product?.product_variants?.map((v) => ({ ...v })) || [newVariant()])
  const [suppliers, setSuppliers] = useState([])
  const [err, setErr] = useState(null)
  const [busy, setBusy] = useState(false)
  const [photo, setPhoto] = useState(null)          // { file, preview } chosen but not uploaded yet
  const [bigChanges, setBigChanges] = useState(null) // price edits over ±30% waiting for confirmation
  const toast = useToast()
  useEffect(() => () => photo && URL.revokeObjectURL(photo.preview), [photo])
  useEffect(() => { loadSuppliers().then(setSuppliers).catch(() => {}) }, [])
  const set = (k) => (e) => setF({ ...f, [k]: e?.target ? (e.target.type === 'checkbox' ? e.target.checked : e.target.value) : e })
  const updV = (i, patch) => setVariants(variants.map((v, j) => (j === i ? { ...v, ...patch } : v)))
  const num = (v) => (v === '' || v === null ? null : Number(v))

  const save = async (confirmed = false) => {
    if (!f.name.trim()) { setErr('Escribe el nombre del producto.'); return }
    const vs = variants.filter((v) => v.label.trim() || v.price !== '')
    if (vs.some((v) => !v.label.trim() || v.price === '' || !(Number(v.pack_qty) > 0))) { setErr('Cada presentación necesita nombre, contenido mayor a 0 y precio.'); return }
    // Guard against typos like 5000 instead of 500: saved cards are charged catalog prices.
    const big = vs.filter((v) => v.id).map((v) => ({ v, old: Number(product.product_variants.find((o) => o.id === v.id)?.price) }))
      .filter(({ v, old }) => old > 0 && Math.abs(Number(v.price) - old) / old > 0.3)
    if (big.length && !confirmed) { setBigChanges(big); setErr(null); return }
    setBigChanges(null); setBusy(true); setErr(null)
    const row = { name: f.name.trim(), category: f.category, base_unit: f.base_unit, unit_cost: num(f.unit_cost), reorder_qty: num(f.reorder_qty), supplier_id: num(f.supplier_id), description: f.description.trim() || null, active: f.active, visible: f.visible, image_url: f.image_url || null }
    try {
      let id = product?.id
      if (id) await q(supabase.from('products').update(row).eq('id', id))
      else id = (await q(supabase.from('products').insert(row).select('id').single())).id
      if (photo) {
        try { await q(supabase.from('products').update({ image_url: await uploadProductImage(photo.file, id) }).eq('id', id)) }
        catch (e) { toast(e.message, true) }
      }
      const keep = new Set(vs.filter((v) => v.id).map((v) => v.id))
      for (const old of product?.product_variants || []) {
        if (!keep.has(old.id)) {
          try { await q(supabase.from('product_variants').delete().eq('id', old.id)) }
          catch { await q(supabase.from('product_variants').update({ active: false }).eq('id', old.id)); toast(`"${old.label}" ya tiene ventas: se desactivó en lugar de borrarse`) }
        }
      }
      for (const v of vs) {
        const vr = { label: v.label.trim(), pack_qty: Number(v.pack_qty), price: Number(v.price), active: v.active, visible: v.visible !== false, subscribable: v.subscribable !== false }
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
  const largest = Math.max(0, ...variants.filter((v) => v.active !== false && Number(v.pack_qty) > 0).map((v) => Number(v.pack_qty))) || null
  return (
    <Modal wide title={product ? product.name : 'Nuevo producto'} onClose={onClose}
      footer={<><div>{product && <DeleteButton onConfirm={remove} />}</div><div className="actions"><button className="btn" onClick={onClose}>Cancelar</button><button className="btn primary" onClick={() => save(false)} disabled={busy}>Guardar producto</button></div></>}>
      <div className="form-grid">
        <Field label="Nombre" className="full"><input value={f.name} onChange={set('name')} placeholder="Cloro granular" autoFocus /></Field>
        <Field label="Categoría"><Select value={f.category} onChange={set('category')} options={options(L.category)} /></Field>
        <Field label="Unidad de inventario" hint="El inventario y el costo se llevan en esta unidad"><Select value={f.base_unit} onChange={set('base_unit')} options={options(L.unit)} /></Field>
        <Field label={`Costo por ${f.base_unit}`} hint="Se actualiza solo con cada compra (costo promedio)"><input type="number" min="0" step="any" inputMode="decimal" value={f.unit_cost} onChange={set('unit_cost')} /></Field>
        <Field label="Proveedor habitual"><Select value={f.supplier_id} onChange={set('supplier_id')} placeholder="—" options={suppliers.map((s) => ({ value: s.id, label: s.name }))} /></Field>
        <Field label={`Cantidad a comprar al reabastecer (${f.base_unit})`} hint="Opcional. Vacío = se sugiere con base en las ventas del último mes"><input type="number" min="0" step="any" inputMode="decimal" value={f.reorder_qty} onChange={set('reorder_qty')} /></Field>
        <div className="field" style={{ alignSelf: 'end' }}><small>La alerta de reabastecimiento sale cuando lo que queda (descontando las suscripciones próximas) alcanza solo para la presentación más grande{largest ? `: ${largest} ${f.base_unit}` : ''}.</small></div>
        <Field label="Descripción / modo de uso" className="full"><textarea value={f.description} onChange={set('description')} /></Field>
        <label className="check"><input type="checkbox" checked={f.active} onChange={set('active')} />Activo (aparece al registrar pedidos)</label>
        <label className="check"><input type="checkbox" checked={f.visible} onChange={set('visible')} disabled={!f.active} />Visible en la tienda en línea</label>
        <div className="field full">
          <span>Foto</span>
          <div className="inline" style={{ alignItems: 'center' }}>
            {(photo?.preview || f.image_url)
              ? <img src={photo?.preview || f.image_url} alt="" width="72" height="72" style={{ borderRadius: 8, objectFit: 'cover', border: '1px solid var(--line)' }} />
              : <div className="muted" style={{ width: 72, height: 72, borderRadius: 8, border: '1px dashed var(--line-strong)', display: 'grid', placeItems: 'center', fontSize: 12 }}>Sin foto</div>}
            <label className="btn sm" style={{ cursor: 'pointer' }}>
              <input type="file" accept="image/*" hidden aria-label="Elegir foto" onChange={(e) => { const file = e.target.files?.[0]; if (file) setPhoto({ file, preview: URL.createObjectURL(file) }) }} />
              {f.image_url || photo ? 'Cambiar foto' : 'Subir foto'}
            </label>
            {(f.image_url || photo) && <button type="button" className="btn sm ghost" onClick={() => { setPhoto(null); setF({ ...f, image_url: null }) }}>Quitar</button>}
          </div>
          <small>Cuadrada de preferencia. Se reduce sola antes de subirla; se guarda al dar Guardar.</small>
        </div>
      </div>
      <div>
        <h3 style={{ marginBottom: 8 }}>Presentaciones</h3>
        <div className="lines">
          <div className="line line-head" style={{ gridTemplateColumns: VGRID }}><div>Nombre</div><div>Contenido ({f.base_unit})</div><div>Precio</div><div className="tot">Margen</div><div title="Se muestra en la tienda">Tienda</div><div title="Se puede pedir por suscripción">Suscr.</div><div /></div>
          {variants.map((v, i) => {
            const m = cost != null && Number(v.price) > 0 ? (Number(v.price) - cost * Number(v.pack_qty || 0)) / Number(v.price) : null
            return (
              <div className="line" key={v.id ?? v.key} style={{ gridTemplateColumns: VGRID }}>
                <input value={v.label} onChange={(e) => updV(i, { label: e.target.value })} placeholder="Bolsa 5 kg" aria-label="Nombre de presentación" />
                <input type="number" min="0.001" step="any" value={v.pack_qty} onChange={(e) => updV(i, { pack_qty: e.target.value })} aria-label="Contenido" />
                <input type="number" min="0" step="any" value={v.price} onChange={(e) => updV(i, { price: e.target.value })} aria-label="Precio" />
                <div className="tot" style={{ color: m !== null && m < 0.2 ? 'var(--danger)' : undefined }}>{m !== null ? pct(m) : '—'}</div>
                <input type="checkbox" checked={v.visible !== false} onChange={(e) => updV(i, { visible: e.target.checked })} aria-label={`${v.label || 'Presentación'}: visible en la tienda`} />
                <input type="checkbox" checked={v.subscribable !== false} onChange={(e) => updV(i, { subscribable: e.target.checked })} aria-label={`${v.label || 'Presentación'}: disponible por suscripción`} />
                <button type="button" className="btn ghost sm" onClick={() => setVariants(variants.filter((_, j) => j !== i))} aria-label="Quitar"><Icon name="x" /></button>
              </div>
            )
          })}
          <div className="line" style={{ display: 'block' }}><button type="button" className="btn sm" onClick={() => setVariants([...variants, newVariant()])}><Icon name="plus" />Agregar presentación</button></div>
        </div>
      </div>
      <p className="muted" style={{ fontSize: 13.5 }}>Si cambias un precio, los suscriptores reciben un aviso por correo y el precio nuevo les aplica en entregas con al menos el aviso configurado en Ajustes.</p>
      {bigChanges && (
        <div className="note" role="alert">
          <b>¿Seguro? Estos precios cambian más de 30%:</b>
          <ul style={{ margin: '6px 0 10px' }}>{bigChanges.map(({ v, old }) => <li key={v.id}>{v.label}: {money(old)} → <b>{money(v.price)}</b></li>)}</ul>
          <div className="actions"><button className="btn primary" onClick={() => save(true)} disabled={busy}>Sí, guardar estos precios</button><button className="btn" onClick={() => setBigChanges(null)}>Revisar</button></div>
        </div>
      )}
      <ErrorBox msg={err} />
    </Modal>
  )
}
