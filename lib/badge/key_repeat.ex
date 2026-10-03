defmodule Badge.KeyRepeat do
  @moduledoc """
  Press-and-hold key auto-repeat, as a pure state machine.

  Takes no hardware, processes, or timers of its own: it is told the current
  time and answers questions. `Badge.Keyboard` owns the clock and the tuning
  constants; this module tracks which key is armed and when it is next due.

  State is a plain map (or `nil` for disarmed). Times passed in are
  microseconds from `:erlang.monotonic_time(:microsecond)`; `delay_ms` and
  `interval_ms` arguments are milliseconds, converted internally.
  """

  @type t :: %{label: term, event: term, due_us: integer} | nil

  @doc "Disarmed state."
  @spec new() :: t
  def new, do: nil

  @doc """
  Arms repeat for `label`, replaying `event` verbatim on every fire. The
  first repeat is due at `now_us + delay_ms` (converted to microseconds).
  Replaces any previously armed key.
  """
  @spec arm(t, term, term, integer, non_neg_integer) :: t
  def arm(_state, label, event, now_us, delay_ms) do
    %{label: label, event: event, due_us: now_us + delay_ms * 1000}
  end

  @doc """
  If the armed label is not in `held_labels`, disarms. Otherwise unchanged.
  A no-op on an already-disarmed state.
  """
  @spec release(t, [term]) :: t
  def release(nil, _held_labels), do: nil

  def release(%{label: label} = state, held_labels) do
    if :lists.member(label, held_labels) do
      state
    else
      nil
    end
  end

  @doc """
  If armed and `now_us` is at or past the due time, fires: returns
  `{:fire, event, t'}` with `t'` re-armed for `now_us + interval_ms`.
  Otherwise (or if disarmed) returns `{:idle, t}` unchanged.
  """
  @spec due(t, integer, non_neg_integer) :: {:fire, term, t} | {:idle, t}
  def due(nil, _now_us, _interval_ms), do: {:idle, nil}

  def due(%{due_us: due_us} = state, now_us, _interval_ms) when now_us < due_us do
    {:idle, state}
  end

  def due(%{event: event} = state, now_us, interval_ms) do
    {:fire, event, %{state | due_us: now_us + interval_ms * 1000}}
  end
end
