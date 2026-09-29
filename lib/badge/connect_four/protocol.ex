defmodule Badge.ConnectFour.Protocol do
  @moduledoc """
  The wire format for the IR beam between two badges, and the pairing and
  turn state machine that selects what to send.

  This module is pure. The page calls `tick/1` on each UI tick, and
  `handle_ir/4` for each frame that arrives. Both functions return the new
  state and the frame to send. The page sends that frame with
  `Badge.Ir.send/1`.

  There are three kinds of frame. A leading tag byte identifies each kind.
  All are much smaller than `Badge.Ir.Frame.max_payload/0`.

      HELLO  <<0>>            both badges, while unpaired or before the first move
      MOVE   <<1, seq, col>>  mover to opponent, one dropped disc
      ACK    <<2, seq>>       opponent to mover, answers a MOVE

  Both badges run the same game, and there is no host. Each badge sends HELLO
  as soon as the page opens. The two badges must agree on one item only:
  which badge moves first. A badge that receives a frame compares the two
  chip ids and decides. The lower id is player 0. No reply is necessary,
  because both badges calculate the same result from the same two ids.
  `Badge.Ir.Frame` puts the sender's chip id in each frame, so the body of a
  HELLO frame is empty.

  ## Use of the beam

  Each kind of frame repeats on a duty cycle. If two badges transmit at the
  same time, neither badge receives the frame of the other badge. One frame
  occupies one half of a tick: at 2400 baud a MOVE frame is 13 bytes, which
  takes 54 ms, and a tick is 100 ms. A badge that transmits on each tick
  therefore occupies one half of the beam, and two such badges leave no free
  time. A MOVE frame and the ACK frame that answers it both repeated on each
  tick before. The two badges transmitted together for the full exchange.

  The three periods are coprime: `@hello_period`, `@move_period` and
  `@ack_period`. The tick loops of the two badges are independent, so the
  phase between them is arbitrary but constant. Coprime periods move the two
  transmit patterns through a different relative position on each cycle. A
  collision therefore stops after one cycle. Equal periods would hold the
  initial phase, and a collision would continue for the full exchange.

  A badge sends HELLO while it has nothing more urgent to send and no badge
  has moved (`seq == 0`). The `:discovering` phase is not the only phase that
  sends HELLO. Pairing has no reply. If badge A receives the HELLO of badge B, but
  badge B does not receive the HELLO of badge A, then badge A pairs and has
  nothing to send until its turn. Badge B stays in the `:discovering` phase
  and cannot pair. The repeat prevents this condition. A HELLO frame that
  arrives after pairing has no effect.

  The `seq == 0` condition is necessary. A complete MOVE and ACK exchange
  shows that both badges paired, and more HELLO frames then cause
  interference only. Pairing occurs once, but a game continues for many
  exchanges.

  A badge in the `:discovering` phase also pairs when it receives a MOVE
  frame. A badge stops sending HELLO when it moves. Without this rule, a
  badge that paired and moved before the other badge received its HELLO would
  send MOVE frames to a badge that discards all of them.

  A MOVE frame repeats until the ACK arrives, because nothing else continues
  the game. An ACK frame repeats a limited number of times and then stops,
  because the MOVE arrives again if the ACK does not. The code counts the
  repeats and does not use a timer, because `Process.send_after/3` is
  expensive on this platform.
  """

  @hello 0
  @move 1
  @ack 2

  # Coprime periods prevent a constant collision between two kinds of frame.
  # HELLO uses the same period as Badge.Page.Name.
  @hello_period 3
  @move_period 2
  @ack_period 3

  # How many times to send an ACK. The MOVE arrives again if all of them fail.
  @ack_sends 10

  # The tick counter wraps at this value and does not grow without a limit.
  # Integers above 2^27 are boxed on this 32-bit VM, and each comparison then
  # allocates. All three periods divide this value, so the wrap does not
  # change any duty cycle.
  @cycle 6

  @doc "A new state. Pairing starts when the page opens."
  @spec new() :: map
  def new, do: %{player: nil, peer: nil, phase: :discovering, seq: 0, outgoing: nil, beam: 0}

  @doc "Whether the two badges paired and the game runs."
  @spec playing?(map) :: boolean
  def playing?(%{phase: :playing}), do: true
  def playing?(_state), do: false

  @doc """
  Records a disc that this badge dropped, and starts to send it.

  The page calls this function immediately after it applies the drop to its
  own board. The MOVE frame repeats until the ACK of the opponent arrives.
  The function also returns the frame, as `tick/1` does, so that the page can
  send it immediately and does not wait for the next tick.
  """
  @spec move(map, non_neg_integer) :: {map, binary}
  def move(%{seq: seq} = state, column) do
    frame = <<@move, seq, column>>

    {%{state | seq: seq + 1, outgoing: forever(frame)}, frame}
  end

  @doc """
  The frame to send on this tick, if there is one.

  Returns `{state, frame_or_nil}`. A limited reply counts down its remaining
  sends and clears itself when no sends remain. The counter advances on each
  tick, with or without a frame, so each kind of frame keeps its own phase.
  """
  @spec tick(map) :: {map, binary | nil}

  # The badge paired, has no queued frame and has already moved. There is
  # nothing to schedule until an event arrives, so the counter does not
  # advance. The state must be identical here, not only equivalent:
  # `Badge.UI` repaints the full panel when a tick changes the page state,
  # and this screen does not change while a player waits.
  def tick(%{outgoing: nil, seq: seq} = state) when seq > 0, do: {state, nil}

  def tick(%{beam: beam} = state) do
    beam = rem(beam + 1, @cycle)

    due(%{state | beam: beam}, beam)
  end

  # No queued frame and no badge has moved. This is the pairing heartbeat.
  defp due(%{outgoing: nil, seq: 0} = state, beam) when rem(beam, @hello_period) == 0 do
    {state, <<@hello>>}
  end

  defp due(%{outgoing: nil} = state, _beam), do: {state, nil}

  defp due(%{outgoing: {frame, sends, period}} = state, beam) when rem(beam, period) == 0 do
    {%{state | outgoing: spend(frame, sends, period)}, frame}
  end

  defp due(state, _beam), do: {state, nil}

  defp spend(_frame, 1, _period), do: nil
  defp spend(frame, :infinite, period), do: {frame, :infinite, period}
  defp spend(frame, sends, period), do: {frame, sends - 1, period}

  @doc """
  Applies a frame that arrived on the IR beam.

  `own_id` is the chip id of this badge. The function needs it only to decide
  which badge moves first, at the moment it receives a frame from a peer.

  Returns `{state, event, frame}`, where `event` is one of:

    * `nil` — the page does nothing
    * `:paired` — a game started
    * `{:move, column}` — the disc of the opponent. The page applies it to
      the local board in the same way as a drop by this badge.

  `frame` is an ACK to send immediately, as `tick/1` does, and not on the
  next tick. It is `nil` when there is nothing to send.

  A badge that pairs from a MOVE frame returns `{:move, column}` and not
  `:paired`, because the page must act on the disc. Use `playing?/1` to know
  that a game runs, whichever kind of frame started it.
  """
  @spec handle_ir(map, binary, binary, binary) ::
          {map, nil | :paired | {:move, non_neg_integer}, binary | nil}
  def handle_ir(%{phase: :discovering} = state, from, <<@hello>>, own_id) do
    {pair(state, from, own_id), :paired, nil}
  end

  # A badge stops sending HELLO when it moves. Its MOVE frame is then the
  # only frame that can pair this badge.
  def handle_ir(%{phase: :discovering} = state, from, <<@move, _seq, _col>> = payload, own_id) do
    state |> pair(from, own_id) |> handle_ir(from, payload, own_id)
  end

  def handle_ir(
        %{phase: :playing, peer: peer, seq: seq} = state,
        peer,
        <<@move, seq, column>>,
        _id
      ) do
    frame = <<@ack, seq>>
    {%{state | seq: seq + 1, outgoing: reply(frame)}, {:move, column}, frame}
  end

  # This badge applied the move already. The opponent waits for the ACK and
  # does not ask for the move a second time.
  def handle_ir(%{phase: :playing, peer: peer} = state, peer, <<@move, seq, _column>>, _id)
      when seq < state.seq do
    frame = <<@ack, seq>>
    {%{state | outgoing: reply(frame)}, nil, frame}
  end

  def handle_ir(
        %{outgoing: {<<@move, seq, _column>>, _sends, _period}, peer: peer} = state,
        peer,
        <<@ack, seq>>,
        _id
      ) do
    {%{state | outgoing: nil}, nil, nil}
  end

  def handle_ir(state, _from, _payload, _id), do: {state, nil, nil}

  defp pair(state, from, own_id) do
    %{state | peer: from, phase: :playing, player: player_for(own_id, from)}
  end

  # The choice of the lower chip id is arbitrary but fixed, so both badges
  # calculate the same result independently. A chip id is 6 unique bytes from
  # the factory. Two equal ids occur only when a badge cannot read its MAC
  # address, as on the host and in the simulator.
  defp player_for(own_id, peer_id) when own_id < peer_id, do: 0
  defp player_for(_own_id, _peer_id), do: 1

  defp forever(frame), do: {frame, :infinite, @move_period}
  defp reply(frame), do: {frame, @ack_sends, @ack_period}
end
