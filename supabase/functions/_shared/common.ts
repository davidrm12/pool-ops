// Shared helpers for all Cloro Edge Functions: env, HTTP, Supabase clients, email.
import { createClient, SupabaseClient } from 'npm:@supabase/supabase-js@2'

export const env = (k: string, d = '') => Deno.env.get(k) ?? d
export const SUPABASE_URL = env('SUPABASE_URL')
export const CITY = env('CITY', 'Torreón, Coahuila')
export const ADMIN_URL = env('SITE_URL')            // admin site (kept name for step 3 compatibility)
export const STORE_URL = env('STORE_URL')           // public store
const FROM = env('MAIL_FROM', 'Cloro <onboarding@resend.dev>')
const RESEND = env('RESEND_API_URL', 'https://api.resend.com/emails')

export const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
export const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

export const serviceClient = (): SupabaseClient =>
  createClient(SUPABASE_URL, env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } })

// Scheduler (x-cron-secret) or a logged-in admin. Returns 'cron' | 'admin' | null.
export async function authorize(req: Request): Promise<'cron' | 'admin' | null> {
  if (env('CRON_SECRET') && req.headers.get('x-cron-secret') === env('CRON_SECRET')) return 'cron'
  const auth = req.headers.get('Authorization') ?? ''
  if (!auth.startsWith('Bearer ')) return null
  const user = createClient(SUPABASE_URL, env('SUPABASE_ANON_KEY'), { global: { headers: { Authorization: auth } }, auth: { persistSession: false } })
  const { data, error } = await user.rpc('is_admin')
  return !error && data === true ? 'admin' : null
}

// ---------- formatting ----------
const mxn = new Intl.NumberFormat('es-MX', { style: 'currency', currency: 'MXN', maximumFractionDigits: 0 })
const mxn2 = new Intl.NumberFormat('es-MX', { style: 'currency', currency: 'MXN', minimumFractionDigits: 2 })
export const money = (v: unknown) => (Number(v) % 1 ? mxn2 : mxn).format(Number(v ?? 0))
export const num = (v: unknown) => new Intl.NumberFormat('es-MX', { maximumFractionDigits: 2 }).format(Number(v ?? 0))
export const esc = (s: unknown) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!))
export const day = (s: string, opts: Intl.DateTimeFormatOptions = { weekday: 'long', day: 'numeric', month: 'long' }) => {
  const [y, m, d] = String(s).slice(0, 10).split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d, 12)).toLocaleDateString('es-MX', { timeZone: 'UTC', ...opts })
}
export const PAY: Record<string, string> = { card: 'Tarjeta', cash: 'Efectivo', spei: 'SPEI' }
export const waLink = (p: string, text = '') => {
  const d = String(p || '').replace(/\D/g, '')
  return d.length >= 10 ? `https://wa.me/${d.length === 10 ? '52' + d : d}${text ? `?text=${encodeURIComponent(text)}` : ''}` : ''
}
export const storeLink = (path: string) => (STORE_URL ? `${STORE_URL.replace(/\/+$/, '')}/#${path}` : '')

// ---------- email building blocks ----------
export const C = { ink: '#12263A', muted: '#6E7E8E', line: '#D9E3E6', tile: '#E4F1F3', water: '#00798A', warn: '#FCF0C6', bad: '#B3412E' }
export const shell = (title: string, sub: string, body: string, footer = '') => `<!doctype html><html><body style="margin:0;background:#F3F7F8;font-family:Arial,Helvetica,sans-serif;color:${C.ink}">
<div style="max-width:640px;margin:0 auto;padding:20px 14px">
  <div style="background:${C.ink};color:#fff;border-radius:10px;padding:18px 20px">
    <div style="font-size:20px;font-weight:bold">${esc(title)}</div>
    <div style="color:#A9C0CB;font-size:14px;margin-top:4px">${esc(sub)}</div>
  </div>
  ${body}
  <p style="color:${C.muted};font-size:12px;margin-top:20px">${footer || `Correo automático${ADMIN_URL ? ` · <a href="${esc(ADMIN_URL)}" style="color:${C.water}">Abrir administración</a>` : ''}`}</p>
</div></body></html>`
export const section = (title: string, inner: string) =>
  `<div style="background:#fff;border:1px solid ${C.line};border-radius:10px;margin-top:14px"><div style="padding:12px 16px;border-bottom:1px solid ${C.line};font-weight:bold">${esc(title)}</div><div style="padding:4px 16px 12px">${inner}</div></div>`
export const row = (l: string, r: string, strong = false) =>
  `<tr><td style="padding:7px 0;border-bottom:1px solid ${C.line}">${l}</td><td style="padding:7px 0;border-bottom:1px solid ${C.line};text-align:right;${strong ? 'font-weight:bold' : ''}">${r}</td></tr>`
export const table = (rows: string) => `<table style="width:100%;border-collapse:collapse;font-size:14px">${rows}</table>`
export const btn = (href: string, label: string) =>
  `<a href="${esc(href)}" style="display:inline-block;background:${C.water};color:#fff;text-decoration:none;padding:9px 14px;border-radius:6px;font-size:14px;margin:6px 6px 0 0">${esc(label)}</a>`
export const para = (html: string) => `<p style="font-size:14px;line-height:1.5;margin:10px 0">${html}</p>`

// ---------- sending ----------
export type SendResult = { email: string; ok: boolean; id?: string; error?: string }

export async function sendEmail(to: string[], subject: string, html: string): Promise<SendResult[]> {
  const out: SendResult[] = []
  for (const email of to) {
    const r = await fetch(RESEND, {
      method: 'POST',
      headers: { Authorization: `Bearer ${env('RESEND_API_KEY')}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ from: FROM, to: [email], subject, html }),
    }).catch((e) => ({ ok: false, statusText: String(e), json: async () => ({}) }) as unknown as Response)
    const b = await r.json().catch(() => ({}))
    out.push({ email, ok: r.ok, ...(r.ok ? { id: b.id } : { error: b.message ?? r.statusText }) })
  }
  return out
}

export async function adminRecipients(db: SupabaseClient): Promise<string[]> {
  const { data } = await db.from('alert_recipients').select('email').eq('active', true)
  return (data ?? []).map((r: { email: string }) => r.email)
}

// What customers see as the order's name: "Pedido 15/10/2026". The internal #id stays for the admin.
export const orderLabel = (d: string | null | undefined) => {
  const [y, m, dd] = String(d ?? '').slice(0, 10).split('-')
  return y && m && dd ? `Pedido ${dd}/${m}/${y}` : 'Pedido'
}
