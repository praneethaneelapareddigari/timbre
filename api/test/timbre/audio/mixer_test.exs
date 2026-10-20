defmodule Timbre.Audio.MixerTest do
  use ExUnit.Case, async: true

  alias Timbre.Audio.{Mixer, Wav}

  defp s16(samples), do: for(s <- samples, into: <<>>, do: <<s::signed-little-16>>)
  defp samples(bin), do: for(<<s::signed-little-16 <- bin>>, do: s)

  describe "flatten/1" do
    test "orders chunks by offset regardless of arrival order" do
      assert samples(Mixer.flatten([{2, s16([3, 4])}, {0, s16([1, 2])}])) == [1, 2, 3, 4]
    end

    test "fills a missing chunk with silence" do
      assert samples(Mixer.flatten([{0, s16([1])}, {3, s16([4])}])) == [1, 0, 0, 4]
    end

    test "drops samples that overlap what's already placed" do
      assert samples(Mixer.flatten([{0, s16([1, 2])}, {1, s16([9, 3])}])) == [1, 2, 3]
      assert samples(Mixer.flatten([{0, s16([1, 2])}, {0, s16([9, 9])}])) == [1, 2]
    end

    test "ignores a trailing odd byte" do
      assert samples(Mixer.flatten([{0, s16([5]) <> <<1>>}])) == [5]
    end
  end

  describe "mix/1" do
    test "sums aligned tracks and pads the shorter one" do
      mixed = Mixer.mix([[{0, s16([100, 200, 300])}], [{1, s16([10, 20])}]])
      assert samples(mixed) == [100, 210, 320]
    end

    test "scales the mix down instead of clipping" do
      mixed = samples(Mixer.mix([[{0, s16([30_000, -30_000])}], [{0, s16([30_000, 0])}]]))
      assert mixed == [32_767, -16_384]
    end

    test "a single track passes through untouched" do
      assert samples(Mixer.mix([[{0, s16([1, -2, 3])}]])) == [1, -2, 3]
    end

    test "no tracks is an empty mix" do
      assert Mixer.mix([]) == <<>>
    end
  end

  describe "Wav" do
    test "encode/3 writes a 44-byte PCM header" do
      wav = Wav.encode(s16([1, 2, 3]), 24_000)

      assert <<"RIFF", riff_size::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
               1::little-16, 24_000::little-32, 48_000::little-32, 2::little-16, 16::little-16,
               "data", 6::little-32, _pcm::binary-size(6)>> = wav

      assert riff_size == byte_size(wav) - 8
    end

    test "duration_ms/2" do
      assert Wav.duration_ms(:binary.copy(<<0, 0>>, 24_000), 24_000) == 1000
    end
  end
end
