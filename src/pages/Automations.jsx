import { useEffect, useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { useLoad } from '../lib/hooks'
import { describeSend, sendReport } from '../lib/data'
import { WEEKDAYS, longDate } from '../lib/format'
import { Badge, Empty, ErrorBox, Field, Icon, Loading, useToast } from '../components/ui'

const JOBS = {
  subscriptions: 'Pedidos de suscripción',
  reorder_check: 'Revisión de inventario',
  route_requested: 'Ruta programada',
  route_email: 'Correo: ruta',
  reorder_email: 'Correo: reabastecer',
  weekly_email: 'Correo: resumen semanal',
  daily: 'Tarea diaria',
  charges: 'Cobros con tarjeta',
  outbox: 'Correos a clientes',
}

function describeRun(r) {
  const d = r.details || {}
  if (d.error) return d.error
  if (r.job === 'subscriptions') return d.orders_created ? `${d.orders_created} pedido(s) creados` : 'Nada que crear'
  if (r.job === 'reorder_check') return d.new_alerts ? `${d.new_alerts} producto(s) nuevos por reabastecer` : 'Sin alertas nuevas'
  if (r.job === 'route_requested') return `Ruta del ${longDate(d.date)}`
  if (r.job === 'charges') return d.attempted ? `${d.charged} cobrado(s), ${d.failed} rechazado(s), ${d.held} retenido(s)` : 'Nada que cobrar'
  if (r.job === 'outbox') return `${d.sent} correo(s)${d.failed ? `, ${d.failed} con error` : ''}`
  if (d.skipped) return d.skipped
  if (d.results) {
    const ok = d.results.filter((x) => x.ok).map((x) => x.email)
    const bad = d.results.filter((x) => !x.ok)
    return [d.subject, ok.length && `enviado a ${ok.join(', ')}`, bad.length && `falló: ${bad.map((x) => `${x.email} (${x.error})`).join(', ')}`].filter(Boolean).join('; ')
  }
  return ''
}

export default function Automations() {
  const toast = useToast()
  const st = useLoad(() => q(supabase.from('settings').select('*').single()))
  const rec = useLoad(() => q(supabase.from('alert_recipients').select('*').order('created_at')))
  const runs = useLoad(() => q(supabase.from('automation_runs').select('*').order('ran_at', { ascending: false }).limit(60)))
  const [f, setF] = useState(null)
  const [email, setEmail] = useState('')
  const [busy, setBusy] = useState(null)
  useEffect(() => { if (st.data) setF(st.data) }, [st.data])

  const toggleDay = (d) => {
    const has = f.delivery_weekdays.includes(d)
    const next = has ? f.delivery_weekdays.filter((x) => x !== d) : [...f.delivery_weekdays, d].sort()
    if (next.length) setF({ ...f, delivery_weekdays: next })
  }
  const saveSettings = async () => {
    try {
      await q(supabase.from('settings').update({
        delivery_weekdays: f.delivery_weekdays, lead_days: Number(f.lead_days),
        reorder_horizon_days: Number(f.reorder_horizon_days), unpaid_alert_days: Number(f.unpaid_alert_days),
      }).eq('id', true))
      toast('Ajustes guardados'); st.reload()
    } catch (e) { toast(e.message, true) }
  }
  const addEmail = async (e) => {
    e.preventDefault()
    try { await q(supabase.from('alert_recipients').insert({ email: email.trim().toLowerCase() })); setEmail(''); rec.reload(); toast('Correo agregado') }
    catch (e2) { toast(e2.message, true) }
  }
  const setActive = async (r, active) => { try { await q(supabase.from('alert_recipients').update({ active }).eq('id', r.id)); rec.reload() } catch (e) { toast(e.message, true) } }
  const remove = async (r) => { try { await q(supabase.from('alert_recipients').delete().eq('id', r.id)); rec.reload(); toast('Correo eliminado') } catch (e) { toast(e.message, true) } }
  const send = async (kind) => {
    setBusy(kind)
    try { toast(describeSend(await sendReport(kind))) } catch (e) { toast(e.message, true) }
    setBusy(null); runs.reload()
  }

  const days = f ? f.delivery_weekdays.map((d) => WEEKDAYS[d].toLowerCase()).join(' y ') : ''
  const routeDays = f ? f.delivery_weekdays.map((d) => WEEKDAYS[(d - f.lead_days + 70) % 7].toLowerCase()).join(' y ') : ''

  return (
    <>
      <div className="page-head">
        <div><h1>Ajustes</h1><p>Tienda en línea, cobros, calendario de reparto y lo que el sistema hace solo.</p></div>
      </div>

      {f && <StoreSettings initial={st.data} onSaved={st.reload} />}

      <div className="grid grid-2" style={{ marginBottom: 16 }}>
        <section className="panel">
          <div className="panel-head"><h2>Calendario de reparto</h2></div>
          {!f ? <Loading /> : (
            <div className="panel-body stack" style={{ gap: 14 }}>
              <div className="field">
                <span>Días de reparto</span>
                <div className="actions">
                  {WEEKDAYS.map((w, i) => (
                    <label key={w} className="check" style={{ border: '1px solid var(--line-strong)', borderRadius: 6, padding: '6px 10px', background: f.delivery_weekdays.includes(i) ? 'var(--water-pale)' : '#fff' }}>
                      <input type="checkbox" checked={f.delivery_weekdays.includes(i)} onChange={() => toggleDay(i)} />{w}
                    </label>
                  ))}
                </div>
                <small>Los pedidos nuevos y las suscripciones caen en estos días. Cualquier pedido se puede mover a otra fecha desde Entregas.</small>
              </div>
              <div className="form-grid">
                <Field label="Crear pedidos de suscripción" hint="Días antes de la entrega">
                  <input type="number" min="0" max="14" value={f.lead_days} onChange={(e) => setF({ ...f, lead_days: e.target.value })} />
                </Field>
                <Field label="Contar suscripciones próximas" hint="Días hacia adelante al revisar inventario">
                  <input type="number" min="0" max="60" value={f.reorder_horizon_days} onChange={(e) => setF({ ...f, reorder_horizon_days: e.target.value })} />
                </Field>
                <Field label="Avisar de entregas sin cobrar" hint="Después de cuántos días">
                  <input type="number" min="1" max="60" value={f.unpaid_alert_days} onChange={(e) => setF({ ...f, unpaid_alert_days: e.target.value })} />
                </Field>
              </div>
              <div><button className="btn primary" onClick={saveSettings}>Guardar ajustes</button></div>
            </div>
          )}
        </section>

        <section className="panel">
          <div className="panel-head"><h2>Qué corre y cuándo</h2></div>
          <ul className="list">
            <li><div><b>Todos los días, 7:00 a.m.</b><div className="muted" style={{ fontSize: 13.5 }}>Crea los pedidos de suscripción que se entregan dentro de {f?.lead_days ?? '…'} días y cobra los que se pagan con tarjeta guardada (un reintento al día siguiente si el banco lo rechaza). Luego revisa el inventario. Si un producto queda bajo, manda un correo (una sola vez hasta que se reabastezca).</div></div></li>
            <li><div><b>{routeDays ? routeDays[0].toUpperCase() + routeDays.slice(1) : '…'}, 7:00 a.m.</b><div className="muted" style={{ fontSize: 13.5 }}>Manda la hoja de ruta del {days || '…'}: qué cargar, paradas por zona, cuánto cobrar y si falta inventario.</div></div></li>
            <li><div><b>Lunes, 7:05 a.m.</b><div className="muted" style={{ fontSize: 13.5 }}>Resumen de la semana anterior: ventas, utilidad, entregas sin cobrar, clientes atrasados y productos por reabastecer.</div></div></li>
          </ul>
          <div className="panel-body" style={{ borderTop: '1px solid var(--line)' }}>
            <div style={{ fontWeight: 600, marginBottom: 8 }}>Enviar ahora</div>
            <div className="actions">
              <button className="btn sm" disabled={!!busy} onClick={() => send('route')}><Icon name="mail" />{busy === 'route' ? 'Enviando…' : 'Hoja de ruta'}</button>
              <button className="btn sm" disabled={!!busy} onClick={() => send('reorder')}><Icon name="mail" />{busy === 'reorder' ? 'Enviando…' : 'Reabastecer'}</button>
              <button className="btn sm" disabled={!!busy} onClick={() => send('weekly')}><Icon name="mail" />{busy === 'weekly' ? 'Enviando…' : 'Resumen semanal'}</button>
            </div>
          </div>
        </section>
      </div>

      <section className="panel" style={{ marginBottom: 16 }}>
        <div className="panel-head"><h2>Quién recibe los correos</h2></div>
        {rec.loading ? <Loading /> : (
          <ul className="list">
            {(rec.data || []).map((r) => (
              <li key={r.id}>
                <div className="inline">{r.email}{!r.active && <Badge cls="b-mute">Pausado</Badge>}</div>
                <div className="actions">
                  <button className="btn sm ghost" onClick={() => setActive(r, !r.active)}>{r.active ? 'Pausar' : 'Reactivar'}</button>
                  <button className="btn sm ghost danger" onClick={() => remove(r)} aria-label={`Eliminar ${r.email}`}><Icon name="trash" /></button>
                </div>
              </li>
            ))}
            <li>
              <form className="inline" style={{ width: '100%' }} onSubmit={addEmail}>
                <input type="email" required placeholder="correo@ejemplo.com" value={email} onChange={(e) => setEmail(e.target.value)} aria-label="Nuevo correo" />
                <button className="btn"><Icon name="plus" />Agregar</button>
              </form>
            </li>
          </ul>
        )}
        <div className="panel-body muted" style={{ fontSize: 13.5, borderTop: '1px solid var(--line)' }}>
          Mientras los correos salgan desde la dirección de prueba de Resend, solo llegan al correo dueño de la cuenta de Resend. Para enviar a más personas hay que verificar un dominio propio en Resend.
        </div>
      </section>

      <section className="panel">
        <div className="panel-head"><h2>Historial</h2><button className="btn sm ghost" onClick={runs.reload}>Actualizar</button></div>
        <ErrorBox msg={runs.error} />
        {runs.loading ? <Loading /> : !runs.data?.length ? <Empty text="Todavía no ha corrido ninguna automatización." /> : (
          <div className="table-wrap">
            <table>
              <thead><tr><th>Fecha</th><th>Tarea</th><th>Resultado</th></tr></thead>
              <tbody>{runs.data.map((r) => (
                <tr key={r.id}>
                  <td style={{ whiteSpace: 'nowrap' }}>{new Date(r.ran_at).toLocaleString('es-MX', { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' })}</td>
                  <td style={{ whiteSpace: 'nowrap' }}>{r.ok ? <Badge cls="b-ok">{JOBS[r.job] || r.job}</Badge> : <Badge cls="b-bad">{JOBS[r.job] || r.job}</Badge>}{r.details?.by === 'manual' && <div className="sub">Enviado a mano</div>}</td>
                  <td className="muted">{describeRun(r)}</td>
                </tr>
              ))}</tbody>
            </table>
          </div>
        )}
      </section>
    </>
  )
}

// ---------- Store and card-charge settings ----------
const STORE_FIELDS = ['store_name', 'store_open', 'store_closed_message', 'store_url', 'store_whatsapp', 'sub_discount_pct', 'delivery_fee',
  'free_delivery_zips', 'bank_name', 'bank_clabe', 'bank_beneficiary', 'max_auto_charge', 'auto_charge_ratio', 'daily_auto_charge_cap', 'price_notice_days']

function StoreSettings({ initial, onSaved }) {
  const toast = useToast()
  const [f, setF] = useState(() => Object.fromEntries(STORE_FIELDS.map((k) => [k, k === 'free_delivery_zips' ? (initial[k] || []).join(', ') : initial[k] ?? ''])))
  const [busy, setBusy] = useState(false)
  const set = (k) => (e) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value })
  const digits = (v) => String(v || '').replace(/\D/g, '')

  const save = async () => {
    const zips = String(f.free_delivery_zips).split(/[\s,]+/).filter(Boolean)
    if (zips.some((z) => !/^\d{5}$/.test(z))) { toast('Los códigos postales sin envío deben ser de 5 dígitos, separados por coma.', true); return }
    if (f.store_whatsapp && digits(f.store_whatsapp).length !== 10) { toast('El WhatsApp de la tienda debe tener 10 dígitos.', true); return }
    if (f.bank_clabe && digits(f.bank_clabe).length !== 18) { toast('La CLABE tiene 18 dígitos.', true); return }
    setBusy(true)
    const n = (v) => (v === '' ? null : Number(v))
    try {
      await q(supabase.from('settings').update({
        store_name: f.store_name.trim() || 'Cloro a Domicilio', store_open: f.store_open, store_closed_message: f.store_closed_message.trim() || null,
        store_url: f.store_url.trim().replace(/\/+$/, '') || null, store_whatsapp: digits(f.store_whatsapp) || null,
        sub_discount_pct: n(f.sub_discount_pct) ?? 0, delivery_fee: n(f.delivery_fee) ?? 0, free_delivery_zips: zips,
        bank_name: f.bank_name.trim() || null, bank_clabe: digits(f.bank_clabe) || null, bank_beneficiary: f.bank_beneficiary.trim() || null,
        max_auto_charge: n(f.max_auto_charge), auto_charge_ratio: n(f.auto_charge_ratio), daily_auto_charge_cap: n(f.daily_auto_charge_cap),
        price_notice_days: n(f.price_notice_days) ?? 7,
      }).eq('id', true))
      toast('Ajustes de la tienda guardados'); onSaved()
    } catch (e) { toast(e.message, true) }
    setBusy(false)
  }

  return (
    <div className="grid grid-2" style={{ marginBottom: 16 }}>
      <section className="panel">
        <div className="panel-head"><h2>Tienda en línea</h2>{f.store_url && <a className="btn sm ghost" href={f.store_url} target="_blank" rel="noreferrer">Abrir tienda</a>}</div>
        <div className="panel-body stack" style={{ gap: 14 }}>
          <label className="check"><input type="checkbox" checked={f.store_open} onChange={set('store_open')} />Recibiendo pedidos</label>
          {!f.store_open && <Field label="Mensaje mientras está cerrada"><input value={f.store_closed_message} onChange={set('store_closed_message')} placeholder="Volvemos el lunes…" /></Field>}
          <div className="form-grid">
            <Field label="Nombre de la tienda"><input value={f.store_name} onChange={set('store_name')} /></Field>
            <Field label="WhatsApp de la tienda" hint="10 dígitos; aparece en la tienda y los correos"><input inputMode="tel" value={f.store_whatsapp} onChange={set('store_whatsapp')} /></Field>
            <Field label="Dirección de la tienda" className="full" hint="Para las ligas en correos y en la administración"><input value={f.store_url} onChange={set('store_url')} placeholder="https://tudominio.mx" /></Field>
            <Field label="Envío ($)"><input type="number" min="0" step="any" value={f.delivery_fee} onChange={set('delivery_fee')} /></Field>
            <Field label="CP con envío gratis" hint="Separados por coma"><input value={f.free_delivery_zips} onChange={set('free_delivery_zips')} /></Field>
            <Field label="Descuento de suscripción (%)"><input type="number" min="0" max="50" step="any" value={f.sub_discount_pct} onChange={set('sub_discount_pct')} /></Field>
            <Field label="Aviso de cambio de precio (días)" hint="A suscriptores, antes de que aplique"><input type="number" min="0" max="60" value={f.price_notice_days} onChange={set('price_notice_days')} /></Field>
          </div>
          <div style={{ fontWeight: 600 }}>Datos para transferencia SPEI</div>
          <div className="form-grid">
            <Field label="Banco"><input value={f.bank_name} onChange={set('bank_name')} /></Field>
            <Field label="CLABE"><input inputMode="numeric" value={f.bank_clabe} onChange={set('bank_clabe')} /></Field>
            <Field label="Beneficiario" className="full"><input value={f.bank_beneficiary} onChange={set('bank_beneficiary')} /></Field>
          </div>
        </div>
      </section>
      <section className="panel">
        <div className="panel-head"><h2>Límites de cobro automático</h2></div>
        <div className="panel-body stack" style={{ gap: 14 }}>
          <p className="muted" style={{ margin: 0, fontSize: 13.5 }}>Protegen las tarjetas guardadas. Un cobro que rebase cualquiera de estos límites no se hace: queda retenido y te llega un correo para revisarlo y aprobarlo en el pedido.</p>
          <div className="form-grid">
            <Field label="Máximo por cobro ($)"><input type="number" min="0" step="any" value={f.max_auto_charge} onChange={set('max_auto_charge')} /></Field>
            <Field label="Máximo vs. último cobro (veces)" hint="1.5 = hasta 50% más que la vez pasada"><input type="number" min="1" step="0.1" value={f.auto_charge_ratio} onChange={set('auto_charge_ratio')} /></Field>
            <Field label="Máximo por día, todos los clientes ($)"><input type="number" min="0" step="any" value={f.daily_auto_charge_cap} onChange={set('daily_auto_charge_cap')} /></Field>
          </div>
          <p className="muted" style={{ margin: 0, fontSize: 13.5 }}>El monto siempre lo calcula la base de datos con los precios del catálogo; nadie lo escribe a mano. Si cambias un precio más de 30%, la administración te pide confirmarlo.</p>
          <div><button className="btn primary" onClick={save} disabled={busy}>Guardar tienda y cobros</button></div>
        </div>
      </section>
    </div>
  )
}
