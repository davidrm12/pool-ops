import { useEffect, useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { L, digits, options } from '../lib/format'
import { DeleteButton, ErrorBox, Field, Modal, Select, useToast } from './ui'

const blank = { name: '', phone: '', email: '', address: '', zone: '', postal_code: '', address_notes: '', customer_type: 'residential', status: 'customer', source: '', whatsapp_opt_in: true, notes: '' }

export default function CustomerForm({ customer, onClose, onSaved }) {
  const [f, setF] = useState({ ...blank, ...(customer || {}) })
  const [err, setErr] = useState(null)
  const [busy, setBusy] = useState(false)
  const toast = useToast()
  // Lists pass rows from views that predate newer columns (postal code): read the real row.
  useEffect(() => {
    if (!customer?.id) return
    q(supabase.from('customers').select('*').eq('id', customer.id).single()).then((c) => setF((x) => ({ ...x, ...c }))).catch(() => {})
  }, [customer?.id])
  const set = (k) => (e) => setF({ ...f, [k]: e?.target ? (e.target.type === 'checkbox' ? e.target.checked : e.target.value) : e })

  const save = async (e) => {
    e?.preventDefault()
    if (!f.name.trim()) { setErr('Escribe el nombre.'); return }
    let d = digits(f.phone)
    if (d.length === 13 && d.startsWith('521')) d = d.slice(3)
    else if (d.length === 12 && d.startsWith('52')) d = d.slice(2)
    if (f.phone && d.length !== 10) { setErr('El teléfono debe tener 10 dígitos (sin 52 ni 044).'); return }
    const zip = digits(f.postal_code)
    if (zip && zip.length !== 5) { setErr('El código postal tiene 5 dígitos.'); return }
    setBusy(true); setErr(null)
    const row = {
      name: f.name.trim(), phone: d || null, postal_code: zip || null, email: f.email.trim() || null, address: f.address.trim() || null,
      zone: f.zone.trim() || null, address_notes: f.address_notes.trim() || null, customer_type: f.customer_type,
      status: f.status, source: f.source.trim() || null, whatsapp_opt_in: f.whatsapp_opt_in, notes: f.notes.trim() || null,
    }
    try {
      const saved = customer?.id
        ? await q(supabase.from('customers').update(row).eq('id', customer.id).select().single())
        : await q(supabase.from('customers').insert(row).select().single())
      toast(customer?.id ? 'Cliente actualizado' : 'Cliente agregado')
      onSaved(saved)
    } catch (e2) { setErr(e2.message); setBusy(false) }
  }
  const remove = async () => {
    try { await q(supabase.from('customers').delete().eq('id', customer.id)); toast('Cliente eliminado'); onSaved(null) }
    catch (e2) { setErr(e2.message.includes('No se puede borrar') ? 'Este cliente tiene pedidos o suscripciones. Cámbialo a "Inactivo" en lugar de borrarlo.' : e2.message) }
  }

  return (
    <Modal title={customer?.id ? 'Editar cliente' : 'Nuevo cliente'} onClose={onClose}
      footer={<>
        <div>{customer?.id && <DeleteButton onConfirm={remove} />}</div>
        <div className="actions"><button className="btn" onClick={onClose}>Cancelar</button><button className="btn primary" onClick={save} disabled={busy}>Guardar cliente</button></div>
      </>}>
      <form className="form-grid" onSubmit={save}>
        <Field label="Nombre" className="full"><input value={f.name} onChange={set('name')} autoFocus /></Field>
        <Field label="WhatsApp / teléfono" hint="10 dígitos"><input type="tel" inputMode="tel" value={f.phone || ''} onChange={set('phone')} /></Field>
        <Field label="Correo"><input type="email" value={f.email || ''} onChange={set('email')} /></Field>
        <Field label="Dirección" className="full"><input value={f.address || ''} onChange={set('address')} placeholder="Calle, número" /></Field>
        <Field label="Colonia / fraccionamiento"><input value={f.zone || ''} onChange={set('zone')} /></Field>
        <Field label="Código postal" hint="Define el costo de envío de la tienda"><input inputMode="numeric" maxLength={5} value={f.postal_code || ''} onChange={set('postal_code')} /></Field>
        <Field label="Referencias"><input value={f.address_notes || ''} onChange={set('address_notes')} placeholder="Portón negro, clave de acceso…" /></Field>
        <Field label="Tipo"><Select value={f.customer_type} onChange={set('customer_type')} options={options(L.customerType)} /></Field>
        <Field label="Estatus"><Select value={f.status} onChange={set('status')} options={options(L.customerStatus)} /></Field>
        <Field label="¿Cómo nos conoció?"><input value={f.source || ''} onChange={set('source')} placeholder="Vecino, referido, web…" /></Field>
        <label className="check" style={{ alignSelf: 'end', paddingBottom: 8 }}><input type="checkbox" checked={f.whatsapp_opt_in} onChange={set('whatsapp_opt_in')} />Acepta recordatorios por WhatsApp</label>
        <Field label="Notas" className="full"><textarea value={f.notes || ''} onChange={set('notes')} /></Field>
        <button type="submit" hidden />
      </form>
      <ErrorBox msg={err} />
    </Modal>
  )
}
