defmodule Badge.Pong.MatchTest do
  use ExUnit.Case, async: true

  alias Badge.Pong.Match
  alias Badge.Pong.Wire

  @a <<0, 0, 0, 0, 0, 1>>
  @b <<0, 0, 0, 0, 0, 2>>
  @c <<0, 0, 0, 0, 0, 3>>

  # Steps both badges `ms` apart for `n` rounds, delivering every frame unless `drop?` says so.
  def play(a, b, now, n, opts \\ []) do
    drop? = Keyword.get(opts, :drop?, fn _payload -> false end)
    dir = Keyword.get(opts, :direction, 0)
    ms = Keyword.get(opts, :ms, 50)

    Enum.reduce(1..n, {a, b, now}, fn _, {a, b, now} ->
      now = now + ms
      {a, out_a} = Match.step(a, now, dir)
      {b, out_b} = Match.step(b, now, dir)
      b = deliver(b, @a, out_a, now, drop?)
      a = deliver(a, @b, out_b, now, drop?)
      {a, b, now}
    end)
  end

  def deliver(match, _from, nil, _now, _drop?), do: match

  def deliver(match, from, payload, now, drop?) do
    if drop?.(payload) do
      match
    else
      case Match.hear(match, from, payload, now) do
        {:ok, next} -> next
        :ignore -> match
      end
    end
  end

  def pair(coin_a \\ 0, coin_b \\ 0) do
    a = Match.new(@a, "Ana", coin_a, 0)
    b = Match.new(@b, "Bo", coin_b, 0)
    play(a, b, 0, 10)
  end

  describe "pairing" do
    test "starts searching, and says hello" do
      match = Match.new(@a, "Ana", 9, 0)

      assert match.phase == :searching
      assert {_match, payload} = Match.step(match, 200, 0)
      assert Wire.decode(payload) == {:ok, {:hello, 9, 0, "Ana"}}
    end

    test "two badges pair and both start the flip" do
      {a, b, _now} = pair()

      assert a.phase == :flipping
      assert b.phase == :flipping
      assert a.peer == @b and a.peer_name == "Bo"
      assert b.peer == @a and b.peer_name == "Ana"
    end

    test "a late joiner still pairs both" do
      a = Match.new(@a, "Ana", 0, 0)
      {a, _b, now} = play(a, Match.new(@b, "Bo", 0, 0), 0, 20, drop?: fn _ -> true end)
      assert a.phase == :searching

      {a, b, _now} = play(a, Match.new(@b, "Bo", 0, now), now, 10)
      assert a.phase == :flipping and b.phase == :flipping
    end

    test "its own frames are ignored" do
      match = Match.new(@a, "Ana", 0, 0)

      assert Match.hear(match, @a, Wire.encode({:hello, 0, 0, "Ana"}), 0) == :ignore
    end

    test "garbage is ignored" do
      match = Match.new(@a, "Ana", 0, 0)

      assert Match.hear(match, @b, "Gus", 0) == :ignore
      assert Match.hear(match, @b, <<0x50, 2, 1>>, 0) == :ignore
    end

    test "a stranger is ignored once paired" do
      {a, _b, _now} = pair()

      assert Match.hear(a, @c, Wire.encode({:hello, 0, 0, "Cy"}), 0) == :ignore
      assert Match.hear(a, @c, Wire.encode(:bye), 0) == :ignore
    end
  end

  # Two badges in a rally, with `a` holding a ball headed for the net.
  def rally do
    {a, b, now} = pair()
    ticks = div(Match.flip_ms() + Match.reveal_ms() + Match.countdown_ms(), 50) + 2
    {a, b, now} = play(a, b, now, ticks)

    case a.ball do
      nil -> {b, a, now, @b}
      _ball -> {a, b, now, @a}
    end
  end

  defp ball?(payload), do: match?({:ok, {:ball, _, _}}, Wire.decode(payload))

  describe "the handoff" do
    test "the ball crosses to the other badge, and only one badge holds it" do
      {server, other, now, _id} = rally()
      {server, other, _now} = play2(server, other, now, 45)

      assert server.ball == nil
      assert other.ball != nil
      assert other.ball.vy > 0
    end

    test "is sent before the ball leaves the screen" do
      {server, _other, _now, _id} = rally()

      assert server.ball.y > 0
      refute server.handed
    end

    test "survives dropped ball frames, and is applied once" do
      {server, other, now, _id} = rally()
      dropped = :counters.new(1, [])

      drop? = fn payload ->
        ball?(payload) and :counters.get(dropped, 1) < 3 and
          (:counters.add(dropped, 1, 1) || true)
      end

      {server, other, _now} = play2(server, other, now, 50, drop?: drop?)

      assert server.ball == nil
      assert other.ball != nil
      assert other.last_ball != nil
    end

    test "a repeated ball frame is acked again but not applied again" do
      {server, other, now, id} = rally()
      {server, other, now} = play2(server, other, now, 60)
      payload = Wire.encode({:ball, other.last_ball, %{d: 0, x: 0, vx: 0, vy: -40}})

      assert {:ok, again} = Match.hear(other, id, payload, now)
      assert again.ball == other.ball
      assert again.acks == other.acks ++ [other.last_ball]
      assert server.ball == nil
    end

    test "a ball parked in the gap enters at the top" do
      {server, other, now, _id} = rally()
      {server, _other, _now} = play2(server, other, now, 100, drop?: &ball?/1)

      assert Badge.Pong.Physics.px(server.ball.y) == -Badge.Pong.Physics.gap()
      assert server.out_ball != nil
    end

    test "a long stall moves the ball at most 100 ms" do
      {server, _other, now, _id} = rally()
      {moved, _payload} = Match.step(server, now + 1_000, 0)

      assert moved.ball.y != server.ball.y
      assert abs(moved.ball.y - server.ball.y) <= abs(server.ball.vy) * 100
    end

    test "a new ball from the peer clears a pending out_ball" do
      {server, _other, now, _id} = rally()
      match = %{server | out_ball: 1, ball: server.ball}
      wire = %{d: 0, x: 0, vx: 0, vy: 40}
      payload = Wire.encode({:ball, 7, wire})

      assert {:ok, result} = Match.hear(match, match.peer, payload, now)
      assert result.out_ball == nil
      assert result.ball == Badge.Pong.Physics.incoming(wire)
    end

    test "stepping with a lost ball and a stale out_ball sends no ball frame" do
      {server, _other, now, _id} = rally()
      match = %{server | out_ball: 1, ball: nil}

      {stepped, payload} = Match.step(match, now + 1_000, 0)

      assert stepped.ball == nil
      if payload, do: refute(ball?(payload))
    end
  end

  # play/5 with the server's id fixed as the first argument's sender.
  defp play2(server, other, now, n, opts \\ []) do
    if server.id == @a do
      play(server, other, now, n, opts)
    else
      {other, server, now} = play(other, server, now, n, opts)
      {server, other, now}
    end
  end

  describe "the coin flip" do
    test "both badges agree who serves" do
      for coin_a <- 0..3, coin_b <- 0..3 do
        {a, b, _now} = pair(coin_a, coin_b)

        assert {a.server, b.server} in [{:me, :them}, {:them, :me}]
      end
    end

    test "an even xor gives the serve to the lower chip id" do
      {a, _b, _now} = pair(4, 6)
      assert a.server == :me

      {a, _b, _now} = pair(4, 5)
      assert a.server == :them
    end

    test "lands, reveals, then counts down to the serve" do
      {a, b, now} = pair()
      ticks = div(Match.flip_ms() + Match.reveal_ms() + Match.countdown_ms(), 50) + 2
      {a, b, _now} = play(a, b, now, ticks)

      assert a.phase == :rally and b.phase == :rally
      server = if a.server == :me, do: a, else: b
      assert server.ball != nil
    end
  end

  # Steps `server` until its ball is missed, without the other badge.
  defp miss(match, now) do
    {match, _payload} =
      Match.step(%{match | paddle: 0, ball: %{match.ball | vy: 40, x: 300 * 256}}, now + 50, 0)

    if match.phase == :rally and match.ball != nil,
      do: miss(match, now + 50),
      else: {match, now + 50}
  end

  describe "a point" do
    test "the badge that missed tells the other, and both agree" do
      {server, other, now, _id} = rally()
      {server, now} = miss(server, now)

      assert server.them == 1
      assert server.phase == :serving
      assert server.server == :me

      {server, other, _now} = play2(server, other, now, 10)
      assert other.me == 1 and other.them == 0
      assert other.server == :them
      assert server.out_score == nil
    end

    test "the score survives dropped frames" do
      {server, other, now, _id} = rally()
      {server, now} = miss(server, now)
      score? = fn p -> match?({:ok, {:score, _, _, _}}, Wire.decode(p)) end
      {server, other, now} = play2(server, other, now, 10, drop?: score?)
      assert other.me == 0

      {_server, other, _now} = play2(server, other, now, 10)
      assert other.me == 1
    end

    test "the fifth point ends the match on both badges" do
      {server, other, now, _id} = rally()
      {server, now} = miss(%{server | them: Match.win() - 1}, now)
      {server, other, _now} = play2(server, other, now, 10)

      assert server.phase == :over and other.phase == :over
      assert other.me == Match.win()
    end

    test "conceding clears a pending out_ball, so the score frame goes next" do
      {server, _other, now, _id} = rally()
      pending = %{server | out_ball: 1}
      {conceded, now} = miss(pending, now)

      assert conceded.out_ball == nil

      assert {_match, payload} = Match.step(conceded, now + 200, 0)
      assert match?({:ok, {:score, _, _, _}}, Wire.decode(payload))
    end

    test "a late score doesn't strand the serve that followed it" do
      {a, b, now} = pair()
      {a, b, now} = play(a, b, now, 80)
      {server, other} = if a.server == :me, do: {a, b}, else: {b, a}

      {server, now} = miss(server, now)

      {x, y} = if server.id == @a, do: {server, other}, else: {other, server}
      {x, y, now} = play(x, y, now, 50, drop?: fn _ -> true end)
      {x, y, _now} = play(x, y, now, 200)

      holding = Enum.count([x, y], fn m -> m.ball != nil or m.out_ball != nil end)
      assert holding == 1
      refute x.phase == :rally and x.ball == nil and y.phase == :rally and y.ball == nil
      assert x.me == y.them and x.them == y.me
    end
  end

  describe "the keepalive" do
    test "a paired badge with nothing else to send emits a ping after 250 ms idle" do
      {a, _b, now} = pair()
      assert a.phase == :flipping

      {stepped, payload} = Match.step(a, now + 300, 0)

      assert Wire.decode(payload) == {:ok, :ping}
      assert stepped.phase == :flipping
    end

    test "a pairing badge that hears a ping from its already-flipped peer flips too" do
      a = Match.new(@a, "Ana", 0, 0)
      b = Match.new(@b, "Bo", 0, 0)

      # both say their first, ready-0 hello and learn of each other
      {a, out_a} = Match.step(a, 10, 0)
      {b, out_b} = Match.step(b, 10, 0)
      {:ok, a} = Match.hear(a, @b, out_b, 10)
      {:ok, b} = Match.hear(b, @a, out_a, 10)
      assert a.phase == :pairing and b.phase == :pairing

      # b hears a's ready-1 hello and flips; a's copy of b's is dropped, so a stays put
      {b, _out_b2} = Match.step(b, 220, 0)
      {a, out_a2} = Match.step(a, 220, 0)
      {:ok, b} = Match.hear(b, @a, out_a2, 220)
      assert b.phase == :flipping
      assert a.phase == :pairing

      # b now sends pings instead of hellos; a hears one and flips too
      {b, ping} = Match.step(b, 470, 0)
      assert Wire.decode(ping) == {:ok, :ping}

      assert {:ok, flipped} = Match.hear(a, @b, ping, 470)
      assert flipped.phase == :flipping
      assert {flipped.server, b.server} in [{:me, :them}, {:them, :me}]
    end
  end

  describe "the link" do
    test "is not lost 1 s after the peer's last frame, but is 1.3 s after" do
      {server, _other, now, _id} = rally()

      {early, _payload} = Match.step(server, now + 1_000, 0)
      refute early.lost

      {late, _payload} = Match.step(server, now + 1_300, 0)
      assert late.lost
    end

    test "is lost after 1.2 s without a frame, and the ball stops" do
      {server, other, now, _id} = rally()
      {server, _other, _now} = play2(server, other, now, 30, drop?: fn _ -> true end)

      assert server.lost
      {still, _payload} = Match.step(server, server.clock + 50, 0)
      assert still.ball == server.ball
    end

    test "comes back when frames do" do
      {server, other, now, _id} = rally()
      {server, other, now} = play2(server, other, now, 70, drop?: fn _ -> true end)
      {server, _other, _now} = play2(server, other, now, 5)

      refute server.lost
    end

    test "a bye means the opponent left" do
      {a, _b, _now} = pair()
      assert {:ok, %{phase: :left}} = Match.hear(a, @b, Wire.encode(:bye), 0)
    end

    test "a searching hello from the peer restarts the match" do
      {server, other, now, id} = rally()
      {server, now} = miss(server, now)
      {_server, other, now} = play2(server, other, now, 10)
      assert other.me == 1

      assert {:ok, restarted} = Match.hear(other, id, Wire.encode({:hello, 3, 0, "Ana"}), now)
      assert restarted.phase == :pairing
      assert {restarted.me, restarted.them} == {0, 0}
      assert restarted.peer == id
    end

    test "a reopened badge with a new coin restarts a stale peer" do
      {a, b, now} = pair()
      {_a, b, now} = play(a, b, now, 80)
      b = %{b | phase: :over}

      a = Match.new(@a, "Ana", 7, now)
      searching? = fn p -> match?({:ok, {:hello, _, 0, _}}, Wire.decode(p)) end
      {a, b, now} = play(a, b, now, 40, drop?: searching?)
      {a, b, _now} = play(a, b, now, 400)

      assert a.phase in [:flipping, :revealing, :serving, :rally]
      assert b.phase in [:flipping, :revealing, :serving, :rally]
      assert a.ball != nil or b.ball != nil
    end
  end
end
