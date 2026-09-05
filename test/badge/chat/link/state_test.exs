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

      assert status.rooms == [
               %{slug: "lobby", name: "Lobby", description: ""},
               %{slug: "goats", name: "Goats", description: ""}
             ]
    end

    test "the join reply carries each room's description" do
      {state, frames} = State.connected(new())
      {_join_ref, ref} = rooms_join(frames)

      {state, []} =
        State.received(
          state,
          reply(ref, "ok", %{
            "banned" => false,
            "rooms" => [
              %{"slug" => "lobby", "name" => "Lobby", "description" => "Bring your badge"},
              %{"slug" => "goats", "name" => "Goats", "description" => :null}
            ]
          })
        )

      status = State.status(state)

      assert status.rooms == [
               %{slug: "lobby", name: "Lobby", description: "Bring your badge"},
               %{slug: "goats", name: "Goats", description: ""}
             ]
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

    test "a drop clears any outstanding pending refs" do
      {state, frames} = State.connected(new())
      {_join_ref, _ref} = rooms_join(frames)
      assert map_size(state.pending) > 0

      {state, []} = State.disconnected(state)

      assert state.pending == %{}
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

      assert State.status(state).rooms == [%{slug: "goats", name: "Goats", description: ""}]
    end

    test "a malformed room list is ignored rather than emptying the rail" do
      {state, []} = State.received(ready(), push_frame(@rooms, "rooms", %{"rooms" => "nonsense"}))

      assert length(State.status(state).rooms) == 2
    end
  end

  describe "rooms" do
    defp in_lobby do
      {state, frames} = State.connected(new())
      {_join_ref, ref} = rooms_join(frames)

      {state, []} =
        State.received(
          state,
          reply(ref, "ok", %{
            "banned" => false,
            "rooms" => [%{"slug" => "lobby", "name" => "Lobby"}]
          })
        )

      state = State.identify(state, "90DA7247F828")
      {state, [{_jr, join_ref_ref, "chat:lobby", "phx_join", %{}}]} = State.enter(state, "lobby")

      {state, join_ref_ref}
    end

    defp room_reply(ref, status, response) do
      %{
        join_ref: nil,
        ref: ref,
        topic: "chat:lobby",
        event: "phx_reply",
        payload: %{"status" => status, "response" => response}
      }
    end

    test "entering a room joins its topic" do
      {state, _ref} = in_lobby()

      assert State.status(state).room == "lobby"
      assert State.status(state).state == :joining
    end

    test "entering clears that room's unread" do
      {state, frames} = State.connected(new())
      {_join_ref, ref} = rooms_join(frames)

      {state, []} =
        State.received(
          state,
          reply(ref, "ok", %{"banned" => false, "rooms" => [%{"slug" => "lobby", "name" => "Lobby"}]})
        )

      {state, []} = State.received(state, push_frame(@rooms, "activity", %{"slug" => "lobby"}))
      assert State.status(state).unread == %{"lobby" => 1}

      {state, _frames} = State.enter(state, "lobby")
      assert State.status(state).unread == %{}
    end

    test "the join reply's history becomes the messages, newest first" do
      {state, ref} = in_lobby()

      {state, []} =
        State.received(
          state,
          room_reply(ref, "ok", %{
            "messages" => [
              %{"chip" => "90DA7247F828", "from" => "Gus", "body" => "two"},
              %{"chip" => "AAAAAAAAAAAA", "from" => "Ana", "body" => "one"}
            ]
          })
        )

      status = State.status(state)

      assert status.state == :joined
      assert for(m <- status.messages, do: m.body) == ["two", "one"]
      assert for(m <- status.messages, do: m.mine) == [true, false]
    end

    test "a refused room join says why" do
      {state, ref} = in_lobby()

      {state, []} = State.received(state, room_reply(ref, "error", %{"reason" => "banned"}))

      assert State.status(state).state == :out
    end

    test "a new message is prepended and counted" do
      {state, ref} = in_lobby()
      {state, []} = State.received(state, room_reply(ref, "ok", %{"messages" => []}))

      {state, []} =
        State.received(state, %{
          join_ref: nil,
          ref: nil,
          topic: "chat:lobby",
          event: "new_msg",
          payload: %{"chip" => "AAAAAAAAAAAA", "from" => "Ana", "body" => "hi"}
        })

      status = State.status(state)

      assert [%{from: "Ana", body: "hi", mine: false}] = status.messages
      assert status.heard == 1
    end

    test "a message in a room it is not in is not taken" do
      {state, ref} = in_lobby()
      {state, []} = State.received(state, room_reply(ref, "ok", %{"messages" => []}))

      {state, []} =
        State.received(state, %{
          join_ref: nil,
          ref: nil,
          topic: "chat:goats",
          event: "new_msg",
          payload: %{"chip" => "AAAAAAAAAAAA", "from" => "Ana", "body" => "elsewhere"}
        })

      assert State.status(state).messages == []
    end

    test "leaving a room sends phx_leave and drops the messages" do
      {state, ref} = in_lobby()

      {state, []} =
        State.received(state, room_reply(ref, "ok", %{"messages" => [%{"from" => "Ana", "body" => "hi"}]}))

      {state, frames} = State.leave_room(state)

      assert [{_jr, _r, "chat:lobby", "phx_leave", %{}}] = frames
      assert State.status(state).room == nil
      assert State.status(state).messages == []
    end

    test "entering another room leaves the first" do
      {state, ref} = in_lobby()
      {state, []} = State.received(state, room_reply(ref, "ok", %{"messages" => []}))

      {_state, frames} = State.enter(state, "goats")

      assert [
               {_lr, _lref, "chat:lobby", "phx_leave", %{}},
               {_jr, _jref, "chat:goats", "phx_join", %{}}
             ] = frames
    end

    test "a stale join reply for a room already left is discarded" do
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

      state = State.identify(state, "chip")
      {state, [{_jr1, lobby_ref, "chat:lobby", "phx_join", %{}}]} = State.enter(state, "lobby")

      {state, [_leave, {_jr2, _goats_ref, "chat:goats", "phx_join", %{}}]} = State.enter(state, "goats")

      {state, []} =
        State.received(state, room_reply(lobby_ref, "ok", %{"messages" => [%{"from" => "Ana", "body" => "hi"}]}))

      status = State.status(state)

      assert status.room == "goats"
      assert status.messages == []
      refute status.state == :joined
    end

    test "a room archived out from under you pops you back to the list" do
      {state, ref} = in_lobby()
      {state, []} = State.received(state, room_reply(ref, "ok", %{"messages" => []}))

      {state, frames} =
        State.received(state, push_frame(@rooms, "rooms", %{"rooms" => []}))

      assert [{_jr, _r, "chat:lobby", "phx_leave", %{}}] = frames
      assert State.status(state).room == nil
    end
  end

  describe "channel errors" do
    defp channel_frame(topic, event), do: %{join_ref: nil, ref: nil, topic: topic, event: event, payload: %{}}

    test "phx_error on the room channel rejoins it" do
      {state, ref} = in_lobby()
      {state, []} = State.received(state, room_reply(ref, "ok", %{"messages" => []}))

      {state, frames} = State.received(state, channel_frame("chat:lobby", "phx_error"))

      assert [{_jr, _r, "chat:lobby", "phx_join", %{}}] = frames
      refute State.status(state).state == :joined
    end

    test "phx_close on the room channel rejoins it" do
      {state, ref} = in_lobby()
      {state, []} = State.received(state, room_reply(ref, "ok", %{"messages" => []}))

      {state, frames} = State.received(state, channel_frame("chat:lobby", "phx_close"))

      assert [{_jr, _r, "chat:lobby", "phx_join", %{}}] = frames
      refute State.status(state).state == :joined
    end

    test "phx_error on the rooms channel rejoins it and clears ready" do
      state = ready()

      {state, frames} = State.received(state, channel_frame(@rooms, "phx_error"))

      assert [{_jr, _r, @rooms, "phx_join", %{}}] = frames
      refute State.status(state).ready
    end

    test "phx_close on the rooms channel rejoins it and clears ready" do
      state = ready()

      {state, frames} = State.received(state, channel_frame(@rooms, "phx_close"))

      assert [{_jr, _r, @rooms, "phx_join", %{}}] = frames
      refute State.status(state).ready
    end

    test "an unrelated topic is undisturbed by phx_error" do
      {state, ref} = in_lobby()
      {state, []} = State.received(state, room_reply(ref, "ok", %{"messages" => []}))

      {next, frames} = State.received(state, channel_frame("chat:goats", "phx_error"))

      assert frames == []
      assert next == state
    end
  end

  describe "posting" do
    test "a refused post says which refusal it was" do
      {state, ref} = in_lobby()
      {state, []} = State.received(state, room_reply(ref, "ok", %{"messages" => []}))

      {state, [{_jr, say_ref, "chat:lobby", "new_msg", %{"body" => "hi"}}]} =
        State.say(state, "hi")

      {state, []} = State.received(state, room_reply(say_ref, "error", %{"reason" => "banned"}))

      assert State.status(state).refused == :banned
    end

    test "an accepted post clears a previous refusal" do
      {state, ref} = in_lobby()
      {state, []} = State.received(state, room_reply(ref, "ok", %{"messages" => []}))

      {state, [{_jr, first, _t, "new_msg", _p}]} = State.say(state, "hi")
      {state, []} = State.received(state, room_reply(first, "error", %{"reason" => "empty"}))
      assert State.status(state).refused == :empty

      {state, [{_jr, second, _t, "new_msg", _p}]} = State.say(state, "again")
      {state, []} = State.received(state, room_reply(second, "ok", %{}))

      assert State.status(state).refused == nil
    end

    test "saying nothing while out of a room sends nothing" do
      {state, _frames} = State.connected(new())

      assert {_state, []} = State.say(state, "hi")
    end
  end
end
