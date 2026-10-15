import { supabase, q } from './supabase'

// Sellable sizes for pickers: "Cloro granular · Bolsa 5 kg" with price.
export async function loadVariants({ includeInactive = false } = {}) {
  let query = supabase
    .from('product_variants')
    .select('id, label, price, pack_qty, active, product:products(id, name, base_unit, active, unit_cost)')
    .order('id')
  const rows = await q(query)
  return rows
    .filter((v) => includeInactive || (v.active && v.product.active))
    .map((v) => ({ ...v, name: `${v.product.name} · ${v.label}` }))
    .sort((a, b) => a.name.localeCompare(b.name, 'es'))
}

export async function loadCustomers() {
  return q(supabase.from('customers').select('id, name, phone, address, zone, status').order('name'))
}

export async function loadProducts() {
  return q(supabase.from('products').select('id, name, base_unit, unit_cost, active').order('name'))
}

export async function loadSuppliers() {
  return q(supabase.from('suppliers').select('*').order('name'))
}

// Replaces the line items of a parent (order / subscription) with the edited list,
// updating existing rows in place so their recorded cost and stock movement are kept.
export async function syncLines(table, parentKey, parentId, lines, toRow) {
  const existing = await q(supabase.from(table).select('*').eq(parentKey, parentId))
  const keep = new Set(lines.filter((l) => l.id).map((l) => l.id))
  const removed = existing.filter((e) => !keep.has(e.id))
  if (removed.length) await q(supabase.from(table).delete().in('id', removed.map((r) => r.id)))
  for (const l of lines) {
    if (l.id) await q(supabase.from(table).update(toRow(l)).eq('id', l.id))
    else await q(supabase.from(table).insert({ ...toRow(l), [parentKey]: parentId }))
  }
}

// Sends a report email now (route | reorder | weekly) through the `reports` Edge Function.
export async function sendReport(kind, extra = {}) {
  const { data, error } = await supabase.functions.invoke('reports', { body: { kind, ...extra } })
  if (error) {
    let b = null
    try { b = await error.context.json() } catch { /* not JSON */ }
    if (b?.results) return b                       // partial: some recipients failed
    throw new Error(b?.error || error.message)
  }
  return data
}

export const nextDeliveryOn = async (from) => q(supabase.rpc('next_delivery_on', from ? { p_from: from } : {}))

// One-line Spanish summary of a send result.
export const describeSend = (r) => {
  if (r?.skipped) return 'No había nada que enviar.'
  const ok = (r?.results || []).filter((x) => x.ok).map((x) => x.email)
  const bad = (r?.results || []).filter((x) => !x.ok)
  return [ok.length ? `Enviado a ${ok.join(', ')}.` : '', bad.length ? `No se pudo enviar a ${bad.map((x) => x.email).join(', ')}.` : ''].filter(Boolean).join(' ')
}

// Card charges through the `charges` Edge Function: charge | approve | refund | payment_link.
export async function chargeAction(action, orderId) {
  const { data, error } = await supabase.functions.invoke('charges', { body: { action, order_id: orderId } })
  if (error) {
    let b = null
    try { b = await error.context.json() } catch { /* not JSON */ }
    throw new Error(b?.error || error.message)
  }
  return data
}

// Public store base URL (Ajustes → Tienda), for links to customer pages.
let storeUrl
export async function getStoreUrl() {
  if (storeUrl === undefined) storeUrl = (await q(supabase.from('settings').select('store_url').single())).store_url || ''
  return storeUrl.replace(/\/+$/, '')
}

// Shrinks a photo in the browser (max 1000 px, WebP) and uploads it to Storage → public URL.
export async function uploadProductImage(file, productId) {
  if (!file.type.startsWith('image/')) throw new Error('El archivo debe ser una imagen.')
  const bmp = await createImageBitmap(file)
  const scale = Math.min(1, 1000 / Math.max(bmp.width, bmp.height))
  const c = document.createElement('canvas')
  c.width = Math.round(bmp.width * scale); c.height = Math.round(bmp.height * scale)
  c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height)
  const blob = await new Promise((res) => c.toBlob(res, 'image/webp', 0.85))
  const path = `p${productId}-${Date.now()}.webp`
  const { error } = await supabase.storage.from('product-images').upload(path, blob, { contentType: 'image/webp', upsert: true })
  if (error) throw new Error(`No se pudo subir la foto: ${error.message}`)
  return supabase.storage.from('product-images').getPublicUrl(path).data.publicUrl
}
