import { useEffect, useRef, type ButtonHTMLAttributes, type ReactNode } from 'react'

type Variant = 'primary' | 'secondary' | 'danger' | 'ghost'

const VARIANTS: Record<Variant, string> = {
  primary: 'bg-ink text-canvas hover:opacity-85',
  secondary: 'border border-hairline text-ink hover:bg-canvas-soft',
  danger: 'border border-hairline text-red-600 hover:bg-red-500/10',
  ghost: 'text-mute hover:text-ink',
}

export function Button({
  variant = 'secondary',
  className = '',
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant }) {
  return (
    <button
      {...props}
      className={`inline-flex items-center justify-center gap-2 rounded-md px-3 py-1.5 text-sm font-medium transition disabled:cursor-not-allowed disabled:opacity-40 ${VARIANTS[variant]} ${className}`}
    />
  )
}

export function Card({ children, className = '' }: { children: ReactNode; className?: string }) {
  return <section className={`rounded-lg border border-hairline bg-canvas p-5 ${className}`}>{children}</section>
}

export function SectionTitle({ children, aside }: { children: ReactNode; aside?: ReactNode }) {
  return (
    <div className="mb-4 flex items-center justify-between gap-3">
      <h2 className="text-sm font-semibold tracking-tight text-ink">{children}</h2>
      {aside}
    </div>
  )
}

export function Badge({ children, tone = 'mute' }: { children: ReactNode; tone?: 'mute' | 'link' | 'live' }) {
  const tones = {
    mute: 'border-hairline text-mute',
    link: 'border-link/40 text-link',
    live: 'border-red-500/40 text-red-500',
  }
  return (
    <span className={`inline-flex items-center rounded-full border px-2 py-0.5 text-[11px] font-medium ${tones[tone]}`}>
      {children}
    </span>
  )
}

/** Horizontal level bar. `level` is RMS in 0..1; displayed on a dB-ish scale. */
export function LevelMeter({ level, className = '' }: { level: number; className?: string }) {
  // -60 dBFS → empty, 0 dBFS → full
  const db = 20 * Math.log10(Math.max(level, 1e-6))
  const pct = Math.max(0, Math.min(100, ((db + 60) / 60) * 100))
  return (
    <div className={`h-1.5 overflow-hidden rounded-full bg-hairline ${className}`}>
      <div className="h-full rounded-full bg-link transition-[width] duration-75" style={{ width: `${pct}%` }} />
    </div>
  )
}

/**
 * <audio> wrapper. Chrome's MediaRecorder writes WebM without a duration, so
 * the native player shows "Infinity" and can't seek; seeking far past the end
 * once forces the browser to scan the file and learn the real duration.
 */
export function AudioPlayer({ src, className = '' }: { src: string; className?: string }) {
  const ref = useRef<HTMLAudioElement>(null)

  useEffect(() => {
    const el = ref.current
    if (!el) return
    const onMeta = () => {
      if (el.duration === Infinity) {
        const reset = () => {
          el.removeEventListener('timeupdate', reset)
          el.currentTime = 0
        }
        el.addEventListener('timeupdate', reset)
        el.currentTime = 1e101
      }
    }
    el.addEventListener('loadedmetadata', onMeta)
    return () => el.removeEventListener('loadedmetadata', onMeta)
  }, [src])

  return <audio ref={ref} src={src} controls preload="metadata" className={`h-9 w-full ${className}`} />
}

/** Min/max-per-pixel waveform of mono samples. */
export function Waveform({ samples, className = '' }: { samples: Float32Array | null; className?: string }) {
  const ref = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = ref.current
    if (!canvas) return
    const dpr = window.devicePixelRatio || 1
    const width = canvas.clientWidth * dpr
    const height = canvas.clientHeight * dpr
    canvas.width = width
    canvas.height = height
    const ctx = canvas.getContext('2d')
    if (!ctx) return
    ctx.clearRect(0, 0, width, height)
    if (!samples || samples.length === 0) return

    ctx.fillStyle = getComputedStyle(canvas).color
    const per = samples.length / width
    const mid = height / 2
    for (let x = 0; x < width; x++) {
      let min = 1
      let max = -1
      const start = Math.floor(x * per)
      const end = Math.min(samples.length, Math.floor((x + 1) * per) + 1)
      for (let i = start; i < end; i++) {
        const v = samples[i]
        if (v < min) min = v
        if (v > max) max = v
      }
      const top = mid - max * mid
      ctx.fillRect(x, top, 1, Math.max(1, (max - min) * mid))
    }
  }, [samples])

  return <canvas ref={ref} className={`h-16 w-full text-ink/70 ${className}`} />
}

export function ErrorNote({ error }: { error: string | null }) {
  if (!error) return null
  return <p className="mt-3 rounded-md border border-red-500/30 bg-red-500/5 px-3 py-2 text-sm text-red-600">{error}</p>
}
