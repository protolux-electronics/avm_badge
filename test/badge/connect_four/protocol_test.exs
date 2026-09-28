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
      {state, :paired} = Protocol.handle_ir(Protocol.new(), @high_id, <<0>>, @low_id)

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

  describe "pairing" do
    test "the lower chip id becomes player 0" do
      state = Protocol.new()

      assert {state, :paired} = Protocol.handle_ir(state, @high_id, <<0>>, @low_id)
      assert %{peer: @high_id, phase: :playing, player: 0} = state
      assert Protocol.playing?(state)
    end

    test "the higher chip id becomes player 1" do
      state = Protocol.new()

      assert {state, :paired} = Protocol.handle_ir(state, @low_id, <<0>>, @high_id)
      assert %{peer: @low_id, phase: :playing, player: 1} = state
    end

    test "both badges land on complementary answers from the same two ids" do
      a = Protocol.new()
      b = Protocol.new()

      {a, :paired} = Protocol.handle_ir(a, @high_id, <<0>>, @low_id)
      {b, :paired} = Protocol.handle_ir(b, @low_id, <<0>>, @high_id)

      assert a.player != b.player
    end

    test "a stray HELLO once already playing is ignored" do
      state = Protocol.new()
      {state, :paired} = Protocol.handle_ir(state, @high_id, <<0>>, @low_id)

      assert Protocol.handle_ir(state, @high_id, <<0>>, @low_id) == {state, nil}
    end
  end

  describe "frames fit the IR beam" do
    test "HELLO fits Frame.max_payload/0" do
      assert byte_size(until_frame(Protocol.new())) <= Frame.max_payload()
    end

    test "MOVE fits Frame.max_payload/0" do
      state = Protocol.move(Protocol.new(), 6)
      assert byte_size(until_frame(state)) <= Frame.max_payload()
    end
  end

  describe "moves" do
    setup do
      first = Protocol.new()
      second = Protocol.new()

      {first, :paired} = Protocol.handle_ir(first, @high_id, <<0>>, @low_id)
      {second, :paired} = Protocol.handle_ir(second, @low_id, <<0>>, @high_id)

      %{first: first, second: second}
    end

    test "a move beams MOVE with the current sequence number", %{first: first} do
      first = Protocol.move(first, 3)

      {_first, frame} = Protocol.tick(first)
      assert frame == <<1, 0, 3>>
    end

    test "the opponent applies it once and starts acking", %{first: first, second: second} do
      first = Protocol.move(first, 3)
      {_first, move_frame} = Protocol.tick(first)

      assert {second, {:move, 3}} = Protocol.handle_ir(second, @low_id, move_frame, @high_id)
      assert second.seq == 1

      {_second, ack} = Protocol.tick(second)
      assert ack == <<2, 0>>
    end

    test "the mover stops once the ACK lands", %{first: first, second: second} do
      first = Protocol.move(first, 3)
      {first, move_frame} = Protocol.tick(first)
      {second, {:move, 3}} = Protocol.handle_ir(second, @low_id, move_frame, @high_id)
      {_second, ack} = Protocol.tick(second)

      assert {first, nil} = Protocol.handle_ir(first, @high_id, ack, @low_id)
      assert first.outgoing == nil
    end

    test "a resend of an already-applied move is not applied twice, but is re-acked",
         %{first: first, second: second} do
      first = Protocol.move(first, 3)
      {_first, move_frame} = Protocol.tick(first)
      {second, {:move, 3}} = Protocol.handle_ir(second, @low_id, move_frame, @high_id)

      assert {second, nil} = Protocol.handle_ir(second, @low_id, move_frame, @high_id)
      assert second.seq == 1

      {_second, ack} = Protocol.tick(second)
      assert ack == <<2, 0>>
    end

    test "a full pairing and multi-move exchange stays in sync", %{first: first, second: second} do
      # first (player 0) moves; second applies it and acks, first clears its retry.
      first = Protocol.move(first, 2)
      {first, move0} = Protocol.tick(first)
      {second, {:move, 2}} = Protocol.handle_ir(second, @low_id, move0, @high_id)
      {second, ack0} = Protocol.tick(second)
      {first, nil} = Protocol.handle_ir(first, @high_id, ack0, @low_id)

      # second (player 1) moves; first applies it and acks, second clears its retry.
      second = Protocol.move(second, 5)
      {second, move1} = Protocol.tick(second)
      {first, {:move, 5}} = Protocol.handle_ir(first, @high_id, move1, @low_id)
      {first, ack1} = Protocol.tick(first)

      assert {second, nil} = Protocol.handle_ir(second, @low_id, ack1, @high_id)
      assert first.seq == 2 and second.seq == 2
    end

    test "frames from anyone but the paired peer are ignored", %{first: first} do
      first = Protocol.move(first, 3)
      {first, move_frame} = Protocol.tick(first)

      assert Protocol.handle_ir(first, @stranger_id, move_frame, @low_id) == {first, nil}
    end

    test "ACK fits Frame.max_payload/0", %{first: first, second: second} do
      first = Protocol.move(first, 3)
      {_first, move_frame} = Protocol.tick(first)
      {second, {:move, 3}} = Protocol.handle_ir(second, @low_id, move_frame, @high_id)

      assert byte_size(until_frame(second)) <= Frame.max_payload()
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
end
