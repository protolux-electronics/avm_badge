defmodule Badge.GameLink.Reliable do
  @moduledoc """
  Pure reliable delivery: one send window per destination slot and one
  ordered stream per sender. Held inside `Badge.GameLink.State` under
  `:reliable`; knows slots and sequences only, never addresses or wire bytes.
  """

  @window 16
  @holdback 16
  @resend_round 8
  @wrap 65536

  @type t :: map

  @doc "A fresh, empty book: no destinations, no senders."
  @spec new() :: t
  def new, do: %{out_next: %{}, pending: [], in: %{}}

  @doc "Drops both directions for a slot whose join epoch changed, or that left."
  @spec reset(t, Badge.GameLink.slot()) :: t
  def reset(reliable, slot) do
    %{
      reliable
      | out_next: Map.delete(reliable.out_next, slot),
        pending: drop_slot(reliable.pending, slot),
        in: Map.delete(reliable.in, slot)
    }
  end

  defp drop_slot([], _slot), do: []
  defp drop_slot([{slot, _sequence, _payload} | rest], slot), do: drop_slot(rest, slot)
  defp drop_slot([entry | rest], slot), do: [entry | drop_slot(rest, slot)]

  @doc """
  Queues one message to every given slot. Refused entirely, naming every
  full destination, when any of their windows (16 unacked) is already full.
  """
  @spec push(t, [Badge.GameLink.slot()], binary) ::
          {:ok, t, [{Badge.GameLink.slot(), 0..65535}]} | {:overflow, [Badge.GameLink.slot()]}
  def push(reliable, destinations, payload) do
    case full_slots(reliable, destinations, []) do
      [] -> queue(reliable, destinations, payload, [], [])
      full -> {:overflow, :lists.reverse(full)}
    end
  end

  defp full_slots(_reliable, [], acc), do: acc

  defp full_slots(reliable, [slot | rest], acc) do
    if pending(reliable, slot) >= @window do
      full_slots(reliable, rest, [slot | acc])
    else
      full_slots(reliable, rest, acc)
    end
  end

  defp queue(reliable, [], _payload, entries, added) do
    {:ok, %{reliable | pending: reliable.pending ++ :lists.reverse(added)},
     :lists.reverse(entries)}
  end

  defp queue(reliable, [slot | rest], payload, entries, added) do
    sequence = Map.get(reliable.out_next, slot, 0)
    reliable = %{reliable | out_next: Map.put(reliable.out_next, slot, wrap(sequence + 1))}

    queue(
      reliable,
      rest,
      payload,
      [{slot, sequence} | entries],
      [{slot, sequence, payload} | added]
    )
  end

  @doc """
  Takes one inbound frame from a sender's stream. Returns the payloads now
  in order, possibly several at once when a hold-back gap closes. A
  duplicate or a frame past the 16-deep hold-back delivers nothing.
  """
  @spec receive(t, Badge.GameLink.slot(), 0..65535, binary) :: {t, [{0..65535, binary}]}
  def receive(reliable, from, sequence, payload) do
    stream = Map.get(reliable.in, from, %{next: 0, acked: 0, holdback: []})

    cond do
      not ahead?(sequence, stream.next) ->
        {reliable, []}

      sequence == stream.next ->
        {delivered, stream} = deliver(stream, sequence, payload)
        {%{reliable | in: Map.put(reliable.in, from, stream)}, delivered}

      :lists.keymember(sequence, 1, stream.holdback) ->
        {reliable, []}

      length(stream.holdback) >= @holdback ->
        {reliable, []}

      true ->
        stream = %{stream | holdback: [{sequence, payload} | stream.holdback]}
        {%{reliable | in: Map.put(reliable.in, from, stream)}, []}
    end
  end

  defp deliver(stream, sequence, payload),
    do: drain(%{stream | next: wrap(sequence + 1)}, [{sequence, payload}])

  defp drain(stream, delivered) do
    case :lists.keytake(stream.next, 1, stream.holdback) do
      {:value, {sequence, payload}, holdback} ->
        drain(
          %{stream | next: wrap(sequence + 1), holdback: holdback},
          delivered ++ [{sequence, payload}]
        )

      false ->
        {delivered, stream}
    end
  end

  @doc """
  The {from, sequence} pairs Badge.UI has taken. Answers one cumulative ack
  per sender that actually advanced: everything up to it was taken.
  """
  @spec taken(t, [{Badge.GameLink.slot(), 0..65535}]) :: {t, [{Badge.GameLink.slot(), 0..65535}]}
  def taken(reliable, entries), do: advance(reliable, highest(entries, []), [])

  defp highest([], acc), do: acc

  defp highest([{from, sequence} | rest], acc) do
    case :lists.keyfind(from, 1, acc) do
      {^from, current} ->
        if ahead?(sequence, current) do
          highest(rest, :lists.keyreplace(from, 1, acc, {from, sequence}))
        else
          highest(rest, acc)
        end

      false ->
        highest(rest, [{from, sequence} | acc])
    end
  end

  defp advance(reliable, [], acked), do: {reliable, :lists.reverse(acked)}

  defp advance(reliable, [{from, sequence} | rest], acked) do
    stream = Map.get(reliable.in, from, %{next: 0, acked: 0, holdback: []})
    next = wrap(sequence + 1)

    if progressed?(next, stream.acked) do
      reliable = %{reliable | in: Map.put(reliable.in, from, %{stream | acked: next})}
      advance(reliable, rest, [{from, next} | acked])
    else
      advance(reliable, rest, acked)
    end
  end

  @doc "A destination's cumulative ack: drops everything below `next` to that slot."
  @spec ack(t, Badge.GameLink.slot(), 0..65535) :: t
  def ack(reliable, from, next) do
    kept =
      for entry = {slot, sequence, _payload} <- reliable.pending,
          slot != from or ahead?(sequence, next),
          do: entry

    %{reliable | pending: kept}
  end

  @doc "One resend round: at most 8 unacked messages in total, oldest first."
  @spec resend(t) :: {t, [{Badge.GameLink.slot(), 0..65535, binary}]}
  def resend(reliable), do: {reliable, take(reliable.pending, @resend_round, [])}

  defp take(_pending, 0, acc), do: :lists.reverse(acc)
  defp take([], _remaining, acc), do: :lists.reverse(acc)
  defp take([entry | rest], remaining, acc), do: take(rest, remaining - 1, [entry | acc])

  @doc "Unacked messages still queued for a slot."
  @spec pending(t, Badge.GameLink.slot()) :: non_neg_integer
  def pending(reliable, slot) do
    :lists.foldl(
      fn {s, _sequence, _payload}, count -> if(s == slot, do: count + 1, else: count) end,
      0,
      reliable.pending
    )
  end

  # Ahead of, or equal to, across the 16-bit wrap.
  defp ahead?(a, b), do: rem(a - b + @wrap, @wrap) < 32768

  # Strictly ahead: a real advance, not the same cursor repeated.
  defp progressed?(a, b), do: a != b and ahead?(a, b)

  defp wrap(sequence), do: rem(sequence, @wrap)
end
