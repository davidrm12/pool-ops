import { useEffect, useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { useLoad } from '../lib/hooks'
import { loadProducts, loadSuppliers } from '../lib/data'
import { date, money, money2, phoneFmt, qty, today } from '../lib/format'
import { Combo, DeleteButton, Empty, ErrorBox, Field, Icon, Loading, Modal, Select, Tabs, useToast } from '../components/ui'

export default function Purchases() {
  const [tab, setTab] = useState('purchases')
  const [editing, setEditing] = useState(null)
  const [editingSup, setEditingSup] = useState(null)
  const purchases = useLoad(() => q(supabase.from('purchases')
    .select('*, supplier:suppliers(name), purchase_items(id, qty, unit_cost, product:products(name, base_unit))')
    .order('purchase_date', { ascending: false }).limit(300)))
  const suppliers = useLoad(loadSuppliers)

  return (
    <>
      <div className="page-head">
        <div><h1>Compras</h1><p>Cada compra suma inventario y actualiza el costo promedio del producto.</p></div>
        {tab === 'purchases'
          ? <button className="btn primary" onClick={() => setEditing({})}><Icon name="plus" />Registrar compra</button>
          : <button className="btn primary" onClick={() => setEditingSup({})}><Icon name="plus" />Nuevo proveedor</button>}
      </div>
      <Tabs value={tab} onChange={setTab} tabs={[{ value: 'purchases', label: 'Compras' }, { value: 'suppliers', label: 'Proveedores' }]} />

      {tab === 'purchases' ? (
        <div className="panel">
          <ErrorBox msg={purchases.error} />
          {purchases.loading ? <Loading /> : !purchases.data?.length ? (
            <Empty text="Registra la primera compra para empezar a llevar inventario y costos." action={<button className="btn primary" onClick={() => setEditing({})}>Registrar compra</button>} />
          ) : (
            <div className="table-wrap">
              <table>
                <thead><tr><th>Fecha</th><th>Proveedor</th><th>Productos</th><th className="num">Envío</th><th className="num">Total</th></tr></thead>
                <tbody>{purchases.data.map((p) => {
                  const goods = p.purchase_items.reduce((s, i) => s + i.qty * i.unit_cost, 0)
                  return (
                    <tr key={p.id} className="click" onClick={() => setEditing(p)} tabIndex={0} onKeyDown={(e) => e.key === 'Enter' && setEditing(p)}>
                      <td style={{ whiteSpace: 'nowrap' }}>{date(p.purchase_date)}</td>
                      <td>{p.supplier?.name || <span className="muted">—</span>}{p.invoice_ref && <div className="sub">Factura {p.invoice_ref}</div>}</td>
                      <td>{p.purchase_items.map((i) => `${qty(i.qty)} ${i.product.base_unit} ${i.product.name}`).join(', ')}</td>
                      <td className="num">{money(p.shipping_cost)}</td>
                      <td className="num"><b>{money(goods + Number(p.shipping_cost))}</b></td>
                    </tr>
                  )
                })}</tbody>
              </table>
            </div>
          )}
        </div>
      ) : (
        <div className="panel">
          {suppliers.loading ? <Loading /> : !suppliers.data?.length ? <Empty text="Sin proveedores todavía." /> : (
            <div className="table-wrap">
              <table>
                <thead><tr><th>Proveedor</th><th>Tienda en línea</th><th>Teléfono</th><th className="hide-sm">Notas</th></tr></thead>
                <tbody>{suppliers.data.map((s) => (
                  <tr key={s.id} className="click" onClick={() => setEditingSup(s)} tabIndex={0} onKeyDown={(e) => e.key === 'Enter' && setEditingSup(s)}>
                    <td><b>{s.name}</b>{!s.active && <div className="sub">Inactivo</div>}{s.contact_name && <div className="sub">{s.contact_name}</div>}</td><td>{s.website ? <a href={s.website} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()}>Abrir tienda</a> : '—'}</td><td>{phoneFmt(s.phone)}</td><td className="hide-sm muted">{s.notes}</td>
                  </tr>
                ))}</tbody>
              </table>
            </div>
          )}
        </div>
      )}
      {editing && <PurchaseForm purchase={editing.id ? editing : null} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); purchases.reload() }} />}
      {editingSup && <SupplierForm supplier={editingSup.id ? editingSup : null} onClose={() => setEditingSup(null)} onSaved={() => { setEditingSup(null); suppliers.reload() }} />}
    </>
  )
}

