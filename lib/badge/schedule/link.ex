defmodule Badge.Schedule.Link do
  @moduledoc """
  Holds the programme for the page, and refreshes it in the background.

  A copy of the programme is compiled in: `assets/schedule.json` is parsed on
  the host into the lines the panel draws and packed into this module, so the
  page has it the moment the badge boots and nothing is parsed on the device.
  `mix badge.schedule` refreshes that file from the site.

  What is held and handed out are `Badge.Schedule.pack/1` entries, a binary
  per session, so neither this process nor the page keeps eighty maps live
  on its heap.

  With `@fetch` on, a ticker also asks `Badge.Schedule.Link.State` every few
  seconds whether a fetch is due: once the clock is set after boot, again
  once the held copy is old, and after a failure with a growing wait. The
  fetch runs in a spawned process, never here: `status/0` answers the render
  loop, and a TLS handshake behind it would stall the page.

  It is off: this VM's `ssl` does not survive the handshake to goatmire.com,
  panicking with peer verification and spinning without it.
  """

  use GenServer

  alias Badge.Page
  alias Badge.Schedule
  alias Badge.Schedule.Link.State

  @fetch false
  @tick 5_000

  @source Path.expand("../../../assets/schedule.json", __DIR__)
  @external_resource @source

  # One binary rather than a literal list: eighty tuples would strain
  # AtomVM's literals table, a single binary does not.
  @packed (case Schedule.parse(File.read!(@source), Page.Schedule.columns()) do
             {:ok, sessions} -> :erlang.term_to_binary(Schedule.pack(sessions))
             :error -> raise "assets/schedule.json is not a programme"
           end)

  def start_link(:ok), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "The programme compiled into this firmware, as entries in timeline order."
  @spec built_in() :: [Schedule.entry()]
  def built_in, do: :erlang.binary_to_term(@packed)

  @doc "Whether the badge refreshes the programme from the site by itself."
  @spec fetching?() :: boolean
  def fetching?, do: @fetch

  @doc "Drops a failure so the next tick fetches again."
  @spec retry() :: :ok
  def retry, do: GenServer.cast(__MODULE__, :retry)

  @doc "Where the fetch stands. Cheap: the entries are not in it."
  @spec status() :: map
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "The held programme, as entries in timeline order."
  @spec entries() :: [Schedule.entry()]
  def entries, do: GenServer.call(__MODULE__, :entries)

  @impl true
  def init(:ok) do
    if @fetch, do: start_ticker()

    {:ok, State.new(built_in())}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, State.status(state), state}
  def handle_call(:entries, _from, state), do: {:reply, state.sessions, state}

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

    spawn(fn -> send(link, {:fetched, packed(Schedule.fetch(Page.Schedule.columns()))}) end)

    state
  end

  # Packed where it was parsed, so the maps never reach this process.
  defp packed({:ok, sessions}), do: {:ok, Schedule.pack(sessions)}
  defp packed(error), do: error

  defp report({:ok, entries}),
    do: :io.format(~c"Schedule: holding ~p sessions~n", [length(entries)])

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
