defmodule TimbreWeb.RecordingController do
  @moduledoc """
  REST surface for recordings.

      GET    /api/recordings              list (metadata only)
      POST   /api/recordings              multipart upload: audio + title [+ metadata]
      GET    /api/recordings/:id          one recording's metadata
      PATCH  /api/recordings/:id          rename
      DELETE /api/recordings/:id
      GET    /api/recordings/:id/audio    the audio bytes (supports Range)
      POST   /api/recordings/:id/transcribe   bonus: transcript + summary via LLM
  """
  use TimbreWeb, :controller

  alias Timbre.{AI, Recordings}
  alias Timbre.Recordings.Recording

  action_fallback TimbreWeb.FallbackController

  def index(conn, _params) do
    render(conn, :index, recordings: Recordings.list_recordings())
  end

  def show(conn, %{"id" => id}) do
    with {:ok, recording} <- fetch(id) do
      render(conn, :show, recording: recording)
    end
  end

  def create(conn, %{"audio" => %Plug.Upload{} = upload} = params) do
    with {:ok, data} <- File.read(upload.path),
         {:ok, recording} <- Recordings.create_recording(create_attrs(params, upload, data)) do
      conn
      |> put_status(:created)
      |> render(:show, recording: recording)
    end
  end

  def create(_conn, _params), do: {:error, :bad_request, "expected a multipart `audio` file"}

  def update(conn, %{"id" => id} = params) do
    with {:ok, recording} <- fetch(id),
         {:ok, recording} <- Recordings.update_recording(recording, Map.take(params, ["title"])) do
      render(conn, :show, recording: recording)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, recording} <- fetch(id),
         {:ok, _} <- Recordings.delete_recording(recording) do
      send_resp(conn, :no_content, "")
    end
  end

  @doc """
  Streams the stored audio. Honours single `Range: bytes=a-b` requests with a
  206 — Safari refuses to play (and every browser refuses to seek) media from
  servers that ignore Range.
  """
  def audio(conn, %{"id" => id}) do
    with {:ok, mime, data} <- fetch_audio(id) do
      size = byte_size(data)

      conn =
        conn
        |> put_resp_content_type(mime, nil)
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("cache-control", "private, max-age=3600")

      case parse_range(get_req_header(conn, "range"), size) do
        {:ok, first, last} ->
          conn
          |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
          |> send_resp(206, binary_part(data, first, last - first + 1))

        :unsatisfiable ->
          conn
          |> put_resp_header("content-range", "bytes */#{size}")
          |> send_resp(416, "")

        :full ->
          send_resp(conn, :ok, data)
      end
    end
  end

  def transcribe(conn, %{"id" => id}) do
    with {:ok, recording} <- fetch(id),
         {:ok, mime, data} <- fetch_audio(id),
         {:ok, result} <- AI.transcribe_and_summarize(data, mime),
         {:ok, recording} <-
           Recordings.update_recording(recording, %{
             transcript: result.transcript,
             summary: result.summary,
             title: result.title
           }) do
      render(conn, :show, recording: recording)
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp fetch(id) do
    case Recordings.get_recording(id) do
      %Recording{} = recording -> {:ok, recording}
      nil -> {:error, :not_found}
    end
  end

  defp fetch_audio(id) do
    case Recordings.fetch_audio(id) do
      {:ok, mime, data} -> {:ok, mime, data}
      :error -> {:error, :not_found}
    end
  end

  defp create_attrs(params, upload, data) do
    %{
      "title" => blank_to_nil(params["title"]) || default_title(),
      "kind" => params["kind"] || "solo",
      # Browsers append codec info ("audio/webm;codecs=opus"); keep it — the
      # <audio> element uses it to pick a decoder.
      "mime_type" => upload.content_type,
      "duration_ms" => params["duration_ms"],
      "effects" => decode_effects(params["effects"]),
      "source_recording_id" => blank_to_nil(params["source_recording_id"]),
      "data" => data
    }
  end

  defp decode_effects(nil), do: nil

  defp decode_effects(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> nil
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp default_title do
    "Recording " <> Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M")
  end

  # Only the single-range forms browsers actually send are supported:
  # "bytes=a-b", "bytes=a-" and suffix "bytes=-n".
  defp parse_range(["bytes=" <> spec], size) when size > 0 do
    case String.split(spec, "-", parts: 2) do
      ["", suffix] ->
        case to_int(suffix) do
          nil -> :full
          n -> range_from(size - n, size - 1, size)
        end

      [first, ""] ->
        range_from(to_int(first), size - 1, size)

      [first, last] ->
        case to_int(last) do
          nil -> :full
          l -> range_from(to_int(first), min(l, size - 1), size)
        end

      _ ->
        :full
    end
  end

  defp parse_range(_, _size), do: :full

  defp range_from(first, last, size) when is_integer(first) and is_integer(last) do
    first = max(first, 0)
    if first <= last and first < size, do: {:ok, first, last}, else: :unsatisfiable
  end

  defp range_from(_, _, _), do: :full

  defp to_int(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end
end
