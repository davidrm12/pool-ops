import { useEffect, useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { loadBundles, loadVariants, uploadProductImage } from '../lib/data'
import { money } from '../lib/format'
import { Badge, DeleteButton, ErrorBox, Field, Icon, Loading, Modal, useToast } from '../components/ui'
import LinesEditor, { validLines } from '../components/LinesEditor'

const SUGGESTED_PCT = 10

// Bundles (paquetes): fixed contents at a fixed price, shown first in the store.
export default function BundlesPanel() {
  const [rows, setRows] = useState(null)
  const [variants, setVariants] = useState([])
  const [editing, setEditing] = useState(null)
  const [err, setErr] = useState(null)
  const reload = () => Promise.all([loadBundles(), loadVariants({ includeInactive: true })])
    .then(([b, v]) => { setRows(b); setVariants(v) }).catch((e) => setErr(e.message))
  useEffect(() => { reload() }, [])

  const byId = Object.fromEntries(variants.map((v) => [v.id, v]))
  const regular = (b) => b.bundle_items.reduce((s, i) => s + i.qty * Number(byId[i.variant_id]?.price || 0), 0)

  return (
    <section className="panel" style={{ marginBottom: 16 }}>
      <div className="panel-head">
        <h2>Paquetes</h2>
        <button className="btn sm" onClick={() => setEditing({})}><Icon name="plus" />Nuevo paquete</button>
      </div>
      <ErrorBox msg={err} />
      {!rows ? <Loading /> : rows.length === 0 ? (
        <div className="panel-body muted" style={{ fontSize: 13.5 }}>Arma combinaciones fijas con descuento (por ejemplo, cloro + clarificador). Aparecen arriba en la tienda y se pueden comprar una vez o por suscripción.</div>
      ) : (
        <div className="table-wrap">
          <table>
            <thead><tr><th>Paquete</th><th>Contenido</th><th className="num">Precio normal</th><th className="num">Precio</th><th className="num">Ahorro</th></tr></thead>
            <tbody>{rows.map((b) => {
              const r = regular(b)
              const broken = b.bundle_items.some((i) => byId[i.variant_id] && !(byId[i.variant_id].active && byId[i.variant_id].product.active))
              return (
                <tr key={b.id} className="click" onClick={() => setEditing(b)} tabIndex={0} onKeyDown={(e) => e.key === 'Enter' && setEditing(b)}>
                  <td><b>{b.name}</b> {!b.active && <Badge cls="b-mute">Inactivo</Badge>}{b.active && !b.visible && <Badge cls="b-mute">Oculto en tienda</Badge>}{broken && <Badge cls="b-bad">Tiene un producto inactivo</Badge>}{!b.subscribable && <div className="sub">Sin suscripción</div>}</td>
                  <td>{b.bundle_items.map((i) => `${i.qty} × ${byId[i.variant_id]?.name ?? '—'}`).join(', ')}</td>
                  <td className="num">{money(r)}</td>
                  <td className="num"><b>{money(b.price)}</b></td>
                  <td className="num">{r > 0 ? `${Math.round((1 - b.price / r) * 100)}%` : '—'}</td>
                </tr>
              )
            })}</tbody>
          </table>
        </div>
      )}
      {editing && <BundleForm bundle={editing.id ? editing : null} variants={variants.filter((v) => v.active && v.product.active)} allVariants={byId}
        onClose={() => setEditing(null)} onSaved={() => { setEditing(null); reload() }} />}
    </section>
  )
}

function BundleForm({ bundle, variants, allVariants, onClose, onSaved }) {
  const toast = useToast()
  const [f, setF] = useState(() => ({ name: bundle?.name ?? '', description: bundle?.description ?? '', price: bundle?.price ?? '', active: bundle?.active ?? true,
    visible: bundle?.visible ?? true, subscribable: bundle?.subscribable ?? true, sort: bundle?.sort ?? 0, image_url: bundle?.image_url ?? null }))
  const [lines, setLines] = useState(() => bundle?.bundle_items?.map((i) => ({ key: i.variant_id, variant_id: i.variant_id, qty: i.qty })) ?? [{ key: 1, variant_id: '', qty: 1 }])
  const [photo, setPhoto] = useState(null)
  const [confirmBig, setConfirmBig] = useState(false)
  const [err, setErr] = useState(null)
  const [busy, setBusy] = useState(false)
  const set = (k) => (e) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value })

  const good = validLines(lines)
  const regular = good.reduce((s, l) => s + Number(l.qty) * Number(allVariants[l.variant_id]?.price || 0), 0)
  // Either the % drives the price (new bundles start at the suggested %, and the price follows
  // as products are added) or a typed price is kept as is.
  const [pctInput, setPctInput] = useState(bundle ? null : String(SUGGESTED_PCT))
  const price = pctInput !== null ? (regular > 0 && pctInput !== '' ? String(Math.round(regular * (1 - Number(pctInput) / 100))) : '') : String(f.price)
  const pct = pctInput !== null ? pctInput : (regular > 0 && Number(f.price) > 0 ? String(Math.round((1 - Number(f.price) / regular) * 1000) / 10) : '')

  const save = async (confirmed = false) => {
    if (!f.name.trim()) { setErr('Escribe el nombre del paquete.'); return }
    if (!good.length) { setErr('Agrega al menos un producto.'); return }
    if (new Set(good.map((l) => String(l.variant_id))).size !== good.length) { setErr('Hay un producto repetido; junta las cantidades en un solo renglón.'); return }
    if (good.some((l) => !Number.isInteger(Number(l.qty)))) { setErr('Las cantidades del paquete deben ser enteras.'); return }
    if (!(Number(price) > 0)) { setErr('Escribe el precio del paquete.'); return }
    if (Number(price) > regular) { setErr(`El precio del paquete (${money(price)}) no puede ser mayor que comprar los productos por separado (${money(regular)}).`); return }
    const old = Number(bundle?.price)
    if (old > 0 && Math.abs(Number(price) - old) / old > 0.3 && !confirmed) { setConfirmBig(true); return }
    setBusy(true); setErr(null); setConfirmBig(false)
    const row = { name: f.name.trim(), description: f.description.trim() || null, price: Number(price), active: f.active, visible: f.visible,
      subscribable: f.subscribable, sort: Number(f.sort) || 0, image_url: f.image_url || null }
    try {
      let id = bundle?.id
      if (id) await q(supabase.from('bundles').update(row).eq('id', id))
      else id = (await q(supabase.from('bundles').insert(row).select('id').single())).id
      if (photo) {
        try { await q(supabase.from('bundles').update({ image_url: await uploadProductImage(photo.file, id, 'b') }).eq('id', id)) } catch (e) { toast(e.message, true) }
      }
      await q(supabase.from('bundle_items').delete().eq('bundle_id', id))
      await q(supabase.from('bundle_items').insert(good.map((l) => ({ bundle_id: id, variant_id: Number(l.variant_id), qty: Number(l.qty) }))))
      toast(bundle ? 'Paquete actualizado' : 'Paquete creado')
      onSaved()
    } catch (e) { setErr(e.message); setBusy(false) }
  }
  const remove = async () => {
    try { await q(supabase.from('bundles').delete().eq('id', bundle.id)); toast('Paquete eliminado'); onSaved() }
    catch { setErr('Este paquete ya se vendió o está en suscripciones. Desmarca "Activo" para retirarlo.') }
  }

  return (
    <Modal wide title={bundle ? bundle.name : 'Nuevo paquete'} onClose={onClose}
      footer={<><div>{bundle && <DeleteButton onConfirm={remove} />}</div><div className="actions"><button className="btn" onClick={onClose}>Cancelar</button><button className="btn primary" onClick={() => save(false)} disabled={busy}>Guardar paquete</button></div></>}>
      <div className="form-grid">
        <Field label="Nombre" className="full"><input value={f.name} onChange={set('name')} placeholder="Paquete inicio de temporada" autoFocus /></Field>
        <Field label="Descripción" className="full"><textarea value={f.description} onChange={set('description')} placeholder="Para qué sirve y para qué tamaño de alberca alcanza" /></Field>
      </div>
      <div><h3 style={{ marginBottom: 8 }}>Contenido</h3><LinesEditor lines={lines} setLines={setLines} variants={variants} showPrice={false} /></div>
      <div className="form-grid">
        <Field label="Precio por separado"><input value={money(regular)} disabled /></Field>
        <Field label="Descuento (%)" hint={`Sugerido: ${SUGGESTED_PCT}%`}><input type="number" min="0" max="90" step="any" value={pct} onChange={(e) => setPctInput(e.target.value)} /></Field>
        <Field label="Precio del paquete ($)" hint="Precio fijo. Si cambian los precios de los productos, este no cambia."><input type="number" min="1" step="any" value={price} onChange={(e) => { setPctInput(null); setF({ ...f, price: e.target.value }) }} /></Field>
        <Field label="Orden en la tienda" hint="Menor = más arriba"><input type="number" value={f.sort} onChange={set('sort')} /></Field>
        <label className="check"><input type="checkbox" checked={f.active} onChange={set('active')} />Activo</label>
        <label className="check"><input type="checkbox" checked={f.visible} onChange={set('visible')} disabled={!f.active} />Visible en la tienda</label>
        <label className="check"><input type="checkbox" checked={f.subscribable} onChange={set('subscribable')} />Disponible por suscripción</label>
        <div className="field full">
          <span>Foto</span>
          <div className="inline" style={{ alignItems: 'center' }}>
            {(photo?.preview || f.image_url)
              ? <img src={photo?.preview || f.image_url} alt="" width="72" height="72" style={{ borderRadius: 8, objectFit: 'cover', border: '1px solid var(--line)' }} />
              : <div className="muted" style={{ width: 72, height: 72, borderRadius: 8, border: '1px dashed var(--line-strong)', display: 'grid', placeItems: 'center', fontSize: 12 }}>Sin foto</div>}
            <label className="btn sm" style={{ cursor: 'pointer' }}>
              <input type="file" accept="image/*" hidden aria-label="Elegir foto del paquete" onChange={(e) => { const file = e.target.files?.[0]; if (file) setPhoto({ file, preview: URL.createObjectURL(file) }) }} />
              {f.image_url || photo ? 'Cambiar foto' : 'Subir foto'}
            </label>
            {(f.image_url || photo) && <button type="button" className="btn sm ghost" onClick={() => { setPhoto(null); setF({ ...f, image_url: null }) }}>Quitar</button>}
          </div>
        </div>
      </div>
      <p className="muted" style={{ fontSize: 13.5 }}>Los suscriptores también reciben el descuento de suscripción (Ajustes) sobre el precio del paquete. Si desactivas el paquete o alguno de sus productos, se quita de las suscripciones y se avisa al cliente.</p>
      {confirmBig && (
        <div className="note" role="alert">
          <b>¿Seguro? El precio cambia más de 30%:</b> {money(bundle.price)} → <b>{money(price)}</b>
          <div className="actions" style={{ marginTop: 8 }}><button className="btn primary" onClick={() => save(true)} disabled={busy}>Sí, guardar este precio</button><button className="btn" onClick={() => setConfirmBig(false)}>Revisar</button></div>
        </div>
      )}
      <ErrorBox msg={err} />
    </Modal>
  )
}
