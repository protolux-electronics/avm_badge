defmodule Badge.Page.Home do
  @moduledoc """
  The 3x2 legend of which button opens which page, in two screens.

  The first screen is the shape keys' own pages. Right or Down turns to the
  second, `Badge.Apps`, which borrow the same six keys while it shows, so
  each cell carries the shape that opens it. Left, Up or Esc turn back.
  There is no cursor on either screen.

  A page cannot switch pages from a key handler, so a shape key on the apps
  screen only notes the choice and the next `tick/1` hands the screen over.
  `Badge.UI` offers shape keys to the page first for exactly this.
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
  @cols_x [0, 107, 214]
  @rows_y [@top, @top + @cell_h + 2]

  @icon_dy 22
  @label_dy 64
  @char_w 8

  # Same order as Badge.Pages.all/0, so the two lists walk together.
  @cell_origins for y <- @rows_y, x <- @cols_x, do: {x, y}

  @impl true
  def title, do: "Badge"

  @impl true
  def init, do: %{grid: :shapes, goto: nil}

  @doc "Which screen is on the panel."
  @spec grid(map) :: :shapes | :apps
  def grid(%{grid: grid}), do: grid

  @impl true
  def render(%{grid: :shapes}) do
    cell_items(Pages.all(), @cell_origins, []) ++ rule_items()
  end

  def render(%{grid: :apps}) do
    app_items(Pages.all(), Apps.all(), @cell_origins, []) ++ rule_items()
  end

  @impl true
  def handle_key({:move, direction}, %{grid: :shapes} = state)
      when direction in [:right, :down] do
    {:ok, %{state | grid: :apps}}
  end

  def handle_key({:move, direction}, %{grid: :apps} = state)
      when direction in [:left, :up] do
    {:ok, %{state | grid: :shapes}}
  end

  def handle_key({:nav, :home}, %{grid: :apps} = state) do
    {:ok, %{state | grid: :shapes}}
  end

  # An empty slot swallows its key rather than opening the shape's usual page.
  def handle_key({:nav, key}, %{grid: :apps} = state) do
    {:ok, %{state | goto: Apps.for_key(key)}}
  end

  def handle_key(_event, _state), do: :ignore

  @impl true
  def tick(%{goto: nil} = state), do: state
  def tick(%{goto: module}), do: {:goto, module}

  defp rule_items do
    [
      {:rect, 106, @top, 1, @bottom - @top, Theme.dim()},
      {:rect, 213, @top, 1, @bottom - @top, Theme.dim()}
    ] ++ Theme.rule(0, @top + @cell_h, Theme.width())
  end

  # Pages and origins threaded together so a label always sits under its own icon.
  defp cell_items([], [], acc), do: :lists.reverse(acc)

  defp cell_items([{_key, nil} | pages], [_origin | origins], acc) do
    cell_items(pages, origins, acc)
  end

  defp cell_items([{_key, module} | pages], [origin | origins], acc) do
    cell_items(pages, origins, cell(module.icon(), module, origin) ++ acc)
  end

  # Slots and apps walk together; the apps run out first and the rest stay empty.
  defp app_items(_slots, [], _origins, acc), do: :lists.reverse(acc)

  defp app_items([{key, _page} | slots], [module | apps], [origin | origins], acc) do
    app_items(slots, apps, origins, cell(key, module, origin) ++ acc)
  end

  # The icon that opens the cell, with the page's title under it.
  defp cell(icon, module, {x, y}) do
    {icon_w, _icon_h} = Icons.size(icon)

    [label(module, x, y), Icons.item(icon, x + div(@cell_w - icon_w, 2), y + @icon_dy)]
  end

  defp label(module, x, y) do
    text = module.title()

    {:text, x + div(@cell_w - @char_w * byte_size(text), 2), y + @label_dy, :default16px,
     Theme.fg(), Theme.bg(), text}
  end
end
