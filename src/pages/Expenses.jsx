import { useState } from 'react'
import { supabase, q } from '../lib/supabase'
import { useLoad } from '../lib/hooks'
import { L, date, money, options, today } from '../lib/format'
import { DeleteButton, Empty, ErrorBox, Field, Icon, Loading, Modal, Select, useToast } from '../components/ui'

export default function Expenses() {
  const [month, setMonth] = useState(today().slice(0, 7))
  const [editing, setEditing] = useState(null)
  const { data, error, loading, reload } = useLoad(() => {
    let qry = supabase.from('expenses').select('*').order('expense_date', { ascending: false })
    if (month) {
      const [y, m] = month.split('-').map(Number)
      const end = m === 12 ? `${y + 1}-01-01` : `${y}-${String(m + 1).padStart(2, '0')}-01`
      qry = qry.gte('expense_date', `${month}-01`).lt('expense_date', end)
    }
    return q(qry)
  }, [month])
  const total = (data || []).reduce((s, e) => s + Number(e.amount), 0)

  return (
    <>
      <div className="page-head">
        <div><h1>Gastos</h1><p>Gasolina, empaque, comisiones y otros gastos que no son mercancía.</p></div>
        <button className="btn primary" onClick={() => setEditing({})}><Icon name="plus" />Registrar gasto</button>
      </div>
      <div className="toolbar">
        <input type="month" value={month} onChange={(e) => setMonth(e.target.value)} aria-label="Mes" style={{ width: 'auto' }} />
        {month && <button className="btn sm ghost" onClick={() => setMonth('')}>Ver todos</button>}
      </div>
      <ErrorBox msg={error} />
      <div className="panel">
        {loading ? <Loading /> : !data?.length ? <Empty text="Sin gastos en este periodo." action={<button className="btn primary" onClick={() => setEditing({})}>Registrar gasto</button>} /> : (
          <div className="table-wrap">
            <table>
              <thead><tr><th>Fecha</th><th>Categoría</th><th>Nota</th><th className="num">Monto</th></tr></thead>
              <tbody>{data.map((e) => (
                <tr key={e.id} className="click" onClick={() => setEditing(e)} tabIndex={0} onKeyDown={(ev) => ev.key === 'Enter' && setEditing(e)}>
                  <td style={{ whiteSpace: 'nowrap' }}>{date(e.expense_date)}</td><td>{L.expense[e.category]}</td><td className="muted">{e.notes}</td><td className="num">{money(e.amount)}</td>
                </tr>
              ))}</tbody>
              <tfoot><tr><td colSpan={3}>Total</td><td className="num">{money(total)}</td></tr></tfoot>
            </table>
          </div>
        )}
      </div>
      {editing && <ExpenseForm expense={editing.id ? editing : null} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); reload() }} />}
    </>
  )
}

function ExpenseForm({ expense, onClose, onSaved }) {
  const [f, setF] = useState({ expense_date: today(), category: 'fuel', amount: '', notes: '', ...(expense || {}) })
  const [err, setErr] = useState(null)
  const toast = useToast()
  const set = (k) => (e) => setF({ ...f, [k]: e?.target ? e.target.value : e })
  const save = async () => {
    if (!(Number(f.amount) > 0)) { setErr('Escribe un monto mayor a 0.'); return }
    const row = { expense_date: f.expense_date, category: f.category, amount: Number(f.amount), notes: f.notes?.trim() || null }
    try {
      if (expense) await q(supabase.from('expenses').update(row).eq('id', expense.id))
      else await q(supabase.from('expenses').insert(row))
      toast('Gasto guardado'); onSaved()
    } catch (e) { setErr(e.message) }
  }
  const remove = async () => { try { await q(supabase.from('expenses').delete().eq('id', expense.id)); toast('Gasto eliminado'); onSaved() } catch (e) { setErr(e.message) } }
  return (
    <Modal title={expense ? 'Editar gasto' : 'Registrar gasto'} onClose={onClose}
      footer={<><div>{expense && <DeleteButton onConfirm={remove} />}</div><div className="actions"><button className="btn" onClick={onClose}>Cancelar</button><button className="btn primary" onClick={save}>Guardar gasto</button></div></>}>
      <div className="form-grid">
        <Field label="Fecha"><input type="date" value={f.expense_date} onChange={set('expense_date')} /></Field>
        <Field label="Categoría"><Select value={f.category} onChange={set('category')} options={options(L.expense)} /></Field>
        <Field label="Monto ($)"><input type="number" min="0" step="any" inputMode="decimal" value={f.amount} onChange={set('amount')} autoFocus /></Field>
        <Field label="Nota"><input value={f.notes || ''} onChange={set('notes')} /></Field>
      </div>
      <ErrorBox msg={err} />
    </Modal>
  )
}
