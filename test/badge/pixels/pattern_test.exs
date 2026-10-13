defmodule Badge.Pixels.PatternTest do
  use ExUnit.Case, async: true

  alias Badge.Pixels.Pattern

  @a [{1, 0, 0}, {0, 0, 0}]
  @b [{0, 0, 0}, {1, 0, 0}]

  # Runs `n` ticks and gives back the frames that were due, as `{tick, frame}`.
  defp run(pattern, n) do
    {frames, _pattern} =
      Enum.reduce(0..(n - 1), {[], pattern}, fn tick, {acc, p} ->
        case Pattern.step(p) do
          {nil, p} -> {acc, p}
          {frame, p} -> {[{tick, frame} | acc], p}
        end
      end)

    Enum.reverse(frames)
  end

  test "the first frame is due at once, the next after its time, and they go round" do
    # 100 ms is five 20 ms ticks.
    assert run(Pattern.new(100, [@a, @b], 20), 12) == [{0, @a}, {5, @b}, {10, @a}]
  end

  test "a time shorter than a tick still takes one tick" do
    assert run(Pattern.new(5, [@a, @b], 20), 4) == [{0, @a}, {1, @b}, {2, @a}, {3, @b}]
  end

  test "an endless frame is written once, and never again" do
    assert run(Pattern.new(:infinity, [@a], 20), 50) == [{0, @a}]
  end

  test "restart writes the current frame again on the next tick" do
    pattern = Pattern.new(:infinity, [@a], 20)
    {@a, pattern} = Pattern.step(pattern)
    assert {nil, pattern} = Pattern.step(pattern)

    assert {@a, _pattern} = pattern |> Pattern.restart() |> Pattern.step()
  end
end
