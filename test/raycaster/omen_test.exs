defmodule Raycaster.OmenTest do
  use ExUnit.Case, async: true

  alias Raycaster.Omen

  @player %{x: 1000, y: 1000, a: 0}
  @cell 256

  defp goat(cells, hunting \\ false), do: {1000 + cells * @cell, 1000, hunting}

  describe "level/2" do
    test "no goat is no dread" do
      assert Omen.level(@player, nil) == 0
    end

    test "grows as the goat comes closer" do
      assert Omen.level(@player, goat(8)) == 0
      assert Omen.level(@player, goat(6)) == 1
      assert Omen.level(@player, goat(3)) == 2
    end

    test "the strobe is for a goat that is close and after you" do
      assert Omen.level(@player, goat(1, true)) == 3
      assert Omen.level(@player, goat(1, false)) == 2
    end

    test "a goat after you but farther than two cells is not the strobe" do
      assert Omen.level(@player, goat(3, true)) == 2
    end
  end

  describe "pattern/1" do
    test "every level has frames of one colour for each of the four LEDs, kept dim" do
      for level <- [1, 2, 3, :caught] do
        {ms, frames} = Omen.pattern(level)

        assert ms == :infinity or ms > 0
        assert [_ | _] = frames

        for frame <- frames do
          assert length(frame) == 4
          for {r, g, b} <- frame, do: assert(r + g + b <= 128)
        end
      end
    end

    test "being caught holds still" do
      assert {:infinity, [_one]} = Omen.pattern(:caught)
    end
  end

  describe "level/3" do
    @cell 256
    defp goat_at(cells, hunting), do: {round(cells * @cell), 0, hunting}
    @player %{x: 0, y: 0}

    test "is level/2 while the level goes up or stays" do
      assert Omen.level(@player, goat_at(6, false), 0) == Omen.level(@player, goat_at(6, false))
      assert Omen.level(@player, goat_at(1, true), 1) == 3
    end

    test "holds a level a cell past its edge, and lets go beyond that" do
      assert Omen.level(@player, goat_at(7.5, false), 1) == 1
      assert Omen.level(@player, goat_at(8.5, false), 1) == 0
      assert Omen.level(@player, goat_at(4.5, false), 2) == 2
      assert Omen.level(@player, goat_at(5.5, false), 2) == 1
      assert Omen.level(@player, goat_at(2.5, true), 3) == 3
      assert Omen.level(@player, goat_at(3.5, true), 3) == 2
    end

    test "a goat that has stopped hunting drops from 3 at once" do
      assert Omen.level(@player, goat_at(1, false), 3) == 2
    end

    test "no goat is 0, and the caught level is not held" do
      assert Omen.level(@player, nil, 2) == 0
      assert Omen.level(@player, goat_at(1, true), :caught) == 3
    end
  end
end
