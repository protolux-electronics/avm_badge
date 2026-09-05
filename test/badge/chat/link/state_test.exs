defmodule Badge.Chat.Link.StateTest do
  use ExUnit.Case, async: true

  alias Badge.Chat.Link.State

  @rooms "rooms:badge"

  defp new, do: State.new("wss://example.test")

  defp reply(ref, status, response) do
    %{
      join_ref: nil,
      ref: ref,
      topic: @rooms,
      event: "phx_reply",
      payload: %{"status" => status, "response" => response}
    }
  end

  defp push_frame(topic, event, payload) do
    %{join_ref: nil, ref: nil, topic: topic, event: event, payload: payload}
  end

  defp rooms_join([{join_ref, ref, @rooms, "phx_join", _payload} | _rest]), do: {join_ref, ref}

  describe "coming up" do
    test "a fresh state has joined nothing and knows nothing" do
      status = State.status(new())

      assert status.rooms == []
      assert status.room == nil
      assert status.ready == false
      assert status.banned == false
      assert status.host == "wss://example.test"
    end

    test "a connected socket joins the rooms channel" do
      {_state, frames} = State.connected(new())

      assert [{_join_ref, _ref, @rooms, "phx_join", %{}}] = frames
    end

    test "the join reply carries the room list" do
      {state, frames} = State.connected(new())
      {_join_ref, ref} = rooms_join(frames)

      {state, []} =
        State.received(
          state,
          reply(ref, "ok", %{
            "banned" => false,
            "rooms" => [
              %{"slug" => "lobby", "name" => "Lobby"},
              %{"slug" => "goats", "name" => "Goats"}
            ]
          })
        )

      status = State.status(state)

      assert status.ready
      assert status.rooms == [%{slug: "lobby", name: "Lobby"}, %{slug: "goats", name: "Goats"}]
    end

    test "a ban arrives instead of a room list" do
      {state, frames} = State.connected(new())
      {_join_ref, ref} = rooms_join(frames)

      {state, []} =
        State.received(state, reply(ref, "ok", %{"banned" => true, "reason" => "spam"}))

      status = State.status(state)

      assert status.banned
      assert status.ban_reason == "spam"
      assert status.rooms == []
    end

    test "a ban with no reason still reads as banned" do
      {state, frames} = State.connected(new())
      {_join_ref, ref} = rooms_join(frames)

      {state, []} = State.received(state, reply(ref, "ok", %{"banned" => true}))

      assert State.status(state).banned
    end

    test "a refused join leaves the channel out" do
      {state, frames} = State.connected(new())
      {_join_ref, ref} = rooms_join(frames)

      {state, []} = State.received(state, reply(ref, "error", %{}))

      refute State.status(state).ready
    end

    test "a dropped socket forgets the rooms channel and rejoins on the next connect" do
      {state, frames} = State.connected(new())
      {_join_ref, ref} = rooms_join(frames)
      {state, []} = State.received(state, reply(ref, "ok", %{"banned" => false, "rooms" => []}))

      {state, []} = State.disconnected(state)
      refute State.status(state).ready

      {_state, frames} = State.connected(state)
      assert [{_jr, _r, @rooms, "phx_join", %{}}] = frames
    end

    test "each join gets its own join_ref" do
      {state, first} = State.connected(new())
      {state, []} = State.disconnected(state)
      {_state, second} = State.connected(state)

      {first_join_ref, _ref} = rooms_join(first)
      {second_join_ref, _ref} = rooms_join(second)

      refute first_join_ref == second_join_ref
    end
  end

  describe "activity" do
    defp ready do
      {state, frames} = State.connected(new())
      {_join_ref, ref} = rooms_join(frames)

      {state, []} =
        State.received(
          state,
          reply(ref, "ok", %{
            "banned" => false,
            "rooms" => [%{"slug" => "lobby", "name" => "Lobby"}, %{"slug" => "goats", "name" => "Goats"}]
          })
        )

      state
    end

    test "counts a message in a room it is not in" do
      {state, []} = State.received(ready(), push_frame(@rooms, "activity", %{"slug" => "goats"}))
      {state, []} = State.received(state, push_frame(@rooms, "activity", %{"slug" => "goats"}))

      assert State.status(state).unread == %{"goats" => 2}
    end

    test "ignores activity with no slug" do
      {state, []} = State.received(ready(), push_frame(@rooms, "activity", %{}))

      assert State.status(state).unread == %{}
    end

    test "a pushed room list replaces the one it has" do
      {state, []} =
        State.received(
          ready(),
          push_frame(@rooms, "rooms", %{"rooms" => [%{"slug" => "goats", "name" => "Goats"}]})
        )

      assert State.status(state).rooms == [%{slug: "goats", name: "Goats"}]
    end

    test "a malformed room list is ignored rather than emptying the rail" do
      {state, []} = State.received(ready(), push_frame(@rooms, "rooms", %{"rooms" => "nonsense"}))

      assert length(State.status(state).rooms) == 2
    end
  end
end
