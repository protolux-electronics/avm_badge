defmodule Badge.Page.Chat.Rooms do
  @moduledoc """
  Which rooms there are, and where the conversation is.

  The list comes from `Badge.Chat.Link` through the container; this draws it
  and remembers which line is picked. Entering a room is the container's job,
  so Enter is ignored here.
  """

  use Badge.Page

  alias Badge.Nav
  alias Badge.Text
  alias Badge.Theme

  @char_w 8
  @margin 8

  @heading_y Theme.content_top()
  @rule_y @heading_y + 22
  @top @rule_y + 8
  @pitch 20

  @desc_lines 2
  @desc_top Theme.height() - @desc_lines * @pitch
  @foot_rule_y @desc_top - 8
  @desc_columns div(Theme.width() - 2 * @margin, @char_w)

  # How many rooms fit between the heading rule and the description rule.
  @rows div(@foot_rule_y - @top, @pitch)

  # Marker column, then a gap column, before the name starts.
  @name_x @margin + 2 * @char_w

  @heading "ROOMS"
  @none "No rooms"
  @waiting "connecting"

  @impl true
  def title, do: "Rooms"

  # Nothing here moves fast enough to be worth a full repaint ten times a second.
  @impl true
  def refresh(_state), do: 333

  @impl true
  def init, do: %{rooms: [], unread: %{}, selected: 0, offset: 0, ready: false}

  @doc "Takes what the container read from the link. Called instead of `tick/1`."
  @spec apply_status(map, map) :: map
  def apply_status(status, state) do
    selected = clamp(state.selected, length(status.rooms))

    %{
      state
      | rooms: status.rooms,
        unread: status.unread,
        ready: status.ready,
        selected: selected,
        offset: place(state.offset, selected)
    }
  end

  @doc "The slug of the picked room, or nil when there is nothing to pick."
  @spec selected(map) :: binary | nil
  def selected(%{rooms: []}), do: nil

  def selected(%{rooms: rooms, selected: selected}) do
    %{slug: slug} = :lists.nth(selected + 1, rooms)

    slug
  end

  # Nothing to move through is nothing to move; let the container keep the key.
  @impl true
  def handle_key({:move, _dir}, %{rooms: []}), do: :ignore

  def handle_key({:move, :up}, state) do
    selected = max(state.selected - 1, 0)

    {:ok, %{state | selected: selected, offset: place(state.offset, selected)}}
  end

  def handle_key({:move, :down}, state) do
    selected = min(state.selected + 1, length(state.rooms) - 1)

    {:ok, %{state | selected: selected, offset: place(state.offset, selected)}}
  end

  def handle_key(_event, _state), do: :ignore

  @impl true
  def render(%{rooms: []} = state), do: heading() ++ [empty(state)] ++ footer(state)

  def render(state) do
    visible = :lists.sublist(drop(state.rooms, state.offset), @rows)
    entries = entries(visible, state.unread, state.offset, state.selected, [])

    heading() ++ Nav.rows(entries, state.selected - state.offset, @top, @pitch) ++ footer(state)
  end

  defp heading do
    [{:text, @margin, @heading_y, :default16px, Theme.dim(), Theme.bg(), @heading}] ++
      Theme.rule(@margin, @rule_y, Theme.width() - 2 * @margin)
  end

  defp empty(%{ready: true}),
    do: {:text, @name_x, @top, :default16px, Theme.dim(), Theme.bg(), @none}

  defp empty(_state),
    do: {:text, @name_x, @top, :default16px, Theme.muted(), Theme.bg(), @waiting}

  defp entries([], _unread, _index, _selected, acc), do: :lists.reverse(acc)

  defp entries([room | rest], unread, index, selected, acc) do
    entry = %{
      value: Map.get(room, :name, ""),
      colour: name_colour(index == selected),
      trailing: count_text(Map.get(unread, Map.get(room, :slug), 0)),
      trailing_colour: Theme.accent()
    }

    entries(rest, unread, index + 1, selected, [entry | acc])
  end

  defp name_colour(true), do: Theme.fg()
  defp name_colour(false), do: Theme.muted()

  defp count_text(0), do: nil
  defp count_text(n), do: :erlang.integer_to_binary(n)

  defp footer(state) do
    Theme.rule(@margin, @foot_rule_y, Theme.width() - 2 * @margin) ++ description(state)
  end

  defp description(%{rooms: []}), do: []

  defp description(state) do
    room = :lists.nth(state.selected + 1, state.rooms)

    description_lines(Map.get(room, :description, ""))
  end

  defp description_lines(""), do: []

  defp description_lines(text) do
    lines = :lists.sublist(Text.wrap(text, @desc_columns), @desc_lines)

    text_items(lines, @desc_top, [])
  end

  defp text_items([], _y, acc), do: :lists.reverse(acc)

  defp text_items([line | rest], y, acc) do
    text_items(rest, y + @pitch, [
      {:text, @margin, y, :default16px, Theme.muted(), Theme.bg(), line} | acc
    ])
  end

  defp drop(list, 0), do: list
  defp drop([], _n), do: []
  defp drop([_head | rest], n), do: drop(rest, n - 1)

  # The view holds still until the selection would leave it.
  defp place(offset, selected) when selected < offset, do: selected
  defp place(offset, selected) when selected >= offset + @rows, do: selected - @rows + 1
  defp place(offset, _selected), do: offset

  defp clamp(_selected, 0), do: 0
  defp clamp(selected, count), do: min(max(selected, 0), count - 1)
end
