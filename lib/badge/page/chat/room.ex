defmodule Badge.Page.Chat.Room do
  @moduledoc """
  The conversation, on the panel.

  A sub-page of `Badge.Page.Chat`, which owns the link and feeds this module
  its status via `apply_status/2`. This module only reads what it has heard
  and hands typed lines back. Newest sits nearest the draft line, so the eye
  follows the conversation downwards.
  """

  use Badge.Page

  alias Badge.Chat.Link
  alias Badge.Field
  alias Badge.Profile
  alias Badge.Readout
  alias Badge.Text
  alias Badge.Theme

  @fg Theme.fg()
  @accent Theme.accent()
  @dim Theme.dim()
  @muted Theme.muted()
  @select Theme.select()
  @warn Theme.warn()
  @alert Theme.alert()
  @bg Theme.bg()

  @char_w 8
  @margin 8

  # What a line can hold before it runs off the panel.
  @line_columns div(Theme.width() - 2 * @margin, @char_w)

  # A message gives up its first column to the selection marker.
  @columns @line_columns - 1
  @body_x @margin + @char_w

  # The counter needs the right-hand end of the draft line: two digits and a gap.
  @draft_columns @line_columns - 3

  # Where the caret settles once the draft is long enough to scroll.
  @caret_rest div(@draft_columns, 2)

  @draft_y 214
  @rule_y 206
  @rows 8
  @pitch 20
  @top Theme.content_top() + 8

  # Three panel lines' worth, shared with the name the message is drawn under.
  # The server's cap of 200 is the outer bound.
  @budget 3 * @columns

  # How much ragged gap a space may leave before a word is dashed instead.
  # Without it a long unbroken word pushes the sender's name onto a line of
  # its own and wastes most of the one below.
  @orphan 6

  # Room for the hyphens `Text.wrap/3` adds when one long word is broken.
  @hyphens 3

  @none "No messages yet"

  @impl true
  def title, do: "Room"

  # A frame is a whole panel, and messages arrive at walking pace.
  @impl true
  def refresh(_state), do: 333

  @impl true
  def init do
    %{
      messages: [],
      link: :offline,
      draft: Field.new(limit_for(nil)),
      selected: nil,
      offset: 0,
      heard: 0,
      limit: limit_for(nil),
      loaded: false,
      refused: nil
    }
  end

  @doc "Takes what the container read from the link. Called instead of `tick/1`."
  @spec apply_status(map, map) :: map
  def apply_status(status, state) do
    state = named(state)

    %{
      state
      | messages: status.messages,
        link: status.state,
        refused: status.refused,
        draft: Field.resize(state.draft, state.limit)
    }
    |> drift(status.heard - state.heard)
    |> clamp_offset()
    |> Map.put(:heard, status.heard)
  end

  # A rejoin can replace the messages with a shorter history than was scrolled to.
  defp clamp_offset(state), do: %{state | offset: min(state.offset, max(length(state.messages) - 1, 0))}

  # The profile arrives on the first status; a page built afresh picks up a renamed badge.
  defp named(%{loaded: true} = state), do: state

  defp named(state) do
    %{state | loaded: true, limit: limit_for(Profile.display_name(Profile.load()))}
  end

  @impl true
  def handle_key({:move, :up}, state), do: older(state, length(state.messages))

  def handle_key({:move, :down}, state), do: newer(state)

  # Anything that is not a scroll puts the focus back where it is typed.
  def handle_key({:char, char}, state) do
    {:ok, %{focus(state) | draft: Field.insert(state.draft, char)}}
  end

  def handle_key({:edit, :backspace}, state) do
    {:ok, %{focus(state) | draft: Field.backspace(state.draft)}}
  end

  def handle_key({:edit, :newline}, state), do: send_draft(Field.value(state.draft), focus(state))

  def handle_key({:move, :left}, state) do
    {:ok, %{focus(state) | draft: Field.left(state.draft)}}
  end

  def handle_key({:move, :right}, state) do
    {:ok, %{focus(state) | draft: Field.right(state.draft)}}
  end

  def handle_key(_event, _state), do: :ignore

  # Nothing heard is nothing to scroll through; let the router keep the key.
  defp older(_state, 0), do: :ignore

  defp older(%{selected: nil} = state, _count), do: {:ok, show(state, 0)}

  defp older(%{selected: selected} = state, count) do
    {:ok, show(state, min(selected + 1, count - 1))}
  end

  defp newer(%{selected: nil}), do: :ignore

  defp newer(%{selected: 0} = state), do: {:ok, focus(state)}

  defp newer(%{selected: selected} = state), do: {:ok, show(state, selected - 1)}

  defp focus(state), do: %{state | selected: nil, offset: 0}

  # Nothing to say is not a message; let the router keep the key.
  defp send_draft("", _state), do: :ignore

  # The view holds still until the selection would leave it.
  defp show(state, selected) do
    %{state | selected: selected, offset: place(state.messages, state.offset, selected)}
  end

  defp place(_messages, offset, selected) when selected <= offset, do: selected

  defp place(messages, offset, selected) do
    case selected < offset + shown(messages, offset) do
      true -> offset
      false -> place(messages, offset + 1, selected)
    end
  end

  # How many whole messages the rows hold, counting back from `offset`.
  defp shown(messages, offset), do: length(newest(drop(messages, offset), @rows, []))

  defp drop(list, 0), do: list
  defp drop([], _n), do: []
  defp drop([_head | rest], n), do: drop(rest, n - 1)

  defp send_draft(body, state) do
    Link.say(body)

    {:ok, %{state | draft: Field.new(Field.capacity(state.draft))}}
  end

  @impl true
  def render(state) do
    rows(drop(state.messages, state.offset), @rows, @top, marked(state)) ++
      [
        {:rect, @margin, @rule_y, Theme.width() - 2 * @margin, 1, @dim},
        draft(state)
      ] ++ counter(state.draft) ++ empty(state)
  end

  # Oldest at the top so the newest ends up against the draft line. A message
  # can take several lines, so the newest are taken until the room runs out.
  defp rows(messages, left, top, selected) do
    drawn = newest(messages, left, [])

    lines(drawn, top, length(drawn) - 1 - selected, [])
  end

  # Nothing is marked while the draft has focus; -1 never matches a position.
  defp marked(%{selected: nil}), do: -1
  defp marked(state), do: state.selected - state.offset

  # Walks newest first, keeping whole messages until the lines are spent.
  defp newest([], _left, acc), do: acc

  defp newest(_messages, left, acc) when left <= 0, do: acc

  defp newest([message | rest], left, acc) do
    wrapped = wrap(message)
    count = length(wrapped)

    case count > left do
      true -> acc
      false -> newest(rest, left - count, [{message, wrapped} | acc])
    end
  end

  defp wrap(message) do
    Text.wrap(prefix(message) <> Map.get(message, :body, ""), @columns, @orphan)
  end

  defp prefix(message), do: Map.get(message, :from, "") <> ": "

  defp lines([], _y, _at, acc), do: :lists.reverse(acc)

  defp lines([{message, [first | rest_lines]} | rest], y, at, acc) do
    count = length(rest_lines) + 1

    items =
      head_items(message, first, y) ++
        tail_items(rest_lines, y + @pitch, []) ++ markers(at == 0, y, count, [])

    lines(rest, y + @pitch * count, at - 1, items ++ acc)
  end

  # One marker per line, so a message that wraps is marked all the way down.
  defp markers(false, _y, _count, acc), do: acc
  defp markers(true, _y, 0, acc), do: acc

  defp markers(true, y, count, acc) do
    item = {:text, @margin, y, :default16px, @select, @bg, ">"}

    markers(true, y + @pitch, count - 1, [item | acc])
  end

  # The name is drawn separately so it can carry its own colour.
  defp head_items(message, first, y) do
    name = prefix(message)

    case byte_size(first) > byte_size(name) and :binary.part(first, 0, byte_size(name)) == name do
      true ->
        rest = :binary.part(first, byte_size(name), byte_size(first) - byte_size(name))

        [
          {:text, @body_x + @char_w * byte_size(name), y, :default16px, @fg, @bg, rest},
          {:text, @body_x, y, :default16px, name_colour(message), @bg, name}
        ]

      false ->
        [{:text, @body_x, y, :default16px, name_colour(message), @bg, first}]
    end
  end

  defp tail_items([], _y, acc), do: acc

  defp tail_items([body | rest], y, acc) do
    item = {:text, @body_x, y, :default16px, @fg, @bg, body}

    tail_items(rest, y + @pitch, [item | acc])
  end

  # Every message reads the same; only the name says who is speaking.
  defp name_colour(%{mine: true}), do: @select
  defp name_colour(_message), do: @accent

  # Scrolled away, the draft keeps its text but gives up the caret that says
  # a keystroke would land there.
  defp draft(%{selected: selected} = state) when selected != nil do
    line = "> " <> Field.value(state.draft)

    prompt(clipped(line, byte_size(line) - 1), @muted)
  end

  defp draft(%{draft: field} = state) do
    case Field.value(field) do
      "" -> idle(state)
      value -> prompt(window(value, Field.cursor(field)), colour(state.link))
    end
  end

  # The caret is drawn between the two halves rather than after the value.
  defp window(value, at) do
    line =
      :binary.part(value, 0, at) <>
        "_" <> :binary.part(value, at, byte_size(value) - at)

    clip(line, 2 + at)
  end

  # An empty draft is the only time there is room to say why the last line failed.
  defp idle(%{refused: :banned}), do: prompt("banned - cannot post", @alert)
  defp idle(%{refused: :empty}), do: prompt("nothing to say", @warn)
  defp idle(%{link: :joined}), do: prompt("> _", @select)
  defp idle(_state), do: prompt("connecting to the room", @muted)

  defp prompt(text, colour), do: {:text, @margin, @draft_y, :default16px, colour, @bg, text}

  @doc "Keeps the selection on its message as newer ones push it down the list."
  @spec drift(map, integer) :: map
  def drift(%{selected: nil} = state, _arrived), do: state

  def drift(state, arrived), do: drifted(state, arrived, length(state.messages))

  defp drifted(state, _arrived, 0), do: focus(state)

  defp drifted(state, arrived, count) do
    offset = min(max(state.offset + arrived, 0), count - 1)

    show(%{state | offset: offset}, min(max(state.selected + arrived, 0), count - 1))
  end

  @doc "What a message may hold once the name it is drawn under is taken out."
  @spec limit_for(binary | nil) :: non_neg_integer
  def limit_for(nil), do: @budget - @hyphens
  def limit_for(name), do: max(@budget - @hyphens - byte_size(name) - 2, 0)

  @doc "The colour for a count of characters left, or `nil` while there is room."
  @spec counter_colour(non_neg_integer) :: integer | nil
  def counter_colour(left) when left > 20, do: nil
  def counter_colour(left) when left > 5, do: @warn
  def counter_colour(_left), do: @alert

  defp counter(field) do
    left = Field.remaining(field)

    case counter_colour(left) do
      nil -> []
      colour -> [count_item(:erlang.integer_to_binary(left), colour)]
    end
  end

  # Right-aligned, in the columns the draft leaves free.
  defp count_item(text, colour) do
    x = Theme.width() - @margin - @char_w * byte_size(text)

    {:text, x, @draft_y, :default16px, colour, @bg, text}
  end

  defp colour(:joined), do: @select
  defp colour(_link), do: @muted

  # Only says the room is empty when there is nothing else to look at.
  defp empty(%{messages: [], link: :joined}) do
    [{:text, Readout.centre_x(@none), 120, :default16px, @dim, @bg, @none}]
  end

  defp empty(_state), do: []

  # Typing runs off the left rather than the right, so the caret stays in view.
  defp clip(line, at), do: clipped("> " <> line, at)

  defp clipped(line, _at) when byte_size(line) <= @draft_columns, do: line

  # The caret walks in to the middle before the text starts moving under it.
  defp clipped(line, at) do
    start = min(max(at - @caret_rest, 0), byte_size(line) - @draft_columns)

    :binary.part(line, start, @draft_columns)
  end
end
