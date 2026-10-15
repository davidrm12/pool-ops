// Minimal Stripe REST client (no SDK): form-encoded requests, idempotency keys,
// webhook signature check. STRIPE_API_BASE can point to a mock for local tests.
import { env } from './common.ts'

const BASE = env('STRIPE_API_BASE', 'https://api.stripe.com')

function encode(obj: Record<string, unknown>, prefix = '', out = new URLSearchParams()): URLSearchParams {
  for (const [k, v] of Object.entries(obj)) {
    if (v === undefined || v === null) continue
    const key = prefix ? `${prefix}[${k}]` : k
    if (Array.isArray(v)) v.forEach((item, i) => (typeof item === 'object' ? encode(item as Record<string, unknown>, `${key}[${i}]`, out) : out.append(`${key}[${i}]`, String(item))))
    else if (typeof v === 'object') encode(v as Record<string, unknown>, key, out)
    else out.append(key, String(v))
  }
  return out
}

export class StripeError extends Error {
  status: number; code?: string; decline_code?: string; payment_intent?: { id: string }; type?: string
  constructor(status: number, e: Record<string, any>) {
    super(e?.message ?? `Stripe error ${status}`)
    this.status = status; this.code = e?.code; this.decline_code = e?.decline_code; this.payment_intent = e?.payment_intent; this.type = e?.type
  }
}

export async function stripe(method: 'GET' | 'POST', path: string, params: Record<string, unknown> = {}, idempotencyKey?: string) {
  const qs = encode(params).toString()
  const headers: Record<string, string> = { Authorization: `Bearer ${env('STRIPE_SECRET_KEY')}`, 'Stripe-Version': '2024-06-20' }
  if (method === 'POST') headers['Content-Type'] = 'application/x-www-form-urlencoded'
  if (idempotencyKey) headers['Idempotency-Key'] = idempotencyKey
  const r = await fetch(`${BASE}/v1/${path}${method === 'GET' && qs ? `?${qs}` : ''}`, { method, headers, body: method === 'POST' ? qs : undefined })
  const b = await r.json().catch(() => ({}))
  if (!r.ok) throw new StripeError(r.status, b.error ?? {})
  return b
}

// Stripe-Signature: t=<ts>,v1=<hex hmac of "t.payload">. Rejects if older than 5 minutes.
export async function verifyWebhook(raw: string, header: string | null, secret: string): Promise<boolean> {
  if (!header || !secret) return false
  const parts = Object.fromEntries(header.split(',').map((p) => p.split('=') as [string, string]))
  const sigs = header.split(',').filter((p) => p.startsWith('v1=')).map((p) => p.slice(3))
  const t = Number(parts.t)
  if (!t || Math.abs(Date.now() / 1000 - t) > 300) return false
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${t}.${raw}`))
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('')
  return sigs.some((s) => s.length === hex.length && timingSafeEqual(s, hex))
}
function timingSafeEqual(a: string, b: string) {
  let r = 0
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return r === 0
}

export const toCents = (mxn: number) => Math.round(Number(mxn) * 100)
