defmodule Badge.AccelTest do
  use ExUnit.Case, async: true

  alias Badge.Accel

  describe "decode/1" do
    test "converts raw counts to milli-g" do
      bytes = <<-1120::little-signed-16, 13936::little-signed-16, -9184::little-signed-16>>
      assert Accel.decode(bytes) == {-68, 850, -560}
    end

    test "a stationary reading has unit magnitude" do
      # Real probe reading of a badge sitting flat on a desk.
      bytes = <<-1120::little-signed-16, 13936::little-signed-16, -9184::little-signed-16>>
      {x, y, z} = Accel.decode(bytes)
      magnitude = :math.sqrt(x * x + y * y + z * z)

      assert_in_delta magnitude, 1000, 30
    end
  end

  describe "to_panel/1" do
    test "the sensor's X is the panel's Y" do
      assert Accel.to_panel({1000, 0, 0}) == {0, 1000, 0}
    end

    test "the sensor's Y is the panel's -X" do
      assert Accel.to_panel({0, 1000, 0}) == {-1000, 0, 0}
    end

    test "the sensor's Z is the panel's -Z" do
      assert Accel.to_panel({0, 0, 1000}) == {0, 0, -1000}
    end

    test "a badge lying panel up reads level" do
      assert Accel.orientation(Accel.to_panel({0, 0, -1000})) == {0, 0}
    end

    test "tilting the sensor about its own X becomes pitch, not roll" do
      assert Accel.orientation(Accel.to_panel({0, 500, -866})) == {0, 30}
    end
  end

  describe "average/2" do
    test "nil previous adopts the sample as-is" do
      assert Accel.average(nil, {100, 200, 300}) == {100, 200, 300}
    end

    test "a repeated sample settles near it and then stops moving" do
      settle = fn n ->
        :lists.foldl(
          fn _i, acc -> Accel.average(acc, {100, 200, 300}) end,
          {0, 0, 0},
          :lists.seq(1, n)
        )
      end

      {x, y, z} = settle.(40)

      # Integer division truncates, so the average stalls within 3 of the target
      # rather than reaching it. That is what stops it dithering once settled.
      assert_in_delta x, 100, 3
      assert_in_delta y, 200, 3
      assert_in_delta z, 300, 3

      assert settle.(80) == settle.(40)
    end

    test "one step moves a quarter of the way" do
      assert Accel.average({0, 0, 0}, {100, 200, 300}) == {25, 50, 75}
    end
  end

  describe "orientation/1" do
    test "flat, z up, gives zero roll and pitch" do
      assert Accel.orientation({0, 0, 1000}) == {0, 0}
    end

    test "rolled 90 degrees onto its side" do
      assert Accel.orientation({0, 1000, 0}) == {90, 0}
    end

    test "pitched 90 degrees nose down" do
      assert Accel.orientation({1000, 0, 0}) == {0, -90}
    end
  end
end
