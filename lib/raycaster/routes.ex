defmodule Raycaster.Routes do
  @moduledoc """
  The way round walls: the first step on a shortest way from one floor cell to another.

  The map is one integer with a bit for each cell (`Raycaster.Engine.open_mask/0`), and the
  search runs waves out from the goal, each a few shifts and ors, until one reaches `from`.
  The step is a neighbour of `from` in the wave before, tried east, west, south, north. The
  map's outer ring must be wall, so a wave shifted off one side of a row never lands on floor.
  """

  import Bitwise

  alias Raycaster.Engine

  @doc """
  The cell to step to from `from` on a shortest way to `to`, both `{column, row}` of floor, or
  nil when they are the same cell, either is a wall or off the map, or there is no way.
  """
  @spec next({integer, integer}, {integer, integer}) :: {integer, integer} | nil
  def next({cx, cy} = from, {tx, ty} = to)
      when cx in 0..15 and cy in 0..15 and tx in 0..15 and ty in 0..15 do
    open = Engine.open_mask()
    start = ty * 16 + tx
    from_bit = cy * 16 + cx

    if from != to and bit?(open, from_bit) and bit?(open, start) do
      goal = 1 <<< start

      from_bit
      |> waves(goal, bxor(open, goal))
      |> cell()
    end
  end

  def next(_from, _to), do: nil

  defp bit?(map, n), do: (map >>> n &&& 1) == 1

  # `frontier` is the cells `steps` away from the goal, `unseen` the floor not yet reached.
  defp waves(from, frontier, unseen) do
    reached =
      (frontier <<< 1 ||| frontier >>> 1 ||| frontier <<< 16 ||| frontier >>> 16) &&& unseen

    cond do
      reached == 0 -> nil
      bit?(reached, from) -> step(frontier, from)
      true -> waves(from, reached, bxor(unseen, reached))
    end
  end

  # The neighbour of `from` in the wave before: east, west, south, north.
  defp step(before, from) do
    cond do
      bit?(before, from + 1) -> from + 1
      bit?(before, from - 1) -> from - 1
      bit?(before, from + 16) -> from + 16
      true -> from - 16
    end
  end

  defp cell(nil), do: nil
  defp cell(n), do: {rem(n, 16), div(n, 16)}
end
