import { useEffect, useRef, useState } from 'react'
import { compact, money, monthLabel } from '../lib/format'

// Grouped columns per month. series: [{ key, label, color }]. Colors validated
// (CVD ΔE ≥ 16, contrast ≥ 3:1 on white) with the dataviz palette checker.
export default function MonthChart({ rows, series, height = 220 }) {
  const [hover, setHover] = useState(null)
  const box = useRef(null)
  const [W, setW] = useState(640)
  // Draw at the container's real width so text and bars keep their size on any screen.
  useEffect(() => {
    const el = box.current
    if (!el) return
    const ro = new ResizeObserver(([e]) => setW(Math.max(280, Math.round(e.contentRect.width))))
    ro.observe(el)
    return () => ro.disconnect()
  }, [])
  const H = height, padL = 44, padB = 26, padT = 10
  const n = rows.length
  const max = Math.max(1, ...rows.flatMap((r) => series.map((s) => Number(r[s.key]) || 0)))
  const step = niceStep(max)
  const top = Math.ceil(max / step) * step
  const y = (v) => padT + (H - padT - padB) * (1 - Math.max(0, v) / top)
  const band = (W - padL) / Math.max(n, 1)
  const barW = Math.min(22, (band - 12) / series.length - 2)
  const ticks = []
  for (let t = 0; t <= top; t += step) ticks.push(t)

  return (
    <div className="chart" ref={box}>
      <div className="legend" style={{ marginBottom: 8 }}>
        {series.map((s) => <span key={s.key}><i style={{ background: s.color }} />{s.label}</span>)}
      </div>
      <svg viewBox={`0 0 ${W} ${H}`} width={W} height={H} role="img" aria-label={`Gráfica mensual: ${series.map((s) => s.label).join(' y ')}`}>
        {ticks.map((t) => (
          <g key={t}>
            <line x1={padL} x2={W} y1={y(t)} y2={y(t)} stroke="#E3EAEC" strokeWidth="1" />
            <text x={padL - 8} y={y(t) + 4} textAnchor="end" fontSize="11" fill="#6E7E8E">{compact(t)}</text>
          </g>
        ))}
        {rows.map((r, i) => {
          const cx = padL + band * i + band / 2
          const groupW = series.length * barW + (series.length - 1) * 2
          return (
            <g key={r.month} onMouseEnter={() => setHover(i)} onMouseLeave={() => setHover(null)}>
              <rect x={padL + band * i} y={padT} width={band} height={H - padT - padB} fill={hover === i ? '#F1F7F8' : 'transparent'} />
              {series.map((s, j) => {
                const v = Number(r[s.key]) || 0
                const x = cx - groupW / 2 + j * (barW + 2)
                const h = Math.max(0, y(0) - y(v))
                return <path key={s.key} d={colPath(x, y(0), barW, h)} fill={s.color} />
              })}
              <text x={cx} y={H - 8} textAnchor="middle" fontSize="11" fill="#6E7E8E">{monthLabel(r.month)}</text>
            </g>
          )
        })}
      </svg>
      {hover !== null && rows[hover] && (
        <div className="tip" style={{ left: `${((padL + band * hover + band / 2) / W) * 100}%`, top: `${(y(Math.max(...series.map((s) => Number(rows[hover][s.key]) || 0))) / H) * 100}%` }}>
          <div style={{ fontWeight: 700, marginBottom: 4 }}>{monthLabel(rows[hover].month)}</div>
          {series.map((s) => <div key={s.key}><i style={{ background: s.color }} />{s.label}: {money(rows[hover][s.key])}</div>)}
        </div>
      )}
    </div>
  )
}

// Column with a 4px rounded top and a square base.
function colPath(x, base, w, h) {
  if (h <= 0) return ''
  const r = Math.min(4, w / 2, h)
  return `M${x},${base} V${base - h + r} Q${x},${base - h} ${x + r},${base - h} H${x + w - r} Q${x + w},${base - h} ${x + w},${base - h + r} V${base} Z`
}
function niceStep(max) {
  const raw = max / 4
  const p = Math.pow(10, Math.floor(Math.log10(raw)))
  const m = raw / p
  return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 5 ? 5 : 10) * p
}
