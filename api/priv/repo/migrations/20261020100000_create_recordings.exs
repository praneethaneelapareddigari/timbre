defmodule Timbre.Repo.Migrations.CreateRecordings do
  use Ecto.Migration

  def change do
    create table(:recordings) do
      add :title, :string, null: false
      # solo (Part 1) | processed (Part 2, WASM output) | session (Part 3 mix)
      add :kind, :string, null: false, default: "solo"
      add :mime_type, :string, null: false
      add :byte_size, :integer, null: false
      add :duration_ms, :integer
      # The effect chain that produced a processed recording (JSON list).
      add :effects, :map
      # How many voices went into a session mix.
      add :participants, :integer
      add :source_recording_id, references(:recordings, on_delete: :nilify_all)
      # The audio itself. Kept in SQLite to keep the stack to one moving part;
      # see README for why object storage is the production answer.
      add :data, :binary, null: false
      # Bonus: LLM transcription + summary.
      add :transcript, :text
      add :summary, :text

      timestamps(type: :utc_datetime)
    end

    create index(:recordings, [:inserted_at])
    create index(:recordings, [:source_recording_id])
  end
end
