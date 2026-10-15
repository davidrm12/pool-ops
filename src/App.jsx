import { useEffect, useState } from 'react'
import { HashRouter, NavLink, Navigate, Route, Routes } from 'react-router-dom'
import { configured, supabase } from './lib/supabase'
import { Icon, Loading, ToastProvider } from './components/ui'
import Login from './pages/Login'
import Dashboard from './pages/Dashboard'
import Orders from './pages/Orders'
import Deliveries from './pages/Deliveries'
import Customers from './pages/Customers'
import Products from './pages/Products'
import Inventory from './pages/Inventory'
import Purchases from './pages/Purchases'
import Expenses from './pages/Expenses'
import Subscriptions from './pages/Subscriptions'
import Finance from './pages/Finance'
import More from './pages/More'

const NAV = [
  { to: '/', label: 'Resumen', icon: 'dash', end: true },
  { to: '/entregas', label: 'Entregas', icon: 'truck' },
  { to: '/pedidos', label: 'Pedidos', icon: 'orders' },
  { to: '/directorio', label: 'Directorio', icon: 'people' },
  { to: '/suscripciones', label: 'Suscripciones', icon: 'repeat' },
  { to: '/productos', label: 'Productos', icon: 'box' },
  { to: '/inventario', label: 'Inventario', icon: 'stock' },
  { to: '/compras', label: 'Compras', icon: 'cart' },
  { to: '/gastos', label: 'Gastos', icon: 'cash' },
  { to: '/finanzas', label: 'Finanzas', icon: 'chart' },
]
const MOBILE = ['/', '/entregas', '/pedidos', '/directorio']

export default function App() {
  const [session, setSession] = useState(undefined)
  const [admin, setAdmin] = useState(undefined)

  useEffect(() => {
    if (!configured) return
    supabase.auth.getSession().then(({ data }) => setSession(data.session))
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s))
    return () => sub.subscription.unsubscribe()
  }, [])

  // A valid login is not enough: the account must be on the admins list.
  useEffect(() => {
    if (!session) { setAdmin(undefined); return }
    supabase.rpc('is_admin').then(({ data, error }) => setAdmin(!error && data === true))
  }, [session])

  if (!configured) {
    return (
      <div className="login"><div className="login-card">
        <h1>Falta configurar</h1>
        <p>Agrega <code>VITE_SUPABASE_URL</code> y <code>VITE_SUPABASE_ANON_KEY</code> (en <code>.env.local</code> o como secretos del repositorio) y vuelve a construir el sitio.</p>
      </div></div>
    )
  }
  if (session === undefined) return <Loading />
  if (!session) return <ToastProvider><Login /></ToastProvider>
  if (admin === undefined) return <Loading />
  if (!admin) {
    return (
      <div className="login"><div className="login-card">
        <h1>Sin acceso</h1>
        <p>La cuenta <b>{session.user.email}</b> inició sesión, pero no está autorizada para ver los datos del negocio.</p>
        <button className="btn" onClick={() => supabase.auth.signOut()}>Cerrar sesión</button>
      </div></div>
    )
  }

  return (
    <ToastProvider>
      <HashRouter>
        <div className="shell">
          <aside className="side">
            <a className="brand" href="#/">
              <img src="./favicon.svg" width="34" height="34" alt="" />
              <span><b>Cloro</b><small>Administración</small></span>
            </a>
            <nav className="nav">
              {NAV.map((n) => (
                <NavLink key={n.to} to={n.to} end={n.end}><Icon name={n.icon} />{n.label}</NavLink>
              ))}
            </nav>
            <div className="side-foot">
              <div>{session.user.email}</div>
              <button onClick={() => supabase.auth.signOut()}>Cerrar sesión</button>
            </div>
          </aside>
          <main className="main">
            <Routes>
              <Route path="/" element={<Dashboard />} />
              <Route path="/entregas" element={<Deliveries />} />
              <Route path="/pedidos" element={<Orders />} />
              <Route path="/directorio" element={<Customers />} />
              <Route path="/suscripciones" element={<Subscriptions />} />
              <Route path="/productos" element={<Products />} />
              <Route path="/inventario" element={<Inventory />} />
              <Route path="/compras" element={<Purchases />} />
              <Route path="/gastos" element={<Expenses />} />
              <Route path="/finanzas" element={<Finance />} />
              <Route path="/mas" element={<More nav={NAV.filter((n) => !MOBILE.includes(n.to))} email={session.user.email} />} />
              <Route path="*" element={<Navigate to="/" />} />
            </Routes>
          </main>
          <nav className="mobile-bar" aria-label="Navegación">
            {NAV.filter((n) => MOBILE.includes(n.to)).map((n) => (
              <NavLink key={n.to} to={n.to} end={n.end}><Icon name={n.icon} />{n.label}</NavLink>
            ))}
            <NavLink to="/mas"><Icon name="more" />Más</NavLink>
          </nav>
        </div>
      </HashRouter>
    </ToastProvider>
  )
}
