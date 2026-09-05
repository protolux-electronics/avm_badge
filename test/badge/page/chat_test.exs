defmodule Badge.Page.ChatTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Chat

  defp status(overrides) do
    Map.merge(
      %{
        state: :out,
        ready: true,
        rooms: [%{slug: "lobby", name: "Lobby"}, %{slug: "goats", name: "Goats"}],
        room: nil,
        unread: %{},
        banned: false,
        ban_reason: "",
        messages: [],
        heard: 0,
        refused: nil,
        host: "wss://example.test"
      },
      overrides
    )
  end

  # loaded: true skips the profile read, which needs hardware absent on host.
  defp shown(overrides \\ %{}) do
    init = Chat.init()
    Chat.apply_status(status(overrides), %{init | room: %{init.room | loaded: true}})
  end

  describe "identity" do
    test "announces itself for the home grid" do
      assert Chat.title() == "Chat"
      assert Chat.icon() == :triangle
    end

    test "repaints slowly, since a frame is a whole panel" do
      assert Chat.refresh(Chat.init()) == 333
    end
  end

  describe "which screen" do
    test "with no room entered it shows the list" do
      assert Chat.view(shown()) == :rooms
    end

    test "with a room entered it shows the room" do
      assert Chat.view(shown(%{room: "lobby", state: :joined})) == :room
    end

    test "a ban beats both" do
      assert Chat.view(shown(%{banned: true, ban_reason: "spam", room: "lobby"})) == :banned
    end

    test "the ban notice is what gets drawn" do
      texts =
        for {:text, _x, _y, _f, _c, _b, body} <-
              Chat.render(shown(%{banned: true, ban_reason: "spam"})),
            do: body

      assert Enum.member?(texts, "BANNED")
    end
  end

  describe "keys" do
    test "moves reach the room list" do
      state = shown()
      {:ok, moved} = Chat.handle_key({:move, :down}, state)

      refute moved == state
    end

    test "Esc on the list is left for the router, so it goes Home" do
      assert Chat.handle_key({:nav, :home}, shown()) == :ignore
    end

    test "Esc in a room pops back to the list without going Home" do
      state = shown(%{room: "lobby", state: :joined})

      assert {:ok, popped} = Chat.handle_key({:nav, :home}, state)
      assert Chat.view(popped) == :rooms
    end

    test "Esc in the ban notice is left for the router" do
      assert Chat.handle_key({:nav, :home}, shown(%{banned: true})) == :ignore
    end

    test "typing in a room reaches the draft, not the list" do
      state = shown(%{room: "lobby", state: :joined})

      assert {:ok, typed} = Chat.handle_key({:char, ?a}, state)
      refute typed == state
    end
  end
end
