// Thin typed client for the Phoenix JSON API. Same origin in dev (Vite proxy)
// and prod (Phoenix serves the built app), so plain relative URLs everywhere.

export type RecordingKind = 'solo' | 'processed' | 'session'

export interface EffectStep {
  id: string
  [param: string]: number | string
}

export interface Recording {
  id: number
  title: string
  kind: RecordingKind
  mime_type: string
  byte_size: number
  duration_ms: number | null
  effects: EffectStep[] | null
  participants: number | null
  source_recording_id: number | null
  transcript: string | null
  summary: string | null
  audio_url: string
  inserted_at: string
}

async function request<T>(url: string, init?: RequestInit): Promise<T> {
  const res = await fetch(url, { headers: { Accept: 'application/json' }, ...init })
  if (!res.ok) {
    let detail = `${res.status} ${res.statusText}`
    try {
      const body = await res.json()
      const errors = body?.errors
      if (errors?.detail) detail = errors.detail
      else if (errors) detail = Object.entries(errors).map(([k, v]) => `${k} ${(v as string[]).join(', ')}`).join('; ')
    } catch {
      /* non-JSON error body */
    }
    throw new Error(detail)
  }
  return res.status === 204 ? (undefined as T) : res.json()
}

export const listRecordings = () => request<{ data: Recording[] }>('/api/recordings').then((r) => r.data)

export const getRecording = (id: number) =>
  request<{ data: Recording }>(`/api/recordings/${id}`).then((r) => r.data)

export interface UploadOptions {
  title: string
  durationMs?: number
  kind?: RecordingKind
  effects?: EffectStep[]
  sourceRecordingId?: number
  filename?: string
}

export function uploadRecording(audio: Blob, opts: UploadOptions): Promise<Recording> {
  const form = new FormData()
  form.append('audio', audio, opts.filename ?? `recording.${extensionFor(audio.type)}`)
  form.append('title', opts.title)
  if (opts.durationMs != null) form.append('duration_ms', String(Math.round(opts.durationMs)))
  if (opts.kind) form.append('kind', opts.kind)
  if (opts.effects) form.append('effects', JSON.stringify(opts.effects))
  if (opts.sourceRecordingId != null) form.append('source_recording_id', String(opts.sourceRecordingId))
  return request<{ data: Recording }>('/api/recordings', { method: 'POST', body: form }).then((r) => r.data)
}

export const renameRecording = (id: number, title: string) =>
  request<{ data: Recording }>(`/api/recordings/${id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify({ title }),
  }).then((r) => r.data)

export const deleteRecording = (id: number) => request<void>(`/api/recordings/${id}`, { method: 'DELETE' })

export const transcribeRecording = (id: number) =>
  request<{ data: Recording }>(`/api/recordings/${id}/transcribe`, { method: 'POST' }).then((r) => r.data)

export const createSession = () =>
  request<{ data: { code: string; sample_rate: number } }>('/api/sessions', { method: 'POST' }).then((r) => r.data)

export function extensionFor(mime: string): string {
  if (mime.includes('webm')) return 'webm'
  if (mime.includes('ogg')) return 'ogg'
  if (mime.includes('mp4') || mime.includes('aac')) return 'm4a'
  if (mime.includes('wav')) return 'wav'
  return 'bin'
}
