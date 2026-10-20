// Browser-side audio plumbing shared by the recorder, studio and sessions.
import { mix_to_mono } from 'timbre_kit'
import { wasmReady } from './wasm'

export interface MonoClip {
  samples: Float32Array
  sampleRate: number
}

/** Decode any browser-playable audio (webm/opus, mp4/aac, wav…) to mono f32 PCM. */
export async function decodeToMono(data: ArrayBuffer): Promise<MonoClip> {
  await wasmReady
  const ctx = new AudioContext()
  try {
    const buf = await ctx.decodeAudioData(data)
    const samples =
      buf.numberOfChannels > 1
        ? mix_to_mono(buf.getChannelData(0), buf.getChannelData(1))
        : new Float32Array(buf.getChannelData(0))
    return { samples, sampleRate: buf.sampleRate }
  } finally {
    void ctx.close()
  }
}

/** Encode mono f32 PCM as a 16-bit WAV blob (what processed clips are saved as). */
export function encodeWav(samples: Float32Array, sampleRate: number): Blob {
  const bytes = samples.length * 2
  const buf = new ArrayBuffer(44 + bytes)
  const view = new DataView(buf)
  const ascii = (offset: number, s: string) => [...s].forEach((c, i) => view.setUint8(offset + i, c.charCodeAt(0)))

  ascii(0, 'RIFF')
  view.setUint32(4, 36 + bytes, true)
  ascii(8, 'WAVE')
  ascii(12, 'fmt ')
  view.setUint32(16, 16, true) // fmt chunk size
  view.setUint16(20, 1, true) // PCM
  view.setUint16(22, 1, true) // mono
  view.setUint32(24, sampleRate, true)
  view.setUint32(28, sampleRate * 2, true) // byte rate
  view.setUint16(32, 2, true) // block align
  view.setUint16(34, 16, true) // bits per sample
  ascii(36, 'data')
  view.setUint32(40, bytes, true)

  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]))
    view.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true)
  }
  return new Blob([buf], { type: 'audio/wav' })
}

/** Best container the browser can record into, most compact first. */
export function pickRecorderMime(): string | undefined {
  const candidates = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus']
  return candidates.find((m) => typeof MediaRecorder !== 'undefined' && MediaRecorder.isTypeSupported(m))
}

export function formatDuration(ms: number | null | undefined): string {
  if (ms == null || !Number.isFinite(ms)) return '–:––'
  const total = Math.round(ms / 1000)
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`
}

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`
  return `${(n / 1024 / 1024).toFixed(1)} MB`
}

/** Speech-friendly mic constraints. */
export const MIC_CONSTRAINTS: MediaStreamConstraints = {
  audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
}
