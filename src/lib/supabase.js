import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_ANON_KEY

export const configured = Boolean(url && key)

// The anon key is public by design; the database only answers to logged-in admins.
export const supabase = configured
  ? createClient(url, key, { auth: { persistSession: true, autoRefreshToken: true } })
  : null

// Throws the Supabase error so callers can show it; returns data otherwise.
export async function q(promise) {
  const { data, error } = await promise
  if (error) throw new Error(translateError(error))
  return data
}

function translateError(e) {
  const m = e.message || String(e)
  if (e.code === '23503') return 'No se puede borrar: hay registros que dependen de este (pedidos, compras o suscripciones). Desactívalo en su lugar.'
  if (e.code === '23505') return 'Ya existe un registro con ese valor (nombre, teléfono o presentación repetidos).'
  if (e.code === '23514') return 'Algún valor no es válido (revisa cantidades, precios y montos).'
  if (e.code === '42501' || /row-level security/i.test(m)) return 'Tu cuenta no tiene permiso para esta acción.'
  if (/Failed to fetch|NetworkError/i.test(m)) return 'Sin conexión con la base de datos. Revisa tu internet e intenta de nuevo.'
  return m
}
