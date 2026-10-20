// Part 2: run recordings through the Rust/WASM effect chain, compare before
// and after, and save the result as a new recording.
import { useEffect, useMemo, useState } from 'react'
import { uploadRecording, type Recording } from '../lib/api'
import { decodeToMono, encodeWav, formatDuration, type MonoClip } from '../lib/audio'
import {
  chainItem,
  describeChain,
  EFFECT_BY_ID,
  EFFECTS,
  PRESETS,
  type ChainItem,
  type Tier,
} from '../lib/effects'
import { navigate } from '../lib/router'
import { wasmReady } from '../lib/wasm'
import { Badge, Button, Card, ErrorNote, SectionTitle, Waveform } from './ui'

interface Props {
  recordings: Recording[]
  selectedId: number | null
  onSaved: (r: Recording) => void
}

interface Result {
  clip: MonoClip
  url: string
  ms: number
  chain: ChainItem[]
}

const TIER_ORDER: Tier[] = ['easy', 'medium', 'advanced']

export default function Studio({ recordings, selectedId, onSaved }: Props) {
  const source = recordings.find((r) => r.id === selectedId) ?? null
  const [original, setOriginal] = useState<{ clip: MonoClip; url: string } | null>(null)
  const [chain, setChain] = useState<ChainItem[]>(() => PRESETS[0].chain())
  const [result, setResult] = useState<Result | null>(null)
  const [status, setStatus] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)

  // Load + decode the selected recording whenever the selection changes.
  useEffect(() => {
    setOriginal(null)
    setResult(null)
    setError(null)
    if (!source) return
    let cancelled = false
    let url: string | null = null
    setStatus('Decoding…')
    ;(async () => {
      try {
        const data = await (await fetch(source.audio_url)).arrayBuffer()
        const clip = await decodeToMono(data)
        if (cancelled) return
        url = URL.createObjectURL(encodeWav(clip.samples, clip.sampleRate))
        setOriginal({ clip, url })
        setStatus(null)
      } catch (e) {
        if (!cancelled) {
          setError(`Couldn't decode this recording: ${(e as Error).message}`)
          setStatus(null)
        }
      }
    })()
    return () => {
      cancelled = true
      if (url) URL.revokeObjectURL(url)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [source?.id])

  useEffect(() => () => {
    if (result) URL.revokeObjectURL(result.url)
  }, [result])

  async function apply() {
    if (!original) return
    setError(null)
    setStatus('Processing in WASM…')
    // Let React paint the status before the (synchronous) DSP runs.
    await new Promise((r) => setTimeout(r, 30))
    try {
      await wasmReady
      const t0 = performance.now()
      let samples = original.clip.samples
      for (const item of chain) {
        samples = EFFECT_BY_ID[item.id].run(samples, original.clip.sampleRate, item.params)
      }
      const ms = performance.now() - t0
      const clip = { samples, sampleRate: original.clip.sampleRate }
      setResult({ clip, url: URL.createObjectURL(encodeWav(samples, clip.sampleRate)), ms, chain })
    } catch (e) {
      setError(`Processing failed: ${(e as Error).message}`)
    } finally {
      setStatus(null)
    }
  }

  async function save() {
    if (!result || !source) return
    setSaving(true)
    setError(null)
    try {
      const names = result.chain.map((c) => EFFECT_BY_ID[c.id].label.toLowerCase()).join(', ')
      const rec = await uploadRecording(encodeWav(result.clip.samples, result.clip.sampleRate), {
        title: `${source.title} (${names || 'unprocessed'})`.slice(0, 200),
        kind: 'processed',
        durationMs: (result.clip.samples.length / result.clip.sampleRate) * 1000,
        effects: describeChain(result.chain),
        sourceRecordingId: source.id,
        filename: 'processed.wav',
      })
      onSaved(rec)
      navigate('/')
    } catch (e) {
      setError(`Save failed: ${(e as Error).message}`)
    } finally {
      setSaving(false)
    }
  }

  const stale = result && result.chain !== chain

  return (
    <div className="space-y-6">
      <Card>
        <SectionTitle>Source</SectionTitle>
        {recordings.length === 0 ? (
          <p className="text-sm text-mute">Record something first, then come back to process it.</p>
        ) : (
          <select
            value={selectedId ?? ''}
            onChange={(e) => navigate(e.target.value ? `/studio/${e.target.value}` : '/studio')}
            className="w-full rounded-md border border-hairline bg-canvas px-3 py-2 text-sm text-ink outline-none focus:border-link"
          >
            <option value="">Choose a recording…</option>
            {recordings.map((r) => (
              <option key={r.id} value={r.id}>
                {r.title} — {formatDuration(r.duration_ms)}
              </option>
            ))}
          </select>
        )}
      </Card>

      <Card>
        <SectionTitle
          aside={
            <div className="flex flex-wrap justify-end gap-1">
              {PRESETS.map((p) => (
                <Button key={p.name} variant="ghost" className="!px-2 text-xs" onClick={() => setChain(p.chain())}>
                  {p.name}
                </Button>
              ))}
            </div>
          }
        >
          Effect chain
        </SectionTitle>
        <ChainEditor chain={chain} onChange={setChain} />
      </Card>

      <Card>
        <SectionTitle
          aside={
            <div className="flex gap-2">
              <Button variant="primary" onClick={apply} disabled={!original || !!status || chain.length === 0}>
                {status ?? (result ? 'Re-apply' : 'Apply chain')}
              </Button>
              <Button onClick={save} disabled={!result || saving || !!stale}>
                {saving ? 'Saving…' : 'Save as new recording'}
              </Button>
            </div>
          }
        >
          Before / after
        </SectionTitle>
        {!source ? (
          <p className="text-sm text-mute">Pick a source recording.</p>
        ) : (
          <div className="space-y-4">
            <Compare label="Original" clip={original?.clip ?? null} url={original?.url ?? null} />
            <Compare
              label={
                result
                  ? `Processed · ${result.ms.toFixed(0)} ms in WASM${stale ? ' · chain changed, re-apply' : ''}`
                  : 'Processed'
              }
              clip={result?.clip ?? null}
              url={result?.url ?? null}
            />
          </div>
        )}
        <ErrorNote error={error} />
      </Card>
    </div>
  )
}

function Compare({ label, clip, url }: { label: string; clip: MonoClip | null; url: string | null }) {
  return (
    <div>
      <div className="mb-1 flex items-baseline justify-between text-xs text-mute">
        <span>{label}</span>
        {clip && (
          <span>
            {formatDuration((clip.samples.length / clip.sampleRate) * 1000)} · {clip.sampleRate / 1000} kHz
          </span>
        )}
      </div>
      <div className="rounded-md bg-canvas-soft px-2 py-1">
        <Waveform samples={clip?.samples ?? null} />
      </div>
      {url ? <audio src={url} controls className="mt-2 h-9 w-full" /> : <div className="mt-2 h-9" />}
    </div>
  )
}

function ChainEditor({ chain, onChange }: { chain: ChainItem[]; onChange: (c: ChainItem[]) => void }) {
  const grouped = useMemo(
    () => TIER_ORDER.map((tier) => ({ tier, effects: EFFECTS.filter((e) => e.tier === tier) })),
    [],
  )

  const update = (uid: number, key: string, value: number) =>
    onChange(chain.map((c) => (c.uid === uid ? { ...c, params: { ...c.params, [key]: value } } : c)))
  const remove = (uid: number) => onChange(chain.filter((c) => c.uid !== uid))
  const move = (i: number, dir: -1 | 1) => {
    const next = [...chain]
    const j = i + dir
    if (j < 0 || j >= next.length) return
    ;[next[i], next[j]] = [next[j], next[i]]
    onChange(next)
  }

  return (
    <div className="space-y-4">
      {chain.length === 0 && <p className="text-sm text-mute">Empty chain — add an effect below.</p>}
      <ol className="space-y-2">
        {chain.map((item, i) => {
          const def = EFFECT_BY_ID[item.id]
          return (
            <li key={item.uid} className="rounded-md border border-hairline p-3">
              <div className="mb-2 flex items-center justify-between gap-2">
                <div className="flex items-center gap-2">
                  <span className="font-mono text-xs text-mute">{i + 1}</span>
                  <span className="text-sm font-medium text-ink">{def.label}</span>
                  <Badge tone={def.tier === 'advanced' ? 'link' : 'mute'}>{def.tier}</Badge>
                </div>
                <div className="flex">
                  <Button variant="ghost" className="!px-1.5" onClick={() => move(i, -1)} disabled={i === 0} aria-label="Move up">
                    ↑
                  </Button>
                  <Button
                    variant="ghost"
                    className="!px-1.5"
                    onClick={() => move(i, 1)}
                    disabled={i === chain.length - 1}
                    aria-label="Move down"
                  >
                    ↓
                  </Button>
                  <Button variant="ghost" className="!px-1.5 hover:text-red-600" onClick={() => remove(item.uid)} aria-label="Remove">
                    ✕
                  </Button>
                </div>
              </div>
              <p className="mb-2 text-xs text-mute">{def.blurb}</p>
              <div className="grid gap-x-4 gap-y-2 sm:grid-cols-2">
                {def.params.map((p) => (
                  <label key={p.key} className="flex items-center gap-2 text-xs text-body">
                    <span className="w-20 shrink-0">{p.label}</span>
                    <input
                      type="range"
                      min={p.min}
                      max={p.max}
                      step={p.step}
                      value={item.params[p.key]}
                      onChange={(e) => update(item.uid, p.key, Number(e.target.value))}
                      className="flex-1 accent-[var(--color-link)]"
                    />
                    <span className="w-16 shrink-0 text-right font-mono tabular-nums text-ink">
                      {item.params[p.key]}
                      {p.unit ? ` ${p.unit}` : ''}
                    </span>
                  </label>
                ))}
              </div>
            </li>
          )
        })}
      </ol>

      <div className="space-y-2 border-t border-hairline pt-3">
        {grouped.map(({ tier, effects }) => (
          <div key={tier} className="flex flex-wrap items-center gap-1">
            <span className="w-20 text-xs uppercase tracking-wide text-mute">{tier}</span>
            {effects.map((e) => (
              <Button key={e.id} variant="ghost" className="!px-2 text-xs" onClick={() => onChange([...chain, chainItem(e.id)])}>
                + {e.label}
              </Button>
            ))}
          </div>
        ))}
      </div>
    </div>
  )
}
