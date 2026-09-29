defmodule Badge.Pong.Match do
  @moduledoc """
  One Pong match against one other badge, as plain data.

  `Badge.Page.Pong` owns the clock, the keys and the beam; this module owns
  the rest. Feed it frames with `hear/4` and time with `step/3`, and put
  whatever payload `step/3` returns on the beam:

      match = Match.new(chip_id, "Ana", coin, now)
      {match, payload} = Match.step(match, now, direction)

  Times are milliseconds from one monotonic clock. Nothing here touches
  hardware, so both badges of a match can run side by side in a test.
  """

  import Bitwise

  alias Badge.Pong.Physics
  alias Badge.Pong.Wire

  @win 5

  @flip_ms 1_500
  @reveal_ms 1_000
  @countdown_ms 1_500

  # One frame per link read, and how often each kind repeats until answered.
  @send_gap_ms 110
  @hello_ms 200
  @ball_ms 150
  @score_ms 300
  @keepalive_ms 500
  @lost_ms 3_000

  # A longer step is a stall, not time the ball should cover.
  @max_dt 100

  @paired [:flipping, :revealing, :serving, :rally, :over]
  @playing [:flipping, :revealing, :serving, :rally]

  def win, do: @win
  def flip_ms, do: @flip_ms
  def reveal_ms, do: @reveal_ms
  def countdown_ms, do: @countdown_ms

  @doc "A match looking for an opponent."
  def new(id, name, coin, now) do
    %{
      id: id,
      name: name,
      coin: coin,
      phase: :searching,
      since: now,
      clock: now,
      peer: nil,
      peer_name: "",
      peer_coin: 0,
      server: nil,
      me: 0,
      them: 0,
      paddle: Physics.paddle_home(),
      ball: nil,
      handed: false,
      seq: 0,
      out_ball: nil,
      out_score: nil,
      acks: [],
      sent_at: nil,
      ball_sent_at: nil,
      score_sent_at: nil,
      hello_at: nil,
      heard_at: now,
      last_ball: nil,
      last_score: nil,
      lost: false
    }
  end

  @doc "The match `now`, and the payload to send, if one is due."
  def step(match, now, direction) do
    dt = min(max(now - match.clock, 0), @max_dt)

    %{match | clock: now}
    |> watch_link(now)
    |> advance(now, dt, direction)
    |> transmit(now)
  end

  @doc "The match after a frame from `from`, or `:ignore` for one it has no use for."
  def hear(%{id: id}, id, _payload, _now), do: :ignore

  def hear(match, from, payload, now) do
    case {Wire.decode(payload), match.peer} do
      {:error, _peer} -> :ignore
      {{:ok, message}, nil} -> from_stranger(match, from, message, now)
      {{:ok, message}, ^from} -> {:ok, from_peer(%{match | heard_at: now}, message, now)}
      _other -> :ignore
    end
  end

  defp from_stranger(match, from, {:hello, coin, ready, name}, now) do
    match = %{match | peer: from, peer_coin: coin, peer_name: name, heard_at: now}

    {:ok, greet(match, ready, now)}
  end

  defp from_stranger(_match, _from, _message, _now), do: :ignore

  defp greet(match, 1, now), do: flip(match, now)
  defp greet(match, _ready, now), do: enter(match, :pairing, now)

  defp from_peer(%{phase: :pairing} = match, {:hello, coin, 1, _name}, now) do
    flip(%{match | peer_coin: coin}, now)
  end

  defp from_peer(match, {:hello, _coin, _ready, _name}, _now), do: match

  # Task 6 and Task 7 add the :ball, :ack, :score and :bye clauses above this one.
  defp from_peer(match, _message, _now), do: match

  defp flip(match, now) do
    enter(%{match | server: serve_by_coin(match)}, :flipping, now)
  end

  # Both badges hold the same two coins and chip ids, so both pick the same server.
  defp serve_by_coin(match) do
    lower = match.id < match.peer

    case {band(bxor(match.coin, match.peer_coin), 1), lower} do
      {0, true} -> :me
      {1, false} -> :me
      _other -> :them
    end
  end

  defp enter(match, phase, now), do: %{match | phase: phase, since: now}

  # Task 7 replaces this with the real link watch.
  defp watch_link(match, _now), do: match

  defp advance(%{lost: true} = match, _now, _dt, _direction), do: match

  defp advance(%{phase: :flipping} = match, now, _dt, _direction) do
    after_ms(match, now, @flip_ms, :revealing)
  end

  defp advance(%{phase: :revealing} = match, now, _dt, _direction) do
    after_ms(match, now, @reveal_ms, :serving)
  end

  defp advance(%{phase: :serving} = match, now, dt, direction) do
    match = glide(match, dt, direction)

    case now - match.since >= @countdown_ms do
      true -> serve(enter(match, :rally, now))
      false -> match
    end
  end

  defp advance(%{phase: :rally} = match, _now, dt, direction) do
    match |> glide(dt, direction) |> fly(dt)
  end

  defp advance(match, _now, _dt, _direction), do: match

  defp after_ms(match, now, ms, next) do
    case now - match.since >= ms do
      true -> enter(match, next, now)
      false -> match
    end
  end

  defp glide(match, dt, direction) do
    %{match | paddle: Physics.move_paddle(match.paddle, direction, dt)}
  end

  defp serve(%{server: :me} = match), do: %{match | ball: Physics.serve(match.paddle)}
  defp serve(match), do: match

  # Task 6 replaces this with the rally.
  defp fly(match, _dt), do: match

  defp transmit(match, now) do
    case due?(match.sent_at, now, @send_gap_ms) do
      true -> pick(match, now)
      false -> {match, nil}
    end
  end

  # One frame, the most urgent first.
  defp pick(match, now) do
    cond do
      match.out_ball != nil and due?(match.ball_sent_at, now, @ball_ms) ->
        sent(
          %{match | ball_sent_at: now},
          now,
          {:ball, match.out_ball, Physics.outgoing(match.ball)}
        )

      match.acks != [] ->
        [seq | rest] = match.acks
        sent(%{match | acks: rest}, now, {:ack, seq})

      match.out_score != nil and due?(match.score_sent_at, now, @score_ms) ->
        sent(%{match | score_sent_at: now}, now, {:score, match.out_score, match.me, match.them})

      hello?(match, now) ->
        sent(%{match | hello_at: now}, now, {:hello, match.coin, ready(match), match.name})

      true ->
        {match, nil}
    end
  end

  defp sent(match, now, message), do: {%{match | sent_at: now}, Wire.encode(message)}

  defp hello?(%{phase: :searching} = match, now), do: due?(match.hello_at, now, @hello_ms)
  defp hello?(%{phase: :pairing} = match, now), do: due?(match.hello_at, now, @hello_ms)
  defp hello?(%{phase: :left}, _now), do: false
  defp hello?(match, now), do: due?(match.sent_at, now, @keepalive_ms)

  defp ready(%{phase: :searching}), do: 0
  defp ready(_match), do: 1

  defp due?(nil, _now, _ms), do: true
  defp due?(at, now, ms), do: now - at >= ms

  @doc false
  def paired, do: @paired

  @doc false
  def playing, do: @playing
end