function PurchaseForm({ purchase, onClose, onSaved }) {
  const [f, setF] = useState({ supplier_id: purchase?.supplier_id ?? '', purchase_date: purchase?.purchase_date ?? today(), shipping_cost: purchase?.shipping_cost ?? 0, invoice_ref: purchase?.invoice_ref ?? '', notes: purchase?.notes ?? '' })
  const [items, setItems] = useState(purchase?.purchase_items ? [] : [{ key: 1, product_id: '', qty: '', unit_cost: '' }])
  const [products, setProducts] = useState([])
  const [suppliers, setSuppliers] = useState([])
  const [err, setErr] = useState(null)
  const [busy, setBusy] = useState(false)
  const toast = useToast()
  useEffect(() => {
    Promise.all([loadProducts(), loadSuppliers()]).then(([p, s]) => { setProducts(p); setSuppliers(s) })
    if (purchase) q(supabase.from('purchase_items').select('*').eq('purchase_id', purchase.id).order('id')).then((r) => setItems(r.map((i) => ({ ...i, key: i.id }))))
  }, [purchase])
  const set = (k) => (e) => setF({ ...f, [k]: e?.target ? e.target.value : e })
  const upd = (i, patch) => setItems(items.map((x, j) => (j === i ? { ...x, ...patch } : x)))
  const good = items.filter((i) => i.product_id && Number(i.qty) > 0 && i.unit_cost !== '')
  const total = good.reduce((s, i) => s + Number(i.qty) * Number(i.unit_cost), 0) + Number(f.shipping_cost || 0)

  const save = async () => {
    if (!good.length) { setErr('Agrega al menos un producto con cantidad y costo.'); return }
    setBusy(true); setErr(null)
    const row = { supplier_id: f.supplier_id ? Number(f.supplier_id) : null, purchase_date: f.purchase_date, shipping_cost: Number(f.shipping_cost) || 0, invoice_ref: f.invoice_ref.trim() || null, notes: f.notes.trim() || null }
    try {
      let id = purchase?.id
      if (id) await q(supabase.from('purchases').update(row).eq('id', id))
      else id = (await q(supabase.from('purchases').insert(row).select('id').single())).id
      const keep = new Set(good.filter((i) => i.id).map((i) => i.id))
      const old = purchase ? await q(supabase.from('purchase_items').select('id').eq('purchase_id', id)) : []
      const gone = old.filter((o) => !keep.has(o.id)).map((o) => o.id)
      if (gone.length) await q(supabase.from('purchase_items').delete().in('id', gone))
      for (const i of good) {
        const r = { product_id: Number(i.product_id), qty: Number(i.qty), unit_cost: Number(i.unit_cost) }
        if (i.id) await q(supabase.from('purchase_items').update(r).eq('id', i.id))
        else await q(supabase.from('purchase_items').insert({ ...r, purchase_id: id }))
      }
      toast(purchase ? 'Compra actualizada' : 'Compra registrada: inventario y costos actualizados')
      onSaved()
    } catch (e) { setErr(e.message); setBusy(false) }
  }
  const remove = async () => {
    try { await q(supabase.from('purchases').delete().eq('id', purchase.id)); toast('Compra eliminada'); onSaved() } catch (e) { setErr(e.message) }
  }
  const prodOpts = products.filter((p) => p.active).map((p) => ({ value: p.id, label: p.name, sub: `por ${p.base_unit}` }))

  return (
    <Modal wide title={purchase ? 'Editar compra' : 'Registrar compra'} onClose={onClose}
      footer={<><div>{purchase && <DeleteButton onConfirm={remove} />}</div><div className="actions"><button className="btn" onClick={onClose}>Cancelar</button><button className="btn primary" onClick={save} disabled={busy}>Guardar compra</button></div></>}>
      <div className="form-grid">
        <Field label="Proveedor"><Select value={f.supplier_id} onChange={set('supplier_id')} placeholder="—" options={suppliers.map((s) => ({ value: s.id, label: s.name }))} /></Field>
        <Field label="Fecha"><input type="date" value={f.purchase_date} onChange={set('purchase_date')} /></Field>
        <Field label="Costo de envío ($)" hint="Cuenta como gasto en el estado de resultados"><input type="number" min="0" step="any" value={f.shipping_cost} onChange={set('shipping_cost')} /></Field>
        <Field label="Factura / referencia"><input value={f.invoice_ref} onChange={set('invoice_ref')} /></Field>
      </div>
      <div className="lines">
        <div className="line line-head"><div>Producto</div><div>Cantidad</div><div>Costo unitario</div><div className="tot">Importe</div><div /></div>
        {items.map((i, idx) => {
          const p = products.find((x) => String(x.id) === String(i.product_id))
          return (
            <div className="line" key={i.key ?? i.id}>
              <Combo value={i.product_id} onChange={(v) => upd(idx, { product_id: v })} options={prodOpts} placeholder="Producto…" aria-label="Producto" />
              <input type="number" min="0" step="any" value={i.qty} onChange={(e) => upd(idx, { qty: e.target.value })} placeholder={p ? p.base_unit : ''} aria-label="Cantidad" />
              <input type="number" min="0" step="any" value={i.unit_cost} onChange={(e) => upd(idx, { unit_cost: e.target.value })} placeholder={p ? `$/${p.base_unit}` : ''} aria-label="Costo unitario" />
              <div className="tot">{money2((Number(i.qty) || 0) * (Number(i.unit_cost) || 0))}</div>
              <button type="button" className="btn ghost sm" onClick={() => setItems(items.filter((_, j) => j !== idx))} aria-label="Quitar"><Icon name="x" /></button>
            </div>
          )
        })}
        <div className="line" style={{ display: 'block' }}><button type="button" className="btn sm" onClick={() => setItems([...items, { key: Math.random(), product_id: '', qty: '', unit_cost: '' }])}><Icon name="plus" />Agregar producto</button></div>
      </div>
      <p className="muted" style={{ fontSize: 13.5 }}>Captura el costo por kg, L o pieza (ej. saco de 50 kg a $2,450 → cantidad 50, costo 49).</p>
      <Field label="Notas"><textarea value={f.notes} onChange={set('notes')} /></Field>
      <div className="totals"><span className="grand">Total</span><span className="grand right">{money2(total)}</span></div>
      <ErrorBox msg={err} />
    </Modal>
  )
}

