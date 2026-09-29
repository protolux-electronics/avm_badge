defmodule Badge.Ir.Link do
  @moduledoc """
  Owns UART1 on the IR beam for the life of the badge.

  Listens continuously and writes only when asked. `Badge.Ir.send/1` casts
  here and the frame goes out on the next pass of the loop, so a send waits
  at most one read window.

  The loop is a blocking read followed by a self-send rather than a timer,
  because `Process.send_after/3` is expensive on this platform. Casts queue
  behind the read and are taken first when it returns.

  UART1 is used rather than UART0. The pins are UART0's by default, but the
  ESP32-S3 routes any peripheral to any pin through the GPIO matrix, so
  claiming them for UART1 leaves the console with nowhere to drive and no
  base image rebuild is needed.
  """

  use GenServer

  alias Badge.Hardware
  alias Badge.Identity
  alias Badge.Ir.Frame

  @compile {:no_warn_undefined, :uart}

  # 4800 smears a 21-byte frame down to 12 at anything but square alignment.
  @baud 2400
  @read_ms 100

  # Enough for several frames; a stream of noise that never frames up must
  # not grow without bound.
  @buffer_limit 256

  def start_link(:ok) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Frames a payload from this badge and puts it on the beam."
  @spec transmit(binary) :: :ok
  def transmit(payload) do
    GenServer.cast(__MODULE__, {:transmit, payload})
  end

  @doc "The baud this build was compiled for."
  @spec baud() :: pos_integer
  def baud, do: @baud

  @impl true
  def init(:ok) do
    id = Identity.chip_id()
    port = open()

    :io.format(~c"Ir: up baud=~p id=~s~n", [@baud, Identity.format(id)])

    send(self(), :read)

    {:ok, %{port: port, id: id, buffer: <<>>}}
  end

  @impl true
  def handle_call(request, _from, state), do: {:stop, {:bad_call, request}, state}

  @impl true
  def handle_cast({:transmit, payload}, state) do
    write(state.port, Frame.encode(state.id, payload))

    {:noreply, state}
  end

  @impl true
  def handle_info(:read, state) do
    buffer = state.buffer |> read(state.port) |> harvest(state.id)

    send(self(), :read)

    {:noreply, %{state | buffer: buffer}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A restart is otherwise silent, and the reason is the only thing that says
  # the pins have been given up.
  @impl true
  def terminate(reason, state) do
    :uart.close(state.port)
    :io.format(~c"Ir: down ~p~n", [reason])

    :ok
  end

  defp open do
    :uart.open("UART1",
      tx: Hardware.ir_led(),
      rx: Hardware.ir_sense(),
      speed: @baud,
      data_bits: 8,
      stop_bits: 1,
      parity: :none,
      flow_control: :none
    )
  end

  # Badge.Ir refuses an oversized payload first; this is the second line.
  defp write(_port, {:error, reason}) do
    :io.format(~c"Ir: refused ~p~n", [reason])
  end

  defp write(port, frame), do: :uart.write(port, frame)

  defp read(buffer, port) do
    case :uart.read(port, @read_ms) do
      {:ok, data} ->
        cap(buffer <> :erlang.iolist_to_binary(data))

      {:error, :timeout} ->
        buffer

      other ->
        :io.format(~c"Ir: read returned ~p~n", [other])
        buffer
    end
  end

  defp cap(buffer) when byte_size(buffer) <= @buffer_limit, do: buffer

  defp cap(buffer) do
    :binary.part(buffer, byte_size(buffer) - @buffer_limit, @buffer_limit)
  end

  defp harvest(buffer, id) do
    case Frame.decode(buffer) do
      {:ok, frame, rest} ->
        deliver(id, frame)
        harvest(rest, id)

      {:bad, reason, rest} ->
        :io.format(~c"Ir: bad frame ~p~n", [reason])
        harvest(rest, id)

      {:more, rest} ->
        rest
    end
  end

  # Our own beam reaching our own sensor would be a hardware finding, not a peer.
  defp deliver(id, %{from: id}) do
    :io.format(~c"Ir: SELF ECHO, own beam reaches own sensor~n")
  end

  # Badge.UI owns the mailbox every page reads through, and it can restart.
  defp deliver(_id, %{from: from, payload: payload}) do
    case Process.whereis(Badge.UI) do
      nil -> :ok
      ui -> Kernel.send(ui, {:ir, from, payload})
    end
  end
end
