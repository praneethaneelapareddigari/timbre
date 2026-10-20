defmodule Timbre.Recordings.Recording do
  @moduledoc """
  A saved audio clip. `data` holds the encoded audio (whatever the browser's
  MediaRecorder produced for solo takes, WAV for processed clips and session
  mixes); everything else is metadata.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds [:solo, :processed, :session]
  # Plenty for a voice memo; keeps a single row (and a single request) sane.
  @max_bytes 50_000_000

  schema "recordings" do
    field :title, :string
    field :kind, Ecto.Enum, values: @kinds, default: :solo
    field :mime_type, :string
    field :byte_size, :integer
    field :duration_ms, :integer
    field :effects, {:array, :map}
    field :participants, :integer
    field :data, :binary, redact: true
    field :transcript, :string
    field :summary, :string

    belongs_to :source_recording, __MODULE__

    timestamps(type: :utc_datetime)
  end

  @doc "Every field except the audio payload — what list/show queries select."
  def metadata_fields, do: __schema__(:fields) -- [:data]

  def max_bytes, do: @max_bytes

  def create_changeset(recording, attrs) do
    recording
    |> cast(attrs, [
      :title,
      :kind,
      :mime_type,
      :duration_ms,
      :effects,
      :participants,
      :data,
      :source_recording_id
    ])
    |> put_byte_size()
    |> validate_required([:title, :mime_type, :data])
    |> update_change(:title, &String.trim/1)
    |> validate_length(:title, min: 1, max: 200)
    |> validate_format(:mime_type, ~r{^audio/}, message: "must be an audio type")
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> validate_number(:byte_size, greater_than: 0, less_than_or_equal_to: @max_bytes)
    |> foreign_key_constraint(:source_recording_id)
  end

  def update_changeset(recording, attrs) do
    recording
    |> cast(attrs, [:title, :transcript, :summary])
    |> update_change(:title, &String.trim/1)
    |> validate_length(:title, min: 1, max: 200)
  end

  defp put_byte_size(changeset) do
    case get_change(changeset, :data) do
      data when is_binary(data) -> put_change(changeset, :byte_size, byte_size(data))
      _ -> changeset
    end
  end
end
