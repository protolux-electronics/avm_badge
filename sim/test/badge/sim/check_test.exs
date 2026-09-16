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

  test "every page renders through the shared UI" do
    _sequence =
      Enum.reduce(Check.pages(), 0, fn page, sequence ->
        assert {:ok, items, frame, assets} = Check.render(page)
        assert items != [], "#{inspect(page)} drew nothing"
        assert length(frame) == length(items), "#{inspect(page)} has an unsupported display item"
        assert %{page: ^page} = :sys.get_state(Badge.UI)

        snapshot = Display.snapshot()
        assert snapshot.sequence > sequence
        assert snapshot.items == items
        assert snapshot.frame == frame
        assert snapshot.assets == assets

        snapshot.sequence
      end)
  end

  test "the board runs the shared UI and survives a reboot" do
    ui = Process.whereis(Badge.UI)
    assert is_pid(ui)

    initial = Display.snapshot()
    assert initial.frame != []

    Badge.UI.key_event({:nav, :diamond})
    assert %{page: Badge.Page.Settings} = :sys.get_state(Badge.UI)
    sequence = Display.snapshot().sequence
    send(Badge.UI, :render_tick)
    assert {:ok, navigated} = Display.await_frame(sequence, 200)
    assert navigated.sequence > sequence
    assert navigated.frame != []

    Board.reboot()
    rebooted = Display.snapshot()
    assert rebooted.sequence > 0
    assert rebooted.frame != []
    assert is_pid(Process.whereis(Badge.UI))
    refute Process.whereis(Badge.UI) == ui
  end
end
