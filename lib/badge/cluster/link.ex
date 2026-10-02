defmodule Badge.Cluster.Link do
  @moduledoc """
  Erlang distribution over wifi, started from the Cluster app.

  Unlike the chat and update links this is not page-scoped: the point of
  clustering is to reach the badge from somewhere else, so once `open/0` has
  brought the node up it stays up after the page is left. `close/0` is the
  only way back down.

  The node is named for its own address, `badge@192.168.1.42`, because
  nothing resolves a badge by name. A lease that hands out a different
  address renames the node, so a host connected to the old name reconnects.

  Distribution cannot start before wifi has an address, so `open/0` only
  records the intent and a ticker does the work once `Badge.Wifi.status/0`
  reports one.

  Each badge has its own cookie, `goat-` and twelve random hex digits, made
  on first start and kept in the `dist_cookie` NVS key. A host reads it off
  the Cluster page.
  """

  use GenServer

  import Bitwise

  alias Badge.Nvs
  alias Badge.Wifi

  @compile {:no_warn_undefined, [:epmd, :net_kernel]}

  @prefix "goat-"
  @random_bytes 6

  @tick 1_000

  # More greetings than the panel can show is still worth keeping a little of.
  @keep 8

  def start_link(:ok), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Brings the node up, once wifi has an address."
  @spec open() :: :ok
  def open, do: GenServer.cast(__MODULE__, :open)

  @doc "Takes the node down, dropping every connected peer."
  @spec close() :: :ok
  def close, do: GenServer.cast(__MODULE__, :close)

  @doc """
  Stores the cookie, and applies it at once if the node is already up.

  An empty value is replaced by a fresh random cookie, so the badge never
  clusters on no secret, or on one every badge shares.
  """
  @spec set_cookie(binary) :: :ok
  def set_cookie(value), do: GenServer.cast(__MODULE__, {:cookie, value})

  @doc """
  Records a host that has reached the badge, for the page to show.

  AtomVM has no `:erlang.nodes/0` and `net_kernel` keeps its connection map
  to itself, so a badge cannot ask who is connected. A host says so instead,
  through `Badge.Cluster.Remote.hello/1`.
  """
  @spec greet(atom | binary) :: :ok
  def greet(peer), do: GenServer.cast(__MODULE__, {:greet, peer})

  @doc "Where the node is, and who is connected to it."
  @spec status() :: %{
          state: atom,
          node: binary | nil,
          cookie: binary,
          ip: binary | nil,
          peers: [binary],
          reason: binary | nil
        }
  def status, do: GenServer.call(__MODULE__, :status)

  # epmd is linked to this process, so without trapping exits its death would
  # take the page and `Badge.UI` with it rather than showing up as a failure.
  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)

    state = %{
      want: false,
      state: :off,
      node: nil,
      ip: nil,
      reason: nil,
      peers: [],
      cookie: provisioned(Nvs.get(:dist_cookie))
    }

    start_ticker()

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      state: state.state,
      node: state.node,
      cookie: state.cookie,
      ip: state.ip,
      peers: state.peers,
      reason: state.reason
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_cast(:open, %{want: true} = state), do: {:noreply, state}

  def handle_cast(:open, state) do
    {:noreply, start_node(%{state | want: true, state: :waiting, reason: nil})}
  end

  def handle_cast(:close, %{want: false} = state), do: {:noreply, state}

  def handle_cast(:close, state), do: {:noreply, %{stop_node(state) | want: false}}

  def handle_cast({:cookie, value}, state) do
    cookie = cookie(value, fresh())
    Nvs.put(:dist_cookie, cookie)

    # A running node takes it now; connections already made keep the old one.
    case state.state do
      :up -> :net_kernel.set_cookie(cookie)
      _down -> :ok
    end

    :io.format(~c"Cluster: cookie set~n")

    {:noreply, %{state | cookie: cookie}}
  end

  def handle_cast({:greet, peer}, state) do
    name = describe(peer)

    :io.format(~c"Cluster: ~s said hello~n", [name])

    {:noreply, %{state | peers: remember(name, state.peers)}}
  end

  @impl true
  def handle_info(:tick, %{want: true, state: name} = state) when name != :up do
    {:noreply, start_node(state)}
  end

  # The address can change under a running node, which renames it.
  def handle_info(:tick, %{want: true} = state) do
    case Wifi.status() do
      %{ip: ip} when ip != nil and ip != state.ip -> {:noreply, rename(state)}
      _held -> {:noreply, state}
    end
  end

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  # Whatever died took distribution with it; the ticker builds it again.
  def handle_info({:EXIT, pid, reason}, state) do
    :io.format(~c"Cluster: ~p exited ~p~n", [pid, reason])

    {:noreply, %{state | state: :failed, node: nil, reason: describe(reason), peers: []}}
  end

  def handle_info(message, state) do
    :io.format(~c"Cluster: unhandled ~p~n", [message])

    {:noreply, state}
  end

  @doc "What keeps the node from starting, given `Badge.Wifi.status/0`, or `nil`."
  @spec blocker(map) :: binary | nil
  def blocker(%{radio: :connected, ip: ip}) when is_binary(ip), do: nil
  def blocker(%{radio: :connected}), do: "waiting for an address"
  def blocker(%{radio: :connecting}), do: "wifi connecting"
  def blocker(%{radio: :failed}), do: "wifi failed"
  def blocker(_wifi), do: "wifi off"

  @doc "The long node name a badge at `ip` answers to."
  @spec node_name(binary) :: atom
  def node_name(ip), do: :erlang.binary_to_atom(<<"badge@", ip::binary>>, :latin1)

  defp rename(state), do: start_node(stop_node(state))

  defp start_node(state) do
    wifi = Wifi.status()

    case blocker(wifi) do
      nil -> up(state, wifi.ip)
      reason -> %{state | state: :waiting, reason: reason}
    end
  end

  # Both listeners are local, so neither call is worth moving off this process.
  defp up(state, ip) do
    node = node_name(ip)

    case ensure_epmd() do
      :ok -> started(:net_kernel.start(node, %{name_domain: :longnames}), node, ip, state)
      {:error, reason} -> failed(state, reason)
    end
  end

  defp started({:ok, _pid}, node, ip, state), do: named(node, ip, state)
  defp started({:error, {:already_started, _pid}}, node, ip, state), do: named(node, ip, state)
  defp started({:error, reason}, _node, _ip, state), do: failed(state, reason)

  defp named(node, ip, state) do
    :net_kernel.set_cookie(state.cookie)

    :io.format(~c"Cluster: node ~p up~n", [node])

    %{state | state: :up, node: :erlang.atom_to_binary(node, :latin1), ip: ip, reason: nil}
  end

  defp stop_node(state) do
    case state.node do
      nil -> :ok
      name -> :io.format(~c"Cluster: node ~s down~n", [name])
    end

    stop_kernel()

    %{state | state: :off, node: nil, ip: nil, reason: nil, peers: []}
  end

  # Stopping a kernel that never started answers an error rather than :ok.
  defp stop_kernel do
    :net_kernel.stop()
  catch
    _kind, _reason -> :ok
  end

  # epmd outlives a node that stops and starts again, so a second start is not a failure.
  defp ensure_epmd do
    case :epmd.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    _kind, reason -> {:error, reason}
  end

  @doc "A greeting added to the front of the list it is remembered in, without repeats."
  @spec remember(binary, [binary]) :: [binary]
  def remember(name, peers) do
    kept = :lists.filter(fn seen -> seen != name end, peers)

    :lists.sublist([name | kept], @keep)
  end

  defp failed(state, reason) do
    :io.format(~c"Cluster: could not start ~p~n", [reason])

    %{state | state: :failed, reason: describe(reason)}
  end

  defp describe(term) when is_binary(term), do: term
  defp describe(term) when is_atom(term), do: :erlang.atom_to_binary(term, :latin1)
  defp describe(term), do: :erlang.iolist_to_binary(:io_lib.format(~c"~p", [term]))

  @doc "The cookie to use: `stored` unless it is absent or empty, else `fresh`."
  @spec cookie(binary | nil, binary) :: binary
  def cookie(stored, _fresh) when is_binary(stored) and stored != "", do: stored
  def cookie(_absent, fresh), do: fresh

  @doc "A cookie from six random bytes: `goat-` and their twelve hex digits."
  @spec random_cookie(<<_::48>>) :: binary
  def random_cookie(<<_::48>> = bytes) do
    digits = :lists.flatmap(&[hex(&1 >>> 4), hex(&1 &&& 15)], :erlang.binary_to_list(bytes))

    @prefix <> :erlang.list_to_binary(digits)
  end

  defp hex(n) when n < 10, do: ?0 + n
  defp hex(n), do: ?a + n - 10

  defp fresh, do: random_cookie(:crypto.strong_rand_bytes(@random_bytes))

  # A badge that has never had a cookie makes one, and keeps it.
  defp provisioned(stored) do
    case cookie(stored, nil) do
      nil ->
        made = fresh()
        Nvs.put(:dist_cookie, made)
        made

      cookie ->
        cookie
    end
  end

  defp start_ticker do
    link = self()

    spawn_link(fn -> tick_loop(link) end)
  end

  defp tick_loop(link) do
    Process.sleep(@tick)
    send(link, :tick)
    tick_loop(link)
  end
end
