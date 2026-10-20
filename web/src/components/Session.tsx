// Part 3: multiplayer sessions. Everyone in the room streams their mic to
// Phoenix over a channel; Phoenix mixes the takes into one saved recording.
//
// Mic path:  mic → AudioWorklet (Float32 blocks) → Rust StreamResampler
//            (→ 24 kHz Int16) → 100 ms frames → channel.push("audio", binary)
import { Channel, Socket } from 'phoenix'
import { useEffect, useRef, useState } from 'react'
import { rms_level, StreamResampler } from 'timbre_kit'
import { createSession, type Recording } from '../lib/api'
import { formatDuration, MIC_CONSTRAINTS } from '../lib/audio'
import { navigate, shareUrl } from '../lib/router'
import { wasmReady } from '../lib/wasm'
import { AudioPlayer, Badge, Button, Card, ErrorNote, LevelMeter, SectionTitle } from './ui'

interface Participant {
  id: string
  name: string
}

interface SessionState {
  code: string
  status: 'idle' | 'recording' | 'finalizing'
  take: number
  sample_rate: number
  participants: Participant[]
  last_recording: { id: number; title: string; duration_ms: number } | null
}

const NAME_KEY = 'timbre:name'
const FRAME_SAMPLES = 2400 // 100 ms at 24 kHz

function storedName(): string {
  try {
    return localStorage.getItem(NAME_KEY) ?? ''
  } catch {
    return ''
  }
}

function rememberName(name: string) {
  try {
    localStorage.setItem(NAME_KEY, name)
  } catch {
    /* storage unavailable (private mode) — not important */
  }
}

// --- lobby -------------------------------------------------------------------

export function SessionLobby() {
  const [code, setCode] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)

  async function create() {
    setCreating(true)
    setError(null)
    try {
      const s = await createSession()
      navigate(`/session/${s.code}`)
    } catch (e) {
      setError((e as Error).message)
      setCreating(false)
    }
  }

  return (
    <Card>
      <SectionTitle>Group session</SectionTitle>
      <p className="mb-4 text-sm text-body">
        Start a session, share the link, and everyone who joins — other tabs, phones, laptops — records together. Their
        microphones stream live to the server, which mixes them into a single recording.
      </p>
      <div className="flex flex-col gap-3 sm:flex-row">
        <Button variant="primary" onClick={create} disabled={creating}>
          {creating ? 'Creating…' : 'Start a new session'}
        </Button>
        <form
          className="flex flex-1 gap-2"
          onSubmit={(e) => {
            e.preventDefault()
            const c = code.trim().toUpperCase()
            if (c) navigate(`/session/${c}`)
          }}
        >
          <input
            value={code}
            onChange={(e) => setCode(e.target.value)}
            placeholder="or enter a code"
            className="flex-1 rounded-md border border-hairline bg-canvas px-3 py-1.5 font-mono text-sm uppercase text-ink outline-none focus:border-link"
          />
          <Button type="submit">Join</Button>
        </form>
      </div>
      <ErrorNote error={error} />
    </Card>
  )
}

// --- room --------------------------------------------------------------------

export function SessionRoom({ code, onRecordingSaved }: { code: string; onRecordingSaved: (r?: Recording) => void }) {
  const [name, setName] = useState(storedName)
  const [joined, setJoined] = useState(false)

  if (!joined) {
    return (
      <Card>
        <SectionTitle>
          Join session <span className="font-mono">{code}</span>
        </SectionTitle>
        <form
          className="flex gap-2"
          onSubmit={(e) => {
            e.preventDefault()
            rememberName(name.trim())
            // This click is also the user gesture browsers require before
            // they'll let us open the mic and start an AudioContext.
            setJoined(true)
          }}
        >
          <input
            autoFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Your name"
            maxLength={40}
            className="flex-1 rounded-md border border-hairline bg-canvas px-3 py-1.5 text-sm text-ink outline-none focus:border-link"
          />
          <Button variant="primary" type="submit">
            Join with microphone
          </Button>
        </form>
      </Card>
    )
  }

  return <LiveRoom code={code} name={name.trim() || 'Guest'} onRecordingSaved={onRecordingSaved} />
}

