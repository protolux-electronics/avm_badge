defmodule Badge.Page.ConnectFourTest do
  use ExUnit.Case, async: true

  alias Badge.ConnectFour.Board
  alias Badge.ConnectFour.Protocol
  alias Badge.Page.ConnectFour

  @peer <<2, 2, 2, 2, 2, 2>>

  defp playing(player),
    do: %{
      ConnectFour.init()
      | link: %{Protocol.new() | phase: :playing, player: player},
        screen: :game
    }

  describe "handle_key/2" do
    test "Esc stays unclaimed on every screen, so the home grid is always reachable" do
      assert ConnectFour.handle_key({:nav, :home}, ConnectFour.init()) == :ignore
      assert ConnectFour.handle_key({:nav, :home}, playing(0)) == :ignore
      assert ConnectFour.handle_key({:nav, :home}, %{playing(0) | screen: :over}) == :ignore
    end

    test "a shape key is claimed while pairing, rather than switching apps" do
      assert {:ok, _state} = ConnectFour.handle_key({:nav, :square}, ConnectFour.init())
    end

    test "a shape key is claimed once the game is over, rather than switching apps" do
      state = %{playing(0) | screen: :over}

      assert {:ok, ^state} = ConnectFour.handle_key({:nav, :square}, state)
    end

    test "a shape key is claimed on the opponent's turn, rather than switching apps" do
      state = playing(1)

      assert {:ok, ^state} = ConnectFour.handle_key({:nav, :square}, state)
    end

    test "a shape key drops a disc on this player's turn" do
      state = playing(0)

      assert {:ok, next} = ConnectFour.handle_key({:nav, :square}, state)
      assert next != state
    end
  end

  describe "handle_ir/3" do
    # The mover goes quiet on HELLO once it moves, so the opponent's MOVE is
    # what has to open the board; waiting for a HELLO would hang on "hold
    # badges together" with the other badge beaming at us the whole time.
    test "the opponent's first MOVE opens the board, not just a HELLO" do
      pairing = %{ConnectFour.init() | own_id: <<2, 2, 2, 2, 2, 2>>}

      assert {:ok, state} = ConnectFour.handle_ir(<<1, 1, 1, 1, 1, 1>>, <<1, 0, 3>>, pairing)
      assert state.screen == :game
      assert state.link.player == 1
      assert Map.get(state.board.cells, {3, 0}) == 0
    end

    # The opponent could only have moved after applying ours, so their move
    # confirms our disc even when our own ACK never reached them.
    test "the opponent's next MOVE confirms our pending disc, ack or no ack" do
      {:ok, dropped} = ConnectFour.handle_key({:nav, :square}, playing(0))
      dropped = %{dropped | own_id: <<1, 1, 1, 1, 1, 1>>, link: %{dropped.link | peer: @peer}}

      assert dropped.pending == {0, 0}

      assert {:ok, state} = ConnectFour.handle_ir(@peer, <<1, 1, 4>>, dropped)
      assert state.pending == nil
      assert Map.get(state.board.cells, {4, 0}) == 1
    end
  end

  describe "render/1 while pairing" do
    test "leads with the badge-share artwork, centred and on screen" do
      items = ConnectFour.render(ConnectFour.init())
      {art_w, art_h} = Badge.Icons.size(:badge_share)

      assert [{:image, x, y, _bg, {:rgba8888, ^art_w, ^art_h, _data}}] =
               for({:image, _x, _y, _bg, _payload} = item <- items, do: item)

      assert x == div(Badge.Theme.width() - art_w, 2)
      assert y + art_h <= Badge.Theme.height()
    end

    test "the caption clears the artwork rather than drawing over it" do
      items = ConnectFour.render(ConnectFour.init())
      {_art_w, art_h} = Badge.Icons.size(:badge_share)

      [{:image, _x, art_y, _bg, _payload}] =
        for {:image, _x, _y, _bg, _payload} = item <- items, do: item

      captions = for {:text, _x, y, _font, _fg, _bg, text} <- items, do: {y, text}

      assert Enum.any?(captions, fn {y, text} ->
               text == "hold badges together" and y >= art_y + art_h
             end)
    end
  end

  describe "render/1" do
    # The discs are the game's identity, not the skin's, so they are fixed
    # here as they are in the workshop's renderers. These are the values in
    # priv/static/main.mjs: Tailwind amber-400, red-500 and zinc-700.
    test "disc colours match the workshop's web client rather than the skin" do
      {:ok, _cell, board} = Board.drop(Board.new(), 0, 0)
      {:ok, _cell, board} = Board.drop(board, 1, 1)

      colours =
        for {:rect, _x, _y, 20, 20, colour} <- ConnectFour.render(%{playing(0) | board: board}),
            do: colour

      assert 0xFBBF24 in colours
      assert 0xEF4444 in colours
      assert 0x3F3F46 in colours
    end

    test "a move renders smaller and centred until it is acked" do
      {:ok, dropped} = ConnectFour.handle_key({:nav, :square}, playing(0))

      assert dropped.pending == {0, 0}

      pending_sized =
        for {:rect, _x, _y, 10, 10, _colour} <- ConnectFour.render(dropped), do: :disc

      assert pending_sized == [:disc]
    end

    test "acking the move clears pending, back to a full-size disc" do
      {:ok, dropped} = ConnectFour.handle_key({:nav, :square}, playing(0))

      acked = %{dropped | link: %{dropped.link | outgoing: nil}, own_id: <<0, 0, 0, 0, 0, 0>>}
      assert {:ok, next} = ConnectFour.handle_ir(<<0, 0, 0, 0, 0, 0>>, <<>>, acked)

      assert next.pending == nil

      pending_sized =
        for {:rect, _x, _y, 10, 10, _colour} <- ConnectFour.render(next), do: :disc

      assert pending_sized == []
    end
  end
end
