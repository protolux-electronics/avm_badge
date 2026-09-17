defmodule Badge.Schedule.Link.State do
  @moduledoc """
  What the link knows, as plain data.

  No socket and no clock: `Badge.Schedule.Link` owns those and calls in here
  on every tick, which keeps freshness, retrying and the held copy testable
  on the host.

  A held programme outlives a failed refresh, so a badge that fetched once
  keeps showing what it has when the site goes quiet.
  """

  # How old a held programme may be before it is fetched again.
  @stale 30 * 60_000

  # How long the first failure stands; each one after doubles it, to a cap.
  @retry 60_000
  @max_retry 30 * 60_000

  @doc """
  A link holding the compiled-in programme, or nothing.

  A held copy counts as old from the start, so the first tick with a clock
  fetches a fresh one while the page already has something to show.
  """
  @spec new(tuple) :: map
  def new(sessions \\ {}) do
    %{state: :idle, sessions: sessions, reason: nil, version: 1, at: nil, failures: 0}
  end

  @doc "What a page reads each tick. `held` says whether `sessions/0` has anything."
  @spec status(map) :: map
  def status(state) do
    %{
      state: state.state,
      reason: state.reason,
      version: state.version,
      held: tuple_size(state.sessions) > 0
    }
  end

  @doc """
  A tick, given whether the clock is set and the time in milliseconds.

  `:fetch` means the caller should start one; `:wait` means there is nothing
  to do yet, or already a copy fresh enough.
  """
  @spec load(map, boolean, integer) :: {:fetch | :wait, map}
  def load(%{state: :loading} = state, _clock, _now), do: {:wait, state}

  def load(%{state: :failed} = state, clock, now) do
    case now - state.at < backoff(state.failures) do
      true -> {:wait, state}
      false -> attempt(state, clock)
    end
  end

  def load(%{state: :ready, at: at} = state, _clock, now) when now - at < @stale,
    do: {:wait, state}

  def load(state, clock, _now), do: attempt(state, clock)

  # Not ready, and a copy on hand beats a waiting screen while the clock settles.
  defp attempt(%{state: :ready} = state, false), do: {:wait, state}
  defp attempt(state, false), do: {:wait, %{state | state: :waiting}}
  defp attempt(state, true), do: {:fetch, %{state | state: :loading}}

  defp backoff(failures), do: min(@retry * doubled(failures - 1), @max_retry)

  defp doubled(0), do: 1
  defp doubled(n), do: 2 * doubled(n - 1)

  @doc "Takes what the fetch process brought back."
  @spec fetched(map, {:ok, tuple} | {:error, term}, integer) :: map
  def fetched(state, {:ok, sessions}, now) do
    %{
      state
      | state: :ready,
        sessions: sessions,
        reason: nil,
        version: state.version + 1,
        at: now,
        failures: 0
    }
  end

  def fetched(state, {:error, reason}, now) do
    %{state | state: :failed, reason: reason, at: now, failures: state.failures + 1}
  end

  @doc "Clears a failure so the next tick fetches at once."
  @spec retry(map) :: map
  def retry(%{state: :failed} = state), do: %{state | state: :idle, failures: 0}
  def retry(state), do: state
end
