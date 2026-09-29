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
end
