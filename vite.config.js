import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// base './' lets the build run from any GitHub Pages sub-path (https://user.github.io/repo/).
export default defineConfig({
  plugins: [react()],
  base: './',
})
