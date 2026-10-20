defmodule TimbreWeb.RecordingJSON do
  alias Timbre.Recordings.Recording

  def index(%{recordings: recordings}), do: %{data: Enum.map(recordings, &data/1)}

  def show(%{recording: recording}), do: %{data: data(recording)}

  defp data(%Recording{} = r) do
    %{
      id: r.id,
      title: r.title,
      kind: r.kind,
      mime_type: r.mime_type,
      byte_size: r.byte_size,
      duration_ms: r.duration_ms,
      effects: r.effects,
      participants: r.participants,
      source_recording_id: r.source_recording_id,
      transcript: r.transcript,
      summary: r.summary,
      audio_url: "/api/recordings/#{r.id}/audio",
      inserted_at: r.inserted_at
    }
  end
end
