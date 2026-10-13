defmodule Raycaster.GoatTest do
  use ExUnit.Case, async: true

  alias Raycaster.Engine
  alias Raycaster.Goat

  @cell 256
  @grid Engine.grid()

  # The middle of a cell.
  defp mid({cx, cy}), do: {cx * @cell + 128, cy * @cell + 128}

  # Runs the goat on, 100 ms a step, for `ms`; `prey` is where the player stands. Returns the goat,
  # whether it caught the player, and every place it stood.
  defp run(goat, prey, ms, pace \\ :calm, now \\ 0) do
    Enum.reduce_while(1..div(ms, 100), {goat, false, []}, fn i, {goat, _caught, trail} ->
      {goat, caught} = Goat.step(goat, @grid, prey, 100, now + i * 100, pace)
      acc = {goat, caught, [Goat.where(goat) | trail]}
      if caught, do: {:halt, acc}, else: {:cont, acc}
    end)
  end

  defp on_floor?({x, y, _hunting}), do: Engine.open?(@grid, x, y)

  describe "wandering" do
    test "it starts in the middle of its cell, wandering" do
      assert Goat.where(Goat.new({14, 14}, 7)) == {14 * @cell + 128, 14 * @cell + 128, false}
    end

    test "it goes places, and never into a wall" do
      {goat, false, trail} = run(Goat.new({14, 14}, 7), nil, 60_000)

      assert Enum.all?(trail, &on_floor?/1)
      # It has been a long way: more than a few cells between the first and last places.
      cells = trail |> Enum.map(fn {x, y, _} -> {div(x, @cell), div(y, @cell)} end) |> Enum.uniq()
      assert length(cells) > 20
      assert {_, _, false} = Goat.where(goat)
    end

    test "the same seed goes the same way, a different one another" do
      {_g, _c, one} = run(Goat.new({14, 14}, 7), nil, 20_000)
      {_g, _c, again} = run(Goat.new({14, 14}, 7), nil, 20_000)
      {_g, _c, other} = run(Goat.new({14, 14}, 8), nil, 20_000)

      assert one == again
      refute one == other
    end

    test "it walks at the calm pace: no more than 250 a second" do
      {goat, false, _trail} = run(Goat.new({14, 14}, 3), nil, 2_000)
      {x, y, _} = Goat.where(goat)
      {sx, sy} = mid({14, 14})

      assert :math.sqrt((x - sx) * (x - sx) + (y - sy) * (y - sy)) <= 2 * 250 + 1
    end
  end

  describe "hunting" do
    # Row 1 is open from column 1 to 14, so a goat and a player there see each other.
    defp player, do: mid({10, 1})

    test "it goes after a player it sees, and catches them" do
      {goat, caught, _trail} = run(Goat.new({3, 1}, 1), player(), 10_000)

      assert caught
      assert {_x, _y, true} = Goat.where(goat)
    end

    test "it hunts faster than it wanders, and slower than a player walks" do
      # Seven cells off, in sight: a second of hunting at 330 a second, not 250 and not 800.
      {goat, false, _trail} = run(Goat.new({1, 1}, 1), mid({8, 1}), 1_000)
      {x, _y, true} = Goat.where(goat)
      {start_x, _} = mid({1, 1})

      assert_in_delta x - start_x, 330, 40
    end

    test "it goes faster as the pace goes up" do
      far = mid({8, 1})
      {calm, false, _} = run(Goat.new({1, 1}, 1), far, 1_000, :calm)
      {fast, false, _} = run(Goat.new({1, 1}, 1), far, 1_000, :fast)
      {faster, false, _} = run(Goat.new({1, 1}, 1), far, 1_000, :faster)

      assert [calm, fast, faster]
             |> Enum.map(fn g -> elem(Goat.where(g), 0) end)
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> a < b end)
    end

    test "it does not see a player behind a wall, even close" do
      # Column 3, rows 2 to 5 is a wall, so the cells on either side do not see each other.
      {goat, false, _trail} = run(Goat.new({2, 4}, 1), mid({4, 4}), 100)
      assert {_x, _y, false} = Goat.where(goat)
    end

    test "it does not see a player more than eight cells off" do
      {goat, false, _trail} = run(Goat.new({1, 1}, 1), mid({14, 1}), 100)
      assert {_x, _y, false} = Goat.where(goat)
    end

    test "a player that is not to be hunted is not caught, though it is next to them" do
      goat = Goat.new({5, 1}, 1)
      {_goat, caught, _trail} = run(goat, nil, 1_000)
      refute caught
    end

    test "after losing sight of the player it searches, and then wanders again" do
      {goat, false, _} = run(Goat.new({1, 1}, 1), mid({6, 1}), 300)
      assert {_x, _y, true} = Goat.where(goat)

      # The player is gone. It searches for four seconds, and wanders after that.
      {searching, false, _} = run(goat, nil, 2_000, :calm, 300)
      assert {_x, _y, true} = Goat.where(searching)

      {wandering, false, _} = run(searching, nil, 4_000, :calm, 2_300)
      assert {_x, _y, false} = Goat.where(wandering)
    end
  end

  describe "the way round walls" do
    test "it finds its way to a cell in another room, always on floor" do
      goat = %{Goat.new({1, 1}, 1) | mode: :search, goal: mid({14, 14}), lost_at: 0}

      {goat, false, trail} = run(goat, nil, 3_000, :faster, 0)
      assert Enum.all?(trail, &on_floor?/1)
      {x, y, _} = Goat.where(goat)
      assert {x, y} != mid({1, 1})
    end
  end

  describe "in_sight?/1" do
    test "is true while hunting and false while wandering" do
      goat = Goat.new({1, 1}, 1)
      refute Goat.in_sight?(goat)
      assert Goat.in_sight?(%{goat | mode: :hunt})
      refute Goat.in_sight?(%{goat | mode: :search})
    end
  end

  describe "integer positions" do
    test "the goat stays on whole numbers however it moves" do
      goat = %{
        Goat.new({1, 1}, 1)
        | mode: :search,
          goal: {14 * 256 + 128, 14 * 256 + 128},
          lost_at: 0
      }

      {goat, _caught, _trail} = run(goat, nil, 3_000, :faster, 0)

      assert is_integer(goat.x) and is_integer(goat.y)
    end

    test "it covers about the distance its pace says" do
      goat = Goat.new({1, 1}, 1)
      goat = %{goat | goal: {14 * 256 + 128, 1 * 256 + 128}}
      {moved, _caught} = Goat.step(goat, @grid, nil, 100, 100, :calm)

      # 250 a second for 100 ms is 25, and only the part of a unit is lost.
      assert (moved.x - goat.x) in 24..25
    end
  end
end
