defmodule Badge.Bluesky.Link.State do
  @moduledoc """
  What the link knows, as plain data.

  No socket, no radio and no clock: `Badge.Bluesky.Link` owns those and calls
  in here on every tick, which keeps wanting, freshness, retrying and the
  held posts testable on the host.

  The feed is wanted only while the page shows and names an account. A
  different account drops what was held, so a handle changed on the Name
  page never shows the old owner's posts. Held posts outlive a failed
  refresh, so a badge that fetched once keeps showing them.
  """

  # How old held posts may be before they are fetched again.
  @stale 5 * 60_000

  # How long the first failure stands; each one after doubles it, to a cap.
  @retry 30_000
  @max_retry 10 * 60_000

  @doc "A link that wants nothing and holds nothing."
  @spec new(binary) :: map
  def new(base) do
    %{
      base: base,
      actor: nil,
      want: false,
      state: :idle,
      posts: {},
      reason: nil,
      version: 0,
      at: nil,
      failures: 0
    }
  end

  @doc "What a page reads each tick. `count` is how many posts `posts/0` holds."
  @spec status(map) :: map
  def status(state) do
    %{
      state: state.state,
      actor: state.actor,
      reason: state.reason,
      version: state.version,
      count: tuple_size(state.posts)
    }
  end

  @doc "The page shows and names an account. Another account starts over."
  @spec open(map, binary) :: map
  def open(%{actor: actor} = state, actor), do: %{state | want: true}

  def open(state, actor) do
    %{
      state
      | actor: actor,
        want: true,
        state: :idle,
        posts: {},
        reason: nil,
        version: state.version + 1,
        at: nil,
        failures: 0
    }
  end

  @doc "The page went away. Nothing is fetched until it is back."
  @spec close(map) :: map
  def close(state), do: %{state | want: false}

  @doc """
  A tick, given whether the network is ready and the time in milliseconds.

  `{:fetch, actor}` means the caller should start one for that account;
  `:wait` means there is nothing to do yet, or posts fresh enough on hand.
  """
  @spec load(map, boolean, integer) :: {{:fetch, binary} | :wait, map}
  def load(%{want: false} = state, _ready, _now), do: {:wait, state}
  def load(%{actor: nil} = state, _ready, _now), do: {:wait, state}
  def load(%{state: :loading} = state, _ready, _now), do: {:wait, state}

  def load(%{state: :failed} = state, ready, now) do
    case now - state.at < backoff(state.failures) do
      true -> {:wait, state}
      false -> attempt(state, ready)
    end
  end

  def load(%{state: :ready, at: at} = state, _ready, now) when now - at < @stale,
    do: {:wait, state}

  def load(state, ready, _now), do: attempt(state, ready)

  # Not ready, and posts on hand beat a waiting screen while the radio settles.
  defp attempt(%{state: :ready} = state, false), do: {:wait, state}
  defp attempt(state, false), do: {:wait, %{state | state: :waiting}}
  defp attempt(state, true), do: {{:fetch, state.actor}, %{state | state: :loading}}

  defp backoff(failures), do: min(@retry * doubled(failures - 1), @max_retry)

  defp doubled(0), do: 1
  defp doubled(n), do: 2 * doubled(n - 1)

  @doc """
  Takes what a fetch process brought back for `actor`.

  An answer for an account no longer wanted is dropped, so a slow fetch
  cannot overwrite the account the page moved on to.
  """
  @spec fetched(map, binary, {:ok, tuple} | {:error, term}, integer) :: map
  def fetched(%{actor: actor} = state, actor, {:ok, posts}, now) do
    %{
      state
      | state: :ready,
        posts: posts,
        reason: nil,
        version: state.version + 1,
        at: now,
        failures: 0
    }
  end

  def fetched(%{actor: actor} = state, actor, {:error, reason}, now) do
    %{state | state: :failed, reason: reason, at: now, failures: state.failures + 1}
  end

  def fetched(state, _other, _result, _now), do: state

  @doc "Clears a failure so the next tick fetches at once."
  @spec retry(map) :: map
  def retry(%{state: :failed} = state), do: %{state | state: :idle, failures: 0}
  def retry(state), do: state
end
