defmodule Badge.Page.PongTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Pong, as: Page
  alias Badge.Pages
  alias Badge.Pong.Match
  alias Badge.Pong.Wire

  @me <<0, 0, 0, 0, 0, 1>>
  @peer <<0, 0, 0, 0, 0, 2>>

  defp loaded(overrides \\ %{}) do
    match = Map.merge(Match.new(@me, "Ana", 0, 0), overrides)
    %{Page.init() | match: match, seen: match}
  end

  defp texts(state), do: for({:text, _x, _y, _f, _c, _b, body} <- Page.render(state), do: body)
  defp says?(state, text), do: Enum.any?(texts(state), &(:binary.match(&1, text) != :nomatch))

  test "is on the home grid" do
    assert :lists.member(Page, Pages.all())
    assert Page.title() == "Pong"
  end

  test "asks for 50 ms frames" do
    assert Page.refresh(Page.init()) == 50
  end

  describe "direction/1" do
    test "left keys go left, right keys go right" do
      assert Page.direction([~c"Q"]) == -1
      assert Page.direction([~c"C"]) == -1
      assert Page.direction([~c"P"]) == 1
      assert Page.direction([~c"B"]) == 1
    end

    test "both or neither stay put, and other keys do nothing" do
      assert Page.direction([]) == 0
      assert Page.direction([~c"Q", ~c"P"]) == 0
      assert Page.direction([~c"T", ~c"LShift"]) == 0
    end
  end

  describe "held keys" do
    test "arrive from the keyboard watch" do
      assert {:ok, %{held: [~c"Q"]}} = Page.handle_info({:held, [~c"Q"]}, loaded())
    end

    test "anything else is ignored" do
      assert Page.handle_info(:whatever, loaded()) == :ignore
    end
  end

  describe "the beam" do
    test "nothing is heard before the first tick" do
      assert Page.handle_ir(@peer, Wire.encode({:hello, 0, 0, "Bo"}), Page.init()) == :ignore
    end

    test "a hello pairs" do
      assert {:ok, state} = Page.handle_ir(@peer, Wire.encode({:hello, 0, 0, "Bo"}), loaded())
      assert state.match.phase == :pairing
    end

    test "garbage is ignored" do
      assert Page.handle_ir(@peer, "noise", loaded()) == :ignore
    end
  end

  describe "keys" do
    test "are left alone, so escape still leaves" do
      assert Page.handle_key({:nav, :home}, loaded()) == :ignore
      assert Page.handle_key({:char, ?q}, loaded()) == :ignore
    end
  end

  describe "the screen" do
    test "waits for an opponent" do
      assert says?(loaded(), "Waiting for opponent")
    end

    test "names the server once the coin lands" do
      state = loaded(%{phase: :revealing, server: :them, peer_name: "Bo", peer: @peer})

      assert says?(state, "Bo serves")
    end

    test "draws a spinning coin" do
      state = loaded(%{phase: :flipping, server: :me, peer: @peer})

      assert Enum.any?(Page.render(state), &match?({:rect, _, _, _, _, _}, &1))
    end

    test "counts down to the serve" do
      state = %{loaded(%{phase: :serving, since: 0, peer: @peer}) | now: 0}

      assert says?(state, "3")
    end

    test "shows the score in a rally" do
      state = loaded(%{phase: :rally, me: 2, them: 1, peer: @peer})

      assert says?(state, "2 - 1")
    end

    test "says who won" do
      assert says?(loaded(%{phase: :over, me: 5, them: 3}), "You win")
      assert says?(loaded(%{phase: :over, me: 1, them: 5}), "You lose")
    end

    test "says when the link is lost and when the opponent left" do
      assert says?(loaded(%{phase: :rally, lost: true, peer: @peer}), "Link lost")
      assert says?(loaded(%{phase: :left}), "Opponent left")
    end

    test "draws a ball only while it is on this screen" do
      rally = %{phase: :rally, peer: @peer}
      on = loaded(Map.put(rally, :ball, %{x: 100 * 256, y: 50 * 256, vx: 0, vy: 40}))
      off = loaded(Map.put(rally, :ball, %{x: 100 * 256, y: -50 * 256, vx: 0, vy: 40}))

      assert length(Page.render(on)) == length(Page.render(off)) + 1
    end
  end

  describe "awake?/1" do
    test "keeps the screen on in a match, not while waiting" do
      assert Page.awake?(loaded(%{phase: :rally}))
      refute Page.awake?(loaded())
      refute Page.awake?(Page.init())
    end
  end
end
