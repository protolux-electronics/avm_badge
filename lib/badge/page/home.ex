defmodule Badge.Page.Home do
  @moduledoc """
  The 3x2 legend of which button opens which page, one screen of six at a time.

  Right or Down turns to the next screen of `Badge.Pages` and Left, Up or
  Esc turn back; a chevron in a bottom corner shows when there is a screen
  that way. Each cell carries the shape that opens it, on every screen.
  There is no cursor.

  A page cannot switch pages from a key handler, so a shape key here only
  notes the choice and the next `tick/1` hands the screen over. `Badge.UI`
  offers shape keys to the page first for exactly this, so a key on a later
  screen opens that screen's page rather than the first screen's.
  """

  use Badge.Page

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
  @margin 8

  @chevron_y Theme.height() - 18

  # Cells in reading order, which is the order of a screen's slots.
  @cell_origins for y <- @rows_y, x <- @cols_x, do: {x, y}

  @impl true
  def title, do: "Badge"

  @impl true
  def init, do: %{screen: 0, goto: nil}

  @doc "Which screen of the grid is on the panel, from zero."
  @spec screen(map) :: non_neg_integer
  def screen(%{screen: screen}), do: screen

  @impl true
  def render(%{screen: screen}) do
    chevrons(screen) ++ cell_items(Pages.screen(screen), @cell_origins, []) ++ rule_items()
  end

  @impl true
  def handle_key({:move, direction}, state) when direction in [:right, :down] do
    turn(state, state.screen + 1)
  end

  def handle_key({:move, direction}, state) when direction in [:left, :up] do
    turn(state, state.screen - 1)
  end

  def handle_key({:nav, :home}, %{screen: 0}), do: :ignore
  def handle_key({:nav, :home}, state), do: {:ok, %{state | screen: 0}}

  # The first screen is the router's to open; on a later one an empty slot
  # swallows its key rather than opening the first screen's page.
  def handle_key({:nav, _key}, %{screen: 0}), do: :ignore

  def handle_key({:nav, key}, state) do
    {:ok, %{state | goto: Pages.for_key(key, state.screen)}}
  end

  def handle_key(_event, _state), do: :ignore

  @impl true
  def tick(%{goto: nil} = state), do: state
  def tick(%{goto: module}), do: {:goto, module}

  # Off either end there is nothing to turn to; let the router keep the key.
  defp turn(state, screen) do
    case screen >= 0 and screen < Pages.screens() do
      true -> {:ok, %{state | screen: screen}}
      false -> :ignore
    end
  end

  defp chevrons(screen) do
    left =
      case screen > 0 do
        true -> [chevron(@margin, "<")]
        false -> []
      end

    right =
      case screen < Pages.screens() - 1 do
        true -> [chevron(Theme.width() - @margin - @char_w, ">")]
        false -> []
      end

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

  # Slots and origins threaded together so a label always sits under its own icon.
  defp cell_items([], [], acc), do: :lists.reverse(acc)

  defp cell_items([{_key, nil} | slots], [_origin | origins], acc) do
    cell_items(slots, origins, acc)
  end

  defp cell_items([{key, module} | slots], [{x, y} | origins], acc) do
    label = module.title()

    {icon_w, _icon_h} = Icons.size(key)
    icon = Icons.item(key, x + div(@cell_w - icon_w, 2), y + @icon_dy)

    text =
      {:text, x + div(@cell_w - @char_w * byte_size(label), 2), y + @label_dy, :default16px,
       Theme.fg(), Theme.bg(), label}

    cell_items(slots, origins, [text, icon | acc])
  end
end
