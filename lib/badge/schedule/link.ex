defmodule Badge.Schedule.Link do
  @moduledoc """
  Fetches the programme in the background and holds it for the page.

  A ticker asks `Badge.Schedule.Link.State` every few seconds whether a
  fetch is due: once the clock is set after boot, again once the held copy
  is old, and after a failure with a growing wait. No page has to be open
  for any of that, so the schedule is normally in hand before it is asked
  for.

  The fetch runs in a spawned process, never here: `status/0` answers the
  render loop, and a TLS handshake behind it would stall the page. What the
  process brings back is kept as it will be drawn.

  A fetch waits for the clock: certificates cannot be checked at the epoch.
  """

  use GenServer

  alias Badge.Schedule
  alias Badge.Schedule.Link.State

  @tick 5_000

  def start_link(:ok), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Drops a failure so the next tick fetches again."
  @spec retry() :: :ok
  def retry, do: GenServer.cast(__MODULE__, :retry)

  @doc "Where the fetch stands. Cheap: the sessions are not in it."
  @spec status() :: map
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "The held programme, in timeline order."
  @spec sessions() :: [Schedule.session()]
  def sessions, do: GenServer.call(__MODULE__, :sessions)

  @impl true
  def init(:ok) do
    start_ticker()

    {:ok, State.new()}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, State.status(state), state}
  def handle_call(:sessions, _from, state), do: {:reply, state.sessions, state}

  @impl true
  def handle_cast(:retry, state), do: {:noreply, State.retry(state)}

  @impl true
  def handle_info(:tick, state) do
    clock = Schedule.clock_set?(:erlang.system_time(:second))

    case State.load(state, clock, :erlang.monotonic_time(:millisecond)) do
      {:fetch, state} -> {:noreply, start_fetch(state)}
      {:wait, state} -> {:noreply, state}
    end
  end

  def handle_info({:fetched, result}, state) do
    report(result)

    {:noreply, State.fetched(state, result, :erlang.monotonic_time(:millisecond))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The fetch has its own process, so a crash in it is a message here, not a restart.
  defp start_fetch(state) do
    :io.format(~c"Schedule: fetching~n")

    link = self()

    spawn(fn -> send(link, {:fetched, Schedule.fetch()}) end)

    state
  end

  defp report({:ok, sessions}),
    do: :io.format(~c"Schedule: holding ~p sessions~n", [length(sessions)])

  defp report({:error, reason}), do: :io.format(~c"Schedule: fetch failed ~p~n", [reason])

  # Waits in a linked process, so this GenServer never sleeps in a callback.
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
