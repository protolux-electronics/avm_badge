defmodule Badge.Ble.Link do
  @moduledoc """
  Owns the `ble_hid` port while the Keyboard page shows.

  `open/0` starts the Bluetooth stack and puts `Badge.Keyboard` in raw mode;
  `close/0` does the reverse, so raw mode never outlives the link. In
  between, `report/1` turns a raw label set into an input report, and
  `passkey/1` and `forget/0` drive pairing.

  `status/0` answers from memory: a ticker reads the internal RAM figures
  once a second, never the caller. Every driver event is logged.

  Traps exits, so a port that dies becomes an `:error` status rather than a
  dead link, which would take `Badge.UI` with it.
  """

  use GenServer

  alias Badge.Ble.Hid, as: Driver
  alias Badge.Ble.Status
  alias Badge.Identity
  alias Badge.Keyboard

  @mem_interval 1_000

  def start_link(:ok), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Starts advertising and turns raw keys on, if not already open."
  @spec open() :: :ok
  def open do
    Keyboard.raw(true)
    GenServer.cast(__MODULE__, :open)
  end

  @doc "Turns raw keys off and closes the link. Safe before the link has started."
  @spec close() :: :ok
  def close do
    Keyboard.raw(false)

    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, :close)
    end
  end

  @doc "Sends the keys held right now, as labels, to the host."
  @spec report([charlist]) :: :ok
  def report(labels), do: GenServer.cast(__MODULE__, {:report, labels})

  @doc "Answers the host's passkey request."
  @spec passkey(non_neg_integer) :: :ok
  def passkey(n), do: GenServer.cast(__MODULE__, {:passkey, n})

  @doc "Forgets every bonded host and waits to be paired again."
  @spec forget() :: :ok
  def forget, do: GenServer.cast(__MODULE__, :forget)

  @doc "Where the link is; see `Badge.Ble.Status`. Off while the link is not running."
  @spec status() :: Status.t()
  def status do
    case Process.whereis(__MODULE__) do
      nil -> Status.new("Badge")
      pid -> GenServer.call(pid, :status)
    end
  catch
    :exit, _reason -> Status.new("Badge")
  end

  @doc "The advertised name: \"Badge \" and the last four hex digits of the chip id."
  @spec name(binary) :: binary
  def name(chip) do
    case Identity.format(chip) do
      <<_head::binary-8, tail::binary-4>> -> "Badge " <> tail
      _unknown -> "Badge"
    end
  end

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)

    status = Status.new(name(Identity.chip_id()))

    {:ok, %{port: nil, status: status, measured: false, ticker: start_ticker()}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(_request, _from, state), do: {:reply, {:error, :unknown}, state}

  @impl true
  def handle_cast(:open, %{port: nil} = state), do: {:noreply, opening(state)}

  def handle_cast(:close, %{port: nil} = state) do
    {:noreply, %{state | status: Status.closed(state.status)}}
  end

  def handle_cast(:close, state), do: {:noreply, shut(state)}

  def handle_cast(_request, %{port: nil} = state), do: {:noreply, state}

  def handle_cast({:report, labels}, state) do
    sent(Driver.report(state.port, Badge.Hid.report(labels)))

    {:noreply, state}
  end

  def handle_cast({:passkey, n}, state) do
    :io.format(~c"BLE: passkey entered~n")
    logged(:passkey, Driver.passkey(state.port, n))

    {:noreply, state}
  end

  def handle_cast(:forget, state) do
    :io.format(~c"BLE: forgetting bonds~n")
    logged(:forget, Driver.forget(state.port))

    {:noreply, %{state | status: Status.event(state.status, :advertising)}}
  end

  def handle_cast(_request, state), do: {:noreply, state}

  @impl true
  def handle_info(:mem, %{port: nil} = state), do: {:noreply, state}

  def handle_info(:mem, state), do: {:noreply, measure(state)}

  # A port closed before its last events were read.
  def handle_info({:ble_hid, _port, event}, %{port: nil} = state) do
    :io.format(~c"BLE: late ~p~n", [event])

    {:noreply, state}
  end

  def handle_info({:ble_hid, _port, event}, state) do
    :io.format(~c"BLE: ~p~n", [event])

    {:noreply, %{state | status: Status.event(state.status, event)}}
  end

  def handle_info({:EXIT, pid, reason}, %{ticker: pid} = state) do
    :io.format(~c"BLE: ticker exited ~p~n", [reason])

    {:noreply, %{state | ticker: start_ticker()}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) when port != nil do
    :io.format(~c"BLE: port exited ~p~n", [reason])
    Keyboard.raw(false)

    {:noreply, %{state | port: nil, status: Status.failed(state.status, :port_exited)}}
  end

  # A port closed by shut/1 exits after the state already forgot it.
  def handle_info({:EXIT, _port, :normal}, state), do: {:noreply, state}

  def handle_info(message, state) do
    :io.format(~c"BLE: unhandled ~p~n", [message])

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: nil}), do: :ok

  def terminate(_reason, state) do
    Driver.close(state.port)
    Keyboard.raw(false)

    :ok
  end

  defp opening(state) do
    :io.format(~c"BLE: opening as ~s~n", [state.status.name])

    case Driver.open(state.status.name) do
      {:ok, port} ->
        %{state | port: port, status: Status.starting(state.status), measured: false}

      {:error, reason} ->
        :io.format(~c"BLE: open failed ~p~n", [reason])

        %{state | status: Status.failed(state.status, :open_failed)}
    end
  end

  # Releases every key first, so nothing stays held on the host.
  defp shut(state) do
    Driver.report(state.port, Badge.Hid.empty())
    logged(:close, Driver.close(state.port))

    %{state | port: nil, status: Status.closed(state.status)}
  end

  defp measure(state) do
    case Driver.mem(state.port) do
      {:ok, free, largest} ->
        log_first(state, free, largest)

        %{state | status: Status.mem(state.status, free, largest), measured: true}

      _error ->
        state
    end
  end

  defp log_first(%{measured: true}, _free, _largest), do: :ok

  defp log_first(state, free, largest) do
    case Driver.mem_at_open(state.port) do
      {:ok, before, before_largest} ->
        :io.format(~c"BLE: internal RAM ~p free, ~p largest before open; ~p, ~p now~n", [
          before,
          before_largest,
          free,
          largest
        ])

      _error ->
        :ok
    end
  end

  # Keys pressed before the host has paired or listened go nowhere, quietly.
  defp sent(:ok), do: :ok
  defp sent({:error, :not_connected}), do: :ok
  defp sent({:error, :not_encrypted}), do: :ok
  defp sent(other), do: :io.format(~c"BLE: report refused ~p~n", [other])

  defp logged(_what, :ok), do: :ok
  defp logged(what, other), do: :io.format(~c"BLE: ~p refused ~p~n", [what, other])

  defp start_ticker do
    link = self()

    spawn_link(fn -> tick_loop(link) end)
  end

  defp tick_loop(link) do
    Process.sleep(@mem_interval)
    send(link, :mem)
    tick_loop(link)
  end
end
