defmodule Badge.Skin.Solaris do
  @moduledoc """
  CDE as Sun shipped it: a lilac-grey client area under a mauve window
  frame, with a window menu button on the left and minimise and maximise
  buttons on the right.

  Backgrounds are from CDE's Crimson palette. Shadows and the darker page
  colours are those backgrounds run through Motif's shadow calculation.
  """

  @behaviour Badge.Skin

  alias Badge.Icons
  alias Badge.Theme

  @white 0xFFFFFF
  @black 0x000000
  @body 0xAEB2C3
  @body_light 0xDCDEE5
  @body_dark 0x5D6069
  @frame 0xB24D7A
  @frame_light 0xDCADC2
  @frame_dark 0x57253B

  @button_w Theme.bar_h()
  @maximise_x Theme.width() - @button_w
  @minimise_x @maximise_x - @button_w
  @title_x @button_w
  @title_w @minimise_x - @title_x

  @text_y 3
  @text_x @title_x + 6
  @char_w 8

  @status_gap 6
  @status_w elem(Icons.size(:battery_100), 0)
  @battery_x @minimise_x - @status_gap - @status_w
  @wifi_x @battery_x - @status_gap - @status_w

  @impl true
  def name, do: "Solaris"

  @impl true
  def bg, do: @body
  @impl true
  def fg, do: @black
  @impl true
  def muted, do: @body_dark
  @impl true
  def dim, do: 0x9397A5
  @impl true
  def accent, do: 0x384552
  @impl true
  def ok, do: 0x355452
  @impl true
  def warn, do: 0x7D593B
  @impl true
  def alert, do: 0x6F5050
  @impl true
  def select, do: @frame_dark
  @impl true
  def glyph, do: @black

  # Frame icons are white on mauve, like the title beside them.
  @impl true
  def chrome(title, status) do
    [
      Icons.item(status.battery, @battery_x, @text_y, @white, @frame),
      Icons.item(status.wifi, @wifi_x, @text_y, @white, @frame),
      clock_item(status.clock),
      {:text, @text_x, @text_y, :pixel_operator, @white, @frame, title}
    ] ++
      menu_bar() ++
      raised(@minimise_x + 9, 9, 4, 4) ++
      raised(@maximise_x + 6, 6, 10, 10) ++
      raised(0, 0, @button_w, @button_w) ++
      raised(@title_x, 0, @title_w, @button_w) ++
      raised(@minimise_x, 0, @button_w, @button_w) ++
      raised(@maximise_x, 0, @button_w, @button_w) ++
      [{:rect, 0, 0, Theme.width(), Theme.bar_h(), @frame}] ++
      rule(0, Theme.bar_h(), Theme.width()) ++
      [{:rect, 0, 0, Theme.width(), Theme.height(), @body}]
  end

  # An etched line: shadow above, highlight below.
  @impl true
  def rule(x, y, w) do
    [{:rect, x, y, w, 1, @body_dark}, {:rect, x, y + 1, w, 1, @body_light}]
  end

  defp clock_item(clock) do
    x = div(Theme.width() - @char_w * byte_size(clock), 2)

    {:text, x, @text_y, :default16px, @white, @frame, clock}
  end

  # The window menu button's bar: a highlight row over a shadow row.
  defp menu_bar do
    x = div(@button_w - 10, 2)

    [{:rect, x, 10, 10, 1, @frame_light}, {:rect, x, 11, 10, 1, @frame_dark}]
  end

  # Highlight on the top and left edges, shadow on the bottom and right.
  defp raised(x, y, w, h) do
    [
      {:rect, x, y, w, 1, @frame_light},
      {:rect, x, y, 1, h, @frame_light},
      {:rect, x, y + h - 1, w, 1, @frame_dark},
      {:rect, x + w - 1, y, 1, h, @frame_dark}
    ]
  end
end