function SupplierForm({ supplier, onClose, onSaved }) {
  const [f, setF] = useState({ name: '', contact_name: '', phone: '', email: '', website: '', notes: '', active: true, ...(supplier || {}) })
  const [err, setErr] = useState(null)
  const toast = useToast()
  const set = (k) => (e) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value })
  const save = async () => {
    if (!f.name?.trim()) { setErr('Escribe el nombre.'); return }
    const row = { name: f.name.trim(), contact_name: f.contact_name || null, phone: f.phone || null, email: f.email || null, website: f.website?.trim() ? (/^https?:\/\//.test(f.website.trim()) ? f.website.trim() : `https://${f.website.trim()}`) : null, notes: f.notes || null, active: f.active }
    try {
      if (supplier) await q(supabase.from('suppliers').update(row).eq('id', supplier.id))
      else await q(supabase.from('suppliers').insert(row))
      toast('Proveedor guardado'); onSaved()
    } catch (e) { setErr(e.message) }
  }
  const remove = async () => {
    try { await q(supabase.from('suppliers').delete().eq('id', supplier.id)); toast('Proveedor eliminado'); onSaved() } catch (e) { setErr(e.message) }
  }
  return (
    <Modal title={supplier ? 'Editar proveedor' : 'Nuevo proveedor'} onClose={onClose}
      footer={<><div>{supplier && <DeleteButton onConfirm={remove} />}</div><div className="actions"><button className="btn" onClick={onClose}>Cancelar</button><button className="btn primary" onClick={save}>Guardar proveedor</button></div></>}>
      <div className="form-grid">
        <Field label="Nombre" className="full"><input value={f.name} onChange={set('name')} autoFocus /></Field>
        <Field label="Contacto"><input value={f.contact_name || ''} onChange={set('contact_name')} /></Field>
        <Field label="Teléfono"><input type="tel" value={f.phone || ''} onChange={set('phone')} /></Field>
        <Field label="Correo"><input type="email" value={f.email || ''} onChange={set('email')} /></Field>
        <Field label="Tienda en línea" hint="Liga para hacer pedidos; aparece en las alertas"><input type="url" value={f.website || ''} onChange={set('website')} placeholder="https://…" /></Field>
        <Field label="Notas" className="full"><textarea value={f.notes || ''} onChange={set('notes')} placeholder="Tiempos de entrega, mínimos de compra…" /></Field>
        <label className="check"><input type="checkbox" checked={f.active} onChange={set('active')} />Activo</label>
      </div>
      <ErrorBox msg={err} />
    </Modal>
  )
}
