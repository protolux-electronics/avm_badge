defmodule Badge.Bluesky.Link do
  @moduledoc """
  Holds an account's posts and saved feeds for the page, and refreshes them
  in the background.

  Page-scoped, like `Badge.Chat.Link`: `open/2` names the account and its
  app password while the page shows, `select/1` picks a saved feed, `close/0`
  on the way out stops the refreshing. A ticker asks
  `Badge.Bluesky.Link.State` every few seconds whether a fetch is due: once
  the radio has an address and a clock, again once the held posts are old,
  and after a failure with a growing wait.

  The fetch runs in a spawned process, never here: `status/0` answers the
  render loop, and a TLS handshake behind it would stall the page. What is
  held and handed out is `Badge.Bluesky.pack/1`'s tuple, a binary per entry,
  so neither this process nor the page keeps the posts live on its heap.
  """

  use GenServer

  alias Badge.Bluesky
  alias Badge.Bluesky.Account
  alias Badge.Bluesky.Link.State
  alias Badge.Nvs
  alias Badge.Page
  alias Badge.Wifi

  @tick 2_000

  def start_link(:ok), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Wants the feeds of `actor`, logged in with `password` unless it is nil."
  @spec open(binary, binary | nil) :: :ok
  def open(actor, password), do: GenServer.cast(__MODULE__, {:open, actor, password})

  @doc "Shows the saved feed with this key next."
  @spec select(Account.key()) :: :ok
  def select(key), do: GenServer.cast(__MODULE__, {:select, key})

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

  @doc "The held saved feeds, each packed as `Badge.Bluesky.Account.feed()`."
  @spec feeds() :: Bluesky.posts()
  def feeds, do: GenServer.call(__MODULE__, :feeds)

  @impl true
  def init(:ok) do
    # Resolved once: status/0 answers the render loop and must not read flash.
    start_ticker()

    {:ok, State.new(Bluesky.base_url(Nvs.get(:bsky_url)), pds(Nvs.get(:bsky_pds)))}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, State.status(state), state}
  def handle_call(:posts, _from, state), do: {:reply, state.posts, state}
  def handle_call(:feeds, _from, state), do: {:reply, state.feeds, state}

  @impl true
  def handle_cast({:open, actor, password}, state),
    do: {:noreply, State.open(state, actor, password)}

  def handle_cast({:select, key}, state), do: {:noreply, State.select(state, key)}
  def handle_cast(:close, state), do: {:noreply, State.close(state)}
  def handle_cast(:retry, state), do: {:noreply, State.retry(state)}

  @impl true
  def handle_info(:tick, %{want: false} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    case State.load(state, ready?(), :erlang.monotonic_time(:millisecond)) do
      {{:fetch, job}, state} -> {:noreply, start_fetch(state, job)}
      {:wait, state} -> {:noreply, state}
    end
  end

  def handle_info({:fetched, job, result}, state) do
    report(job, result)

    {:noreply, State.fetched(state, job, result, :erlang.monotonic_time(:millisecond))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp pds(nil), do: nil
  defp pds(""), do: nil
  defp pds(url), do: url

  # A certificate cannot be checked before the clock is right.
  defp ready? do
    case Wifi.status() do
      %{ip: ip, synced: true} when is_binary(ip) -> true
      _other -> false
    end
  end

  # The fetch has its own process, so a crash in it is a message here, not a restart.
  defp start_fetch(state, job) do
    :io.format(~c"Bluesky: fetching ~p for ~s~n", [job.feed, job.actor])

    link = self()
    base = state.base
    columns = Page.Bluesky.columns()

    spawn(fn -> send(link, {:fetched, job, Account.load(job, base, columns)}) end)

    state
  end

  defp report(job, {:ok, result}) do
    :io.format(~c"Bluesky: holding ~p posts of ~p~n", [tuple_size(result.posts), job.feed])
  end

  defp report(job, {:error, reason}),
    do: :io.format(~c"Bluesky: fetch of ~p failed ~p~n", [job.feed, reason])

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
