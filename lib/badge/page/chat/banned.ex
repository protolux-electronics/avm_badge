defmodule Badge.Page.Chat.Banned do
  @moduledoc """
  Why this badge cannot see or say anything.

  Shown instead of the room list. It takes no keys at all, so `Esc` falls
  through the container to `Badge.UI` and goes Home.
  """

  use Badge.Page

  alias Badge.Text
  alias Badge.Theme

  @fg Theme.fg()
  @alert Theme.alert()
  @bg Theme.bg()

  @char_w 8
  @margin 8

  @columns div(Theme.width() - 2 * @margin, @char_w)

  @top Theme.content_top() + 8
  @pitch 20
  @gap 12

  @heading "BANNED"
  @none "no reason given"

  # How much ragged gap a space may leave before a word is dashed instead.
  @orphan 6

  @impl true
  def title, do: "Banned"

  @impl true
  def refresh(_state), do: 333

  @impl true
  def init, do: %{reason: ""}

  @doc "Takes what the container read from the link. Called instead of `tick/1`."
  @spec apply_status(map, map) :: map
  def apply_status(status, state), do: %{state | reason: status.ban_reason}

  @impl true
  def render(state) do
    [{:text, @margin, @top, :default16px, @alert, @bg, @heading}] ++
      lines(Text.wrap(reason(state), @columns, @orphan), @top + @pitch + @gap, [])
  end

  defp reason(%{reason: ""}), do: @none
  defp reason(%{reason: reason}), do: reason

  defp lines([], _y, acc), do: acc

  defp lines([line | rest], y, acc) do
    lines(rest, y + @pitch, [{:text, @margin, y, :default16px, @fg, @bg, line} | acc])
  end
end
