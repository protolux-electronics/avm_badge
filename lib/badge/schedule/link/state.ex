defmodule Badge.Schedule.Link.State do
  @moduledoc """
  What the link knows, as plain data.

  No socket and no clock: `Badge.Schedule.Link` owns those and calls in here
  for every transition, which keeps freshness, retrying and the held copy
  testable on the host.

  A held programme outlives a failed refresh, so a badge that fetched once
  keeps showing what it has when the site goes quiet.
  """

  # How old a held programme may be before opening the page fetches again.
  @stale 30 * 60_000

  # How long a failure stands before a load tries again by itself.
  @retry 60_000

  @doc "A link that holds nothing."
  @spec new() :: map
  def new do
    %{state: :idle, sessions: [], reason: nil, version: 0, at: nil}
  end

  @doc "What a page reads each tick. `held` says whether `sessions/0` has anything."
  @spec status(map) :: map
  def status(state) do
    %{
      state: state.state,
      reason: state.reason,
      version: state.version,
      held: state.sessions != []
    }
  end

  @doc """
  A request to have the programme, given whether the clock is set and the
  time in milliseconds.

  `:fetch` means the caller should start one; `:wait` means there is nothing
  to do yet, or already a copy fresh enough.
  """
  @spec load(map, boolean, integer) :: {:fetch | :wait, map}
  def load(%{state: :loading} = state, _clock, _now), do: {:wait, state}

  def load(%{state: :failed, at: at} = state, _clock, now) when now - at < @retry,
    do: {:wait, state}

  def load(%{state: :ready, at: at} = state, _clock, now) when now - at < @stale,
    do: {:wait, state}

  # Not ready, and a copy on hand beats a waiting screen while the clock settles.
  def load(%{state: :ready} = state, false, _now), do: {:wait, state}
  def load(state, false, _now), do: {:wait, %{state | state: :waiting}}
  def load(state, true, _now), do: {:fetch, %{state | state: :loading}}

  @doc "Takes what the fetch process brought back."
  @spec fetched(map, {:ok, [map]} | {:error, term}, integer) :: map
  def fetched(state, {:ok, sessions}, now) do
    %{state | state: :ready, sessions: sessions, reason: nil, version: state.version + 1, at: now}
  end

  def fetched(state, {:error, reason}, now) do
    %{state | state: :failed, reason: reason, at: now}
  end

  @doc "Clears a failure so the next load fetches at once."
  @spec retry(map) :: map
  def retry(%{state: :failed} = state), do: %{state | state: :idle}
  def retry(state), do: state
end
