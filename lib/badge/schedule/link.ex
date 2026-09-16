defmodule Badge.Schedule.Link do
  @moduledoc """
  Holds the programme once it has been fetched, and fetches it when asked.

  The fetch runs in a spawned process, never here: `status/0` answers the
  render loop, and a TLS handshake behind it would stall the page. What the
  process brings back is kept, so the page opens instantly the next time and
  a fresh copy is only fetched once the held one is old.

  A fetch waits for the clock: certificates cannot be checked at the epoch.
  """

  use GenServer

  alias Badge.Schedule
  alias Badge.Schedule.Link.State

  def start_link(:ok), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Fetches the programme unless one is held and fresh, or a fetch is under way."
  @spec load() :: :ok
  def load, do: GenServer.cast(__MODULE__, :load)

  @doc "Drops a failure so the next `load/0` tries again."
  @spec retry() :: :ok
  def retry, do: GenServer.cast(__MODULE__, :retry)

  @doc "Where the fetch stands. Cheap: the sessions are not in it."
  @spec status() :: map
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "The held programme, in timeline order."
  @spec sessions() :: [Schedule.session()]
  def sessions, do: GenServer.call(__MODULE__, :sessions)

  @impl true
  def init(:ok), do: {:ok, State.new()}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, State.status(state), state}
  def handle_call(:sessions, _from, state), do: {:reply, state.sessions, state}

  @impl true
  def handle_cast(:load, state) do
    clock = Schedule.clock_set?(:erlang.system_time(:second))

    case State.load(state, clock, :erlang.monotonic_time(:millisecond)) do
      {:fetch, state} -> {:noreply, start_fetch(state)}
      {:wait, state} -> {:noreply, state}
    end
  end

  def handle_cast(:retry, state), do: {:noreply, State.retry(state)}

  @impl true
  def handle_info({:fetched, result}, state) do
    {:noreply, State.fetched(state, result, :erlang.monotonic_time(:millisecond))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The fetch has its own process, so a crash in it is a message here, not a restart.
  defp start_fetch(state) do
    link = self()

    spawn(fn -> send(link, {:fetched, Schedule.fetch()}) end)

    state
  end
end
