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
