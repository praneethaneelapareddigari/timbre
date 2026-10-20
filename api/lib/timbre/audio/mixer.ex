defmodule Timbre.Audio.Mixer do
  @moduledoc """
  Mixes several participants' mono s16le PCM tracks into one.

  Each track arrives as a list of `{offset, pcm}` chunks, where `offset` is the
  chunk's position in samples since that participant started recording. Chunks
  are laid out by offset rather than arrival order, so a dropped or reordered
  chunk becomes a short silence instead of shifting the rest of the track out
  of sync.

  Mixing sums samples in a wider (32-bit) accumulator and then scales the whole
  result down only if the sum would clip. That keeps a single speaker at full
  volume while preventing distortion when everyone talks at once — plain
  averaging would make every voice quieter the more people join.
  """

  @type chunk :: {non_neg_integer(), binary()}

  @doc "Mix tracks (each a list of offset chunks) into one s16le binary."
  @spec mix([[chunk()]]) :: binary()
  def mix([]), do: <<>>

  def mix(tracks) do
    flats = Enum.map(tracks, &flatten/1)
    len = flats |> Enum.map(&byte_size/1) |> Enum.max()
    samples = div(len, 2)

    acc =
      Enum.reduce(flats, :binary.copy(<<0::signed-little-32>>, samples), fn track, acc ->
        add(pad(track, len), acc, <<>>)
      end)

    peak = peak(acc, 0)
    scale = if peak > 32_767, do: 32_767 / peak, else: 1.0
    to_s16(acc, scale, <<>>)
  end

  @doc """
  Turn offset chunks into one contiguous track: sorted by offset, gaps filled
  with silence, overlapping (duplicate/retransmitted) samples dropped.
  """
  @spec flatten([chunk()]) :: binary()
  def flatten(chunks) do
    {iodata, _cursor} =
      chunks
      |> Enum.sort_by(fn {offset, _} -> offset end)
      |> Enum.reduce({[], 0}, fn {offset, pcm}, {acc, cursor} ->
        pcm = even(pcm)
        start = offset * 2

        cond do
          start > cursor ->
            gap = :binary.copy(<<0, 0>>, div(start - cursor, 2))
            {[acc, gap, pcm], start + byte_size(pcm)}

          start + byte_size(pcm) <= cursor ->
            {acc, cursor}

          true ->
            skip = cursor - start
            {[acc, binary_part(pcm, skip, byte_size(pcm) - skip)], start + byte_size(pcm)}
        end
      end)

    IO.iodata_to_binary(iodata)
  end

  defp even(pcm) when rem(byte_size(pcm), 2) == 0, do: pcm
  defp even(pcm), do: binary_part(pcm, 0, byte_size(pcm) - 1)

  defp pad(track, len) when byte_size(track) >= len, do: track
  defp pad(track, len), do: track <> :binary.copy(<<0>>, len - byte_size(track))

  # Recursive binary builders: appending to `out` in a tail call lets the BEAM
  # grow the binary in place instead of copying it each step.
  defp add(<<s::signed-little-16, rest16::binary>>, <<a::signed-little-32, rest32::binary>>, out),
    do: add(rest16, rest32, <<out::binary, a + s::signed-little-32>>)

  defp add(<<>>, <<>>, out), do: out

  defp peak(<<a::signed-little-32, rest::binary>>, max), do: peak(rest, max(max, abs(a)))
  defp peak(<<>>, max), do: max

  defp to_s16(<<a::signed-little-32, rest::binary>>, scale, out) when scale == 1.0,
    do: to_s16(rest, scale, <<out::binary, a::signed-little-16>>)

  defp to_s16(<<a::signed-little-32, rest::binary>>, scale, out),
    do: to_s16(rest, scale, <<out::binary, round(a * scale)::signed-little-16>>)

  defp to_s16(<<>>, _scale, out), do: out
end
