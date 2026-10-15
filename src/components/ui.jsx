import { createContext, useContext, useEffect, useMemo, useRef, useState } from 'react'
import { L } from '../lib/format'

// ---------- Icons (inline, stroke-based) ----------
const P = {
  dash: 'M3 13h8V3H3zM13 21h8V11h-8zM3 21h8v-6H3zM13 3v6h8V3z',
  orders: 'M6 3h12l1 4H5zM5 7h14v13a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1zM9 11h6',
  truck: 'M2 6h11v10H2zM13 9h4l4 4v3h-8zM6 19a2 2 0 1 0 0-4 2 2 0 0 0 0 4zM17 19a2 2 0 1 0 0-4 2 2 0 0 0 0 4z',
  people: 'M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM2 21c0-4 3-6 7-6s7 2 7 6M17 11a3 3 0 1 0 0-6M22 20c0-3-2-5-5-5',
  box: 'M3 7l9-4 9 4v10l-9 4-9-4zM3 7l9 4 9-4M12 11v10',
  stock: 'M4 20V10M10 20V4M16 20v-7M22 20H2',
  cart: 'M3 4h2l2.5 11h11L21 7H6.2M9 20a1 1 0 1 0 0-2 1 1 0 0 0 0 2zM18 20a1 1 0 1 0 0-2 1 1 0 0 0 0 2z',
  cash: 'M2 6h20v12H2zM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM6 9v.01M18 15v.01',
  repeat: 'M17 2l4 4-4 4M3 11V9a3 3 0 0 1 3-3h15M7 22l-4-4 4-4M21 13v2a3 3 0 0 1-3 3H3',
  chart: 'M3 3v18h18M7 15l4-4 3 3 6-7',
  plus: 'M12 5v14M5 12h14',
  x: 'M6 6l12 12M18 6L6 18',
  trash: 'M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3',
  phone: 'M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2z',
  map: 'M12 21s-7-6.3-7-12a7 7 0 0 1 14 0c0 5.7-7 12-7 12zM12 11a2 2 0 1 0 0-4 2 2 0 0 0 0 4z',
  chat: 'M21 12a8 8 0 0 1-11.8 7L3 21l2-6A8 8 0 1 1 21 12z',
  check: 'M5 12l5 5L20 7',
  more: 'M5 12h.01M12 12h.01M19 12h.01',
  supplier: 'M3 21V8l9-5 9 5v13M9 21v-6h6v6',
  gear: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z',
  mail: 'M3 5h18v14H3zM3 6l9 7 9-7',
  link: 'M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5',
  calendar: 'M4 5h16v16H4zM4 10h16M9 3v4M15 3v4',
}
export function Icon({ name, ...p }) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" {...p}>
      <path d={P[name]} />
    </svg>
  )
}

// ---------- Toasts ----------
const ToastCtx = createContext(() => {})
export function ToastProvider({ children }) {
  const [t, setT] = useState(null)
  const timer = useRef()
  const show = (msg, bad = false) => {
    clearTimeout(timer.current)
    setT({ msg, bad })
    timer.current = setTimeout(() => setT(null), bad ? 6000 : 2600)
  }
  return (
    <ToastCtx.Provider value={show}>
      {children}
      {t && <div className={`toast${t.bad ? ' bad' : ''}`} role="status">{t.msg}</div>}
    </ToastCtx.Provider>
  )
}
export const useToast = () => useContext(ToastCtx)

// ---------- Modal ----------
export function Modal({ title, onClose, children, footer, wide }) {
  useEffect(() => {
    const k = (e) => e.key === 'Escape' && onClose()
    document.addEventListener('keydown', k)
    document.body.style.overflow = 'hidden'
    return () => { document.removeEventListener('keydown', k); document.body.style.overflow = '' }
  }, [onClose])
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={`modal${wide ? ' wide' : ''}`} role="dialog" aria-modal="true" aria-label={title}>
        <div className="modal-head">
          <h2>{title}</h2>
          <button className="btn ghost sm" onClick={onClose} aria-label="Cerrar"><Icon name="x" /></button>
        </div>
        <div className="modal-body">{children}</div>
        {footer && <div className="modal-foot">{footer}</div>}
      </div>
    </div>
  )
}

