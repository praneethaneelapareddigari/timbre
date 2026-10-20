defmodule Timbre.Audio.Wav do
  @moduledoc """
  Minimal RIFF/WAVE encoding for 16-bit little-endian PCM — the format session
  mixes are stored in, playable by every browser.
  """

  @doc "Wrap raw s16le PCM in a 44-byte WAV header."
  @spec encode(binary(), pos_integer(), pos_integer()) :: binary()
  def encode(pcm, sample_rate, channels \\ 1) when is_binary(pcm) do
    data_size = byte_size(pcm)
    block_align = channels * 2
    byte_rate = sample_rate * block_align

    <<"RIFF", 36 + data_size::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
      channels::little-16, sample_rate::little-32, byte_rate::little-32, block_align::little-16,
      16::little-16, "data", data_size::little-32, pcm::binary>>
  end

  @doc "Duration in milliseconds of s16le mono PCM at `sample_rate`."
  @spec duration_ms(binary(), pos_integer()) :: non_neg_integer()
  def duration_ms(pcm, sample_rate), do: div(div(byte_size(pcm), 2) * 1000, sample_rate)
end