interface Live {
  socket: Socket
  channel: Channel
  stream: MediaStream
  ctx: AudioContext
  node: AudioWorkletNode
  // per-take streaming state
  take: number | null
  resampler: StreamResampler | null
  pending: Int16Array[]
  pendingLen: number
  offset: number
  lastLevelSent: number
}

function LiveRoom({
  code,
  name,
  onRecordingSaved,
}: {
  code: string
  name: string
  onRecordingSaved: (r?: Recording) => void
}) {
  const [state, setState] = useState<SessionState | null>(null)
  const [me, setMe] = useState<string | null>(null)
  const [levels, setLevels] = useState<Record<string, number>>({})
  const [seconds, setSeconds] = useState<Record<string, number>>({})
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const live = useRef<Live | null>(null)
  const meRef = useRef<string | null>(null)
  const savedCb = useRef(onRecordingSaved)
  savedCb.current = onRecordingSaved

  useEffect(() => {
    let disposed = false
    let cleanup: (() => void) | null = null

    ;(async () => {
      try {
        await wasmReady
        const stream = await navigator.mediaDevices.getUserMedia(MIC_CONSTRAINTS)
        const ctx = new AudioContext()
        await ctx.audioWorklet.addModule('/pcm-worklet.js')
        const node = new AudioWorkletNode(ctx, 'pcm-capture')
        ctx.createMediaStreamSource(stream).connect(node)
        // Pull the worklet through the graph without playing the mic back.
        const mute = ctx.createGain()
        mute.gain.value = 0
        node.connect(mute).connect(ctx.destination)

        const socket = new Socket('/socket')
        socket.connect()
        const channel = socket.channel(`session:${code}`, { name })

        const l: Live = {
          socket,
          channel,
          stream,
          ctx,
          node,
          take: null,
          resampler: null,
          pending: [],
          pendingLen: 0,
          offset: 0,
          lastLevelSent: 0,
        }

        cleanup = () => {
          l.node.port.onmessage = null
          l.stream.getTracks().forEach((t) => t.stop())
          void l.ctx.close()
          l.resampler?.free()
          l.channel.leave()
          l.socket.disconnect()
        }
        if (disposed) {
          cleanup()
          return
        }
        live.current = l

        // Send whatever's buffered as one frame: <<take u32le, offset u32le, pcm s16le…>>
        const flush = () => {
          if (l.take == null || l.pendingLen === 0) return
          const frame = new ArrayBuffer(8 + l.pendingLen * 2)
          const header = new DataView(frame)
          header.setUint32(0, l.take, true)
          header.setUint32(4, l.offset, true)
          const body = new Int16Array(frame, 8)
          let at = 0
          for (const part of l.pending) {
            body.set(part, at)
            at += part.length
          }
          l.channel.push('audio', frame)
          l.offset += l.pendingLen
          l.pending = []
          l.pendingLen = 0
        }

        node.port.onmessage = (e: MessageEvent<Float32Array>) => {
          const block = e.data
          const level = rms_level(block)
          const now = performance.now()
          if (meRef.current) setLevels((prev) => ({ ...prev, [meRef.current!]: level }))
          if (now - l.lastLevelSent > 150) {
            l.channel.push('level', { level })
            l.lastLevelSent = now
          }
          if (l.take != null && l.resampler) {
            const pcm = l.resampler.push(block)
            l.pending.push(pcm)
            l.pendingLen += pcm.length
            if (l.pendingLen >= FRAME_SAMPLES) flush()
          }
        }

        channel.on('state', (s: SessionState) => setState(s))
        channel.on('level', ({ id, level }: { id: string; level: number }) =>
          setLevels((prev) => ({ ...prev, [id]: level })),
        )
        channel.on('stats', ({ seconds }: { seconds: Record<string, number> }) => setSeconds(seconds))
        channel.on('recording_started', ({ take, sample_rate }: { take: number; sample_rate: number }) => {
          l.resampler?.free()
          l.resampler = new StreamResampler(ctx.sampleRate, sample_rate)
          l.take = take
          l.offset = 0
          l.pending = []
          l.pendingLen = 0
          setSeconds({})
          setNotice(null)
        })
        channel.on('recording_stopping', ({ take }: { take: number }) => {
          if (l.take === take) {
            flush()
            l.take = null
            channel.push('flushed', { take })
          }
          setNotice('Mixing…')
        })
        channel.on('recording_saved', ({ recording }: { recording: { title: string } }) => {
          setNotice(`Saved “${recording.title}”`)
          savedCb.current()
        })
        channel.on('recording_failed', ({ reason }: { reason: string }) => setNotice(`Not saved: ${reason}`))

        channel
          .join()
          .receive('ok', (reply: { participant_id: string; session: SessionState }) => {
            meRef.current = reply.participant_id
            setMe(reply.participant_id)
            setState(reply.session)
            if (reply.session.status !== 'idle') {
              setNotice('A take is in progress — you’ll be included in the next one.')
            }
          })
          .receive('error', (reply: { reason?: string }) => {
            // Don't let phoenix.js keep retrying a join the server rejected.
            channel.leave()
            setError(reply.reason ?? 'Could not join this session.')
          })
      } catch (e) {
        setError(
          e instanceof DOMException && e.name === 'NotAllowedError'
            ? 'Microphone permission was denied — the session needs your mic.'
            : `Couldn't join: ${(e as Error).message}`,
        )
      }
    })()

    return () => {
      disposed = true
      live.current = null
      cleanup?.()
    }
  }, [code, name])

  function control(event: 'start' | 'stop') {
    live.current?.channel
      .push(event, {})
      .receive('error', (r: { reason?: string }) => setNotice(`Couldn't ${event}: ${r.reason ?? 'error'}`))
  }

  async function copyLink() {
    try {
      await navigator.clipboard.writeText(shareUrl(`/session/${code}`))
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      /* clipboard blocked — the link is visible to copy by hand */
    }
  }

  const recording = state?.status === 'recording'
  const finalizing = state?.status === 'finalizing'

  return (
    <div className="space-y-6">
      <Card>
        <SectionTitle
          aside={
            recording ? (
              <Badge tone="live">● recording · take {state?.take}</Badge>
            ) : finalizing ? (
              <Badge tone="link">mixing…</Badge>
            ) : (
              <Badge>{state ? 'ready' : 'connecting…'}</Badge>
            )
          }
        >
          Session <span className="font-mono">{code}</span>
        </SectionTitle>

        <div className="mb-5 flex items-center gap-2">
          <input
            readOnly
            value={shareUrl(`/session/${code}`)}
            onFocus={(e) => e.target.select()}
            className="flex-1 truncate rounded-md border border-hairline bg-canvas-soft px-3 py-1.5 font-mono text-xs text-body"
          />
          <Button onClick={copyLink}>{copied ? 'Copied' : 'Copy link'}</Button>
        </div>

        <ul className="mb-5 space-y-3">
          {(state?.participants ?? []).map((p) => (
            <li key={p.id} className="flex items-center gap-3">
              <span className="w-32 truncate text-sm text-ink">
                {p.name}
                {p.id === me && <span className="text-mute"> (you)</span>}
              </span>
              <LevelMeter level={levels[p.id] ?? 0} className="flex-1" />
              <span className="w-12 text-right font-mono text-xs tabular-nums text-mute">
                {recording && seconds[p.id] != null ? `${seconds[p.id].toFixed(1)}s` : ''}
              </span>
            </li>
          ))}
        </ul>

        <div className="flex items-center gap-3">
          {recording ? (
            <Button variant="primary" onClick={() => control('stop')}>
              <span className="h-2 w-2 rounded-sm bg-canvas" /> Stop & mix
            </Button>
          ) : (
            <Button variant="primary" onClick={() => control('start')} disabled={!state || finalizing}>
              <span className="h-2 w-2 rounded-full bg-red-500" /> Start recording everyone
            </Button>
          )}
          {notice && <span className="text-sm text-mute">{notice}</span>}
        </div>
        <ErrorNote error={error} />
      </Card>

      {state?.last_recording && (
        <Card>
          <SectionTitle aside={<span className="text-xs text-mute">{formatDuration(state.last_recording.duration_ms)}</span>}>
            Latest mix — {state.last_recording.title}
          </SectionTitle>
          <AudioPlayer src={`/api/recordings/${state.last_recording.id}/audio`} />
          <p className="mt-2 text-xs text-mute">
            Also saved to your recordings —{' '}
            <button className="text-link hover:underline" onClick={() => navigate(`/studio/${state.last_recording!.id}`)}>
              process it in the Studio
            </button>
            .
          </p>
        </Card>
      )}
    </div>
  )
}
