defmodule I2C do
  @moduledoc false

  alias Badge.Hardware

  @sc7a20_addr Hardware.sc7a20_addr()
  @tmp103_addr Hardware.tmp103_addr()

  def open(_options), do: :sim_i2c
  def write_bytes(:sim_i2c, _address, _register, _value), do: :ok

  def read_bytes(:sim_i2c, address, register, count) do
    case {address, register, count} do
      {@sc7a20_addr, 0xA8, 6} ->
        {:ok, <<0::little-signed-16, 0::little-signed-16, -16384::little-signed-16>>}

      {@tmp103_addr, 0x00, 1} ->
        {:ok, <<23>>}

      _other ->
        {:error, :unsupported}
    end
  end
end
