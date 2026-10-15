import { useCallback, useEffect, useRef, useState } from 'react'

// Runs an async loader, exposes { data, error, loading, reload }.
export function useLoad(loader, deps = []) {
  const [state, setState] = useState({ data: null, error: null, loading: true })
  const seq = useRef(0)
  const run = useCallback(async () => {
    const id = ++seq.current
    setState((s) => ({ ...s, loading: true, error: null }))
    try {
      const data = await loader()
      if (id === seq.current) setState({ data, error: null, loading: false })
    } catch (e) {
      if (id === seq.current) setState({ data: null, error: e.message, loading: false })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)
  useEffect(() => { run() }, [run])
  return { ...state, reload: run }
}
