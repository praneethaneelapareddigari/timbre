defmodule Timbre.Recordings do
  @moduledoc """
  The recordings context: persist audio clips and read them back.

  List and show queries never load the `data` column, so listing 100 clips
  doesn't pull 100 audio files into memory; the bytes are only read when a
  client actually streams one via `fetch_audio/1`.
  """
  import Ecto.Query

  alias Timbre.Recordings.Recording
  alias Timbre.Repo

  @doc "All recordings, newest first, without their audio payload."
  def list_recordings do
    Recording
    |> select([r], struct(r, ^Recording.metadata_fields()))
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> Repo.all()
  end

  @doc "One recording's metadata, or nil."
  def get_recording(id) do
    Recording
    |> where([r], r.id == ^id)
    |> select([r], struct(r, ^Recording.metadata_fields()))
    |> Repo.one()
  end

  @doc "The audio bytes and their MIME type, or `:error` if there's no such recording."
  def fetch_audio(id) do
    Recording
    |> where([r], r.id == ^id)
    |> select([r], {r.mime_type, r.data})
    |> Repo.one()
    |> case do
      nil -> :error
      {mime, data} -> {:ok, mime, data}
    end
  end

  def create_recording(attrs) do
    %Recording{}
    |> Recording.create_changeset(attrs)
    |> Repo.insert()
    |> case do
      # Don't hand the (possibly multi-MB) payload back to callers.
      {:ok, rec} -> {:ok, %{rec | data: nil}}
      error -> error
    end
  end

  def update_recording(%Recording{} = recording, attrs) do
    recording
    |> Recording.update_changeset(attrs)
    |> Repo.update()
  end

  def delete_recording(%Recording{} = recording), do: Repo.delete(recording)
end
