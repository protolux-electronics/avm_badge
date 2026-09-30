defmodule Badge.GameLink do
  @moduledoc """
  Short-range multiplayer sessions for app pages.

  Call `open/3` from a page, then `send/3`, `lock/0` and `close/0`; events
  arrive through `Badge.Page.handle_link/2`. Only `Badge.UI` calls
  `release/0` and `taken/0`.
  """

  use GenServer

  import Kernel, except: [send: 2]

  alias Badge.GameLink.State
  alias Badge.GameLink.Wire

  @type slot :: 0..7
  @type address :: binary
  @type chip_reference :: <<_::48>>
  @type session :: <<_::16>>
  @type token :: <<_::32>>
  @type scope :: %{
          required(:channel) => 0..14,
          required(:net) => <<_::16>>,
          optional(:ssid) => binary
        }
  @type mode :: :latest | :reliable
  @type reason ::
          :no_radio
          | :other_no_radio
          | :no_wifi
          | :other_no_wifi
          | :different_network
          | {:no_wifi | :different_network, ssid :: binary}
          | :other_access_point
          | :unreachable
          | :searching
          | :full
          | :started
          | :update_needed
  @type event ::
          {:waiting, reason}
          | {:session, me :: slot, members :: [{slot, name :: binary}]}
          | {:joined, slot, name :: binary}
          | {:left, slot, :bye | :timeout}
          | {:message, from :: slot, payload :: binary}
          | {:overflow, slot}
          | {:closed, :host_left | :reset}
  @type offer :: %{
          version: pos_integer,
          app: binary | nil,
          session: session | nil,
          token: token | nil,
          transport: :espnow | {:other, byte} | nil,
          scope: scope | nil,
          host_reference: chip_reference,
          host_addr: address | nil,
          available: boolean,
          present: boolean,
          admitting: boolean
        }

  @transport if Mix.target() == :badge,
               do: Badge.GameLink.Radio,
               else: Badge.Sim.GameLink.Loopback
  @join if Mix.target() == :badge,
          do: Badge.GameLink.Join.Ir,
          else: Badge.Sim.GameLink.Loopback

  @compile {:no_warn_undefined, Badge.Sim.GameLink.Loopback}

  @max_app_bytes 15
  @unnamed "Badge"

  @doc "Starts the link; the `Badge` supervisor does this at boot."
  @spec start_link(:ok) :: GenServer.on_start()
  def start_link(:ok), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Opens a session for `app_id` (at most 15 bytes) with 2 to 8 players.

  Call from a page. `opts` takes `needs: [:low_latency]`.
  """
  @spec open(binary, 2..8, keyword) :: :ok
  def open(app_id, max_players, opts \\ [])

  def open(app_id, max_players, opts)
      when is_binary(app_id) and byte_size(app_id) <= @max_app_bytes and
             is_integer(max_players) and max_players >= 2 and max_players <= 8 do
    case :erlang.whereis(__MODULE__) do
      :undefined ->
        :ok

      _pid ->
        needs = :proplists.get_value(:needs, opts, [])
        name = player_name(Badge.Profile.load())
        GenServer.cast(__MODULE__, {:open, app_id, max_players, needs, generation(), name})
    end
  end

  def open(_app_id, _max_players, _opts) do
    raise ArgumentError, "GameLink.open: app id over 15 bytes or players outside 2..8"
  end

  @doc "Sends a payload (at most 200 bytes, byte 0 is the message type) to a slot or `:all`."
  @spec send(slot | :all, binary, mode) :: :ok
  def send(to, payload, mode \\ :latest) do
    if sendable?(to, payload, mode),
      do: cast({:send, to, payload, mode}),
      else: raise(ArgumentError, "GameLink.send: bad slot, payload or mode")
  end

  @doc "Stops admitting new players; host only."
  @spec lock() :: :ok
  def lock, do: cast(:lock)

  @doc "Leaves the session; the host's close ends it for everyone."
  @spec close() :: :ok
  def close, do: cast(:close)

  @doc false
  @spec release() :: :ok
  def release, do: cast(:release)

  @doc false
  @spec taken() :: :ok
  def taken, do: cast(:link_taken)

  @doc false
  @spec descriptor() :: map | nil
  def descriptor do
    case :erlang.whereis(__MODULE__) do
      :undefined -> nil
      _pid -> GenServer.call(__MODULE__, :descriptor)
    end
  end

  @doc "The largest app payload a frame carries."
  @spec max_payload() :: 200
  def max_payload, do: Wire.max_payload()

  @doc """
  The text an app shows for a waiting reason, at most 36 characters of code
  page 437; an unknown one gives the generic wait.
  """
  @spec hint(reason | term) :: binary
  def hint({reason, ssid}) when reason == :no_wifi or reason == :different_network do
    name = Badge.Text.cp437(ssid)
    "Join " <> :binary.part(name, 0, min(byte_size(name), 23)) <> " to play"
  end

  def hint(:no_radio), do: "This badge needs a firmware update"
  def hint(:other_no_radio), do: "Other badge needs a firmware update"
  def hint(:no_wifi), do: "Join wifi to play"
  def hint(:other_no_wifi), do: "Other badge has no wifi"
  def hint(:different_network), do: "Join the same wifi to play"
  def hint(:other_access_point), do: "Same wifi, other access point"
  def hint(:unreachable), do: "Waiting for the other badges"
  def hint(:full), do: "Game is full"
  def hint(:started), do: "Game already started"
  def hint(:update_needed), do: "One badge needs a firmware update"
  def hint(_other), do: "Waiting for the other badges"

  @doc false
  @spec player_name(map) :: binary
  def player_name(profile) do
    case Wire.clamp_name(Map.get(profile, :name, "")) do
      "" -> @unnamed
      name -> name
    end
  end

  @doc false
  @spec sleeper(pid) :: :ok
  def sleeper(parent) do
    Process.sleep(50)
    Kernel.send(parent, :tick)

    receive do
      :ticked -> sleeper(parent)
      :stop -> :ok
    end
  end

  defp sendable?(to, payload, mode) do
    is_binary(payload) and (mode == :latest or mode == :reliable) and
      (to == :all or (is_integer(to) and to >= 0 and to <= 7))
  end

  defp cast(message) do
    case :erlang.whereis(__MODULE__) do
      :undefined -> :ok
      _pid -> GenServer.cast(__MODULE__, message)
    end
  end

  defp generation do
    case :erlang.get(:game_link_generation) do
      :undefined -> 0
      generation -> generation
    end
  end

  @impl true
  def init(:ok) do
    state =
      State.new(%{
        reference: Badge.Identity.chip_id(),
        capabilities: @transport.capabilities(),
        random: &:crypto.strong_rand_bytes/1,
        transport: @transport
      })

    to_ui({:game_link, :reset})
    {:ok, %{state: state, sleeper: nil, generation: 0, ui: nil}}
  end

  @impl true
  def handle_call(:descriptor, _from, shell),
    do: {:reply, State.descriptor(shell.state), shell}

  @impl true
  def handle_cast({:open, app_id, max_players, needs, generation, name}, shell) do
    input = {:open, app_id, max_players, needs, name}
    {:noreply, step(%{shell | generation: generation}, input)}
  end

  def handle_cast({:send, to, payload, mode}, shell) do
    if sendable?(to, payload, mode),
      do: {:noreply, step(shell, {:send, to, payload, mode})},
      else: {:noreply, shell}
  end

  def handle_cast(:lock, shell), do: {:noreply, step(shell, :lock)}
  def handle_cast(:close, shell), do: {:noreply, step(shell, :close)}
  def handle_cast(:release, shell), do: {:noreply, step(shell, :release)}
  def handle_cast(:link_taken, shell), do: {:noreply, step(shell, :link_taken)}
  def handle_cast(_other, shell), do: {:noreply, shell}

  @impl true
  def handle_info({:gamelink_received, address, frame}, shell) do
    case Wire.decode(frame) do
      {:ok, message} -> {:noreply, step(shell, {:received, address, message})}
      _dropped -> {:noreply, shell}
    end
  end

  def handle_info({:gamelink_status, status}, shell),
    do: {:noreply, step(shell, {:status, status})}

  def handle_info({:gamelink_offer, offer}, shell),
    do: {:noreply, step(shell, {:offer, offer})}

  def handle_info({:DOWN, reference, :process, _pid, _reason}, %{ui: {_ui, reference}} = shell),
    do: {:noreply, step(%{shell | ui: nil}, :release)}

  def handle_info(:tick, %{sleeper: sleeper} = shell) when is_pid(sleeper) do
    shell = run(shell, :tick)

    if State.idle?(shell.state) do
      Kernel.send(sleeper, :stop)
      {:noreply, %{shell | sleeper: nil}}
    else
      Kernel.send(sleeper, :ticked)
      {:noreply, shell}
    end
  end

  def handle_info(_other, shell), do: {:noreply, shell}

  # Every input but :tick; starts the sleeper when the state left idle.
  defp step(shell, input), do: wake(run(shell, input))

  defp run(shell, input) do
    {state, actions} = State.handle(shell.state, input)
    shell = %{shell | state: state}
    :lists.foldl(fn action, acc -> perform(action, acc) end, shell, actions)
  end

  defp wake(%{sleeper: nil} = shell) do
    if State.idle?(shell.state) do
      shell
    else
      parent = self()
      %{shell | sleeper: spawn_link(fn -> sleeper(parent) end)}
    end
  end

  defp wake(shell), do: shell

  defp perform({:transmit, to, message}, shell) do
    @transport.send(to, Wire.encode(message))
    shell
  end

  defp perform({:add_peer, address}, shell) do
    @transport.add_peer(address)
    shell
  end

  defp perform({:del_peer, address}, shell) do
    @transport.del_peer(address)
    shell
  end

  defp perform({:transport_session, session}, shell) do
    @transport.session(session)
    shell
  end

  defp perform(:transport_open, shell) do
    @transport.open(self())
    shell
  end

  defp perform(:transport_close, shell) do
    @transport.close()
    shell
  end

  defp perform({:advertise, offer}, shell) do
    @join.advertise(offer)
    shell
  end

  defp perform({:join_start, app_id}, shell) do
    @join.start(self(), app_id)
    shell
  end

  defp perform(:join_stop, shell) do
    @join.stop()
    shell
  end

  defp perform({:deliver, events}, shell) do
    case :erlang.whereis(Badge.UI) do
      :undefined ->
        shell

      pid ->
        Kernel.send(pid, {:game_link, shell.generation, events})
        watch(shell, pid)
    end
  end

  defp perform({:log, line}, shell) do
    :io.format(~c"GameLink: ~s~n", [line])
    shell
  end

  defp watch(%{ui: {pid, _reference}} = shell, pid), do: shell

  defp watch(shell, pid) do
    case shell.ui do
      {_old, reference} -> Process.demonitor(reference, [:flush])
      nil -> true
    end

    %{shell | ui: {pid, Process.monitor(pid)}}
  end

  defp to_ui(message) do
    case :erlang.whereis(Badge.UI) do
      :undefined -> :ok
      pid -> Kernel.send(pid, message)
    end
  end
end
