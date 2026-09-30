defmodule Badge.SleepTest do
  use ExUnit.Case, async: true

  alias Badge.Sleep

  test "the CPU sleeps thirty seconds after the screen does" do
    assert Sleep.ticks(100) == 300
  end

  test "a badge on battery with nothing in flight may sleep" do
    assert Sleep.allowed?(%{usb: false, downloading: false})
  end

  test "USB power holds it back, since sleep drops the serial port" do
    refute Sleep.allowed?(%{usb: true, downloading: false})
  end

  test "a download in flight holds it back" do
    refute Sleep.allowed?(%{usb: false, downloading: true})
  end

  test "an open Bluetooth link holds it back, since sleep would drop the host" do
    refute Sleep.allowed?(%{usb: false, downloading: false, bluetooth: true})
    assert Sleep.allowed?(%{usb: false, downloading: false, bluetooth: false})
  end
end
