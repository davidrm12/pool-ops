import { Link } from 'react-router-dom'
import { supabase } from '../lib/supabase'
import { Icon } from '../components/ui'

// Phone-only menu for the screens that don't fit in the bottom bar.
export default function More({ nav, email }) {
  return (
    <div className="stack">
      <h1>Más</h1>
      <div className="panel">
        <ul className="list">
          {nav.map((n) => (
            <li key={n.to}><Link to={n.to} className="inline" style={{ textDecoration: 'none', color: 'inherit', fontWeight: 600 }}><Icon name={n.icon} width="20" height="20" />{n.label}</Link></li>
          ))}
        </ul>
      </div>
      <div className="panel panel-body">
        <p className="muted">{email}</p>
        <button className="btn" style={{ marginTop: 10 }} onClick={() => supabase.auth.signOut()}>Cerrar sesión</button>
      </div>
    </div>
  )
}
