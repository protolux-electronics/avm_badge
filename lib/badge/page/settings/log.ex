defmodule Badge.Page.Settings.Log do
  @moduledoc """
  The console, as the badge saw it.

  Draws the newest lines `Badge.Log` holds, wrapped to the panel with the
  oldest at the top. Up moves back through what has scrolled off and down
  returns; at the bottom the view follows new lines as they arrive.
  """

  use Badge.Page

  alias Badge.Log
  alias Badge.Page.Settings
  alias Badge.Theme

  @fg Theme.fg()
  @bg Theme.bg()

  @x 8
  @top Settings.content_top()
  @pitch 16
  @columns 38
  @rows div(Theme.height() - @top, @pitch)

  @impl true
  def title, do: "Log"

  @impl true
  def init, do: %{lines: [], offset: 0}

  @impl true
  def tick(state), do: %{state | lines: Log.tail(Log.keep())}

  @impl true
  def handle_key({:move, :up}, state) do
    {:ok, %{state | offset: min(state.offset + 1, max_offset(state))}}
  end

  def handle_key({:move, :down}, state) do
    {:ok, %{state | offset: max(state.offset - 1, 0)}}
  end

  def handle_key(_event, _state), do: :ignore

  @impl true
  def render(state) do
    items(window(rows(state.lines), state.offset), @top, [])
  end

  @doc "Lines broken into panel-width rows, in order."
  @spec rows([binary]) :: [binary]
  def rows(lines), do: rows(lines, [])

  @doc "The rows on screen when `offset` rows have been scrolled back from the end."
  @spec window([binary], non_neg_integer) :: [binary]
  def window(rows, offset) do
    last = max(length(rows) - offset, 0)
    first = max(last - @rows, 0)

    :lists.sublist(rows, first + 1, last - first)
  end

  @doc "How many rows fit on the panel."
  def visible_rows, do: @rows

  defp max_offset(state), do: max(length(rows(state.lines)) - @rows, 0)

  defp rows([], acc), do: :lists.reverse(acc)
  defp rows([line | rest], acc), do: rows(rest, chunks(line, acc))

  defp chunks(line, acc) when byte_size(line) <= @columns, do: [line | acc]
  defp chunks(<<head::binary-@columns, rest::binary>>, acc), do: chunks(rest, [head | acc])

  defp items([], _y, acc), do: :lists.reverse(acc)

  defp items([row | rest], y, acc) do
    items(rest, y + @pitch, [{:text, @x, y, :default16px, @fg, @bg, row} | acc])
  end
end
