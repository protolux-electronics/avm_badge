defmodule Badge.Accel do
  @moduledoc """
  Pure maths for the SC7A20 accelerometer: decoding raw registers,
  exponential averaging, and deriving tilt orientation. No I2C, no process
  state.

  The SC7A20 in normal mode is 10-bit, left-justified in a signed 16-bit
  little-endian pair, +-2g full scale, so 1g = 16384 counts and
  `mg = raw * 1000 / 16384`, simplified here to `raw * 125 / 2048`.

  The sensor is mounted with its Z axis inverted relative to the panel, so a
  badge lying flat with the panel upwards reads gravity on -Z rather than
  +Z. `flat/0` is that reference; measure tilt as a difference from it.
  """

  @type mg :: {integer, integer, integer}

  @doc "Decodes the 6 bytes read from OUT_X_L..OUT_Z_H (0x28..0x2D) into milli-g."
  @spec decode(binary) :: mg
  def decode(<<x::little-signed-16, y::little-signed-16, z::little-signed-16>>) do
    {to_mg(x), to_mg(y), to_mg(z)}
  end

  defp to_mg(raw), do: div(raw * 125, 2048)

  @doc """
  Exponential moving average, alpha = 1/4, applied per axis. `nil` as the
  previous value adopts `sample` as-is.
  """
  @spec average(mg | nil, mg) :: mg
  def average(nil, sample), do: sample

  def average({px, py, pz}, {x, y, z}) do
    {ema(px, x), ema(py, y), ema(pz, z)}
  end

  defp ema(previous, new), do: previous + div(new - previous, 4)

  @doc """
  The roll and pitch `orientation/1` reports when the panel is horizontal.

  Gravity lands on -Z rather than +Z, so a level badge reads half a turn of
  roll instead of none.
  """
  @spec flat() :: {integer, integer}
  def flat, do: orientation({0, 0, -1000})

  @doc "Roll and pitch in whole degrees from a milli-g sample."
  @spec orientation(mg) :: {integer, integer}
  def orientation({x, y, z}) do
    roll = -round(:math.atan2(x, z) * 180 / :math.pi())
    pitch = round(:math.atan2(-y, :math.sqrt(x * x + z * z)) * 180 / :math.pi())
    {roll, pitch}
  end
end
