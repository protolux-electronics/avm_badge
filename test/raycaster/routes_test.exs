defmodule Raycaster.RoutesTest do
  use ExUnit.Case, async: true

  alias Raycaster.Engine
  alias Raycaster.Routes

  @grid Engine.grid()

  defp floor_cells do
    for cy <- 0..15, cx <- 0..15, Engine.open_cell?(@grid, cx, cy), do: {cx, cy}
  end

  # Steps from every cell to `goal`, by the plainest search there is.
  defp distances(goal), do: distances([goal], %{goal => 0}, 0)
  defp distances([], seen, _steps), do: seen

  defp distances(frontier, seen, steps) do
    {next, seen} =
      Enum.reduce(frontier, {[], seen}, fn {cx, cy}, acc ->
        Enum.reduce([{1, 0}, {-1, 0}, {0, 1}, {0, -1}], acc, fn {dx, dy}, {next, seen} ->
          cell = {cx + dx, cy + dy}

          if Engine.open_cell?(@grid, elem(cell, 0), elem(cell, 1)) and
               not Map.has_key?(seen, cell),
             do: {[cell | next], Map.put(seen, cell, steps + 1)},
             else: {next, seen}
        end)
      end)

    distances(next, seen, steps + 1)
  end

  test "from every floor cell to every other, the way is a neighbour that is one step nearer" do
    cells = floor_cells()
    assert length(cells) == 164

    for goal <- cells do
      steps = distances(goal)

      for {cx, cy} = from <- cells, from != goal do
        {nx, ny} = next = Routes.next(from, goal)

        assert abs(nx - cx) + abs(ny - cy) == 1,
               "#{inspect(from)} to #{inspect(goal)}: #{inspect(next)}"

        assert Engine.open_cell?(@grid, nx, ny)
        assert steps[next] == steps[from] - 1
      end
    end
  end

  test "there is no next cell in the goal's own cell, for a wall, or off the map" do
    assert Routes.next({5, 5}, {5, 5}) == nil
    assert Routes.next({0, 0}, {5, 5}) == nil
    assert Routes.next({5, 5}, {0, 0}) == nil
    assert Routes.next({-1, 5}, {5, 5}) == nil
    assert Routes.next({5, 5}, {5, 16}) == nil
  end

  test "a way that is walked cell by cell reaches the goal, and across the map is shortest" do
    path =
      Stream.unfold({1, 1}, fn
        {14, 14} -> nil
        from -> {Routes.next(from, {14, 14}), Routes.next(from, {14, 14})}
      end)
      |> Enum.to_list()

    assert List.last(path) == {14, 14}
    assert length(path) == distances({14, 14})[{1, 1}]
    # Corner to corner of a 14 by 14 room takes at least 26 steps.
    assert length(path) >= 26
  end
end
