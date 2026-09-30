defmodule Badge.GameLink.Radio do
  @moduledoc """
  The only caller of `:espnow` in the firmware.

  `:espnow.open/1` is a singleton port whose owner is fixed for its whole
  life, so this GenServer opens it once, the first moment an owner exists
  and wifi is connected, and never reopens it. `close/0` drops the owner and
  every peer it added; the port itself stays open.

  Every public call is a cast: `espnow:send/3` is a synchronous port call
  and must never run on a page's own process.
  """

  use GenServer

  @behaviour Badge.GameLink.Transport

  @compile {:no_warn_undefined, :espnow}

  @broadcast <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
  @flood_limit 16

  @capabilities %{
    max_frame_bytes: 250,
    broadcast: true,
    ordered: false,
    lossless: false,
    round_trip_ms: 15,
    max_peers: 19,
    session_bytes: 2
  }

  @spec start_link(:ok) :: GenServer.on_start()
  def start_link(:ok) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "The ESP-NOW capabilities profile."
  @impl true
  def capabilities, do: @capabilities

  @doc "Assigns the owner; the port opens once wifi is also connected."
  @impl true
  def open(owner), do: cast({:open, owner})

  @doc "Drops the owner and every peer it added; the port stays open."
  @impl true
  def close, do: cast(:close)

  @impl true
  def send(addr, frame), do: cast({:send, addr, frame})

  @impl true
  def add_peer(addr), do: cast({:add_peer, addr})

  @impl true
  def del_peer(addr), do: cast({:del_peer, addr})

  @doc "The session the RX filter admits; nil while seeking."
  @impl true
  def session(session), do: cast({:session, session})

  @doc "Wifi association state; called from Badge.Wifi only."
  @spec wifi(connected :: boolean, ssid :: binary | nil) :: :ok
  def wifi(connected, ssid), do: cast({:wifi, connected, ssid})

  @doc "C4: same channel is compatible; a radio or wifi gap names itself."
  @impl true
  def compatible(_mine, %{present: false}), do: {:error, :other_no_radio}
  def compatible(_mine, %{available: false}), do: {:error, :other_no_wifi}
  def compatible(_mine, %{scope: nil}), do: {:error, :other_no_wifi}
  def compatible(%{channel: channel}, %{scope: %{channel: channel}}), do: :ok
  def compatible(%{net: net}, %{scope: %{net: net}}), do: {:error, :other_access_point}
  def compatible(_mine, _theirs), do: {:error, :different_network}

  @doc "Whether an inbound frame is for us; no decoding."
  @spec admit?(frame :: binary, listening :: :idle | {:open, Badge.GameLink.session() | nil}) ::
          boolean
  def admit?(_frame, :idle), do: false

  def admit?(<<0x1F, 0x01, kind, session::binary-size(2), _rest::binary>>, {:open, listening}) do
    cond do
      kind >= 0x02 and kind <= 0x04 -> true
      kind >= 0x05 and kind <= 0x0A -> listening != nil and session == listening
      true -> false
    end
  end

  def admit?(_frame, _listening), do: false

  @doc "The mailbox cap: past this, received frames are dropped unread."
  @spec flooded?(message_queue_len :: non_neg_integer) :: boolean
  def flooded?(message_queue_len), do: message_queue_len > @flood_limit

  @doc "net is the first two bytes of sha256(ssid); the ssid itself is kept for IR only."
  @spec scope(channel :: 0..14, ssid :: binary) :: Badge.GameLink.scope()
  def scope(channel, ssid) do
    <<net::binary-size(2), _rest::binary>> = :crypto.hash(:sha256, ssid)
    %{channel: channel, net: net, ssid: ssid}
  end

  @doc "Unwraps espnow:open/1's result once; anything unexpected is an error."
  @spec open_result(term) :: {:ok, term} | {:error, term}
  def open_result({:ok, port}), do: {:ok, port}
  def open_result({:error, reason}), do: {:error, reason}
  def open_result(other), do: {:error, other}

  @doc "Interprets a get_channel reply; anything but an integer means no radio."
  @spec channel_status(reply :: term, ssid :: binary) ::
          {:available, Badge.GameLink.scope()} | {:unavailable, :no_radio}
  def channel_status(reply, ssid) when is_integer(reply), do: {:available, scope(reply, ssid)}
  def channel_status(_reply, _ssid), do: {:unavailable, :no_radio}

  @doc "A port call that timed out is wedged; every other outcome leaves it as is."
  @spec next_port(port :: term, outcome :: term) :: term
  def next_port(_port, {:error, :timeout}), do: :dead
  def next_port(port, _outcome), do: port

  @doc "Stores the port a call left; one that just went :dead is reported to the owner."
  @spec put_port(state :: map, port :: term) :: map
  def put_port(%{port: :dead} = state, port), do: %{state | port: port}
  def put_port(state, :dead), do: report(%{state | port: :dead}, state.owner)
  def put_port(state, port), do: %{state | port: port}

  @doc "A non-binary ssid, whatever `connected` says, is not connected."
  @spec wifi_state(connected :: term, ssid :: term) :: {boolean, binary | nil}
  def wifi_state(true, ssid) when is_binary(ssid), do: {true, ssid}
  def wifi_state(_connected, _ssid), do: {false, nil}

  @doc "Records a peer only if add_peer succeeded, or the port isn't open yet."
  @spec record_peer?(port :: term, outcome :: term) :: boolean
  def record_peer?(nil, _outcome), do: true
  def record_peer?(_port, :ok), do: true
  def record_peer?(_port, _outcome), do: false

  @doc "Replays every recorded peer to a newly opened port."
  @spec replay_peers(port :: term, peers :: [Badge.GameLink.address()]) :: term
  def replay_peers(port, peers) do
    Enum.reduce(peers, port, fn addr, acc ->
      {port, _outcome} = call_add_peer(acc, addr)
      port
    end)
  end

  @impl true
  def init(:ok) do
    {:ok, %{owner: nil, port: nil, session: nil, wifi: false, ssid: nil, peers: [], status: nil}}
  end

  @impl true
  def handle_call(_request, _from, state), do: {:reply, {:error, :unknown_call}, state}

  @impl true
  def handle_cast({:open, owner}, state) do
    state = maybe_open(%{state | owner: owner, status: nil})
    {:noreply, report(state, owner)}
  end

  def handle_cast(:close, state) do
    port = Enum.reduce(state.peers, state.port, fn addr, acc -> call_del_peer(acc, addr) end)
    {:noreply, %{state | owner: nil, session: nil, peers: [], port: port, status: nil}}
  end

  def handle_cast({:send, addr, frame}, state) do
    {:message_queue_len, queued} = :erlang.process_info(self(), :message_queue_len)

    state =
      case flooded?(queued) do
        true -> state
        false -> put_port(state, call_send(state.port, wire_address(addr), frame))
      end

    {:noreply, state}
  end

  def handle_cast({peer_call, addr}, state)
      when (peer_call == :add_peer or peer_call == :del_peer) and
             (addr == @broadcast or addr == :broadcast),
      do: {:noreply, state}

  def handle_cast({:add_peer, addr}, state) do
    {port, outcome} = call_add_peer(state.port, addr)

    peers =
      case record_peer?(state.port, outcome) do
        true -> add(state.peers, addr)
        false -> state.peers
      end

    {:noreply, put_port(%{state | peers: peers}, port)}
  end

  def handle_cast({:del_peer, addr}, state) do
    port = call_del_peer(state.port, addr)
    {:noreply, put_port(%{state | peers: :lists.delete(addr, state.peers)}, port)}
  end

  def handle_cast({:session, session}, state), do: {:noreply, %{state | session: session}}

  def handle_cast({:wifi, connected, ssid}, state) do
    {wifi, ssid} = wifi_state(connected, ssid)
    state = maybe_open(%{state | wifi: wifi, ssid: ssid})
    {:noreply, report(state, state.owner)}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info({:espnow, :rx, mac, data}, state) do
    {:message_queue_len, queued} = :erlang.process_info(self(), :message_queue_len)

    case flooded?(queued) do
      true -> :ok
      false -> deliver(state, mac, data)
    end

    {:noreply, state}
  end

  def handle_info({:espnow, :tx, _to, _status}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp cast(message) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, message)
    end
  end

  defp deliver(%{owner: nil}, _mac, _data), do: :ok

  defp deliver(%{owner: owner, session: session}, mac, data) do
    case admit?(data, {:open, session}) do
      true -> Kernel.send(owner, {:gamelink_received, mac, data})
      false -> :ok
    end
  end

  defp wire_address(:broadcast), do: @broadcast
  defp wire_address(addr), do: addr

  defp add(peers, addr) do
    case :lists.member(addr, peers) do
      true -> peers
      false -> [addr | peers]
    end
  end

  # Fires once: the first moment an owner exists and wifi is connected.
  defp maybe_open(%{port: nil, owner: owner, wifi: true} = state) when owner != nil do
    case open_port() do
      {:ok, port} ->
        %{state | port: replay_peers(port, state.peers)}

      {:error, reason} ->
        :io.format(~c"GameLink: no radio: ~p~n", [reason])
        %{state | port: :dead}
    end
  end

  defp maybe_open(state), do: state

  defp open_port do
    fn -> :espnow.open([{:owner, self()}]) end
    |> safe_call()
    |> open_result()
  end

  defp report(state, nil), do: state

  defp report(state, owner) do
    {state, status} = resolve_status(state)

    if status != state.status do
      Kernel.send(owner, {:gamelink_status, status})
    end

    %{state | status: status}
  end

  defp resolve_status(%{port: :dead} = state), do: {state, {:unavailable, :no_radio}}
  defp resolve_status(%{wifi: false} = state), do: {state, {:unavailable, :no_wifi}}
  defp resolve_status(%{port: nil} = state), do: {state, {:unavailable, :no_radio}}

  defp resolve_status(%{port: port, ssid: ssid} = state) do
    {port, outcome} = call_get_channel(port)
    {%{state | port: port}, channel_status(outcome, ssid)}
  end

  defp call_send(nil, _addr, _frame), do: nil
  defp call_send(:dead, _addr, _frame), do: :dead

  defp call_send(port, addr, frame) do
    outcome = safe_call(fn -> :espnow.send(port, addr, frame) end)
    log_failure(:send, outcome)
    next_port(port, outcome)
  end

  defp call_add_peer(nil, _addr), do: {nil, :not_open}
  defp call_add_peer(:dead, _addr), do: {:dead, :not_open}

  defp call_add_peer(port, addr) do
    outcome = safe_call(fn -> :espnow.add_peer(port, addr, 0) end)
    log_failure(:add_peer, outcome)
    {next_port(port, outcome), outcome}
  end

  defp call_del_peer(nil, _addr), do: nil
  defp call_del_peer(:dead, _addr), do: :dead

  defp call_del_peer(port, addr) do
    outcome = safe_call(fn -> :espnow.del_peer(port, addr) end)
    log_failure(:del_peer, outcome)
    next_port(port, outcome)
  end

  defp call_get_channel(port) do
    outcome = safe_call(fn -> gen_call(port, {:get_channel}) end)
    log_failure(:get_channel, outcome)
    {next_port(port, outcome), outcome}
  end

  # Mirrors espnow.erl's gen_server_call/2, but with a 1-tuple request: the
  # driver only parses commands wrapped in a tuple, unlike espnow:get_channel/1.
  defp gen_call(port, request) do
    ref = make_ref()
    Kernel.send(port, {:"$gen_call", {self(), ref}, request})

    receive do
      {^ref, reply} -> reply
    after
      5000 -> {:error, :timeout}
    end
  end

  defp log_failure(fun, {:error, reason}) do
    :io.format(~c"GameLink: ~p failed ~p~n", [fun, reason])
  end

  defp log_failure(_fun, _ok), do: :ok

  defp safe_call(fun) do
    try do
      fun.()
    rescue
      error -> {:error, error}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end
end
