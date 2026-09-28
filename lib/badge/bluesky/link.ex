defmodule Badge.Bluesky.Link do
  @moduledoc """
  Holds an account's posts for the page, and refreshes them in the background.

  Page-scoped, like `Badge.Chat.Link`: `open/1` names the account while the
  page shows, `close/0` on the way out stops the refreshing. A ticker asks
  `Badge.Bluesky.Link.State` every few seconds whether a fetch is due: once
  the radio has an address and a clock, again once the held posts are old,
  and after a failure with a growing wait.

  The fetch runs in a spawned process, never here: `status/0` answers the
  render loop, and a TLS handshake behind it would stall the page. What is
  held and handed out is `Badge.Bluesky.pack/1`'s tuple, a binary per post,
  so neither this process nor the page keeps the posts live on its heap.
  """

  use GenServer

  alias Badge.Bluesky
  alias Badge.Bluesky.Link.State
  alias Badge.Nvs
  alias Badge.Page
  alias Badge.Wifi

  @tick 2_000

  def start_link(:ok), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Wants the feed of `actor`, fetching it if not already held."
  @spec open(binary) :: :ok
  def open(actor), do: GenServer.cast(__MODULE__, {:open, actor})

  @doc "Stops refreshing. The held posts stay until another account is wanted."
  @spec close() :: :ok
  def close, do: GenServer.cast(__MODULE__, :close)

  @doc "Drops a failure so the next tick fetches again."
  @spec retry() :: :ok
  def retry, do: GenServer.cast(__MODULE__, :retry)

  @doc "Where the fetch stands. Cheap: the posts are not in it."
  @spec status() :: map
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "The held posts, newest first."
  @spec posts() :: Bluesky.posts()
  def posts, do: GenServer.call(__MODULE__, :posts)

  @impl true
  def init(:ok) do
    # Resolved once: status/0 answers the render loop and must not read flash.
    start_ticker()

    {:ok, State.new(Bluesky.base_url(Nvs.get(:bsky_url)))}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, State.status(state), state}
  def handle_call(:posts, _from, state), do: {:reply, state.posts, state}

  @impl true
  def handle_cast({:open, actor}, state), do: {:noreply, State.open(state, actor)}
  def handle_cast(:close, state), do: {:noreply, State.close(state)}
  def handle_cast(:retry, state), do: {:noreply, State.retry(state)}

  @impl true
  def handle_info(:tick, %{want: false} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    case State.load(state, ready?(), :erlang.monotonic_time(:millisecond)) do
      {{:fetch, actor}, state} -> {:noreply, start_fetch(state, actor)}
      {:wait, state} -> {:noreply, state}
    end
  end

  def handle_info({:fetched, actor, result}, state) do
    report(actor, result)

    {:noreply, State.fetched(state, actor, result, :erlang.monotonic_time(:millisecond))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A certificate cannot be checked before the clock is right.
  defp ready? do
    case Wifi.status() do
      %{ip: ip, synced: true} when is_binary(ip) -> true
      _other -> false
    end
  end

  # The fetch has its own process, so a crash in it is a message here, not a restart.
  defp start_fetch(state, actor) do
    :io.format(~c"Bluesky: fetching ~s~n", [actor])

    link = self()
    base = state.base
    columns = Page.Bluesky.columns()

    spawn(fn -> send(link, {:fetched, actor, packed(Bluesky.fetch(base, actor, columns))}) end)

    state
  end

  # Packed where it was parsed, so the maps never reach this process.
  defp packed({:ok, posts}), do: {:ok, Bluesky.pack(posts)}
  defp packed(error), do: error

  defp report(actor, {:ok, posts}),
    do: :io.format(~c"Bluesky: holding ~p posts by ~s~n", [tuple_size(posts), actor])

  defp report(actor, {:error, reason}),
    do: :io.format(~c"Bluesky: fetch for ~s failed ~p~n", [actor, reason])

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
