defmodule Badge.Power do
  @moduledoc """
  Owns the ADC for the battery and VBUS voltage dividers.

  Both channels sample through a 1/2 divider, so the true voltage is
  twice the calibrated millivolt reading. Voltage changes slowly, so a
  linked ticker samples both channels every `@interval` rather than on
  demand, and logs a status line every `@report` samples.
  """

  use GenServer

  alias Badge.Hardware

  @compile {:no_warn_undefined, [Esp.ADC]}

  @interval 2_000
  @samples 64

  # Ticks between status lines.
  @report 15

  # VBUS above this is treated as USB present.
  @usb_present_mv 4_000

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "True battery voltage in millivolts, divider applied."
  @spec battery_mv() :: integer
  def battery_mv do
    GenServer.call(__MODULE__, :battery_mv)
  end

  @doc "True VBUS voltage in millivolts, divider applied."
  @spec vbus_mv() :: integer
  def vbus_mv do
    GenServer.call(__MODULE__, :vbus_mv)
  end

  @doc "Battery voltage, VBUS voltage and USB presence in a single call."
  @spec status() :: %{battery_mv: integer, vbus_mv: integer, usb: boolean}
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Whether USB power is present, from the VBUS reading."
  @spec usb_present?() :: boolean
  def usb_present? do
    GenServer.call(__MODULE__, :usb_present?)
  end

  @impl true
  def init(:ok) do
    {:ok, unit} = Esp.ADC.init()
    {:ok, battery_chan} = Esp.ADC.acquire(Hardware.adc_battery_pin(), unit, :bit_max, :db_12)
    {:ok, vbus_chan} = Esp.ADC.acquire(Hardware.adc_vbus_pin(), unit, :bit_max, :db_12)

    :io.format(
      ~c"Power: battery GPIO~p, vbus GPIO~p, sampling every ~ps, reporting every ~ps~n",
      [
        Hardware.adc_battery_pin(),
        Hardware.adc_vbus_pin(),
        div(@interval, 1000),
        div(@interval * @report, 1000)
      ]
    )

    send(self(), :tick)
    start_ticker()

    {:ok,
     %{
       unit: unit,
       battery_chan: battery_chan,
       vbus_chan: vbus_chan,
       battery_mv: 0,
       vbus_mv: 0,
       ticks: 0
     }}
  end

  @impl true
  def handle_call(:battery_mv, _from, state), do: {:reply, state.battery_mv, state}
  def handle_call(:vbus_mv, _from, state), do: {:reply, state.vbus_mv, state}

  def handle_call(:usb_present?, _from, state),
    do: {:reply, state.vbus_mv >= @usb_present_mv, state}

  def handle_call(:status, _from, state) do
    status = %{
      battery_mv: state.battery_mv,
      vbus_mv: state.vbus_mv,
      usb: state.vbus_mv >= @usb_present_mv
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:tick, state) do
    battery_mv = sample_mv(state.unit, state.battery_chan)
    vbus_mv = sample_mv(state.unit, state.vbus_chan)

    report(state.ticks, battery_mv, vbus_mv)

    {:noreply, %{state | battery_mv: battery_mv, vbus_mv: vbus_mv, ticks: state.ticks + 1}}
  end

  # Bring-up instrumentation: this is the only line that runs on every page,
  # so it is where a leak is visible with nothing else switched on.
  defp report(ticks, battery_mv, vbus_mv) when rem(ticks, @report) == 0 do
    :io.format(~c"Power: battery=~pmv vbus=~pmv usb=~p heap=~p internal=~p/~p~n", [
      battery_mv,
      vbus_mv,
      vbus_mv >= @usb_present_mv,
      free_heap(),
      info(:esp32_internal_free_size),
      info(:esp32_internal_largest_free_block)
    ])
  end

  defp report(_ticks, _battery_mv, _vbus_mv), do: :ok

  defp sample_mv(unit, chan) do
    case Esp.ADC.sample(chan, unit, [:raw, :voltage, {:samples, @samples}]) do
      {:ok, {_raw, mv}} -> mv * 2
      {:error, _reason} -> 0
    end
  end

  defp free_heap, do: info(:esp32_free_heap_size)

  defp info(key) do
    :erlang.system_info(key)
  catch
    _kind, _error -> -1
  end

  defp start_ticker do
    power = self()
    spawn_link(fn -> tick_loop(power) end)
  end

  defp tick_loop(power) do
    Process.sleep(@interval)
    send(power, :tick)
    tick_loop(power)
  end
end
