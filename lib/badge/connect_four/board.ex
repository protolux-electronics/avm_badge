defmodule Badge.ConnectFour.Board do
  @moduledoc """
  The 7x6 grid and its rules, as plain data.

  A cell is `{column, row}`, row 0 at the bottom. `players` is a two-element
  tuple of colours, indexed 0 and 1, so a player is a bit rather than a name.

  Kept free of `defstruct` and anything outside AtomVM's `Enum` subset
  (`Enum.chunk_every/3` in particular), so the same module runs on the host
  and on the badge.
  """

  @columns 7
  @rows 6
  @streak 4

  @directions [{0, 1}, {1, 0}, {1, 1}, {1, -1}]

  @doc "An empty board."
  @spec new() :: map
  def new do
    cells =
      for column <- 0..(@columns - 1), row <- 0..(@rows - 1), into: %{} do
        {{column, row}, nil}
      end

    %{cells: cells}
  end

  @doc "How many columns a board has."
  def columns, do: @columns

  @doc "How many rows a board has."
  def rows, do: @rows

  @doc """
  Drops a disc for `player` (0 or 1) into `column`.

  Returns the cell it landed on along with the new board, or `{:error, :full}`
  when the column has no empty cell left.
  """
  @spec drop(map, non_neg_integer, 0 | 1) :: {:ok, {integer, integer}, map} | {:error, :full}
  def drop(%{cells: cells} = board, column, player) do
    with {:ok, row} <- lowest_empty(cells, column, 0) do
      {:ok, {column, row}, %{board | cells: Map.put(cells, {column, row}, player)}}
    end
  end

  defp lowest_empty(_cells, _column, row) when row >= @rows, do: {:error, :full}

  defp lowest_empty(cells, column, row) do
    case Map.fetch!(cells, {column, row}) do
      nil -> {:ok, row}
      _taken -> lowest_empty(cells, column, row + 1)
    end
  end

  @doc "Whether the disc just placed at `cell` completes a four-in-a-row for `player`."
  @spec won?(map, {integer, integer}, 0 | 1) :: boolean
  def won?(%{cells: cells}, cell, player) do
    :lists.any(fn direction -> streak?(cells, cell, direction, player) end, @directions)
  end

  # A line through `cell` in `direction` (and its opposite) is at most
  # 2 * @streak - 1 cells long, so every possible window is checked directly
  # rather than built with Enum.chunk_every.
  defp streak?(cells, cell, direction, player) do
    reach(cells, cell, direction, player, 0) + reach(cells, cell, negate(direction), player, 0) -
      1 >= @streak
  end

  defp negate({dx, dy}), do: {-dx, -dy}

  defp reach(cells, {x, y}, {dx, dy}, player, count) do
    case Map.get(cells, {x, y}) do
      ^player -> reach(cells, {x + dx, y + dy}, {dx, dy}, player, count + 1)
      _other -> count
    end
  end

  @doc "Whether any column still has room for a disc."
  @spec full?(map) :: boolean
  def full?(%{cells: cells}) do
    not :lists.any(fn {_cell, value} -> value == nil end, Map.to_list(cells))
  end
end
