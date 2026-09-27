defmodule Badge.ConnectFour.BoardTest do
  use ExUnit.Case, async: true

  alias Badge.ConnectFour.Board

  describe "new/0" do
    test "every cell starts empty" do
      %{cells: cells} = Board.new()

      assert map_size(cells) == Board.columns() * Board.rows()
      assert Enum.all?(cells, fn {_cell, value} -> value == nil end)
      assert Map.has_key?(cells, {6, 5})
      refute Map.has_key?(cells, {7, 5})
      refute Map.has_key?(cells, {6, 6})
    end
  end

  describe "drop/3" do
    test "lands on the floor of an empty column" do
      board = Board.new()

      assert {:ok, {0, 0}, board} = Board.drop(board, 0, 0)
      assert board.cells[{0, 0}] == 0
    end

    test "stacks on top of what is already there" do
      board = Board.new()

      {:ok, {0, 0}, board} = Board.drop(board, 0, 0)
      {:ok, {0, 1}, board} = Board.drop(board, 0, 1)
      assert {:ok, {0, 2}, board} = Board.drop(board, 0, 0)

      assert board.cells[{0, 0}] == 0
      assert board.cells[{0, 1}] == 1
      assert board.cells[{0, 2}] == 0
    end

    test "a full column refuses the next disc" do
      board = Board.new()

      board =
        Enum.reduce(0..(Board.rows() - 1), board, fn row, board ->
          {:ok, {0, ^row}, board} = Board.drop(board, 0, rem(row, 2))
          board
        end)

      assert {:error, :full} = Board.drop(board, 0, 0)
    end
  end

  describe "won?/3" do
    test "no win with too few discs down" do
      board = Board.new()
      {:ok, cell, board} = Board.drop(board, 0, 0)

      refute Board.won?(board, cell, 0)
    end

    test "no false positive across a column boundary" do
      board = drop_all(Board.new(), [{0, 0}, {1, 1}, {0, 0}, {2, 1}, {0, 0}, {3, 1}])
      {:ok, cell, board} = Board.drop(board, 1, 0)

      refute Board.won?(board, cell, 0)
    end

    test "a vertical streak" do
      board = drop_all(Board.new(), [{0, 0}, {1, 1}, {0, 0}, {2, 1}, {0, 0}, {3, 1}])
      {:ok, cell, board} = Board.drop(board, 0, 0)

      assert Board.won?(board, cell, 0)
    end

    test "a horizontal streak" do
      board = drop_all(Board.new(), [{0, 0}, {6, 1}, {1, 0}, {6, 1}, {2, 0}, {6, 1}])
      {:ok, cell, board} = Board.drop(board, 3, 0)

      assert Board.won?(board, cell, 0)
    end

    test "a rising diagonal streak" do
      board =
        drop_all(Board.new(), [
          {0, 0},
          {1, 1},
          {1, 0},
          {2, 1},
          {2, 0},
          {3, 1},
          {2, 0},
          {3, 1},
          {3, 0},
          {4, 1}
        ])

      {:ok, cell, board} = Board.drop(board, 3, 0)

      assert Board.won?(board, cell, 0)
    end

    test "a falling diagonal streak" do
      board =
        drop_all(Board.new(), [
          {6, 0},
          {5, 1},
          {5, 0},
          {4, 1},
          {4, 0},
          {3, 1},
          {4, 0},
          {3, 1},
          {3, 0},
          {5, 1}
        ])

      {:ok, cell, board} = Board.drop(board, 3, 0)

      assert Board.won?(board, cell, 0)
    end
  end

  describe "full?/1" do
    test "an empty board is not full" do
      refute Board.full?(Board.new())
    end

    test "a board with every cell taken is full" do
      moves =
        for column <- 0..(Board.columns() - 1), row <- 0..(Board.rows() - 1) do
          {column, rem(row, 2)}
        end

      board = drop_all(Board.new(), moves)

      assert Board.full?(board)
    end
  end

  defp drop_all(board, moves) do
    Enum.reduce(moves, board, fn {column, player}, board ->
      {:ok, _cell, board} = Board.drop(board, column, player)
      board
    end)
  end
end
