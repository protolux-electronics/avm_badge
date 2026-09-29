defmodule Badge.ConnectFour.ProtocolTest do
  use ExUnit.Case, async: true

  alias Badge.ConnectFour.Protocol
  alias Badge.Ir.Frame

  # Lower than @high_id, so a badge using @low_id is always player 0.
  @low_id <<1, 1, 1, 1, 1, 1>>
  @high_id <<2, 2, 2, 2, 2, 2>>
  @stranger_id <<9, 9, 9, 9, 9, 9>>

  describe "new/0" do
    test "starts discovering right away, nothing chosen" do
      assert %{player: nil, phase: :discovering, outgoing: nil} = Protocol.new()
      refute Protocol.playing?(Protocol.new())
    end
  end

  describe "tick/1 while discovering" do
    test "beams HELLO on a duty cycle rather than every tick" do
      {ticks, _state} =
        Enum.reduce(1..6, {[], Protocol.new()}, fn _n, {ticks, state} ->
          {state, frame} = Protocol.tick(state)
          {[frame | ticks], state}
        end)

      sent = ticks |> Enum.reverse() |> Enum.reject(&is_nil/1)

      assert sent == [<<0>>, <<0>>]
    end
  end

  describe "tick/1 once paired but idle" do
    # Found on hardware: badge B heard badge A's HELLO and paired, but badge
    # A never heard B's, so A was stuck discovering forever while B sat
    # silent waiting for its turn. HELLO must keep repeating whenever there
    # is nothing more urgent to send, not just while still discovering.
    test "keeps beaming HELLO on the duty cycle, so a peer that missed pairing can still catch up" do
      {state, :paired, nil} = Protocol.handle_ir(Protocol.new(), @high_id, <<0>>, @low_id)

      {ticks, _state} =
        Enum.reduce(1..6, {[], state}, fn _n, {ticks, state} ->
          {state, frame} = Protocol.tick(state)
          {[frame | ticks], state}
        end)

      sent = ticks |> Enum.reverse() |> Enum.reject(&is_nil/1)

      assert sent == [<<0>>, <<0>>]
    end

    # A completed MOVE/ACK round trip already proves both badges paired, so
    # the heartbeat's job is done; continuing it would only self-interfere
    # with the mover's frames on later turns, which is what made a paired
    # game feel slow.
    test "stops once a move has happened, since pairing is proven by then" do
      # Idle the way a badge is between turns: paired, nothing outgoing, but
      # seq > 0 because a MOVE/ACK round trip already completed once.
      idle = %{Protocol.new() | phase: :playing, peer: @high_id, player: 0, seq: 1}

      {ticks, _state} =
        Enum.reduce(1..6, {[], idle}, fn _n, {ticks, state} ->
          {state, frame} = Protocol.tick(state)
          {[frame | ticks], state}
        end)

      assert Enum.all?(ticks, &is_nil/1)
    end
  end

  describe "sharing the beam" do
    setup do
      {first, :paired, nil} = Protocol.handle_ir(Protocol.new(), @high_id, <<0>>, @low_id)
      {second, :paired, nil} = Protocol.handle_ir(Protocol.new(), @low_id, <<0>>, @high_id)

      # Mid-exchange: first is repeating its MOVE, second its ACK.
      {first, move} = Protocol.move(first, 3)
      {second, {:move, 3}, _ack} = Protocol.handle_ir(second, @low_id, move, @high_id)

      %{mover: first, acker: second}
    end

    # The bug this guards: MOVE repeated on every tick while the ACK
    # answering it did the same, so both badges transmitted for over half of
    # every tick and neither had a gap left to hear the other in.
    test "MOVE and ACK each leave the beam idle more often than they use it", ctx do
      assert sent_over(ctx.mover, 12) == 6
      assert sent_over(ctx.acker, 12) == 4
    end

    # Equal periods would hold whatever phase the two free-running tick loops
    # happened to start in; coprime ones walk past each other, so a collision
    # clears within a cycle instead of lasting the whole exchange.
    test "the MOVE and ACK periods are coprime", ctx do
      assert Integer.gcd(period(ctx.mover), period(ctx.acker)) == 1
    end

    test "a bounded reply is counted in sends, not ticks, so throttling loses none", ctx do
      # Far more ticks than the reply's period needs, so it runs itself out.
      assert sent_over(ctx.acker, 200) == 10
    end
  end

  describe "pairing" do
    test "the lower chip id becomes player 0" do
      state = Protocol.new()

      assert {state, :paired, nil} = Protocol.handle_ir(state, @high_id, <<0>>, @low_id)
      assert %{peer: @high_id, phase: :playing, player: 0} = state
      assert Protocol.playing?(state)
    end

    test "the higher chip id becomes player 1" do
      state = Protocol.new()

      assert {state, :paired, nil} = Protocol.handle_ir(state, @low_id, <<0>>, @high_id)
      assert %{peer: @low_id, phase: :playing, player: 1} = state
    end

    test "both badges land on complementary answers from the same two ids" do
      a = Protocol.new()
      b = Protocol.new()

      {a, :paired, nil} = Protocol.handle_ir(a, @high_id, <<0>>, @low_id)
      {b, :paired, nil} = Protocol.handle_ir(b, @low_id, <<0>>, @high_id)

      assert a.player != b.player
    end

    test "a stray HELLO once already playing is ignored" do
      state = Protocol.new()
      {state, :paired, nil} = Protocol.handle_ir(state, @high_id, <<0>>, @low_id)

      assert Protocol.handle_ir(state, @high_id, <<0>>, @low_id) == {state, nil, nil}
    end

    # The deadlock this guards: badge A heard B's HELLO, paired as player 0
    # and dropped a disc before B ever heard A's own HELLO. Moving stops A
    # beaming HELLO for good, so if B discarded MOVE frames while still
    # discovering there would be nothing left to pair them, and A would beam
    # the same MOVE at a deaf peer forever.
    test "a MOVE pairs a badge that never heard the mover's HELLO" do
      {a, :paired, nil} = Protocol.handle_ir(Protocol.new(), @high_id, <<0>>, @low_id)
      {a, move} = Protocol.move(a, 3)

      assert {b, {:move, 3}, ack} = Protocol.handle_ir(Protocol.new(), @low_id, move, @high_id)
      assert %{peer: @low_id, phase: :playing, player: 1} = b
      assert b.seq == 1

      # And the ACK it sends back closes the exchange on the mover's side.
      assert {%{outgoing: nil}, nil, nil} = Protocol.handle_ir(a, @high_id, ack, @low_id)
    end

    test "the mover has stopped beaming HELLO by then, so the MOVE is the only way back" do
      {a, :paired, nil} = Protocol.handle_ir(Protocol.new(), @high_id, <<0>>, @low_id)
      {a, _move} = Protocol.move(a, 3)

      {frames, _a} =
        Enum.map_reduce(1..12, a, fn _n, state ->
          {state, frame} = Protocol.tick(state)
          {frame, state}
        end)

      refute Enum.any?(frames, &(&1 == <<0>>))
    end
  end

  describe "frames fit the IR beam" do
    test "HELLO fits Frame.max_payload/0" do
      assert byte_size(until_frame(Protocol.new())) <= Frame.max_payload()
    end

    test "MOVE fits Frame.max_payload/0" do
      {_state, frame} = Protocol.move(Protocol.new(), 6)
      assert byte_size(frame) <= Frame.max_payload()
    end
  end

  describe "moves" do
    setup do
      first = Protocol.new()
      second = Protocol.new()

      {first, :paired, nil} = Protocol.handle_ir(first, @high_id, <<0>>, @low_id)
      {second, :paired, nil} = Protocol.handle_ir(second, @low_id, <<0>>, @high_id)

      %{first: first, second: second}
    end

    test "a move beams MOVE with the current sequence number", %{first: first} do
      {_first, frame} = Protocol.move(first, 3)

      assert frame == <<1, 0, 3>>
    end

    test "the opponent applies it once and starts acking, right away", %{
      first: first,
      second: second
    } do
      {_first, move_frame} = Protocol.move(first, 3)

      assert {second, {:move, 3}, ack} =
               Protocol.handle_ir(second, @low_id, move_frame, @high_id)

      assert second.seq == 1
      assert ack == <<2, 0>>
    end

    test "the mover stops once the ACK lands", %{first: first, second: second} do
      {first, move_frame} = Protocol.move(first, 3)
      {_second, {:move, 3}, ack} = Protocol.handle_ir(second, @low_id, move_frame, @high_id)

      assert {first, nil, nil} = Protocol.handle_ir(first, @high_id, ack, @low_id)
      assert first.outgoing == nil
    end

    test "a resend of an already-applied move is not applied twice, but is re-acked",
         %{first: first, second: second} do
      {_first, move_frame} = Protocol.move(first, 3)
      {second, {:move, 3}, _ack} = Protocol.handle_ir(second, @low_id, move_frame, @high_id)

      assert {second, nil, ack} = Protocol.handle_ir(second, @low_id, move_frame, @high_id)
      assert second.seq == 1
      assert ack == <<2, 0>>
    end

    test "a full pairing and multi-move exchange stays in sync", %{first: first, second: second} do
      # first (player 0) moves; second applies it and acks, first clears its retry.
      {first, move0} = Protocol.move(first, 2)
      {second, {:move, 2}, ack0} = Protocol.handle_ir(second, @low_id, move0, @high_id)
      {first, nil, nil} = Protocol.handle_ir(first, @high_id, ack0, @low_id)

      # second (player 1) moves; first applies it and acks, second clears its retry.
      {second, move1} = Protocol.move(second, 5)
      {first, {:move, 5}, ack1} = Protocol.handle_ir(first, @high_id, move1, @low_id)

      assert {second, nil, nil} = Protocol.handle_ir(second, @low_id, ack1, @high_id)
      assert first.seq == 2 and second.seq == 2
    end

    test "frames from anyone but the paired peer are ignored", %{first: first} do
      {first, move_frame} = Protocol.move(first, 3)

      assert Protocol.handle_ir(first, @stranger_id, move_frame, @low_id) == {first, nil, nil}
    end

    test "ACK fits Frame.max_payload/0", %{first: first, second: second} do
      {_first, move_frame} = Protocol.move(first, 3)
      {_second, {:move, 3}, ack} = Protocol.handle_ir(second, @low_id, move_frame, @high_id)

      assert byte_size(ack) <= Frame.max_payload()
    end
  end

  # Skips ticks until one produces a frame, since a HELLO only beams on a
  # duty cycle and a reply is armed but not yet due on the tick it's set.
  defp until_frame(state) do
    case Protocol.tick(state) do
      {state, nil} -> until_frame(state)
      {_state, frame} -> frame
    end
  end

  # How many of `ticks` ticks actually put a frame on the beam.
  defp sent_over(state, ticks) do
    {frames, _state} =
      Enum.map_reduce(1..ticks, state, fn _n, state ->
        {state, frame} = Protocol.tick(state)
        {frame, state}
      end)

    Enum.count(frames, &(&1 != nil))
  end

  # The duty cycle a state's queued frame keeps, read back as ticks per send.
  defp period(state), do: div(12, sent_over(state, 12))
end
