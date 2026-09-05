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
    {listed(state, Map.get(payload, "rooms")), []}
  end

  def received(state, _message), do: {state, []}

  defp reply(state, :join_rooms, "ok", response) do
    {joined_rooms(%{state | rooms_channel: :joined}, response), []}
  end

  defp reply(state, :join_rooms, _status, _response) do
    {%{state | rooms_channel: :out}, []}
  end

  defp reply(state, _purpose, _status, _response), do: {state, []}

  defp joined_rooms(state, response) do
    case Map.get(response, "banned") do
      true -> %{state | banned: true, ban_reason: text(response, "reason"), rooms: []}
      _not_banned -> listed(%{state | banned: false, ban_reason: ""}, Map.get(response, "rooms"))
    end
  end

  # A list that is not a list of rooms leaves the rail alone: an empty rail is
  # a worse lie than a stale one.
  defp listed(state, rooms) when is_list(rooms) do
    %{state | rooms: :lists.reverse(wire_rooms(rooms, []))}
  end

  defp listed(state, _rooms), do: state

  defp wire_rooms([], acc), do: acc

  defp wire_rooms([room | rest], acc) when is_map(room) do
    case {Map.get(room, "slug"), Map.get(room, "name")} do
      {slug, name} when is_binary(slug) and is_binary(name) ->
        wire_rooms(rest, [%{slug: slug, name: name} | acc])

      _malformed ->
        wire_rooms(rest, acc)
    end
  end

  defp wire_rooms([_room | rest], acc), do: wire_rooms(rest, acc)

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

  # A join_ref is per join, never reused: Phoenix matches a channel's messages
  # against it, and a rejoin of the same topic under the old one is dropped.
  defp next_join(state) do
    {%{state | join_ref: state.join_ref + 1, ref: state.ref + 1},
     :erlang.integer_to_binary(state.join_ref), :erlang.integer_to_binary(state.ref)}
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
