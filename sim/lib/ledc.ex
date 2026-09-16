defmodule LEDC do
  @moduledoc false

  def low_speed_mode, do: :low_speed
  def timer_config(_options), do: :ok
  def channel_config(_options), do: :ok
  def set_duty(_speed_mode, _channel, _duty), do: :ok
  def update_duty(_speed_mode, _channel), do: :ok
end
