defmodule Badge.Pong.Physics do
  @moduledoc """
  Ball and paddle motion on one badge's half of the court.

  Integer fixed point throughout, so both badges compute the same ball:
  positions are 1/256 px, velocities 1/256 px per millisecond. y runs from
  the top edge, which faces the other badge, down to the paddle; a negative
  y is in the hidden gap between the two screens.

  A ball on the wire is `%{d, x, vx, vy}` from the sender's side, with `d`
  and `x` in 1/16 px. `outgoing/1` writes it and `incoming/1` turns it round
  for the receiver.
  """

  import Bitwise

  @fp 256
  @wire 16

  @width 320
  @height 214
  @ball 6
  @paddle_w 48
  @paddle_h 4
  @paddle_y @height - 10
  @gap 90

  @serve_vx 12
  @serve_vy 38
  @max_vy div(@gap * @fp, 250)
  @spin 3
  @paddle_speed 61

  @lead_ms 300
  @transit_ms 140

  @max_x (@width - @ball) * @fp
  @max_paddle (@width - @paddle_w) * @fp
  @paddle_top @paddle_y * @fp

  def width, do: @width
  def height, do: @height
  def ball_size, do: @ball
  def paddle_w, do: @paddle_w
  def paddle_h, do: @paddle_h
  def paddle_y, do: @paddle_y
  def gap, do: @gap
  def max_vy, do: @max_vy

  @doc "Whole pixels, rounding down, for a fixed-point value."
  @spec px(integer) :: integer
  def px(fixed), do: bsr(fixed, 8)

  @doc "A paddle centred on the court."
  def paddle_home, do: div(@max_paddle, 2)

  @doc "A paddle moved `dt` ms towards `direction`, stopping at the walls."
  def move_paddle(paddle, direction, dt) do
    min(max(paddle + direction * @paddle_speed * dt, 0), @max_paddle)
  end

  @doc "A ball leaving the middle of the paddle, towards the other badge."
  def serve(paddle) do
    %{
      x: paddle + div(@paddle_w - @ball, 2) * @fp,
      y: (@paddle_y - @ball) * @fp,
      vx: @serve_vx,
      vy: -@serve_vy
    }
  end

  @doc "The ball `dt` ms on, off the walls and the paddle, or `:missed` once past it."
  def step(ball, dt, paddle), do: ball |> travel(dt) |> strike(ball, paddle)

  defp travel(ball, dt) do
    {x, vx} = bounce(ball.x + ball.vx * dt, ball.vx)

    %{ball | x: x, vx: vx, y: ball.y + ball.vy * dt}
  end

  defp bounce(x, vx) when x < 0, do: {-x, -vx}
  defp bounce(x, vx) when x > @max_x, do: {2 * @max_x - x, -vx}
  defp bounce(x, vx), do: {x, vx}

  # Crossing the paddle's top edge on this step counts, however far the step went.
  defp strike(%{vy: vy} = ball, before, paddle) when vy > 0 do
    crossed = before.y + @ball * @fp <= @paddle_top and ball.y + @ball * @fp > @paddle_top

    cond do
      crossed and hits?(ball.x, paddle) -> rebound(ball, paddle)
      ball.y > @height * @fp -> :missed
      true -> ball
    end
  end

  defp strike(ball, _before, _paddle), do: ball

  defp hits?(x, paddle), do: x + @ball * @fp > paddle and x < paddle + @paddle_w * @fp

  defp rebound(ball, paddle) do
    offset = div(ball.x + div(@ball * @fp, 2) - (paddle + div(@paddle_w * @fp, 2)), @fp)

    %{
      ball
      | y: @paddle_top - @ball * @fp,
        vx: offset * @spin,
        vy: -min(div(ball.vy * 17, 16) + 1, @max_vy)
    }
  end

  @doc "Whether the ball will leave the top edge within the lead time."
  def due?(%{vy: vy, y: y}) when vy < 0, do: y <= -vy * @lead_ms
  def due?(_ball), do: false

  @doc "Whether the ball has wholly left the top of the screen."
  def above?(ball), do: ball.y + @ball * @fp <= 0

  @doc "The ball held at the far end of the gap, for as long as nobody has taken it."
  def park(ball), do: %{ball | y: max(ball.y, -@gap * @fp)}

  @doc "The ball as the other badge needs it."
  def outgoing(ball) do
    scale = div(@fp, @wire)

    %{d: div(ball.y, scale), x: div(ball.x, scale), vx: ball.vx, vy: ball.vy}
  end

  @doc "A ball from the other badge, placed in the gap above this screen."
  def incoming(%{d: d, x: x, vx: vx, vy: vy}) do
    scale = div(@fp, @wire)
    y = -(@gap * @fp + d * scale) - vy * @transit_ms

    %{x: @max_x - x * scale, y: min(y, 0), vx: -vx, vy: -vy}
  end
end
