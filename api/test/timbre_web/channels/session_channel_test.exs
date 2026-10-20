defmodule TimbreWeb.SessionChannelTest do
  use TimbreWeb.ChannelCase

  alias Timbre.{Recordings, Sessions}
  alias TimbreWeb.{SessionChannel, UserSocket}

  defp join_session(code, name) do
    {:ok, reply, socket} =
      UserSocket
      |> socket(nil, %{})
      |> subscribe_and_join(SessionChannel, "session:" <> code, %{"name" => name})

    {reply, socket}
  end

  # `n` samples of a constant value as s16le
  defp pcm(value, n), do: :binary.copy(<<value::signed-little-16>>, n)

  defp frame(take, offset, pcm),
    do: {:binary, <<take::little-32, offset::little-32, pcm::binary>>}

  test "rejects malformed session codes" do
    assert {:error, %{reason: "invalid session code"}} =
             UserSocket
             |> socket(nil, %{})
             |> subscribe_and_join(SessionChannel, "session:bad code!", %{})
  end

  test "joining returns the participant id and current room" do
    code = Sessions.new_code()
    {%{participant_id: ana_id}, _} = join_session(code, "Ana")
    {%{session: session}, _} = join_session(code, "Ben")

    assert session.status == :idle
    assert Enum.map(session.participants, & &1.name) == ["Ana", "Ben"]
    assert hd(session.participants).id == ana_id
  end

  test "two participants record a take and it is mixed into one saved recording" do
    code = Sessions.new_code()
    {_, ana} = join_session(code, "Ana")
    {_, ben} = join_session(code, "Ben")

    ref = push(ana, "start", %{})
    assert_reply(ref, :ok)
    assert_push("recording_started", %{take: 1, sample_rate: 24_000, started_by: "Ana"})

    # Ana: two chunks, sent out of order. Ben: one chunk, starting later.
    push(ana, "audio", frame(1, 2400, pcm(1000, 2400)))
    push(ana, "audio", frame(1, 0, pcm(1000, 2400)))
    push(ben, "audio", frame(1, 1200, pcm(500, 2400)))
    # A straggler from another take must be ignored.
    push(ben, "audio", frame(7, 0, pcm(30_000, 2400)))

    ref = push(ben, "stop", %{})
    assert_reply(ref, :ok)
    assert_push("recording_stopping", %{take: 1, stopped_by: "Ben"})

    push(ana, "flushed", %{"take" => 1})
    push(ben, "flushed", %{"take" => 1})

    assert_push("recording_saved", %{take: 1, recording: %{id: id}}, 2_000)

    recording = Recordings.get_recording(id)
    assert recording.kind == :session
    assert recording.participants == 2
    assert recording.mime_type == "audio/wav"
    # 4800 samples at 24 kHz
    assert recording.duration_ms == 200

    {:ok, "audio/wav", wav} = Recordings.fetch_audio(id)
    <<_header::binary-size(44), mixed::binary>> = wav
    samples = for <<s::signed-little-16 <- mixed>>, do: s
    assert length(samples) == 4800
    # Ana alone, then Ana + Ben overlapping, then Ana alone again
    assert Enum.at(samples, 0) == 1000
    assert Enum.at(samples, 2000) == 1500
    assert Enum.at(samples, 4799) == 1000
  end

  test "stop finalizes after a timeout even if nobody confirms flushing" do
    code = Sessions.new_code()
    {_, ana} = join_session(code, "Ana")

    ref = push(ana, "start", %{})
    assert_reply(ref, :ok)
    push(ana, "audio", frame(1, 0, pcm(10, 240)))
    ref = push(ana, "stop", %{})
    assert_reply(ref, :ok)

    assert_push("recording_saved", %{recording: %{id: _}}, 3_000)
  end

  test "a take with no audio reports failure instead of saving an empty file" do
    code = Sessions.new_code()
    {_, ana} = join_session(code, "Ana")

    start = push(ana, "start", %{})
    assert_reply(start, :ok)
    stop = push(ana, "stop", %{})
    assert_reply(stop, :ok)
    push(ana, "flushed", %{"take" => 1})

    assert_push("recording_failed", %{take: 1, reason: "no audio was received"}, 2_000)
  end

  test "can't start twice or stop when idle" do
    code = Sessions.new_code()
    {_, ana} = join_session(code, "Ana")

    stop = push(ana, "stop", %{})
    assert_reply(stop, :error, %{reason: "not_recording"})
    start = push(ana, "start", %{})
    assert_reply(start, :ok)
    again = push(ana, "start", %{})
    assert_reply(again, :error, %{reason: "busy"})
  end

  test "levels are relayed to the other participants" do
    code = Sessions.new_code()
    {%{participant_id: ana_id}, ana} = join_session(code, "Ana")
    {_, _ben} = join_session(code, "Ben")

    push(ana, "level", %{"level" => 0.42})
    assert_broadcast("level", %{id: ^ana_id, level: 0.42})
  end

  test "leaving removes the participant" do
    code = Sessions.new_code()
    {_, _ana} = join_session(code, "Ana")
    {_, ben} = join_session(code, "Ben")

    Process.unlink(ben.channel_pid)
    monitor = Process.monitor(ben.channel_pid)
    ref = leave(ben)
    assert_reply(ref, :ok)
    assert_receive {:DOWN, ^monitor, :process, _, _}

    server = Sessions.whereis(code)
    # The session learns about the exit from its own monitor; sync with it first.
    _ = :sys.get_state(server)
    assert Enum.map(Sessions.snapshot(server).participants, & &1.name) == ["Ana"]
  end
end
