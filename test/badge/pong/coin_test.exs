defmodule Badge.Pong.CoinTest do
  use ExUnit.Case, async: true

  alias Badge.Pong.Coin

  test "starts face on, showing this badge" do
    assert Coin.face(0, :them) == {1024, :me}
  end

  test "lands on whoever serves, face on" do
    assert Coin.face(Coin.spin_ms(), :me) == {1024, :me}
    assert Coin.face(Coin.spin_ms(), :them) == {1024, :them}
    assert Coin.face(Coin.spin_ms() + 500, :them) == {1024, :them}
  end

  test "turns edge on and over during the spin" do
    faces = for ms <- 0..Coin.spin_ms()//25, do: Coin.face(ms, :them)

    assert Enum.any?(faces, fn {width, _face} -> width < 200 end)
    assert Enum.any?(faces, fn {_width, face} -> face == :them end)
  end

  test "is a disc" do
    rows = Coin.rows()

    assert {0, Coin.radius()} in rows
    assert Enum.all?(rows, fn {_dy, half} -> half <= Coin.radius() end)
  end
end
