defmodule Badge.Sim.CheckTest do
  use ExUnit.Case

  alias Badge.Sim.Board
  alias Badge.Sim.Check
  alias Badge.Sim.Display

  setup do
    start_supervised!({Badge.Log, :ok})
    start_supervised!(Board)
    :ok
  end

  test "every page renders to draw commands" do
    for page <- Check.pages() do
      assert {:ok, items, frame, _assets} = Check.render(page)
      assert items != [], "#{inspect(page)} drew nothing"

      assert length(frame) == length(items),
             "#{inspect(page)} has an item the simulator cannot draw"
    end
  end

  test "the board runs the shared UI and survives a reboot" do
    ui = Process.whereis(Badge.UI)
    assert is_pid(ui)

    Display.attach(self())
    assert_receive {:frame, initial}, 200
    assert initial != []

    Badge.UI.key_event({:nav, :diamond})
    assert %{page: Badge.Page.Settings} = :sys.get_state(Badge.UI)
    assert_receive {:frame, navigated}, 250
    assert navigated != []

    Board.reboot()
    Display.attach(self())
    assert_receive {:frame, rebooted}, 200
    assert rebooted != []
    assert is_pid(Process.whereis(Badge.UI))
    refute Process.whereis(Badge.UI) == ui
  end
end
