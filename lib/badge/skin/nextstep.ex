defmodule Badge.Skin.NeXTSTEP do
  @moduledoc """
  A light grey client area under the key window's black title bar, with a
  miniaturise button on the left and a close button on the right.

  The chrome uses only the four greys of NeXT's two-bit display. Page
  colours add a few steps between them, so state reads from the words
  rather than the hue.
  """

  @behaviour Badge.Skin

  alias Badge.Font
  alias Badge.Icons
  alias Badge.Theme

  @white 0xFFFFFF
  @light 0xAAAAAA
  @dark 0x555555
  @black 0x000000

  @text_y 3
  @char_w 8

  # Square bevelled buttons, inset two pixels from the bar's ends.
  @button 18
  @button_y 2
  @miniaturise_x 2
  @close_x Theme.width() - 2 - @button

  @status_gap 6
  @status_pad 4
  @status_w elem(Icons.size(:battery_100), 0)
  @battery_x @close_x - @status_gap - @status_w
  @wifi_x @battery_x - @status_gap - @status_w
  @title_left @miniaturise_x + @button

  @impl true
  def name, do: "NeXTSTEP"

  @impl true
  def bg, do: @light
  @impl true
  def fg, do: @black
  @impl true
  def muted, do: @dark
  @impl true
  def dim, do: 0x8A8A8A
  @impl true
  def accent, do: 0x2A2A2A
  @impl true
  def ok, do: 0x404040
  @impl true
  def warn, do: 0x6A6A6A
  @impl true
  def alert, do: 0x1A1A1A
  @impl true
  def select, do: @white
  @impl true
  def glyph, do: @black

  # Title bar icons are white on black, like the title beside them.
  @impl true
  def chrome(title, status) do
    clock_x = @wifi_x - @status_gap - @char_w * byte_size(status.clock)

    [
      Icons.item(status.battery, @battery_x, @text_y, @white, @black),
      Icons.item(status.wifi, @wifi_x, @text_y, @white, @black),
      {:text, clock_x, @text_y, :default16px, @white, @black, status.clock},
      title_item(title, clock_x - @status_pad)
    ] ++
      miniaturise_button() ++
      close_button() ++
      [{:rect, 0, 0, Theme.width(), Theme.bar_h(), @black}] ++
      rule(0, Theme.bar_h(), Theme.width()) ++
      [{:rect, 0, 0, Theme.width(), Theme.height(), @light}]
  end

  # A groove: dark grey above, white below.
  @impl true
  def rule(x, y, w) do
    [{:rect, x, y, w, 1, @dark}, {:rect, x, y + 1, w, 1, @white}]
  end

  # Centred between the miniaturise button and the clock.
  defp title_item(title, right) do
    x = div(@title_left + right - Font.width(:pixel_operator, title), 2)

    {:text, x, @text_y, :pixel_operator, @white, @black, title}
  end

  # A small hollow square: black outline, white inside.
  defp miniaturise_button do
    inner = @miniaturise_x + 5

    [
      {:rect, inner + 1, @button_y + 6, 6, 6, @white},
      {:rect, inner, @button_y + 5, 8, 8, @black}
    ] ++ bezel(@miniaturise_x)
  end

  defp close_button do
    [
      {:text, @close_x + div(@button - @char_w, 2), @button_y + 1, :default16px, @black, @light,
       "x"}
    ] ++ bezel(@close_x)
  end

  # White on the top and left edges, dark grey on the bottom and right, light grey beneath.
  defp bezel(x) do
    edge = @button - 1

    [
      {:rect, x, @button_y, @button, 1, @white},
      {:rect, x, @button_y, 1, @button, @white},
      {:rect, x, @button_y + edge, @button, 1, @dark},
      {:rect, x + edge, @button_y, 1, @button, @dark},
      {:rect, x, @button_y, @button, @button, @light}
    ]
  end
end
