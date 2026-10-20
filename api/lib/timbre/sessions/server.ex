defmodule Timbre.Sessions.Server do
  @moduledoc """
  One live session: who's in it, whether it's recording, and every
  participant's audio for the current take.

  Lifecycle of a take:

      :idle --start--> :recording --stop--> :finalizing --all flushed / 2s--> :idle
                                                         (mix + save)

  Stopping doesn't mix immediately: clients still have a few hundred ms of
  audio in flight, so we broadcast "stopping", wait for every participant to
  acknowledge they've sent their last chunk (or a short timeout), and only
  then mix. Chunks are tagged with the take number so stragglers from an old
  take can't leak into a new one.

  The process monitors each participant's channel process, so a closed tab
  is removed automatically, and it shuts itself down after sitting empty.
  """
  use GenServer, restart: :temporary

  require Logger

  alias Timbre.Audio.{Mixer, Wav}
  alias Timbre.{Recordings, Sessions}

  @flush_timeout 2_000
  @idle_shutdown 60_000
  @stats_interval 500
  # Cap a single take at 15 minutes of audio per participant.
  @max_offset Sessions.sample_rate() * 60 * 15

  # --- client API -----------------------------------------------------------

  def start_link(code) do
    GenServer.start_link(__MODULE__, code, name: {:via, Registry, {Timbre.SessionRegistry, code}})
  end

  def join(server, participant_id, name, pid),
    do: GenServer.call(server, {:join, participant_id, name, pid})

  def start_recording(server, participant_id),
    do: GenServer.call(server, {:start, participant_id})

  def stop_recording(server, participant_id),
    do: GenServer.call(server, {:stop, participant_id})

  # Audio is a cast: the channel shouldn't block on the session for every chunk.
  def push_audio(server, participant_id, take, offset, pcm),
    do: GenServer.cast(server, {:audio, participant_id, take, offset, pcm})

  def flushed(server, participant_id, take),
    do: GenServer.cast(server, {:flushed, participant_id, take})

  def snapshot(server), do: GenServer.call(server, :snapshot)

  # --- server ---------------------------------------------------------------

  @impl true
  def init(code) do
    state = %{
      code: code,
      participants: %{},
      status: :idle,
      take: 0,
      tracks: %{},
      received: %{},
      flushed: MapSet.new(),
      finalize_timer: nil,
      idle_timer: schedule_idle_shutdown(nil),
      last_recording: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:join, id, name, pid}, _from, state) do
    ref = Process.monitor(pid)
    participant = %{id: id, name: name, pid: pid, ref: ref, joined_at: DateTime.utc_now()}
    state = %{state | participants: Map.put(state.participants, id, participant)}
    state = cancel_idle_shutdown(state)
    broadcast(state, "state", public_state(state))
    {:reply, {:ok, public_state(state)}, state}
  end

  def handle_call({:start, id}, _from, %{status: :idle} = state) do
    take = state.take + 1

    state = %{
      state
      | status: :recording,
        take: take,
        tracks: %{},
        received: %{},
        flushed: MapSet.new()
    }

    schedule_stats(take)

    broadcast(state, "recording_started", %{
      take: take,
      sample_rate: Sessions.sample_rate(),
      started_by: participant_name(state, id)
    })

    broadcast(state, "state", public_state(state))
    {:reply, :ok, state}
  end

  def handle_call({:start, _id}, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call({:stop, id}, _from, %{status: :recording} = state) do
    timer = Process.send_after(self(), {:finalize, state.take}, @flush_timeout)
    state = %{state | status: :finalizing, finalize_timer: timer}

    broadcast(state, "recording_stopping", %{
      take: state.take,
      stopped_by: participant_name(state, id)
    })

    broadcast(state, "state", public_state(state))
    {:reply, :ok, maybe_finalize(state)}
  end

  def handle_call({:stop, _id}, _from, state), do: {:reply, {:error, :not_recording}, state}

  def handle_call(:snapshot, _from, state), do: {:reply, public_state(state), state}

  @impl true
  def handle_cast({:audio, id, take, offset, pcm}, %{take: take, status: status} = state)
      when status in [:recording, :finalizing] and offset <= @max_offset do
    state = %{
      state
      | tracks: Map.update(state.tracks, id, [{offset, pcm}], &[{offset, pcm} | &1]),
        received: Map.update(state.received, id, byte_size(pcm), &(&1 + byte_size(pcm)))
    }

    {:noreply, state}
  end

  # Wrong take, not recording, or over the length cap: drop it.
  def handle_cast({:audio, _id, _take, _offset, _pcm}, state), do: {:noreply, state}

  def handle_cast({:flushed, id, take}, %{take: take, status: :finalizing} = state) do
    {:noreply, maybe_finalize(%{state | flushed: MapSet.put(state.flushed, id)})}
  end

  def handle_cast({:flushed, _id, _take}, state), do: {:noreply, state}

  @impl true
  def handle_info({:finalize, take}, %{take: take, status: :finalizing} = state) do
    {:noreply, finalize(state)}
  end

  def handle_info({:finalize, _take}, state), do: {:noreply, state}

  # Tagged with the take so a quick stop/start can't leave two loops running.
  def handle_info({:stats, take}, %{status: :recording, take: take} = state) do
    seconds =
      Map.new(state.received, fn {id, bytes} ->
        {id, Float.round(bytes / 2 / Sessions.sample_rate(), 1)}
      end)

    broadcast(state, "stats", %{seconds: seconds})
    schedule_stats(take)
    {:noreply, state}
  end

  def handle_info({:stats, _take}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.participants, fn {_id, p} -> p.ref == ref end) do
      {id, _} ->
        state = %{state | participants: Map.delete(state.participants, id)}
        broadcast(state, "state", public_state(state))

        state =
          cond do
            # Someone leaving mid-stop shouldn't make everyone wait for the timeout.
            state.status == :finalizing -> maybe_finalize(state)
            # Last person left while recording: save what we have rather than lose it.
            state.status == :recording and map_size(state.participants) == 0 -> finalize(state)
            true -> state
          end

        state =
          if map_size(state.participants) == 0,
            do: %{state | idle_timer: schedule_idle_shutdown(state.idle_timer)},
            else: state

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:idle_shutdown, state) do
    if map_size(state.participants) == 0 and state.status == :idle do
      {:stop, :normal, state}
    else
      {:noreply, %{state | idle_timer: nil}}
    end
  end

  # --- internals ------------------------------------------------------------

  # Mix once every participant still in the room has confirmed their last chunk.
  defp maybe_finalize(%{status: :finalizing} = state) do
    waiting = state.participants |> Map.keys() |> MapSet.new() |> MapSet.difference(state.flushed)
    if MapSet.size(waiting) == 0, do: finalize(state), else: state
  end

  defp maybe_finalize(state), do: state

  defp finalize(state) do
    if state.finalize_timer, do: Process.cancel_timer(state.finalize_timer)
    tracks = Map.values(state.tracks)

    result =
      if tracks == [] do
        {:error, "no audio was received"}
      else
        pcm = Mixer.mix(tracks)

        Recordings.create_recording(%{
          title: "Session #{state.code} · take #{state.take}",
          kind: :session,
          mime_type: "audio/wav",
          data: Wav.encode(pcm, Sessions.sample_rate()),
          duration_ms: Wav.duration_ms(pcm, Sessions.sample_rate()),
          participants: length(tracks)
        })
      end

    state = %{state | status: :idle, tracks: %{}, finalize_timer: nil}

    state =
      case result do
        {:ok, rec} ->
          saved = %{id: rec.id, title: rec.title, duration_ms: rec.duration_ms}
          broadcast(state, "recording_saved", %{take: state.take, recording: saved})
          %{state | last_recording: saved}

        {:error, reason} ->
          Logger.info("session #{state.code} take #{state.take} not saved: #{inspect(reason)}")
          broadcast(state, "recording_failed", %{take: state.take, reason: error_message(reason)})
          state
      end

    broadcast(state, "state", public_state(state))
    state
  end

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(%Ecto.Changeset{}), do: "could not save the mix"

  defp public_state(state) do
    %{
      code: state.code,
      status: state.status,
      take: state.take,
      sample_rate: Sessions.sample_rate(),
      last_recording: state.last_recording,
      participants:
        state.participants
        |> Map.values()
        |> Enum.sort_by(& &1.joined_at, DateTime)
        |> Enum.map(&Map.take(&1, [:id, :name, :joined_at]))
    }
  end

  defp participant_name(state, id) do
    case Map.fetch(state.participants, id) do
      {:ok, p} -> p.name
      :error -> "someone"
    end
  end

  defp broadcast(state, event, payload) do
    Phoenix.PubSub.broadcast(
      Timbre.PubSub,
      Sessions.events_topic(state.code),
      {:session_event, event, payload}
    )
  end

  defp schedule_stats(take), do: Process.send_after(self(), {:stats, take}, @stats_interval)

  defp schedule_idle_shutdown(old) do
    if old, do: Process.cancel_timer(old)
    Process.send_after(self(), :idle_shutdown, @idle_shutdown)
  end

  defp cancel_idle_shutdown(%{idle_timer: nil} = state), do: state

  defp cancel_idle_shutdown(state) do
    Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: nil}
  end
end
