defmodule Badge.Accel do
  @moduledoc """
  Pure maths for the SC7A20 accelerometer: decoding raw registers,
  exponential averaging, and deriving tilt orientation. No I2C, no process
  state.

  The SC7A20 in normal mode is 10-bit, left-justified in a signed 16-bit
  little-endian pair, +-2g full scale, so 1g = 16384 counts and
  `mg = raw * 1000 / 16384`, simplified here to `raw * 125 / 2048`.

  The sensor is mounted turned a quarter turn about Z and with its Z axis
  inverted relative to the panel. `to_panel/1` undoes both, so everything
  after it, `orientation/1` included, is in the panel's frame: a badge lying
  flat with the panel upwards reads gravity on +Z and zero roll and pitch.
  """

  @type mg :: {integer, integer, integer}

  @doc "Decodes the 6 bytes read from OUT_X_L..OUT_Z_H (0x28..0x2D) into milli-g."
  @spec decode(binary) :: mg
  def decode(<<x::little-signed-16, y::little-signed-16, z::little-signed-16>>) do
    {to_mg(x), to_mg(y), to_mg(z)}
  end

  defp to_mg(raw), do: div(raw * 125, 2048)

  @doc """
  Turns a sample from the sensor's axes into the panel's.

  The sensor's X runs along the panel's Y, its Y along the panel's -X, and
  its Z along the panel's -Z. Apply it once, straight after `decode/1`.
  """
  @spec to_panel(mg) :: mg
  def to_panel({x, y, z}), do: {-y, x, -z}

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

  @doc "Roll and pitch in whole degrees from a milli-g sample."
  @spec orientation(mg) :: {integer, integer}
  def orientation({x, y, z}) do
    roll = round(:math.atan2(y, z) * 180 / :math.pi())
    pitch = round(:math.atan2(-x, :math.sqrt(y * y + z * z)) * 180 / :math.pi())
    {roll, pitch}
  end
end
