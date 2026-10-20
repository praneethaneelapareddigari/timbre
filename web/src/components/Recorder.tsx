// Part 1: record from the mic, preview, and save to the Phoenix API.
import { useEffect, useRef, useState } from 'react'
import { rms_level } from 'timbre_kit'
import { uploadRecording, type Recording } from '../lib/api'
import { formatDuration, MIC_CONSTRAINTS, pickRecorderMime } from '../lib/audio'
import { wasmReady } from '../lib/wasm'
import { Button, Card, ErrorNote, LevelMeter, SectionTitle } from './ui'

type Phase = 'idle' | 'recording' | 'review' | 'saving'

interface Take {
  blob: Blob
  url: string
  durationMs: number
}

export default function Recorder({ onSaved }: { onSaved: (r: Recording) => void }) {
  const [phase, setPhase] = useState<Phase>('idle')
  const [elapsed, setElapsed] = useState(0)
  const [level, setLevel] = useState(0)
  const [take, setTake] = useState<Take | null>(null)
  const [title, setTitle] = useState('')
  const [error, setError] = useState<string | null>(null)

  // Everything the live recording needs, torn down together in stopAll().
  const live = useRef<{
    stream: MediaStream
    recorder: MediaRecorder
    ctx: AudioContext
    raf: number
    startedAt: number
  } | null>(null)

  const stopAll = () => {
    const l = live.current
    if (!l) return
    cancelAnimationFrame(l.raf)
    l.stream.getTracks().forEach((t) => t.stop())
    void l.ctx.close()
    live.current = null
    setLevel(0)
  }

  useEffect(() => stopAll, [])
  useEffect(() => () => {
    if (take) URL.revokeObjectURL(take.url)
  }, [take])

  async function start() {
    setError(null)
    try {
      await wasmReady
      const stream = await navigator.mediaDevices.getUserMedia(MIC_CONSTRAINTS)
      const mimeType = pickRecorderMime()
      const recorder = new MediaRecorder(stream, mimeType ? { mimeType } : undefined)
      const chunks: Blob[] = []
      recorder.ondataavailable = (e) => e.data.size > 0 && chunks.push(e.data)

      // Live meter: analyser → Float32 frame → RMS computed in Rust/WASM.
      const ctx = new AudioContext()
      const analyser = ctx.createAnalyser()
      analyser.fftSize = 2048
      ctx.createMediaStreamSource(stream).connect(analyser)
      const frame = new Float32Array(analyser.fftSize)

      const startedAt = performance.now()
      const tick = () => {
        analyser.getFloatTimeDomainData(frame)
        setLevel(rms_level(frame))
        setElapsed(performance.now() - startedAt)
        if (live.current) live.current.raf = requestAnimationFrame(tick)
      }

      recorder.onstop = () => {
        const durationMs = performance.now() - startedAt
        const blob = new Blob(chunks, { type: recorder.mimeType || mimeType || 'audio/webm' })
        stopAll()
        setTake({ blob, url: URL.createObjectURL(blob), durationMs })
        setTitle(`Voice memo ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`)
        setPhase('review')
      }

      live.current = { stream, recorder, ctx, raf: requestAnimationFrame(tick), startedAt }
      // Timeslice so a crash mid-take still leaves us most of the audio.
      recorder.start(1000)
      setElapsed(0)
      setPhase('recording')
    } catch (e) {
      stopAll()
      setError(
        e instanceof DOMException && e.name === 'NotAllowedError'
          ? 'Microphone permission was denied. Allow it in the browser’s site settings and try again.'
          : `Couldn't start recording: ${(e as Error).message}`,
      )
    }
  }

  function stop() {
    live.current?.recorder.stop()
  }

  function discard() {
    setTake(null)
    setPhase('idle')
  }

  async function save() {
    if (!take) return
    setPhase('saving')
    setError(null)
    try {
      const rec = await uploadRecording(take.blob, { title: title.trim() || 'Untitled', durationMs: take.durationMs })
      onSaved(rec)
      setTake(null)
      setPhase('idle')
    } catch (e) {
      setError(`Save failed: ${(e as Error).message}`)
      setPhase('review')
    }
  }

  return (
    <Card>
      <SectionTitle>Record</SectionTitle>

      {(phase === 'idle' || phase === 'recording') && (
        <div className="flex items-center gap-4">
          {phase === 'idle' ? (
            <Button variant="primary" onClick={start}>
              <span className="h-2 w-2 rounded-full bg-red-500" /> Start recording
            </Button>
          ) : (
            <Button variant="primary" onClick={stop}>
              <span className="h-2 w-2 rounded-sm bg-canvas" /> Stop
            </Button>
          )}
          <span className="w-12 font-mono text-sm tabular-nums text-ink">
            {formatDuration(phase === 'recording' ? elapsed : 0)}
          </span>
          <LevelMeter level={level} className="flex-1" />
          {phase === 'recording' && <span className="h-2 w-2 animate-pulse rounded-full bg-red-500" />}
        </div>
      )}

      {(phase === 'review' || phase === 'saving') && take && (
        <div className="space-y-3">
          <audio src={take.url} controls className="h-9 w-full" />
          <div className="flex flex-col gap-2 sm:flex-row">
            <input
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder="Title"
              maxLength={200}
              className="flex-1 rounded-md border border-hairline bg-canvas px-3 py-1.5 text-sm text-ink outline-none focus:border-link"
            />
            <div className="flex gap-2">
              <Button variant="primary" onClick={save} disabled={phase === 'saving'}>
                {phase === 'saving' ? 'Saving…' : 'Save'}
              </Button>
              <Button variant="ghost" onClick={discard} disabled={phase === 'saving'}>
                Discard
              </Button>
            </div>
          </div>
          <p className="text-xs text-mute">
            {formatDuration(take.durationMs)} · {take.blob.type || 'audio'} · {(take.blob.size / 1024).toFixed(0)} KB
          </p>
        </div>
      )}

      <ErrorNote error={error} />
    </Card>
  )
}
