defmodule Badge.Display.AtomGL do
  @moduledoc "AtomGL display backend for the badge panel."

  @behaviour Badge.Display

  alias Badge.Hardware

  @compile {:no_warn_undefined, :port}

  @doc "Opens the display port once so UI restarts can reuse it."
  @spec open(term) :: port
  def open(spi), do: :erlang.open_port({:spawn, "display"}, display_opts(spi))

  @impl true
  def update(port, items) do
    :port.call(port, {:update, items})
    :ok
  end

  @impl true
  def register_font(port, name, bytes) do
    :port.call(port, {:register_font, name, bytes})
    :ok
  end

  @impl true
  def deregister_font(port, name) do
    :port.call(port, {:deregister_font, name})
    :ok
  end

  # init_seq_type "alt_gamma_2" matches this panel; rotation 3 needs the patch noted in Badge.Hardware.
  defp display_opts(spi) do
    [
      compatible: "sitronix,st7789",
      init_seq_type: "alt_gamma_2",
      enable_tft_invon: true,
      width: Hardware.display_width(),
      height: Hardware.display_height(),
      rotation: Hardware.display_rotation(),
      reset: Hardware.display_reset(),
      dc: Hardware.display_dc(),
      cs: Hardware.display_cs(),
      backlight: Hardware.display_backlight(),
      backlight_active: :low,
      backlight_enabled: true,
      clock_speed_hz: Hardware.display_clock_hz(),
      spi_host: spi
    ]
  end
end
