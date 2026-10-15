import { CITY, COUNTRY_CODE } from './config'

const mxn = new Intl.NumberFormat('es-MX', { style: 'currency', currency: 'MXN', maximumFractionDigits: 0 })
const mxn2 = new Intl.NumberFormat('es-MX', { style: 'currency', currency: 'MXN', minimumFractionDigits: 2, maximumFractionDigits: 2 })
const num = new Intl.NumberFormat('es-MX', { maximumFractionDigits: 3 })

export const money = (v) => (v === null || v === undefined || v === '' ? '—' : mxn.format(Number(v)))
export const money2 = (v) => (v === null || v === undefined || v === '' ? '—' : mxn2.format(Number(v)))
export const qty = (v) => (v === null || v === undefined ? '—' : num.format(Number(v)))
export const pct = (v) => (v === null || v === undefined ? '—' : `${(Number(v) * 100).toFixed(1)}%`)

export const compact = (v) => {
  const n = Number(v)
  if (Math.abs(n) >= 1000) return `$${(n / 1000).toFixed(n % 1000 === 0 ? 0 : 1)}k`
  return `$${n}`
}

// Dates come from Postgres as 'YYYY-MM-DD'; parse as local dates (not UTC) to avoid off-by-one.
export const parseDate = (s) => {
  if (!s) return null
  const [y, m, d] = String(s).slice(0, 10).split('-').map(Number)
  return new Date(y, m - 1, d)
}
export const date = (s) => {
  const d = parseDate(s)
  return d ? d.toLocaleDateString('es-MX', { day: 'numeric', month: 'short', year: 'numeric' }) : '—'
}
export const shortDate = (s) => {
  const d = parseDate(s)
  return d ? d.toLocaleDateString('es-MX', { day: 'numeric', month: 'short' }) : '—'
}
export const monthLabel = (s) => {
  const d = parseDate(s)
  return d ? d.toLocaleDateString('es-MX', { month: 'short', year: '2-digit' }) : '—'
}
export const today = () => {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}
export const relDay = (s) => {
  const d = parseDate(s)
  if (!d) return '—'
  const t = parseDate(today())
  const diff = Math.round((d - t) / 86400000)
  if (diff === 0) return 'Hoy'
  if (diff === 1) return 'Mañana'
  if (diff === -1) return 'Ayer'
  if (diff < 0) return `Hace ${-diff} días`
  if (diff < 7) return d.toLocaleDateString('es-MX', { weekday: 'long' })
  return shortDate(s)
}

export const digits = (p) => String(p || '').replace(/\D/g, '')
export const phoneFmt = (p) => {
  const d = digits(p).slice(-10)
  return d.length === 10 ? `${d.slice(0, 3)} ${d.slice(3, 6)} ${d.slice(6)}` : p || '—'
}
export const waLink = (p, text) => {
  const d = digits(p)
  if (d.length < 10) return null
  const full = d.length === 10 ? COUNTRY_CODE + d : d
  return `https://wa.me/${full}${text ? `?text=${encodeURIComponent(text)}` : ''}`
}
export const mapsLink = (address, zone) => {
  if (!address) return null
  const qs = [address, zone, CITY].filter(Boolean).join(', ')
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(qs)}`
}

// ---------- Spanish labels for database values ----------
export const L = {
  orderStatus: { pending: 'Pendiente', confirmed: 'Confirmado', out_for_delivery: 'En ruta', delivered: 'Entregado', cancelled: 'Cancelado' },
  payMethod: { card: 'Tarjeta', cash: 'Efectivo', spei: 'SPEI' },
  payStatus: { pending: 'Por cobrar', paid: 'Pagado' },
  channel: { manual: 'Manual', whatsapp: 'WhatsApp', web: 'Web', subscription: 'Suscripción' },
  customerType: { residential: 'Residencial', pool_service: 'Alberquero', business: 'Negocio' },
  customerStatus: { prospect: 'Prospecto', customer: 'Cliente', inactive: 'Inactivo' },
  subStatus: { active: 'Activa', paused: 'Pausada', cancelled: 'Cancelada' },
  category: { cloro: 'Cloro', alguicida: 'Alguicida', clarificador: 'Clarificador', ph: 'pH', sal: 'Sal', prueba: 'Prueba', abrillantador: 'Abrillantador', accesorio: 'Accesorio', otro: 'Otro' },
  unit: { kg: 'kg', L: 'L', pza: 'pza' },
  expense: { delivery: 'Envíos', packaging: 'Empaque', fuel: 'Gasolina', fees: 'Comisiones', marketing: 'Publicidad', software: 'Software', other: 'Otro' },
  movement: { purchase: 'Compra', sale: 'Venta', count: 'Conteo', waste: 'Merma', internal_use: 'Uso interno' },
}
export const options = (map) => Object.entries(map).map(([value, label]) => ({ value, label }))

export const WEEKDAYS = ['Domingo', 'Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado']
export const longDate = (s) => {
  const d = parseDate(s)
  return d ? d.toLocaleDateString('es-MX', { weekday: 'long', day: 'numeric', month: 'long' }) : '—'
}

// Google Maps directions: one destination + up to 9 stops per link.
// (Phone browsers cap it at 3 stops; the Maps app and computers take 9.)
export const routeLinks = (stops) => {
  const addrs = stops.map((s) => [s.address ?? s.delivery_address, s.zone, CITY].filter(Boolean).join(', '))
    .filter((a) => a.split(',')[0].trim() && !a.startsWith(CITY))
  const out = []
  for (let i = 0; i < addrs.length; i += 10) {
    const c = addrs.slice(i, i + 10)
    const way = c.slice(0, -1).join('|')
    out.push(`https://www.google.com/maps/dir/?api=1&travelmode=driving&destination=${encodeURIComponent(c[c.length - 1])}${way ? `&waypoints=${encodeURIComponent(way)}` : ''}`)
  }
  return out
}
