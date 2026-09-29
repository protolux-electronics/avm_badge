defmodule Badge.Bluesky.Link.State do
  @moduledoc """
  What the link knows, as plain data.

  No socket, no radio and no clock: `Badge.Bluesky.Link` owns those and calls
  in here on every tick, which keeps wanting, freshness, retrying and the
  held posts testable on the host.

  The feed is wanted only while the page shows and names an account. With no
  password the posts are the account's own, read in public. With one, a
  fetch logs in if no session is held, reads the saved feeds once, and reads
  the selected feed, Following until another is chosen. A failure drops the
  session, so the next attempt logs in afresh.

  A different account or password drops everything held, so a handle changed
  on the Name page never shows the old owner's posts. Held posts outlive a
  failed refresh, so a badge that fetched once keeps showing them.

  `pds` is the account's PDS when it is provisioned; nil lets the login try
  `Badge.Bluesky.Account.default_pds/0` and look it up from there.
  """

  # How old held posts may be before they are fetched again.
  @stale 5 * 60_000

  # How long the first failure stands; each one after doubles it, to a cap.
  @retry 30_000
  @max_retry 10 * 60_000

  @doc "A link that wants nothing and holds nothing."
  @spec new(binary, binary | nil) :: map
  def new(base, pds \\ nil) do
    %{
      base: base,
      pds: pds,
      actor: nil,
      password: nil,
      want: false,
      state: :idle,
      session: nil,
      feed: nil,
      posts: {},
      feeds: {},
      reason: nil,
      version: 0,
      at: nil,
      failures: 0
    }
  end

  @doc """
  What a page reads each tick. `count` is how many posts `posts/0` holds,
  `feed` the key of the feed they came from, and `account` whether a password
  was given, so the saved feeds can be.
  """
  @spec status(map) :: map
  def status(state) do
    %{
      state: state.state,
      actor: state.actor,
      account: state.password != nil,
      feed: shown(state),
      reason: state.reason,
      version: state.version,
      count: tuple_size(state.posts)
    }
  end

  @doc "The key of the feed shown: the one chosen, else Following, else the account's own."
  @spec shown(map) :: tuple | nil
  def shown(%{actor: nil}), do: nil
  def shown(%{feed: nil, password: nil, actor: actor}), do: {:author, actor}
  def shown(%{feed: nil}), do: {:timeline, nil}
  def shown(%{feed: feed}), do: feed

  @doc "The page shows and names an account and its password, or nil. Another starts over."
  @spec open(map, binary, binary | nil) :: map
  def open(%{actor: actor, password: password} = state, actor, password),
    do: %{state | want: true}

  def open(state, actor, password) do
    %{
      state
      | actor: actor,
        password: password,
        want: true,
        state: :idle,
        session: nil,
        feed: nil,
        posts: {},
        feeds: {},
        reason: nil,
        version: state.version + 1,
        at: nil,
        failures: 0
    }
  end

  @doc "Another feed is chosen. Its posts are fetched on the next tick; the old ones go."
  @spec select(map, tuple) :: map
  def select(state, key) do
    case shown(state) == key do
      true ->
        state

      false ->
        %{
          state
          | feed: key,
            state: settled(state.state),
            posts: {},
            reason: nil,
            version: state.version + 1,
            at: nil,
            failures: 0
        }
    end
  end

  # One fetch at a time: one under way finishes, and its answer asks again.
  defp settled(:loading), do: :loading
  defp settled(_state), do: :idle

  @doc "The page went away. Nothing is fetched until it is back."
  @spec close(map) :: map
  def close(state), do: %{state | want: false}

  @doc """
  A tick, given whether the network is ready and the time in milliseconds.

  `{:fetch, job}` means the caller should start one, as
  `Badge.Bluesky.Account.load/3` takes it; `:wait` means there is nothing to
  do yet, or posts fresh enough on hand.
  """
  @spec load(map, boolean, integer) :: {{:fetch, map} | :wait, map}
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
  defp attempt(state, true), do: {{:fetch, job(state)}, %{state | state: :loading}}

  @doc "What a fetch for the current want is asked to do."
  @spec job(map) :: map
  def job(state) do
    %{
      actor: state.actor,
      password: state.password,
      session: state.session,
      pds: state.pds,
      feed: shown(state),
      feeds: state.password != nil and state.feeds == {}
    }
  end

  defp backoff(failures), do: min(@retry * doubled(failures - 1), @max_retry)

  defp doubled(0), do: 1
  defp doubled(n), do: 2 * doubled(n - 1)

  @doc """
  Takes what a fetch process brought back for `job`.

  An answer for an account or password no longer wanted is dropped. One for
  a feed no longer shown keeps only its session and saved feeds, so a slow
  fetch cannot overwrite the feed the page moved on to.
  """
  @spec fetched(map, map, {:ok, map} | {:error, term}, integer) :: map
  def fetched(
        %{actor: actor, password: password} = state,
        %{actor: actor, password: password} = job,
        result,
        now
      ) do
    case job.feed == shown(state) do
      true -> apply_result(state, result, now)
      false -> keep_login(state, result)
    end
  end

  def fetched(state, _job, _result, _now), do: state

  defp apply_result(state, {:ok, result}, now) do
    %{
      state
      | state: :ready,
        session: result.session,
        posts: result.posts,
        feeds: feeds(result.feeds, state.feeds),
        reason: nil,
        version: state.version + 1,
        at: now,
        failures: 0
    }
  end

  defp apply_result(state, {:error, reason}, now) do
    %{state | state: :failed, session: nil, reason: reason, at: now, failures: state.failures + 1}
  end

  # The fetch still counts as under way for the feed now shown, which asks again.
  defp keep_login(state, {:ok, result}) do
    %{
      state
      | state: :idle,
        session: result.session,
        feeds: feeds(result.feeds, state.feeds),
        version: state.version + 1
    }
  end

  defp keep_login(state, {:error, _reason}), do: %{state | state: :idle, session: nil}

  defp feeds(nil, held), do: held
  defp feeds(fresh, _held), do: fresh

  @doc "Clears a failure so the next tick fetches at once."
  @spec retry(map) :: map
  def retry(%{state: :failed} = state), do: %{state | state: :idle, failures: 0}
  def retry(state), do: state
end
