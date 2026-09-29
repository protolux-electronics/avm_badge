defmodule Badge.Pong.Coin do
  @moduledoc """
  The coin that picks who serves, at a moment of its spin.

  `face/2` gives how wide the coin looks, out of 1024, and which side is up,
  `elapsed` ms into a flip that lands on `landing`. It turns in whole
  half-turns and eases out, so two badges starting together land together.
  """

  @spin_ms 1_500
  @half_turns 6
  @radius 40

  # One full turn in table steps; the table runs on the host compiler.
  @turn 128
  @cos (for step <- 0..(@turn - 1) do
          round(:math.cos(step * 2 * :math.pi() / @turn) * 1024)
        end)
       |> List.to_tuple()

  @rows for dy <- -@radius..@radius//2, do: {dy, round(:math.sqrt(@radius * @radius - dy * dy))}

  def spin_ms, do: @spin_ms
  def radius, do: @radius

  @doc "Half-widths of the disc, in rows two pixels tall."
  def rows, do: @rows

  @doc "How wide the coin looks and which face is up."
  @spec face(non_neg_integer, :me | :them) :: {0..1024, :me | :them}
  def face(elapsed, landing) do
    half_turns = @half_turns + if(landing == :me, do: 0, else: 1)
    done = div(min(elapsed, @spin_ms) * 1000, @spin_ms)
    left = 1000 - done
    angle = div(half_turns * div(@turn, 2) * (1_000_000 - left * left), 1_000_000)
    cos = elem(@cos, rem(angle, @turn))

    {abs(cos), if(cos >= 0, do: :me, else: :them)}
  end
end
