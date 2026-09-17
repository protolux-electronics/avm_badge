defmodule Badge.Skin.Macintosh do
  @moduledoc """
  White desktop, pinstriped title bar with a close box, black hairline rules.

  The chrome is strictly black and white, as on a one-bit screen. Page
  colours are a grey ramp, so state reads from the words rather than the hue.
  """

  @behaviour Badge.Skin

  alias Badge.Font
  alias Badge.Icons
  alias Badge.Theme

  @white 0xFFFFFF
  @black 0x000000

  # Six pinstripes on alternate rows, inset from both edges.
  @stripe_x 2
  @stripe_w Theme.width() - 2 * @stripe_x
  @stripe_ys [5, 7, 9, 11, 13, 15]
  @stripes_y hd(@stripe_ys)
  @stripes_h List.last(@stripe_ys) - @stripes_y + 1
  @stripes for y <- @stripe_ys, do: {:rect, @stripe_x, y, @stripe_w, 1, @black}

  @text_y 3
  @title_pad 6

  # The close box spans the stripes, with a pixel of white either side.
  @box_x 9
  @box_y @stripes_y
  @box_size @stripes_h

  @status_margin 12
  @status_gap 6
  @status_pad 4
  @status_w elem(Icons.size(:battery_100), 0)
  @char_w 8
  @battery_x Theme.width() - @status_margin - @status_w
  @wifi_x @battery_x - @status_gap - @status_w
  @status_right @battery_x + @status_w + @status_pad
  @title_left @box_x + @box_size + 1

  @impl true
  def name, do: "Macintosh"

  @impl true
  def bg, do: @white
  @impl true
  def fg, do: @black
  @impl true
  def muted, do: 0x555555
  @impl true
  def dim, do: 0xAAAAAA
  @impl true
  def accent, do: 0x404040
  @impl true
  def ok, do: 0x808080
  @impl true
  def warn, do: 0x6A6A6A
  @impl true
  def alert, do: 0x1A1A1A
  @impl true
  def select, do: 0x2A2A2A
  @impl true
  def glyph, do: @black

  @impl true
  def chrome(title, status) do
    clock_x = @wifi_x - @status_gap - @char_w * byte_size(status.clock)
    status_x = clock_x - @status_pad

    [
      Icons.item(status.battery, @battery_x, @text_y, @black, @white),
      Icons.item(status.wifi, @wifi_x, @text_y, @black, @white),
      {:text, clock_x, @text_y, :default16px, @black, @white, status.clock},
      {:rect, status_x, @stripes_y, @status_right - status_x, @stripes_h, @white}
    ] ++
      title_items(title, status_x) ++
      close_box() ++
      @stripes ++
      rule(0, Theme.bar_h(), Theme.width()) ++
      [{:rect, 0, 0, Theme.width(), Theme.height(), @white}]
  end

  @impl true
  def rule(x, y, w), do: [{:rect, x, y, w, 1, @black}]

  # Centred on a white gap in the stripes left of the status cluster.
  defp title_items(title, right) do
    w = Font.width(:pixel_operator, title)
    x = div(@title_left + right - w, 2)

    [
      {:text, x, @text_y, :pixel_operator, @black, @white, title},
      {:rect, x - @title_pad, @stripes_y, w + 2 * @title_pad, @stripes_h, @white}
    ]
  end

  # A white face inside a black outline, on a white gap one pixel wider each side.
  defp close_box do
    [
      {:rect, @box_x + 1, @box_y + 1, @box_size - 2, @box_size - 2, @white},
      {:rect, @box_x, @box_y, @box_size, @box_size, @black},
      {:rect, @box_x - 1, @box_y, @box_size + 2, @box_size, @white}
    ]
  end
end
