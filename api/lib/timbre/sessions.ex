defmodule Timbre.Sessions do
  @moduledoc """
  Multiplayer recording sessions (Part 3).

  Each session is a `Timbre.Sessions.Server` process, registered under its
  short share code in `Timbre.SessionRegistry` and started on demand under
  `Timbre.SessionSupervisor`. Nothing about a live session is persisted: the
  process *is* the session, and only the final mix is written to the database
  as an ordinary recording.

  Clients talk to it through `TimbreWeb.SessionChannel`; the server publishes
  state changes on `events_topic/1` via `Timbre.PubSub`.
  """

  alias Timbre.Sessions.Server

  # Every participant streams mono 16-bit PCM at this rate. 24 kHz keeps
  # speech crisp at ~48 KB/s per voice.
  @sample_rate 24_000
  # No ambiguous characters (0/O, 1/I) — people read these codes out loud.
  @alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @code_length 6

  def sample_rate, do: @sample_rate

  @doc "A fresh random share code like `K7XQ2M`."
  def new_code do
    for _ <- 1..@code_length, into: "", do: <<Enum.random(@alphabet)>>
  end

  def valid_code?(code) when is_binary(code), do: Regex.match?(~r/^[A-Z2-9]{4,12}$/, code)
  def valid_code?(_), do: false

  def events_topic(code), do: "session_events:" <> code

  @doc "Find the session process for `code`, starting it if needed."
  def ensure_started(code) do
    case DynamicSupervisor.start_child(Timbre.SessionSupervisor, {Server, code}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  def whereis(code) do
    case Registry.lookup(Timbre.SessionRegistry, code) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defdelegate join(server, participant_id, name, pid), to: Server
  defdelegate start_recording(server, participant_id), to: Server
  defdelegate stop_recording(server, participant_id), to: Server
  defdelegate push_audio(server, participant_id, take, offset, pcm), to: Server
  defdelegate flushed(server, participant_id, take), to: Server
  defdelegate snapshot(server), to: Server
end
