defmodule Timbre.AI do
  @moduledoc """
  Bonus: transcribe a recording and have an LLM title + summarize it.

  Uses OpenAI's HTTP API through `Req` (speech-to-text, then a small chat
  completion constrained to JSON). Configure with `OPENAI_API_KEY`; without it
  the feature reports itself as unavailable instead of failing obscurely.
  Models are overridable via `OPENAI_TRANSCRIBE_MODEL` / `OPENAI_CHAT_MODEL`.
  """

  require Logger

  @base_url "https://api.openai.com/v1"

  # Explicitly use the OS CA trust store in production releases.
  defp http_options do
    [connect_options: [transport_opts: [cacertfile: "/etc/ssl/certs/ca-certificates.crt"]]]
  end

  @type result :: %{transcript: String.t(), title: String.t(), summary: String.t()}

  @spec transcribe_and_summarize(binary(), String.t()) ::
          {:ok, result()} | {:error, :ai_not_configured | {:ai_failed, String.t()}}
  def transcribe_and_summarize(audio, mime_type) do
    with {:ok, key} <- api_key(),
         {:ok, transcript} <- transcribe(key, audio, mime_type) do
      case summarize(key, transcript) do
        {:ok, %{title: title, summary: summary}} ->
          {:ok, %{transcript: transcript, title: title, summary: summary}}

        {:error, reason} ->
          Logger.warning("Summary unavailable; preserving transcript: #{inspect(reason)}")

          {:ok,
           %{
             transcript: transcript,
             title: "Transcribed recording",
             summary: "Transcript available below."
           }}
      end
    end
  end

  defp api_key do
    case Application.get_env(:timbre, :openai_api_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :ai_not_configured}
    end
  end

  defp transcribe(key, audio, mime_type) do
    # The API sniffs the format from the filename extension.
    file =
      {audio, filename: "recording." <> extension(mime_type), content_type: base_mime(mime_type)}

    case Req.post(@base_url <> "/audio/transcriptions",
           auth: {:bearer, key},
           form_multipart: [file: file, model: model(:transcribe), response_format: "json"],
           receive_timeout: 120_000,
           connect_options: http_options()[:connect_options]
         ) do
      {:ok, %{status: 200, body: %{"text" => text}}} -> {:ok, String.trim(text)}
      other -> failure("transcription", other)
    end
  end

  defp summarize(_key, ""),
    do: {:ok, %{title: "Silent recording", summary: "No speech detected."}}

  defp summarize(key, transcript) do
    body = %{
      model: model(:chat),
      response_format: %{type: "json_object"},
      messages: [
        %{
          role: "system",
          content:
            "You title and summarize voice recordings. Reply with JSON " <>
              ~s|{"title": string (max 8 words), "summary": string (1-3 sentences)}.|
        },
        %{role: "user", content: transcript}
      ]
    }

    with {:ok,
          %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} <-
           Req.post(@base_url <> "/chat/completions",
             auth: {:bearer, key},
             json: body,
             receive_timeout: 60_000,
             connect_options: http_options()[:connect_options]
           ),
         {:ok, %{"title" => title, "summary" => summary}} <- Jason.decode(content) do
      {:ok, %{title: String.slice(title, 0, 200), summary: summary}}
    else
      other -> failure("summary", other)
    end
  end

  defp failure(step, other) do
    Logger.warning("AI #{step} failed: #{inspect(other, limit: 20)}")

    message =
      case other do
        {:ok, %{status: status, body: %{"error" => %{"message" => msg}}}} ->
          "#{step} failed (#{status}): #{msg}"

        {:ok, %{status: status}} ->
          "#{step} failed (HTTP #{status})"

        {:error, %{__exception__: true} = e} ->
          "#{step} failed: #{Exception.message(e)}"

        _ ->
          "#{step} failed"
      end

    {:error, {:ai_failed, message}}
  end

  defp model(:transcribe), do: System.get_env("OPENAI_TRANSCRIBE_MODEL", "whisper-1")
  defp model(:chat), do: System.get_env("OPENAI_CHAT_MODEL", "gpt-4o-mini")

  defp base_mime(mime), do: mime |> String.split(";") |> hd() |> String.trim()

  defp extension(mime) do
    case base_mime(mime) do
      "audio/webm" -> "webm"
      "audio/ogg" -> "ogg"
      "audio/wav" -> "wav"
      "audio/x-wav" -> "wav"
      "audio/mp4" -> "mp4"
      "audio/mpeg" -> "mp3"
      "audio/aac" -> "m4a"
      _ -> "webm"
    end
  end
end
