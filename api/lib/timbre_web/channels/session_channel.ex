defmodule TimbreWeb.SessionChannel do
  @moduledoc """
  `session:<CODE>` — one browser tab in a multiplayer session.

  Client → server
    * `"start"` / `"stop"`  — control the take (anyone in the room can)
    * `"audio"`  (binary)   — `<<take::u32-le, offset::u32-le, pcm::s16le>>`,
      ~100 ms of mono 24 kHz audio; `offset` counts samples since this tab
      started the take
    * `"flushed"` `%{take}` — "I've sent my last chunk for this take"
    * `"level"`  `%{level}` — mic level for everyone's meters (relayed, not stored)

  Server → client: `"state"`, `"recording_started"`, `"recording_stopping"`,
  `"recording_saved"`, `"recording_failed"`, `"stats"`, `"level"`.

  The channel stays thin: it decodes frames and forwards them to the session
  process, and relays the session's PubSub events down the socket.
  """
  use TimbreWeb, :channel

  alias Timbre.Sessions

  @impl true
  def join("session:" <> code, params, socket) do
    if Sessions.valid_code?(code) do
      name = display_name(params["name"])
      participant_id = 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      with {:ok, server} <- Sessions.ensure_started(code),
           :ok <- Phoenix.PubSub.subscribe(Timbre.PubSub, Sessions.events_topic(code)),
           {:ok, snapshot} <- Sessions.join(server, participant_id, name, self()) do
        socket = assign(socket, code: code, server: server, participant_id: participant_id)
        {:ok, %{participant_id: participant_id, session: snapshot}, socket}
      else
        _ -> {:error, %{reason: "could not join session"}}
      end
    else
      {:error, %{reason: "invalid session code"}}
    end
  end

  @impl true
  def handle_in("start", _payload, socket) do
    session_reply(Sessions.start_recording(socket.assigns.server, socket.assigns.participant_id), socket)
  end

  def handle_in("stop", _payload, socket) do
    session_reply(Sessions.stop_recording(socket.assigns.server, socket.assigns.participant_id), socket)
  end

  def handle_in("audio", {:binary, <<take::little-32, offset::little-32, pcm::binary>>}, socket) do
    Sessions.push_audio(
      socket.assigns.server,
      socket.assigns.participant_id,
      take,
      offset,
      pcm
    )

    {:noreply, socket}
  end

  def handle_in("audio", _malformed, socket), do: {:noreply, socket}

  def handle_in("flushed", %{"take" => take}, socket) when is_integer(take) do
    Sessions.flushed(socket.assigns.server, socket.assigns.participant_id, take)
    {:noreply, socket}
  end

  def handle_in("level", %{"level" => level}, socket) when is_number(level) do
    broadcast_from!(socket, "level", %{id: socket.assigns.participant_id, level: level})
    {:noreply, socket}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:session_event, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  defp session_reply(:ok, socket), do: {:reply, :ok, socket}

  defp session_reply({:error, reason}, socket),
    do: {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}

  defp display_name(name) when is_binary(name) do
    case name |> String.trim() |> String.slice(0, 40) do
      "" -> "Guest"
      trimmed -> trimmed
    end
  end

  defp display_name(_), do: "Guest"
end
