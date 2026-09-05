defmodule Badge.Chat.Link.State do
  @moduledoc """
  What the link knows, as plain data.

  No port, no radio and no flash: `Badge.Chat.Link` owns those and calls in
  here for every transition. That is what makes ref dispatch, rejoining and
  unread counting testable on the host, which is where they will break.

  Every transition answers `{state, frames}`. A frame is
  `{join_ref, ref, topic, event, payload}` — the argument order of
  `Badge.Chat.Wire.encode/5` — and the caller is what sends it.

  Replies are dispatched by ref, not by topic: a room carries both a join
  reply and a `new_msg` reply on the same topic, and telling them apart is the
  only way a refused post can be shown.
  """

  @rooms_topic "rooms:badge"
  @chat_prefix "chat:"

  @doc "A link that has connected to nothing."
  @spec new(binary) :: map
  def new(base) do
    %{
      base: base,
      up: false,
      rooms_channel: :out,
      room_channel: :out,
      room: nil,
      rooms: [],
      unread: %{},
      banned: false,
      ban_reason: "",
      messages: [],
      heard: 0,
      refused: nil,
      chip: nil,
      ref: 1,
      join_ref: 1,
      room_join_ref: nil,
      pending: %{}
    }
  end

  @doc "The socket came up. Joins the rooms channel, and rejoins a room if in one."
  @spec connected(map) :: {map, [tuple]}
  def connected(state) do
    state = %{state | up: true, rooms_channel: :out, room_channel: :out}

    {state, rooms_frames} = join_rooms(state)
    {state, room_frames} = join_room(state, state.room)

    {state, rooms_frames ++ room_frames}
  end

  @doc "The socket went away. The room is remembered so a reconnection can rejoin it."
  @spec disconnected(map) :: {map, [tuple]}
  def disconnected(state) do
    {%{state | up: false, rooms_channel: :out, room_channel: :out}, []}
  end

  @doc "The chip this badge posts as, so its own lines can be marked."
  @spec identify(map, binary) :: map
  def identify(state, chip), do: %{state | chip: chip}

  @doc "Enters a room, leaving whichever one it was in."
  @spec enter(map, binary) :: {map, [tuple]}
  def enter(state, slug) when is_binary(slug) do
    {state, leave_frames} = leave_room(state)

    state = %{
      state
      | room: slug,
        messages: [],
        refused: nil,
        unread: Map.delete(state.unread, slug)
    }

    {state, join_frames} = join_room(state, slug)

    {state, leave_frames ++ join_frames}
  end

  @doc "Leaves the room, keeping the socket and the rooms channel."
  @spec leave_room(map) :: {map, [tuple]}
  def leave_room(%{room: nil} = state), do: {state, []}

  def leave_room(state) do
    {next, frames} = leave_frames(state)

    {%{next | room: nil, room_channel: :out, messages: [], refused: nil}, frames}
  end

  @doc "Posts a line to the room, or nothing at all if not in one."
  @spec say(map, binary) :: {map, [tuple]}
  def say(%{room_channel: channel} = state, _body) when channel != :joined, do: {state, []}

  def say(state, body) do
    {state, ref} = next_ref(state)
    state = %{state | pending: Map.put(state.pending, ref, :say)}

    {state, [{state.room_join_ref, ref, topic(state.room), "new_msg", %{"body" => body}}]}
  end

  @doc "What the page reads. Called from the render loop, so it only reads."
  @spec status(map) :: map
  def status(state) do
    %{
      state: state.room_channel,
      ready: state.rooms_channel == :joined,
      rooms: state.rooms,
      room: state.room,
      unread: state.unread,
      banned: state.banned,
      ban_reason: state.ban_reason,
      messages: state.messages,
      heard: state.heard,
      refused: state.refused,
      host: state.base
    }
  end

  @doc "Applies one decoded frame."
  @spec received(map, map) :: {map, [tuple]}
  def received(state, %{event: "phx_reply", ref: ref, payload: payload}) do
    {purpose, pending} = take(state.pending, ref)

    reply(%{state | pending: pending}, purpose, field(payload, "status"), response(payload))
  end

  def received(state, %{topic: @rooms_topic, event: "activity", payload: payload}) do
    {noted(state, field(payload, "slug")), []}
  end

  def received(state, %{topic: @rooms_topic, event: "rooms", payload: payload}) do
    pruned(listed(state, Map.get(payload, "rooms")))
  end

  def received(%{room: room} = state, %{topic: topic, event: "new_msg", payload: payload})
      when is_binary(room) do
    case topic == topic(room) do
      true -> {heard(state, payload), []}
      false -> {state, []}
    end
  end

  def received(state, _message), do: {state, []}

  defp reply(state, :join_rooms, "ok", response) do
    {joined_rooms(%{state | rooms_channel: :joined}, response), []}
  end

  defp reply(state, :join_rooms, _status, _response) do
    {%{state | rooms_channel: :out}, []}
  end

  defp reply(state, :join_room, "ok", response) do
    {%{state | room_channel: :joined, messages: history(response, state.chip)}, []}
  end

  defp reply(state, :join_room, _status, _response) do
    {%{state | room_channel: :out}, []}
  end

  defp reply(state, :say, "ok", _response), do: {%{state | refused: nil}, []}

  defp reply(state, :say, _status, response) do
    {%{state | refused: refusal(text(response, "reason"))}, []}
  end

  defp reply(state, _purpose, _status, _response), do: {state, []}

  defp joined_rooms(state, response) do
    case Map.get(response, "banned") do
      true -> %{state | banned: true, ban_reason: text(response, "reason"), rooms: []}
      _not_banned -> listed(%{state | banned: false, ban_reason: ""}, Map.get(response, "rooms"))
    end
  end

  # A non-list leaves the rail as it was, rather than emptying it.
  defp listed(state, rooms) when is_list(rooms) do
    %{state | rooms: :lists.reverse(wire_rooms(rooms, []))}
  end

  defp listed(state, _rooms), do: state

  defp wire_rooms([], acc), do: acc

  defp wire_rooms([room | rest], acc) when is_map(room) do
    case {Map.get(room, "slug"), Map.get(room, "name")} do
      {slug, name} when is_binary(slug) and is_binary(name) ->
        wire_rooms(rest, [%{slug: slug, name: name, description: text(room, "description")} | acc])

      _malformed ->
        wire_rooms(rest, acc)
    end
  end

  defp wire_rooms([_room | rest], acc), do: wire_rooms(rest, acc)

  # A room archived while you are standing in it: the list is the truth.
  defp pruned(%{room: nil} = state), do: {state, []}

  defp pruned(state) do
    case listed?(state.rooms, state.room) do
      true -> {state, []}
      false -> leave_room(state)
    end
  end

  defp listed?([], _slug), do: false
  defp listed?([%{slug: slug} | _rest], slug), do: true
  defp listed?([_room | rest], slug), do: listed?(rest, slug)

  @keep 16

  defp history(response, chip) do
    case Map.get(response, "messages") do
      messages when is_list(messages) -> for message <- messages, do: line(message, chip)
      _absent -> []
    end
  end

  defp heard(state, payload) do
    messages = keep([line(payload, state.chip) | state.messages], @keep, [])

    %{state | messages: messages, heard: state.heard + 1}
  end

  defp keep(_list, 0, acc), do: :lists.reverse(acc)
  defp keep([], _left, acc), do: :lists.reverse(acc)
  defp keep([head | rest], left, acc), do: keep(rest, left - 1, [head | acc])

  defp line(payload, chip) do
    %{from: text(payload, "from"), body: text(payload, "body"), mine: text(payload, "chip") == chip}
  end

  defp refusal("banned"), do: :banned
  defp refusal(_reason), do: :empty

  defp noted(state, slug) when is_binary(slug) do
    case slug == state.room do
      true -> state
      false -> %{state | unread: Map.put(state.unread, slug, count(state.unread, slug) + 1)}
    end
  end

  defp noted(state, _slug), do: state

  defp count(unread, slug), do: Map.get(unread, slug, 0)

  defp join_rooms(%{up: true, rooms_channel: :out} = state) do
    {state, join_ref, ref} = next_join(state)

    state = %{
      state
      | rooms_channel: :joining,
        pending: Map.put(state.pending, ref, :join_rooms)
    }

    {state, [{join_ref, ref, @rooms_topic, "phx_join", %{}}]}
  end

  defp join_rooms(state), do: {state, []}

  defp join_room(%{up: true} = state, slug) when is_binary(slug) do
    {state, join_ref, ref} = next_join(state)

    state = %{
      state
      | room_channel: :joining,
        room_join_ref: join_ref,
        pending: Map.put(state.pending, ref, :join_room)
    }

    {state, [{join_ref, ref, topic(slug), "phx_join", %{}}]}
  end

  defp join_room(state, _slug), do: {state, []}

  @doc "The pubsub topic a room's messages travel on."
  @spec topic(binary) :: binary
  def topic(slug), do: @chat_prefix <> slug

  # A fresh join_ref per join; a rejoin under the old one is dropped.
  defp next_join(state) do
    {%{state | join_ref: state.join_ref + 1, ref: state.ref + 1},
     :erlang.integer_to_binary(state.join_ref), :erlang.integer_to_binary(state.ref)}
  end

  defp leave_frames(%{up: false} = state), do: {state, []}

  defp leave_frames(state) do
    {state, ref} = next_ref(state)

    {state, [{state.room_join_ref, ref, topic(state.room), "phx_leave", %{}}]}
  end

  defp next_ref(state) do
    {%{state | ref: state.ref + 1}, :erlang.integer_to_binary(state.ref)}
  end

  defp take(pending, ref) do
    case Map.get(pending, ref) do
      nil -> {nil, pending}
      purpose -> {purpose, Map.delete(pending, ref)}
    end
  end

  defp response(payload) do
    case Map.get(payload, "response") do
      response when is_map(response) -> response
      _absent -> %{}
    end
  end

  defp field(payload, key), do: Map.get(payload, key)

  defp text(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _absent -> ""
    end
  end
end
