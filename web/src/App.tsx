import { useCallback, useEffect, useState } from 'react'
import ReactMarkdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { rms_level } from 'timbre_kit'
// The assignment brief, shown under "Brief". Lives at the repo root; ?raw inlines it.
import assignment from '../../ASSIGNMENT.md?raw'
import Recorder from './components/Recorder'
import RecordingList from './components/RecordingList'
import { SessionLobby, SessionRoom } from './components/Session'
import Studio from './components/Studio'
import { listRecordings, type Recording } from './lib/api'
import { navigate, useRoute } from './lib/router'
import { wasmReady } from './lib/wasm'

const TABS = [
  { path: '/', label: 'Record' },
  { path: '/studio', label: 'Studio' },
  { path: '/session', label: 'Session' },
  { path: '/brief', label: 'Brief' },
]

export default function App() {
  const route = useRoute()
  const [wasmOk, setWasmOk] = useState(false)
  const [apiOk, setApiOk] = useState(false)
  const [recordings, setRecordings] = useState<Recording[]>([])
  const [loading, setLoading] = useState(true)

  // Boot WASM and confirm it runs (RMS of a full-scale signal ≈ 1).
  useEffect(() => {
    wasmReady
      .then(() => setWasmOk(rms_level(new Float32Array([1, -1, 1, -1])) > 0.99))
      .catch(() => setWasmOk(false))
  }, [])

  const refresh = useCallback(() => {
    listRecordings()
      .then((r) => {
        setRecordings(r)
        setApiOk(true)
      })
      .catch(() => setApiOk(false))
      .finally(() => setLoading(false))
  }, [])

  useEffect(refresh, [refresh])

  const studioMatch = route.match(/^\/studio(?:\/(\d+))?$/)
  const sessionMatch = route.match(/^\/session(?:\/([A-Za-z0-9]+))?$/)
  const activeTab = TABS.find((t) => (t.path === '/' ? route === '/' : route.startsWith(t.path)))?.path ?? '/'

  let page
  if (studioMatch) {
    page = (
      <Studio
        recordings={recordings}
        selectedId={studioMatch[1] ? Number(studioMatch[1]) : null}
        onSaved={refresh}
      />
    )
  } else if (sessionMatch) {
    const code = sessionMatch[1]?.toUpperCase()
    page = code ? <SessionRoom key={code} code={code} onRecordingSaved={refresh} /> : <SessionLobby />
  } else if (route === '/brief') {
    page = (
      <article className="prose prose-neutral max-w-none dark:prose-invert prose-headings:text-ink prose-a:text-link prose-code:before:content-none prose-code:after:content-none">
        <ReactMarkdown remarkPlugins={[remarkGfm]}>{assignment}</ReactMarkdown>
      </article>
    )
  } else {
    page = (
      <div className="space-y-6">
        <Recorder onSaved={refresh} />
        <RecordingList recordings={recordings} loading={loading} onChange={refresh} />
      </div>
    )
  }

  const Dot = ({ ok, label }: { ok: boolean; label: string }) => (
    <span className="inline-flex items-center gap-1.5 text-xs text-mute">
      <span className={`h-1.5 w-1.5 rounded-full ${ok ? 'bg-link' : 'bg-hairline-strong'}`} />
      {label}
    </span>
  )

  return (
    <div className="min-h-screen bg-canvas">
      <header className="sticky top-0 z-10 border-b border-hairline bg-canvas/80 backdrop-blur">
        <div className="mx-auto flex max-w-3xl items-center justify-between gap-4 px-4 py-3 sm:px-6">
          <div className="flex items-center gap-5">
            <button onClick={() => navigate('/')} className="font-semibold tracking-tight text-ink">
              timbre
            </button>
            <nav className="flex gap-1">
              {TABS.map((t) => (
                <a
                  key={t.path}
                  href={`#${t.path}`}
                  className={`rounded-md px-2 py-1 text-sm transition ${
                    activeTab === t.path ? 'bg-canvas-soft text-ink' : 'text-mute hover:text-ink'
                  }`}
                >
                  {t.label}
                </a>
              ))}
            </nav>
          </div>
          <div className="hidden items-center gap-4 sm:flex">
            <Dot ok={wasmOk} label="WASM" />
            <Dot ok={apiOk} label="API" />
          </div>
        </div>
      </header>

      <main className="mx-auto max-w-3xl px-4 py-8 sm:px-6">{page}</main>
    </div>
  )
}
