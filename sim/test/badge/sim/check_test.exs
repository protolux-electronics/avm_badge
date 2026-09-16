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

  test "the board runs the production hardware owners and keeps their settings across reboot" do
    assert %{percent: 80, sleep: :s30} = :sys.get_state(Badge.Backlight)
    assert %{spi: :sim_spi} = :sys.get_state(Badge.Pixels)
    assert %{i2c: :sim_i2c} = :sys.get_state(Badge.Sensors)
    assert %{unit: :sim_adc} = :sys.get_state(Badge.Power)

    assert Badge.Sensors.acceleration() == {0, 0, -1000}
    assert Badge.Sensors.orientation() == Badge.Accel.flat()
    assert Badge.Sensors.temperature() == 23
    assert Badge.Power.status() == %{battery_mv: 3900, vbus_mv: 4600, usb: true}
    refute Badge.Keyboard.holding?(~c"Fn")

    nvs = Process.whereis(Badge.Sim.Nvs)
    backlight = Process.whereis(Badge.Backlight)
    pixels = Process.whereis(Badge.Pixels)

    Badge.Backlight.set(42)
    Badge.Backlight.store(42, :s60)
    assert Badge.Backlight.settings() == %{brightness: 42, sleep: :s60}

    Badge.Pixels.set_mode({:solid, 120})
    assert Badge.Pixels.mode() == {:solid, 120}

    Board.reboot()

    assert Process.whereis(Badge.Sim.Nvs) == nvs
    refute Process.whereis(Badge.Backlight) == backlight
    refute Process.whereis(Badge.Pixels) == pixels
    assert Badge.Backlight.settings() == %{brightness: 42, sleep: :s60}
    assert Badge.Pixels.mode() == {:solid, 120}
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
