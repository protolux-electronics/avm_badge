defmodule Badge.Sim.GameLink.Loopback do
  @moduledoc """
  Host stub for `Badge.GameLink.Transport` and `Badge.GameLink.Join`: always
  available, sends nowhere. UDP loopback, `SIM_PORT` and the panel control
  are Plan B; multi-badge host tests use `Badge.GameLink.Switchboard`
  instead.
  """

  @behaviour Badge.GameLink.Transport
  @behaviour Badge.GameLink.Join

  import Kernel, except: [send: 2]

  @capabilities %{
    max_frame_bytes: 250,
    broadcast: true,
    ordered: false,
    lossless: false,
    round_trip_ms: 15,
    max_peers: 19,
    session_bytes: 2
  }

  @impl Badge.GameLink.Transport
  def capabilities, do: @capabilities

  @impl Badge.GameLink.Transport
  def open(owner) do
    Kernel.send(owner, {:gamelink_status, {:available, %{channel: 6, net: <<0, 0>>}}})
    :ok
  end

  @impl Badge.GameLink.Transport
  def close, do: :ok

  @impl Badge.GameLink.Transport
  def send(_addr_or_broadcast, _frame), do: :ok

  @impl Badge.GameLink.Transport
  def add_peer(_addr), do: :ok

  @impl Badge.GameLink.Transport
  def del_peer(_addr), do: :ok

  @impl Badge.GameLink.Transport
  def session(_session_or_nil), do: :ok

  @impl Badge.GameLink.Transport
  def compatible(mine, theirs) do
    cond do
      theirs.present == false -> {:error, :other_no_radio}
      theirs.available == false or theirs.scope == nil -> {:error, :other_no_wifi}
      theirs.scope.channel == mine.channel -> :ok
      theirs.scope.net == mine.net -> {:error, :other_access_point}
      true -> {:error, :different_network}
    end
  end

  @impl Badge.GameLink.Join
  def start(_owner, _app_id), do: :ok

  @impl Badge.GameLink.Join
  def advertise(_offer), do: :ok

  @impl Badge.GameLink.Join
  def stop, do: :ok
end
