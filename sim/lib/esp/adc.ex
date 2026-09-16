defmodule Esp.ADC do
  @moduledoc false

  alias Badge.Hardware

  @battery_pin Hardware.adc_battery_pin()
  @vbus_pin Hardware.adc_vbus_pin()

  def init, do: {:ok, :sim_adc}

  def acquire(pin, :sim_adc, :bit_max, :db_12),
    do: {:ok, {:sim_adc_channel, pin}}

  def sample({:sim_adc_channel, pin}, :sim_adc, _options) do
    case pin do
      @battery_pin -> {:ok, {0, 1950}}
      @vbus_pin -> {:ok, {0, 2300}}
      _other -> {:error, :unsupported}
    end
  end
end
