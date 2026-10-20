defmodule Timbre.RecordingsTest do
  use Timbre.DataCase

  alias Timbre.Recordings
  alias Timbre.Recordings.Recording

  @valid %{title: "Standup notes", mime_type: "audio/webm;codecs=opus", data: "fake-audio-bytes"}

  test "create_recording/1 stores the audio and its size" do
    assert {:ok, %Recording{} = rec} = Recordings.create_recording(@valid)
    assert rec.byte_size == byte_size(@valid.data)
    assert rec.kind == :solo
    # the payload isn't echoed back to callers
    assert rec.data == nil
    assert {:ok, "audio/webm;codecs=opus", "fake-audio-bytes"} = Recordings.fetch_audio(rec.id)
  end

  test "create_recording/1 rejects non-audio and missing data" do
    assert {:error, cs} = Recordings.create_recording(%{@valid | mime_type: "text/plain"})
    assert %{mime_type: ["must be an audio type"]} = errors_on(cs)

    assert {:error, cs} = Recordings.create_recording(Map.delete(@valid, :data))
    assert %{data: ["can't be blank"]} = errors_on(cs)
  end

  test "processed recordings keep their effect chain and source" do
    {:ok, source} = Recordings.create_recording(@valid)

    {:ok, processed} =
      Recordings.create_recording(
        %{
          @valid
          | title: "Anonymized",
            mime_type: "audio/wav"
        }
        |> Map.merge(%{
          kind: "processed",
          source_recording_id: source.id,
          effects: [%{"id" => "anonymize", "semitones" => -3}]
        })
      )

    loaded = Recordings.get_recording(processed.id)
    assert loaded.kind == :processed
    assert loaded.source_recording_id == source.id
    assert loaded.effects == [%{"id" => "anonymize", "semitones" => -3}]
  end

  test "list_recordings/0 is newest first and never loads audio" do
    {:ok, a} = Recordings.create_recording(%{@valid | title: "first"})
    {:ok, b} = Recordings.create_recording(%{@valid | title: "second"})

    assert [%{id: id1, data: nil}, %{id: id2, data: nil}] = Recordings.list_recordings()
    assert [id1, id2] == [b.id, a.id]
  end

  test "update and delete" do
    {:ok, rec} = Recordings.create_recording(@valid)
    rec = Recordings.get_recording(rec.id)
    assert {:ok, %{title: "Renamed"}} = Recordings.update_recording(rec, %{title: "  Renamed "})
    assert {:ok, _} = Recordings.delete_recording(rec)
    assert Recordings.get_recording(rec.id) == nil
    assert Recordings.fetch_audio(rec.id) == :error
  end
end
