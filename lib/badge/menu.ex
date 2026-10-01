defmodule Badge.Menu do
  @moduledoc "Shared six-shape grid layout and navigation for Home and Games."

  alias Badge.Icons
  alias Badge.Theme

  @keys [:square, :triangle, :cross, :circle, :clover, :diamond]
  @top Theme.content_top()
  @bottom Theme.height() - 2
  @cell_w 106
  @cell_h 105
  @cell_origins for y <- [@top, @top + @cell_h + 2], x <- [0, 107, 214], do: {x, y}
  @chevron_y Theme.height() - 18

  def keys, do: @keys
  def init, do: %{screen: 0, goto: nil}
  def screens(pages), do: div(length(pages) + 5, 6)
  def screen(pages, n), do: pair(@keys, drop(pages, n * 6), [])

  def for_key(pages, key, n) do
    case :lists.keyfind(key, 1, screen(pages, n)) do
      {_key, module} -> module
      false -> nil
    end
  end

  def tick(%{goto: nil} = state), do: state
  def tick(%{goto: module}), do: {:goto, module}

  def handle_key(pages, {:move, direction}, state) when direction in [:right, :down],
    do: turn(pages, state, state.screen + 1)

  def handle_key(pages, {:move, direction}, state) when direction in [:left, :up],
    do: turn(pages, state, state.screen - 1)

  def handle_key(_pages, {:nav, :home}, %{screen: 0}), do: :ignore
  def handle_key(_pages, {:nav, :home}, state), do: {:ok, %{state | screen: 0}}

  def handle_key(pages, {:nav, key}, state),
    do: {:ok, %{state | goto: for_key(pages, key, state.screen)}}

  def handle_key(_pages, _event, _state), do: :ignore

  def render(pages, %{screen: screen}) do
    chevrons(screen, screens(pages)) ++
      cell_items(screen(pages, screen), @cell_origins, []) ++
      rule_items()
  end

  defp turn(pages, state, screen) do
    case screen >= 0 and screen < screens(pages) do
      true -> {:ok, %{state | screen: screen}}
      false -> :ignore
    end
  end

  defp chevrons(screen, count) do
    left = if screen > 0, do: [chevron(8, "<")], else: []
    right = if screen < count - 1, do: [chevron(Theme.width() - 16, ">")], else: []
    left ++ right
  end

  defp chevron(x, text),
    do: {:text, x, @chevron_y, :default16px, Theme.muted(), Theme.bg(), text}

  defp rule_items do
    [
      {:rect, 106, @top, 1, @bottom - @top, Theme.dim()},
      {:rect, 213, @top, 1, @bottom - @top, Theme.dim()}
    ] ++ Theme.rule(0, @top + @cell_h, Theme.width())
  end

  defp cell_items([], [], acc), do: :lists.reverse(acc)

  defp cell_items([{_key, nil} | slots], [_origin | origins], acc),
    do: cell_items(slots, origins, acc)

  defp cell_items([{key, module} | slots], [{x, y} | origins], acc) do
    label = module.title()
    {icon_w, _icon_h} = Icons.size(key)
    icon = Icons.item(key, x + div(@cell_w - icon_w, 2), y + 22)

    text =
      {:text, x + div(@cell_w - 8 * byte_size(label), 2), y + 64, :default16px, Theme.fg(),
       Theme.bg(), label}

    cell_items(slots, origins, [text, icon | acc])
  end

  defp pair([], _pages, acc), do: :lists.reverse(acc)
  defp pair([key | keys], [], acc), do: pair(keys, [], [{key, nil} | acc])
  defp pair([key | keys], [page | pages], acc), do: pair(keys, pages, [{key, page} | acc])
  defp drop(list, n) when n <= 0, do: list
  defp drop([], _n), do: []
  defp drop([_head | rest], n), do: drop(rest, n - 1)
end
