// A ten-line hash router. Hash URLs (/#/session/K7XQ2M) mean the server only
// ever has to serve "/", in dev and in prod, with no SPA fallback rules.
import { useSyncExternalStore } from 'react'

const subscribe = (cb: () => void) => {
  window.addEventListener('hashchange', cb)
  return () => window.removeEventListener('hashchange', cb)
}

const current = () => window.location.hash.replace(/^#/, '') || '/'

export function useRoute(): string {
  return useSyncExternalStore(subscribe, current)
}

export function navigate(path: string) {
  window.location.hash = path
}

/** Absolute shareable URL for an in-app path. */
export function shareUrl(path: string): string {
  return `${window.location.origin}${window.location.pathname}#${path}`
}
