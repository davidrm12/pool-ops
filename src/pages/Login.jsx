import { useState } from 'react'
import { supabase } from '../lib/supabase'
import { ErrorBox, Field } from '../components/ui'

export default function Login() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [err, setErr] = useState(null)
  const [busy, setBusy] = useState(false)

  const submit = async (e) => {
    e.preventDefault()
    setBusy(true); setErr(null)
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password })
    setBusy(false)
    if (error) setErr(/invalid/i.test(error.message) ? 'Correo o contraseña incorrectos.' : error.message)
  }

  return (
    <div className="login">
      <form className="login-card" onSubmit={submit}>
        <div className="inline">
          <img src="./favicon.svg" width="40" height="40" alt="" />
          <div><h1>Cloro</h1><p className="muted">Administración del negocio</p></div>
        </div>
        <Field label="Correo">
          <input type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required autoFocus />
        </Field>
        <Field label="Contraseña">
          <input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required />
        </Field>
        <ErrorBox msg={err} />
        <button className="btn primary" disabled={busy}>{busy ? 'Entrando…' : 'Entrar'}</button>
        <p className="muted" style={{ fontSize: 13 }}>¿Olvidaste la contraseña? El administrador la cambia desde Supabase.</p>
      </form>
    </div>
  )
}
