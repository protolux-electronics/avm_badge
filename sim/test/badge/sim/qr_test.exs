defmodule Badge.Sim.QRTest do
  use ExUnit.Case, async: true

  test "the shared QR item is encoded for the browser simulator" do
    {:ok, code} =
      Badge.QR.encode("https://github.com/protolux-electronics/avm_badge")

    item = Badge.QR.item(code, 78, 28, 4)

    assert {[command], [asset], _sent} = Badge.Sim.Encode.encode([item], MapSet.new())
    assert command.t == "img"
    assert command.x == 78
    assert command.y == 28
    assert command.w == 148
    assert command.h == 148
    assert command.xs == 4
    assert command.ys == 4
    assert asset.w == 37
    assert asset.h == 37
  end
end
