defmodule Badge.Ble.Hid do
  @moduledoc """
  The `ble_hid` port driver: the badge as a Bluetooth LE keyboard.

  A thin wrapper over the ESP-IDF component in `components/atomvm_ble_hid`.
  NimBLE and the HID services run on their own FreeRTOS task; the owner that
  opened the port receives

      {:ble_hid, port, :advertising}
      {:ble_hid, port, {:connected, addr}}
      {:ble_hid, port, :passkey_input}
      {:ble_hid, port, {:passkey_display, n}}
      {:ble_hid, port, {:encrypted, bonded}}
      {:ble_hid, port, :ready}
      {:ble_hid, port, :disconnected}
      {:ble_hid, port, {:error, reason}}

  Match the port without pinning it; the driver's port term is not the one
  `open/1` returns. Every other call blocks until the driver answers.
  """

  @compile {:no_warn_undefined, :port}

  @timeout 2_000
  @close_timeout 10_000

  @doc "Starts the stack and advertises as `name`. Events go to the caller."
  @spec open(binary) :: {:ok, port} | {:error, term}
  def open(name) do
    {:ok, :erlang.open_port({:spawn, "ble_hid"}, owner: self(), name: name)}
  catch
    _kind, reason -> {:error, reason}
  end

  @doc "Sends an 8-byte input report from `Badge.Hid.report/1`."
  @spec report(port, binary) :: :ok | {:error, term}
  def report(port, report), do: call(port, {:report, report}, @timeout)

  @doc "Answers a `:passkey_input` with the six digits the host shows."
  @spec passkey(port, non_neg_integer) :: :ok | {:error, term}
  def passkey(port, n), do: call(port, {:passkey, n}, @timeout)

  @doc "Deletes every bond and drops the connection; advertising carries on."
  @spec forget(port) :: :ok | {:error, term}
  def forget(port), do: call(port, :forget, @timeout)

  @doc "Sets the Battery Service level, 0 to 100."
  @spec battery(port, 0..100) :: :ok | {:error, term}
  def battery(port, level), do: call(port, {:battery, level}, @timeout)

  @doc "Free internal RAM and its largest block, in bytes."
  @spec mem(port) :: {:ok, integer, integer} | {:error, term}
  def mem(port), do: call(port, :mem, @timeout)

  @doc "The same two figures, taken just before the stack started."
  @spec mem_at_open(port) :: {:ok, integer, integer} | {:error, term}
  def mem_at_open(port), do: call(port, :mem_at_open, @timeout)

  @doc "Disconnects, stops the stack and destroys the port."
  @spec close(port) :: :ok | {:error, term}
  def close(port), do: call(port, :close, @close_timeout)

  defp call(port, request, timeout) do
    case :port.call(port, request, timeout) do
      :badarg -> {:error, :badarg}
      reply -> reply
    end
  end
end
