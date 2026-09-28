defmodule Badge.Page.Chat.RoomsTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Chat.Rooms
  alias Badge.Theme

  defp status(overrides) do
    Map.merge(
      %{
        state: :out,
        ready: true,
        rooms: [
          %{slug: "lobby", name: "Lobby", description: "Where it all begins."},
          %{slug: "goats", name: "Goats", description: ""}
        ],
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

  defp downs(state, n), do: :lists.foldl(fn _i, acc -> press(acc, {:move, :down}) end, state, :lists.seq(1, n))
  defp ups(state, n), do: :lists.foldl(fn _i, acc -> press(acc, {:move, :up}) end, state, :lists.seq(1, n))

  defp many_rooms(n) do
    for i <- 0..(n - 1) do
      digits = :erlang.integer_to_binary(i)
      %{slug: "room" <> digits, name: "Room " <> digits, description: ""}
    end
  end

  # Below the description's two lines, whatever is above it.
  defp desc_top, do: Theme.height() - 2 * 20

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

  describe "heading" do
    test "names the page above the list" do
      assert Enum.member?(texts(listed()), "ROOMS")
    end
  end

  describe "the caret gap" do
    test "leaves a blank column between the marker and the name" do
      [marker_x] =
        for {:text, x, _y, _f, colour, _b, ">"} <- Rooms.render(listed()), colour == Theme.select(), do: x

      [name_x | _] = for {:text, x, _y, _f, _c, _b, "Lobby"} <- Rooms.render(listed()), do: x

      assert name_x - marker_x == 8
    end
  end

  describe "the description footer" do
    test "shows the selected room's description" do
      assert Enum.member?(texts(listed()), "Where it all begins.")
    end

    test "follows the selection to the next room" do
      state = press(listed(), {:move, :down})

      refute Enum.member?(texts(state), "Where it all begins.")
    end

    test "an empty description leaves the footer blank" do
      state = press(listed(), {:move, :down})

      refute Enum.any?(Rooms.render(state), fn
               {:text, _x, y, _f, _c, _b, _body} -> y >= desc_top()
               _other -> false
             end)
    end

    test "wraps onto at most two lines" do
      long = String.duplicate("word ", 30) |> String.trim_trailing()

      state =
        listed(%{
          rooms: [%{slug: "lobby", name: "Lobby", description: long}]
        })

      lines = for {:text, _x, y, _f, _c, _b, body} <- Rooms.render(state), y >= desc_top(), do: body

      assert length(lines) == 2
    end

    test "no rooms means no description either" do
      refute Enum.any?(Rooms.render(listed(%{rooms: []})), fn
               {:text, _x, y, _f, _c, _b, _body} -> y >= desc_top()
               _other -> false
             end)
    end
  end

  describe "scrolling a long list" do
    test "the selection is always among the drawn rows while scrolling down" do
      state = listed(%{rooms: many_rooms(20), unread: %{}})

      :lists.foldl(
        fn _i, acc ->
          next = press(acc, {:move, :down})
          %{name: name} = :lists.nth(next.selected + 1, next.rooms)

          assert Enum.member?(texts(next), name)

          next
        end,
        state,
        :lists.seq(1, 19)
      )
    end

    test "moving past the bottom scrolls the window" do
      state = listed(%{rooms: many_rooms(20), unread: %{}}) |> downs(19)

      assert state.selected == 19
      assert state.offset > 0
    end

    test "moving back up scrolls the window back" do
      state = listed(%{rooms: many_rooms(20), unread: %{}}) |> downs(19) |> ups(19)

      assert state.selected == 0
      assert state.offset == 0
    end

    test "the selection is always among the drawn rows on the way back up" do
      bottom = listed(%{rooms: many_rooms(20), unread: %{}}) |> downs(19)

      :lists.foldl(
        fn _i, acc ->
          next = press(acc, {:move, :up})
          %{name: name} = :lists.nth(next.selected + 1, next.rooms)

          assert Enum.member?(texts(next), name)

          next
        end,
        bottom,
        :lists.seq(1, 19)
      )
    end
  end
end
