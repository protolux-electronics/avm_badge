defmodule Badge.ConnectFour.Protocol do
  @moduledoc """
  Wire format for the two badges' IR beam, and the pairing/turn state machine
  that decides what goes out on it.

  Pure and side-effect free: the page calls `tick/1` on every UI tick and
  `handle_ir/4` on every arriving frame, gets back the next state and
  whatever should be sent, and does the one send through `Badge.Ir.send/1`
  itself.

  Three frame kinds, distinguished by a leading tag byte, all far under
  `Badge.Ir.Frame.max_payload/0`:

      HELLO  <<0>>            both badges, while pairing
      MOVE   <<1, seq, col>>  mover -> opponent, one dropped disc
      ACK    <<2, seq>>       opponent -> mover, replies to a MOVE

  Both badges run the identical game and beam HELLO the moment the page
  opens; there is nothing to choose, and no "host" — the only asymmetry two
  independent boards need is which one moves first, and whichever hears the
  other's chip id first settles that unilaterally by comparing the two ids
  (the lower one is player 0). No reply is needed, since both sides compute
  the same answer from the same two ids. `Badge.Ir.Frame` already carries the
  sender's chip id in every frame, so the HELLO body itself stays empty.

  While pairing, *both* badges are beaming at once, unlike a MOVE/ACK
  exchange where only one side is ever repeating at a time. Continuous
  transmission then would leave neither side a moment to hear the other, so
  HELLO instead repeats on a duty cycle, one tick in `@beam_ticks` — the same
  throttle `Badge.Page.Name` uses for its own two-way "hold badges together"
  exchange, and for the same reason.

  A MOVE or its ACK, once pairing is done, is still repeated on every tick
  rather than on a timer (`Process.send_after/3` is expensive on this
  platform). MOVE repeats until the ACK is heard, since nothing else moves
  the game forward; ACK repeats a bounded number of ticks and then stops,
  since the MOVE it answers will simply come again if this badge's ACK never
  lands.
  """

  @hello 0
  @move 1
  @ack 2

  # One tick in three is on, matching Badge.Page.Name's beam_ticks.
  @beam_ticks 3

  # How many ticks a reply that nothing depends on hearing keeps repeating for.
  @reply_ticks 10

  @doc "Fresh state: pairing starts the instant the page opens, nothing to choose."
  @spec new() :: map
  def new, do: %{player: nil, peer: nil, phase: :discovering, seq: 0, outgoing: nil, beam: 0}

  @doc "Whether a game has been paired and is on."
  @spec playing?(map) :: boolean
  def playing?(%{phase: :playing}), do: true
  def playing?(_state), do: false

  @doc """
  Records a disc this badge just dropped, and starts beaming it.

  Called right after the page applies the drop to its own board, with the
  column that was dropped. Keeps beaming the MOVE frame until the opponent's
  ACK is heard.
  """
  @spec move(map, non_neg_integer) :: map
  def move(%{seq: seq} = state, column) do
    %{state | seq: seq + 1, outgoing: forever(<<@move, seq, column>>)}
  end

  @doc """
  What to send on this tick, if anything.

  Returns `{state, frame_or_nil}`; a bounded reply's repeat count ticks down
  and clears itself once spent.
  """
  @spec tick(map) :: {map, binary | nil}
  def tick(%{phase: :discovering, beam: beam} = state) do
    case rem(beam + 1, @beam_ticks) do
      0 -> {%{state | beam: 0}, <<@hello>>}
      next -> {%{state | beam: next}, nil}
    end
  end

  def tick(%{outgoing: nil} = state), do: {state, nil}
  def tick(%{outgoing: {frame, :infinite}} = state), do: {state, frame}

  def tick(%{outgoing: {frame, repeats}} = state) when repeats <= 1 do
    {%{state | outgoing: nil}, frame}
  end

  def tick(%{outgoing: {frame, repeats}} = state) do
    {%{state | outgoing: {frame, repeats - 1}}, frame}
  end

  @doc """
  Applies a frame heard on the IR beam.

  `own_id` is this badge's own chip id, needed only to work out who moves
  first the instant a HELLO is heard. Returns `{state, event}`, where `event`
  is `nil` (nothing for the page to react to), `:paired` (a game just
  started), or `{:move, column}` (the opponent's disc, to be applied to the
  local board exactly like one of this badge's own drops).
  """
  @spec handle_ir(map, binary, binary, binary) ::
          {map, nil | :paired | {:move, non_neg_integer}}
  def handle_ir(%{phase: :discovering} = state, from, <<@hello>>, own_id) do
    {%{state | peer: from, phase: :playing, player: player_for(own_id, from)}, :paired}
  end

  def handle_ir(
        %{phase: :playing, peer: peer, seq: seq} = state,
        peer,
        <<@move, seq, column>>,
        _id
      ) do
    {%{state | seq: seq + 1, outgoing: reply(<<@ack, seq>>)}, {:move, column}}
  end

  # A move already applied: the opponent is still waiting on our ack, not
  # asking us to apply it twice.
  def handle_ir(%{phase: :playing, peer: peer} = state, peer, <<@move, seq, _column>>, _id)
      when seq < state.seq do
    {%{state | outgoing: reply(<<@ack, seq>>)}, nil}
  end

  def handle_ir(
        %{outgoing: {<<@move, seq, _column>>, _repeats}, peer: peer} = state,
        peer,
        <<@ack, seq>>,
        _id
      ) do
    {%{state | outgoing: nil}, nil}
  end

  def handle_ir(state, _from, _payload, _id), do: {state, nil}

  # The lower chip id is arbitrary but fixed, so both sides land on the same
  # answer independently; ids are 6 distinct factory-programmed bytes, so a
  # tie only happens if the mac could not be read (host/simulator testing).
  defp player_for(own_id, peer_id) when own_id < peer_id, do: 0
  defp player_for(_own_id, _peer_id), do: 1

  defp forever(frame), do: {frame, :infinite}
  defp reply(frame), do: {frame, @reply_ticks}
end
