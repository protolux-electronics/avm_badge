defmodule Badge.Sim.CheckTest do
  use ExUnit.Case

  alias Badge.Sim.Board
  alias Badge.Sim.Check
  alias Badge.Sim.Screen

  setup do
    start_supervised!({Badge.Log, :ok})
    start_supervised!(Board)
    :ok
  end

  test "every page renders to draw commands" do
    for page <- Check.pages() do
      assert {:ok, items, frame, _assets} = Check.render(page)
      assert items != [], "#{inspect(page)} drew nothing"
      assert length(frame) == length(items), "#{inspect(page)} has an item the simulator cannot draw"
    end
  end

  test "the screen follows keys and survives a reboot" do
    for key <- [{:nav, :diamond}, {:move, :right}, {:move, :right}], do: Screen.key(key)
    Process.sleep(150)
    assert Screen.frame() != []

    Board.reboot()
    Process.sleep(150)
    assert Screen.frame() != []
  end
end
