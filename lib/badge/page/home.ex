defmodule Badge.Page.Home do
  @moduledoc """
  The 3x2 legend of which button opens which page, and behind it the apps.

  The first screen is informational: there is no cursor, and pressing a
  shape key navigates from anywhere, so it handles no input. Any arrow key
  turns the page to the second screen, a grid of `Badge.Apps` with a cursor
  that the arrows move and Enter opens. Esc, or Left off the first column,
  turns back to the shapes.

  A page cannot switch pages from a key handler, so Enter only notes which
  app was chosen and the next `tick/1` hands the screen over.
  """

  use Badge.Page

  alias Badge.Apps
  alias Badge.Icons
  alias Badge.Pages
  alias Badge.Theme

  @top Theme.content_top()
  @bottom Theme.height() - 2

  @cell_w 106
  @cell_h 105
  @cols 3
  @cols_x [0, 107, 214]
  @rows_y [@top, @top + @cell_h + 2]

  @icon_dy 22
  @label_dy 64
  @char_w 8
  @frame 2

  # Same order as Badge.Pages.all/0, so the two lists walk together.
  @cell_origins for y <- @rows_y, x <- @cols_x, do: {x, y}

  @impl true
  def title, do: "Badge"

  @impl true
  def init, do: %{grid: :shapes, cursor: 0, goto: nil}

  @doc "Which grid is on the panel."
  @spec grid(map) :: :shapes | :apps
  def grid(%{grid: grid}), do: grid

  @doc "Which app the cursor is on."
  @spec cursor(map) :: non_neg_integer
  def cursor(%{cursor: cursor}), do: cursor

  @impl true
  def render(%{grid: :shapes}) do
    cell_items(Pages.all(), @cell_origins, []) ++ rule_items()
  end

  def render(%{grid: :apps, cursor: cursor}) do
    frame_items(:lists.nth(cursor + 1, @cell_origins)) ++
      cell_items(Apps.all(), @cell_origins, []) ++ rule_items()
  end

  @impl true
  def handle_key({:move, _direction}, %{grid: :shapes} = state) do
    {:ok, %{state | grid: :apps, cursor: 0}}
  end

  def handle_key({:move, direction}, %{grid: :apps} = state) do
    {:ok, moved(direction, state)}
  end

  def handle_key({:edit, :newline}, %{grid: :apps, cursor: cursor} = state) do
    case Apps.at(cursor) do
      nil -> :ignore
      module -> {:ok, %{state | goto: module}}
    end
  end

  def handle_key({:nav, :home}, %{grid: :apps} = state) do
    {:ok, %{state | grid: :shapes, cursor: 0}}
  end

  def handle_key(_event, _state), do: :ignore

  @impl true
  def tick(%{goto: nil} = state), do: state
  def tick(%{goto: module}), do: {:goto, module}

  defp moved(:left, %{cursor: cursor} = state) when rem(cursor, @cols) == 0 do
    %{state | grid: :shapes, cursor: 0}
  end

  defp moved(:left, state), do: place(state, state.cursor - 1)

  defp moved(:right, %{cursor: cursor} = state) when rem(cursor, @cols) == @cols - 1, do: state
  defp moved(:right, state), do: place(state, state.cursor + 1)
  defp moved(:up, state), do: place(state, state.cursor - @cols)
  defp moved(:down, state), do: place(state, state.cursor + @cols)

  # A move that would leave the apps stays put.
  defp place(state, cursor) do
    case cursor >= 0 and cursor < Apps.count() and cursor < length(@cell_origins) do
      true -> %{state | cursor: cursor}
      false -> state
    end
  end

  defp rule_items do
    [
      {:rect, 106, @top, 1, @bottom - @top, Theme.dim()},
      {:rect, 213, @top, 1, @bottom - @top, Theme.dim()}
    ] ++ Theme.rule(0, @top + @cell_h, Theme.width())
  end

  # Four thin rects around the cell the cursor is on. Drawn first, so on top.
  defp frame_items({x, y}) do
    colour = Theme.select()

    [
      {:rect, x, y, @cell_w, @frame, colour},
      {:rect, x, y + @cell_h - @frame, @cell_w, @frame, colour},
      {:rect, x, y, @frame, @cell_h, colour},
      {:rect, x + @cell_w - @frame, y, @frame, @cell_h, colour}
    ]
  end

  # Pages and origins threaded together so a label always sits under its own icon.
  defp cell_items([], _origins, acc), do: :lists.reverse(acc)
  defp cell_items(_pages, [], acc), do: :lists.reverse(acc)

  defp cell_items([{_key, nil} | pages], [_origin | origins], acc) do
    cell_items(pages, origins, acc)
  end

  defp cell_items([{_key, module} | pages], origins, acc) do
    cell_items([module | pages], origins, acc)
  end

  defp cell_items([module | pages], [{x, y} | origins], acc) do
    label = module.title()

    {icon_w, _icon_h} = Icons.size(module.icon())
    icon = Icons.item(module.icon(), x + div(@cell_w - icon_w, 2), y + @icon_dy)

    text =
      {:text, x + div(@cell_w - @char_w * byte_size(label), 2), y + @label_dy, :default16px,
       Theme.fg(), Theme.bg(), label}

    cell_items(pages, origins, [text, icon | acc])
  end
end
