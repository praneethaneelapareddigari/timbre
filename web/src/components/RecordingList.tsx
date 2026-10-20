// Part 1: saved recordings with playback, plus entry points into Part 2
// (process in the Studio) and the transcription bonus.
import { useState } from 'react'
import {
  deleteRecording,
  renameRecording,
  transcribeRecording,
  type Recording,
} from '../lib/api'
import { formatBytes, formatDuration } from '../lib/audio'
import { EFFECT_BY_ID } from '../lib/effects'
import { navigate } from '../lib/router'
import { AudioPlayer, Badge, Button, Card, ErrorNote, SectionTitle } from './ui'

interface Props {
  recordings: Recording[]
  loading: boolean
  onChange: () => void
}

export default function RecordingList({ recordings, loading, onChange }: Props) {
  return (
    <Card>
      <SectionTitle aside={<span className="text-xs text-mute">{recordings.length} saved</span>}>
        Recordings
      </SectionTitle>
      {loading && recordings.length === 0 ? (
        <p className="text-sm text-mute">Loading…</p>
      ) : recordings.length === 0 ? (
        <p className="text-sm text-mute">Nothing yet — record something above.</p>
      ) : (
        <ul className="divide-y divide-hairline">
          {recordings.map((r) => (
            <RecordingRow key={r.id} recording={r} all={recordings} onChange={onChange} />
          ))}
        </ul>
      )}
    </Card>
  )
}

function RecordingRow({ recording: r, all, onChange }: { recording: Recording; all: Recording[]; onChange: () => void }) {
  const [busy, setBusy] = useState<null | 'delete' | 'transcribe' | 'rename'>(null)
  const [editing, setEditing] = useState(false)
  const [title, setTitle] = useState(r.title)
  const [error, setError] = useState<string | null>(null)
  const source = r.source_recording_id ? all.find((x) => x.id === r.source_recording_id) : null

  async function run(kind: 'delete' | 'transcribe' | 'rename', fn: () => Promise<unknown>): Promise<boolean> {
    setBusy(kind)
    setError(null)
    try {
      await fn()
      onChange()
      return true
    } catch (e) {
      setError((e as Error).message)
      return false
    } finally {
      setBusy(null)
    }
  }

  return (
    <li className="py-4 first:pt-0 last:pb-0">
      <div className="mb-2 flex flex-wrap items-center gap-2">
        {editing ? (
          <form
            className="flex flex-1 gap-2"
            onSubmit={(e) => {
              e.preventDefault()
              void run('rename', () => renameRecording(r.id, title)).then((ok) => ok && setEditing(false))
            }}
          >
            <input
              autoFocus
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              className="flex-1 rounded-md border border-hairline bg-canvas px-2 py-1 text-sm text-ink outline-none focus:border-link"
            />
            <Button type="submit" disabled={busy === 'rename'}>
              Save
            </Button>
          </form>
        ) : (
          <button
            className="truncate text-left text-sm font-medium text-ink hover:underline"
            title="Rename"
            onClick={() => setEditing(true)}
          >
            {r.title}
          </button>
        )}
        <KindBadge r={r} />
      </div>

      <AudioPlayer src={r.audio_url} />

      <div className="mt-2 flex flex-wrap items-center justify-between gap-2">
        <p className="text-xs text-mute">
          {formatDuration(r.duration_ms)} · {formatBytes(r.byte_size)} · {new Date(r.inserted_at).toLocaleString()}
          {source && <> · from “{source.title}”</>}
          {r.effects && r.effects.length > 0 && (
            <> · {r.effects.map((e) => EFFECT_BY_ID[e.id]?.label ?? e.id).join(' → ')}</>
          )}
        </p>
        <div className="flex gap-1">
          <Button variant="ghost" onClick={() => navigate(`/studio/${r.id}`)}>
            Process
          </Button>
          <Button
            variant="ghost"
            disabled={busy !== null}
            onClick={() => run('transcribe', () => transcribeRecording(r.id))}
          >
            {busy === 'transcribe' ? 'Transcribing…' : r.transcript ? 'Re-transcribe' : 'Transcribe'}
          </Button>
          <Button
            variant="ghost"
            className="hover:text-red-600"
            disabled={busy !== null}
            onClick={() => confirmDelete(r) && run('delete', () => deleteRecording(r.id))}
          >
            Delete
          </Button>
        </div>
      </div>

      {(r.summary || r.transcript) && (
        <details className="mt-2 rounded-md bg-canvas-soft px-3 py-2 text-sm">
          <summary className="cursor-pointer text-ink">{r.summary ?? 'Transcript'}</summary>
          <p className="mt-2 whitespace-pre-wrap text-body">{r.transcript}</p>
        </details>
      )}
      <ErrorNote error={error} />
    </li>
  )
}

// A native confirm() is deliberate here: deleting is rare and irreversible.
function confirmDelete(r: Recording) {
  return window.confirm(`Delete “${r.title}”? This can't be undone.`)
}

function KindBadge({ r }: { r: Recording }) {
  if (r.kind === 'processed') return <Badge tone="link">processed</Badge>
  if (r.kind === 'session') return <Badge tone="link">session · {r.participants ?? '?'} voices</Badge>
  return <Badge>recording</Badge>
}
