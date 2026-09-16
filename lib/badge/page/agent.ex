defmodule Badge.Page.Agent do
  @moduledoc """
  A conversation with `Badge.Eliza`, the 1966 program, on the panel.

  Lines you type sit against the draft at the bottom and her answers follow
  them; the transcript scrolls up with the arrows and any keystroke on the
  draft brings the newest line back into view. Enter sends the draft, and
  the reply is computed in place, since nothing about it needs a process.
  """

  use Badge.Page

  alias Badge.Eliza
  alias Badge.Field
  alias Badge.Text
  alias Badge.Theme

  @char_w 8
  @margin 8

  @columns div(Theme.width() - 2 * @margin, @char_w)

  @draft_y 214
  @rule_y 206
  @rows 8
  @pitch 20
  @top Theme.content_top() + 8

  # Where the caret settles once the draft is long enough to scroll.
  @caret_rest div(@columns, 2)

  # Three panel lines' worth is plenty for a complaint.
  @limit 3 * @columns

  # Wrapped lines kept; older ones are gone, which keeps a long chat cheap.
  @keep 64

  # How much ragged gap a space may leave before a word is dashed instead.
  @orphan 6

  @prompt "> "

  @impl true
  def title, do: "Agent"

  @impl true
  def init do
    %{eliza: Eliza.new(), lines: [], draft: Field.new(@limit), offset: 0}
    |> said(:eliza, Eliza.greeting())
  end

  @doc "The transcript as `{who, line}` pairs, newest first, already wrapped."
  @spec lines(map) :: [{:you | :eliza, binary}]
  def lines(%{lines: lines}), do: lines

  @impl true
  def handle_key({:char, char}, state) do
    {:ok, %{focus(state) | draft: Field.insert(state.draft, char)}}
  end

  def handle_key({:edit, :backspace}, state) do
    {:ok, %{focus(state) | draft: Field.backspace(state.draft)}}
  end

  def handle_key({:edit, :newline}, state), do: send_draft(Field.value(state.draft), state)

  def handle_key({:move, :left}, state) do
    {:ok, %{focus(state) | draft: Field.left(state.draft)}}
  end

  def handle_key({:move, :right}, state) do
    {:ok, %{focus(state) | draft: Field.right(state.draft)}}
  end

  def handle_key({:move, :up}, state), do: older(state)
  def handle_key({:move, :down}, state), do: newer(state)

  def handle_key(_event, _state), do: :ignore

  # Nothing to say is not a line; let the router keep the key.
  defp send_draft("", _state), do: :ignore

  defp send_draft(text, state) do
    {reply, eliza} = Eliza.respond(text, state.eliza)

    state =
      %{focus(state) | draft: Field.new(@limit), eliza: settled(reply, eliza)}
      |> said(:you, text)
      |> said(:eliza, reply)

    {:ok, state}
  end

  # A goodbye ends the conversation, so the next line starts a fresh one.
  defp settled(reply, eliza) do
    case Eliza.farewell?(reply) do
      true -> Eliza.new()
      false -> eliza
    end
  end

  defp said(state, who, text) do
    wrapped = Text.wrap(prefix(who) <> text, @columns, @orphan)
    tagged = :lists.map(fn line -> {who, line} end, :lists.reverse(wrapped))

    %{state | lines: take(tagged ++ state.lines, @keep, [])}
  end

  defp prefix(:you), do: @prompt
  defp prefix(:eliza), do: ""

  defp take([], _n, acc), do: :lists.reverse(acc)
  defp take(_lines, 0, acc), do: :lists.reverse(acc)
  defp take([line | rest], n, acc), do: take(rest, n - 1, [line | acc])

  defp older(%{offset: offset, lines: lines} = state) do
    case offset + @rows < length(lines) do
      true -> {:ok, %{state | offset: offset + 1}}
      false -> :ignore
    end
  end

  defp newer(%{offset: 0}), do: :ignore
  defp newer(state), do: {:ok, %{state | offset: state.offset - 1}}

  defp focus(state), do: %{state | offset: 0}

  @impl true
  def render(state) do
    rows(state) ++
      Theme.rule(@margin, @rule_y, Theme.width() - 2 * @margin) ++ [draft(state)]
  end

  # Newest against the rule; the ones above are whatever still fits.
  defp rows(state) do
    shown = take(drop(state.lines, state.offset), @rows, [])

    row_items(:lists.reverse(shown), @top, [])
  end

  defp drop(list, 0), do: list
  defp drop([], _n), do: []
  defp drop([_head | rest], n), do: drop(rest, n - 1)

  defp row_items([], _y, acc), do: :lists.reverse(acc)

  defp row_items([{who, line} | rest], y, acc) do
    item = {:text, @margin, y, :default16px, colour(who), Theme.bg(), line}

    row_items(rest, y + @pitch, [item | acc])
  end

  defp colour(:you), do: Theme.muted()
  defp colour(:eliza), do: Theme.fg()

  # Scrolled away, the draft keeps its text but gives up the caret.
  defp draft(%{offset: offset} = state) when offset > 0 do
    line = @prompt <> Field.value(state.draft)

    prompt(clipped(line, byte_size(line) - 1), Theme.muted())
  end

  defp draft(%{draft: field}) do
    value = Field.value(field)
    at = Field.cursor(field)

    line =
      @prompt <>
        :binary.part(value, 0, at) <> "_" <> :binary.part(value, at, byte_size(value) - at)

    prompt(clipped(line, byte_size(@prompt) + at), Theme.select())
  end

  defp prompt(text, colour),
    do: {:text, @margin, @draft_y, :default16px, colour, Theme.bg(), text}

  defp clipped(line, _at) when byte_size(line) <= @columns, do: line

  # The caret walks in to the middle before the text starts moving under it.
  defp clipped(line, at) do
    start = min(max(at - @caret_rest, 0), byte_size(line) - @columns)

    :binary.part(line, start, @columns)
  end
end
