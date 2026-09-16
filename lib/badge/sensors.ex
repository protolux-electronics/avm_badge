defmodule Badge.Sensors do
  @moduledoc """
  Reads the SC7A20 accelerometer and TMP103 temperature sensor over the
  shared I2C bus.

  Every reading is taken on demand, inside the call that asks for it. This
  process runs no timer and takes no interrupt, so a page that never asks
  costs nothing and a caller never queues behind background sampling.

  Accelerometer samples are smoothed against the previous reading, so the
  averaging follows how often a page actually polls.
  """

  use GenServer

  import Bitwise

  alias Badge.Accel
  alias Badge.Hardware

  @compile {:no_warn_undefined, I2C}

  @sc7a20_addr Hardware.sc7a20_addr()
  @tmp103_addr Hardware.tmp103_addr()

  @sc7a20_ctrl_reg1 0x20
  @sc7a20_ctrl_reg1_25hz_xyz 0x37
  @sc7a20_ctrl_reg3 0x22
  @sc7a20_ctrl_reg3_int_off 0x00
  @sc7a20_ctrl_reg4 0x23
  @sc7a20_ctrl_reg4_bdu_2g 0x80
  @sc7a20_out_x_l 0x28
  @sc7a20_auto_increment 0x80

  @tmp103_reg 0x00

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Reads the accelerometer now, in milli-g."
  @spec acceleration() :: Accel.mg()
  def acceleration do
    GenServer.call(__MODULE__, :acceleration)
  end

  @doc "Reads the accelerometer now and returns roll and pitch in whole degrees."
  @spec orientation() :: {integer, integer}
  def orientation do
    GenServer.call(__MODULE__, :orientation)
  end

  @doc "Reads the TMP103 now in whole degrees C, or :unavailable if the read fails."
  @spec temperature() :: integer | :unavailable
  def temperature do
    GenServer.call(__MODULE__, :temperature)
  end

  @impl true
  def init(:ok) do
    i2c = I2C.open(scl: Hardware.i2c_scl(), sda: Hardware.i2c_sda(), clock_speed_hz: 100_000)

    :ok = I2C.write_bytes(i2c, @sc7a20_addr, @sc7a20_ctrl_reg1, @sc7a20_ctrl_reg1_25hz_xyz)
    :ok = I2C.write_bytes(i2c, @sc7a20_addr, @sc7a20_ctrl_reg4, @sc7a20_ctrl_reg4_bdu_2g)

    # INT1 stays off: readings are polled, so a data-ready line would only generate traffic.
    :ok = I2C.write_bytes(i2c, @sc7a20_addr, @sc7a20_ctrl_reg3, @sc7a20_ctrl_reg3_int_off)

    :io.format(~c"Sensors: sc7a20 and tmp103, polled on demand~n")

    {:ok, %{i2c: i2c, accel: nil}}
  end

  @impl true
  def handle_call(:acceleration, _from, state) do
    accel = read_accel(state)

    {:reply, accel, %{state | accel: accel}}
  end

  def handle_call(:orientation, _from, state) do
    accel = read_accel(state)

    {:reply, Accel.orientation(accel), %{state | accel: accel}}
  end

  def handle_call(:temperature, _from, state) do
    {:reply, read_temp(state.i2c), state}
  end

  defp read_accel(%{i2c: i2c, accel: previous}) do
    case I2C.read_bytes(i2c, @sc7a20_addr, @sc7a20_out_x_l ||| @sc7a20_auto_increment, 6) do
      {:ok, bytes} -> Accel.average(previous, Accel.decode(bytes))
      {:error, _reason} -> previous || {0, 0, 0}
    end
  end

  defp read_temp(i2c) do
    case I2C.read_bytes(i2c, @tmp103_addr, @tmp103_reg, 1) do
      {:ok, <<raw>>} -> signed_byte(raw)
      {:error, _reason} -> :unavailable
    end
  end

  # TMP103 register 0x00 is a signed 8-bit whole-degree-C reading.
  defp signed_byte(raw) when raw >= 128, do: raw - 256
  defp signed_byte(raw), do: raw
end
