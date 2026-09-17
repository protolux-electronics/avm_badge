defmodule Badge.Page.About do
  @moduledoc """
  The Goatmire badge story, credits and repository QR code.

  Left and right move through the three static screens. The repository code is
  encoded once on entry and uses the same AtomGL item on hardware and in the
  simulator.
  """

  use Badge.Page

  alias Badge.Font
  alias Badge.Icons
  alias Badge.QR
  alias Badge.Theme

  @repository "https://github.com/protolux-electronics/avm_badge"

  @screens 3
  @dot 6
  @dot_gap 10
  @dot_y 232

  @impl true
  def title, do: "About"

  @impl true
  def icon, do: :triangle

  @impl true
  def init, do: %{index: 0, qr: QR.encode(@repository)}

  @impl true
  def handle_key({:move, :right}, state) do
    {:ok, %{state | index: rem(state.index + 1, @screens)}}
  end

  def handle_key({:move, :left}, state) do
    {:ok, %{state | index: rem(state.index + @screens - 1, @screens)}}
  end

  def handle_key(_event, _state), do: :ignore

  @impl true
  def render(%{index: index} = state), do: screen(index, state) ++ dots(index)

  defp screen(0, _state) do
    [
      heading("Description"),
      centered("Made for Goatmire", 62),
      text(16, 86, "An open, hackable badge by"),
      centered("Protolux Electronics", 106),
      text(16, 136, "ESP32-S3 + ST7789 display"),
      text(16, 160, "6x13 keyboard + SK6812 LEDs"),
      text(16, 184, "Elixir firmware on AtomVM")
    ]
  end

  defp screen(1, _state) do
    [
      heading("Credits"),
      credit("Gus Workman", 68),
      credit("Lars Wikman", 100),
      credit("Pepe Marquez", 132),
      credit("Davide Bettio", 164)
    ]
  end

  defp screen(2, %{qr: {:ok, code}}) do
    scale = 3
    width = (code.size + 8) * scale

    [heading("Getting started"), QR.item(code, div(Theme.width() - width, 2), 54, scale)] ++
      repository_label(190)
  end

  defp screen(2, %{qr: {:error, _reason}}) do
    [heading("Getting started"), centered("QR unavailable", 104)] ++ repository_label(190)
  end

  defp text(x, y, body) do
    {:text, x, y, :default16px, Theme.fg(), Theme.bg(), body}
  end

  defp heading(body) do
    x = div(Theme.width() - byte_size(body) * 8, 2)
    {:text, x, 30, :default16px, Theme.accent(), Theme.bg(), body}
  end

  defp centered(body, y), do: centered(body, y, :default16px)

  defp centered(body, y, font) do
    x = div(Theme.width() - Font.width(font, body), 2)
    {:text, x, y, font, Theme.fg(), Theme.bg(), body}
  end

  defp credit(body, y), do: centered(body, y, :pixel_operator)

  defp repository_label(y) do
    body = "protolux-electronics/avm_badge"
    {icon_width, _height} = Icons.size(:github)
    gap = 6
    width = icon_width + gap + Font.width(:pixel_operator, body)
    x = div(Theme.width() - width, 2)

    [
      Icons.item(:github, x, y),
      {:text, x + icon_width + gap, y, :pixel_operator, Theme.fg(), Theme.bg(), body}
    ]
  end

  defp dots(current) do
    left = div(Theme.width() - (@screens * @dot + (@screens - 1) * (@dot_gap - @dot)), 2)

    for index <- 0..(@screens - 1) do
      colour = if index == current, do: Theme.fg(), else: Theme.dim()

      {:rect, left + index * @dot_gap, @dot_y, @dot, @dot, colour}
    end
  end
end