// ---------- Form fields ----------
export function Field({ label, hint, className = '', children }) {
  return (
    <label className={`field ${className}`}>
      <span>{label}</span>
      {children}
      {hint && <small>{hint}</small>}
    </label>
  )
}
export function Select({ value, onChange, options, placeholder, ...rest }) {
  return (
    <select value={value ?? ''} onChange={(e) => onChange(e.target.value)} {...rest}>
      {placeholder !== undefined && <option value="">{placeholder}</option>}
      {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
    </select>
  )
}

// Searchable picker (customers, products). options: [{value,label,sub}]
export function Combo({ value, onChange, options, placeholder = 'Buscar…', ...rest }) {
  const sel = options.find((o) => String(o.value) === String(value))
  const [text, setText] = useState(sel?.label || '')
  const [open, setOpen] = useState(false)
  const [hi, setHi] = useState(0)
  useEffect(() => { setText(sel?.label || '') }, [sel?.label])
  const list = useMemo(() => {
    const t = text.trim().toLowerCase()
    const base = !t || (sel && sel.label === text) ? options : options.filter((o) => `${o.label} ${o.sub || ''}`.toLowerCase().includes(t))
    return base.slice(0, 40)
  }, [text, options, sel])
  const pick = (o) => { onChange(o.value); setText(o.label); setOpen(false) }
  return (
    <div style={{ position: 'relative' }}>
      <input
        {...rest}
        value={text}
        placeholder={placeholder}
        onChange={(e) => { setText(e.target.value); setOpen(true); setHi(0); if (!e.target.value) onChange('') }}
        onFocus={() => setOpen(true)}
        onBlur={() => setTimeout(() => { setOpen(false); setText(sel?.label || '') }, 150)}
        onKeyDown={(e) => {
          if (e.key === 'ArrowDown') { e.preventDefault(); setHi((h) => Math.min(h + 1, list.length - 1)) }
          if (e.key === 'ArrowUp') { e.preventDefault(); setHi((h) => Math.max(h - 1, 0)) }
          if (e.key === 'Enter' && open && list[hi]) { e.preventDefault(); pick(list[hi]) }
        }}
        role="combobox" aria-expanded={open} autoComplete="off"
      />
      {open && list.length > 0 && (
        <ul role="listbox" style={{ position: 'absolute', zIndex: 60, left: 0, right: 0, top: '100%', marginTop: 4, background: '#fff', border: '1px solid var(--line-strong)', borderRadius: 6, maxHeight: 260, overflowY: 'auto', listStyle: 'none', padding: 4, boxShadow: 'var(--shadow-pop)' }}>
          {list.map((o, i) => (
            <li key={o.value} role="option" aria-selected={i === hi}
                onMouseDown={(e) => { e.preventDefault(); pick(o) }} onMouseEnter={() => setHi(i)}
                style={{ padding: '7px 9px', borderRadius: 4, cursor: 'pointer', background: i === hi ? 'var(--tile)' : 'transparent' }}>
              <div>{o.label}</div>
              {o.sub && <div className="muted" style={{ fontSize: 12.5 }}>{o.sub}</div>}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

// ---------- Status display ----------
const STATUS_CLASS = {
  pending: 'b-warn', confirmed: 'b-info', out_for_delivery: 'b-info', delivered: 'b-ok', cancelled: 'b-mute',
  paid: 'b-ok', active: 'b-ok', paused: 'b-warn', customer: 'b-ok', prospect: 'b-info', inactive: 'b-mute',
}
export function OrderStatus({ s }) { return <span className={`badge ${STATUS_CLASS[s]}`}>{L.orderStatus[s]}</span> }
export function PayStatus({ s }) { return <span className={`badge ${s === 'paid' ? 'b-ok' : 'b-warn'}`}>{L.payStatus[s]}</span> }
export function Badge({ cls = '', children }) { return <span className={`badge ${cls}`}>{children}</span> }
export const statusClass = (s) => STATUS_CLASS[s] || ''

// ---------- States ----------
export const Loading = () => <div className="loading">Cargando…</div>
export const ErrorBox = ({ msg }) => (msg ? <div className="err" role="alert">{msg}</div> : null)
export function Empty({ text, action }) {
  return <div className="empty"><p>{text}</p>{action}</div>
}

// Two-step delete to avoid accidents.
export function DeleteButton({ onConfirm, label = 'Eliminar', confirmLabel = 'Sí, eliminar' }) {
  const [ask, setAsk] = useState(false)
  useEffect(() => { if (ask) { const t = setTimeout(() => setAsk(false), 4000); return () => clearTimeout(t) } }, [ask])
  return ask
    ? <button type="button" className="btn danger" onClick={onConfirm}>{confirmLabel}</button>
    : <button type="button" className="btn ghost danger" onClick={() => setAsk(true)}><Icon name="trash" />{label}</button>
}

export function Tabs({ tabs, value, onChange }) {
  return (
    <div className="tabs" role="tablist">
      {tabs.map((t) => (
        <button key={t.value} role="tab" aria-selected={value === t.value} className={value === t.value ? 'on' : ''} onClick={() => onChange(t.value)}>{t.label}</button>
      ))}
    </div>
  )
}

export function Seg({ value, onChange, options }) {
  return (
    <div className="seg">
      {options.map((o) => <button key={o.value} type="button" className={value === o.value ? 'on' : ''} onClick={() => onChange(o.value)}>{o.label}</button>)}
    </div>
  )
}
