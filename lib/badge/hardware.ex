defmodule Badge.Hardware do
  @moduledoc """
  Board pin assignments and bus constants for the AVM badge (ESP32-S3).

  Nothing here has side effects; these are compile-time constants exposed as
  functions so that every other module reads pins from exactly one place.
  """

  # 6x13 matrix, no diodes. ROW5 (GPIO45) and COL7 (GPIO46) are strapping pins.
  def rows, do: [38, 39, 40, 41, 42, 45]
  def cols, do: [37, 36, 35, 48, 34, 33, 47, 46, 21, 18, 17, 16, 15]

  # 240x320 native; the badge mounts the panel landscape, so these are rotated.
  def display_width, do: 320
  def display_height, do: 240
  # Needs AtomGL branch led-modes (11be5f9); without it the panel is silently black.
  def display_rotation, do: 3
  def display_sclk, do: 5
  def display_mosi, do: 8
  def display_miso, do: 9
  def display_cs, do: 7
  def display_dc, do: 4
  def display_reset, do: 6
  # Strapping pin (JTAG source select), active low.
  def display_backlight, do: 3
  def display_peripheral, do: "spi2"
  # AtomGL's ST7789 default is 40 MHz. The SPI clock only divides 80 MHz, so a
  # value in between rounds to one of those; 80 halves the ~31 ms full-frame
  # write. These pins route through the GPIO matrix, so drop back to 40 MHz if
  # the panel shows noise.
  def display_clock_hz, do: 80_000_000

  # SK6812/WS2812 chain; no clock line, so SCLK is -1.
  def pixel_data, do: 14
  def pixel_sclk, do: -1
  def pixel_peripheral, do: "spi3"
  def pixel_clock_hz, do: 3_200_000
  def pixel_count, do: 4

  # Battery and VBUS each read through a 1/2 voltage divider.
  def adc_battery_pin, do: 1
  def adc_vbus_pin, do: 2

  # TMP103 temperature sensor and SC7A20 accelerometer share this bus.
  def i2c_scl, do: 10
  def i2c_sda, do: 11
  def tmp103_addr, do: 0x70
  def sc7a20_addr, do: 0x19

  # SC7A20 INT1, routed for a data-ready interrupt.
  def accel_int_pin, do: 12

  # IR link. These are UART0's default pins, so the console has to be driven
  # off them before either is usable; configuring them takes the IO MUX back.
  # LED is active low, and the phototransistor idles high, so beam-present
  # reads low at both ends and standard UART polarity works without inverting.
  def ir_led, do: 43
  def ir_sense, do: 44
end
