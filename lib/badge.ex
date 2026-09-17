defmodule Badge do
  @moduledoc """
  Firmware entry point.

  Opens both SPI buses and the display port, and passes them to the supervised
  children as arguments; children only add devices to an already-open bus, and
  never open a bus or a port themselves. A child that opened its own would leak
  it every time the supervisor restarted the child.

  `Badge.Ir.Link` is the exception and opens its own UART, because it holds
  those pins for the life of the badge rather than sharing them.

  Two buses are used: the panel and the LED chain need different MOSI pins
  and clock rates.

  `start/0` parks after starting the supervisor, since AtomVM terminates
  when the start function returns.
  """

  alias Badge.Hardware

  @compile {:no_warn_undefined, [:atomvm, :spi]}

  def start do
    # First, so every process below prints through the log ring.
    {:ok, _log} = Badge.Log.start_link(:ok)
    Badge.Log.capture()

    :io.format(~c"Badge: starting~n")

    # Rickroll frames live in their own partition, shared by both OTA slots.
    case :atomvm.add_avm_pack_file(~c"/dev/partition/by-name/assets.avm", name: :assets) do
      :ok -> :ok
      {:error, reason} -> :io.format(~c"Badge: no assets partition: ~p~n", [reason])
    end

    display_spi = open_display_spi()
    pixel_spi = open_pixel_spi()

    # Opened here, not in the child, so a Badge.UI restart reuses the display
    # instead of orphaning its framebuffer.
    display = Badge.UI.open_display(display_spi)

    children = [
      {Badge.UI, display},
      {Badge.Backlight, :ok},
      {Badge.Keyboard, :ok},
      {Badge.Wifi, :ok},
      {Badge.Pixels, pixel_spi},
      {Badge.Sensors, :ok},
      {Badge.Power, :ok},
      {Badge.Ir.Link, :ok},
      {Badge.Chat.Link, :ok},
      {Badge.Update.Link, :ok},
      {Badge.Cluster.Link, :ok}
    ]

    {:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

    :io.format(~c"Badge: running~n")

    Badge.Autopilot.start()

    park()
  end

  # AtomGL adds its own SPI device, so device_config is empty here.
  defp open_display_spi do
    :spi.open(%{
      bus_config: %{
        peripheral: Hardware.display_peripheral(),
        sclk: Hardware.display_sclk(),
        mosi: Hardware.display_mosi(),
        miso: Hardware.display_miso()
      },
      device_config: %{}
    })
  end

  # LED chain has no clock line, so SCLK is -1.
  defp open_pixel_spi do
    :spi.open(%{
      bus_config: %{
        peripheral: Hardware.pixel_peripheral(),
        sclk: Hardware.pixel_sclk(),
        mosi: Hardware.pixel_data()
      },
      device_config: %{
        pixels: %{
          clock_speed_hz: Hardware.pixel_clock_hz(),
          mode: 0,
          cs: -1,
          address_len_bits: 0,
          command_len_bits: 0
        }
      }
    })
  end

  defp park do
    Process.sleep(60_000)
    park()
  end
end
