defmodule Badge.Page.Chat.RoomsTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Chat.Rooms
  alias Badge.Theme

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

  defp listed(overrides \\ %{}), do: Rooms.apply_status(status(overrides), Rooms.init())

  defp press(state, event) do
    {:ok, next} = Rooms.handle_key(event, state)

    next
  end

  defp texts(state), do: for({:text, _x, _y, _f, _c, _b, body} <- Rooms.render(state), do: body)

  defp marked(state) do
    for {:text, _x, _y, _f, colour, _b, body} <- Rooms.render(state),
        colour == Theme.select(),
        do: body
  end

  describe "the list" do
    test "draws every room it was given" do
      texts = texts(listed())

      assert Enum.member?(texts, "Lobby")
      assert Enum.member?(texts, "Goats")
    end

    test "the first room starts selected" do
      assert Rooms.selected(listed()) == "lobby"
    end

    test "down moves the selection and up moves it back" do
      state = press(listed(), {:move, :down})
      assert Rooms.selected(state) == "goats"

      assert Rooms.selected(press(state, {:move, :up})) == "lobby"
    end

    test "the selection stops at the ends rather than wrapping" do
      state = listed() |> press({:move, :down}) |> press({:move, :down})
      assert Rooms.selected(state) == "goats"

      assert Rooms.selected(press(listed(), {:move, :up})) == "lobby"
    end

    test "the selected room is the one marked" do
      assert Enum.member?(marked(listed()), ">")
    end

    test "a shorter list pulls the selection back inside it" do
      state = press(listed(), {:move, :down})

      state = Rooms.apply_status(status(%{rooms: [%{slug: "lobby", name: "Lobby"}]}), state)

      assert Rooms.selected(state) == "lobby"
    end

    test "anything that is not a move is left for the container" do
      assert Rooms.handle_key({:edit, :newline}, listed()) == :ignore
      assert Rooms.handle_key({:char, ?a}, listed()) == :ignore
      assert Rooms.handle_key({:nav, :home}, listed()) == :ignore
    end
  end

  describe "unread" do
    test "a room with unread lines carries the count" do
      texts = texts(listed(%{unread: %{"goats" => 3}}))

      assert Enum.member?(texts, "3")
    end

    test "a room with none carries no digit" do
      refute Enum.member?(texts(listed()), "0")
    end
  end

  describe "empty and waiting" do
    test "no rooms says so" do
      assert Enum.member?(texts(listed(%{rooms: []})), "No rooms")
      assert Rooms.selected(listed(%{rooms: []})) == nil
    end

    test "before the list lands it says it is connecting" do
      state = Rooms.apply_status(status(%{rooms: [], ready: false}), Rooms.init())

      assert Enum.member?(texts(state), "connecting")
    end

    test "moving in an empty list is left for the container" do
      assert Rooms.handle_key({:move, :down}, listed(%{rooms: []})) == :ignore
    end
  end
end
