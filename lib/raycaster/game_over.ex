defmodule Raycaster.GameOver do
  @moduledoc """
  The screen for a player the goat has caught: the goat itself, close and
  hunting, on dark red, with how long they lasted and what to do next.

  A display list like any frame, drawn once and left up until a key is pressed.
  The goat is `Engine.sprites/5` looking at one a cell and three quarters away,
  so it is the same goat as in the game.
  """

  alias Raycaster.Engine

  # The default font is 8 pixels to a character.
  @char 8
  @back 0x3A0808
  @band 0xB01010
  @panel 0x240404
  @glow 0x5A0C0C

  # Where the goat is looked at from: open floor on row 9, facing east.
  @eye_x 2 * 256 + 128
  @eye_y 9 * 256 + 128
  @goat_at 448

  def items(grid, survived_s, width, height) do
    lasted = :erlang.integer_to_binary(survived_s)

    goat =
      Engine.sprites(
        grid,
        %{x: @eye_x, y: @eye_y, a: 0},
        [{:goat, @eye_x + @goat_at, @eye_y, true}],
        width,
        height
      )

    [
      text(width, 22, 0xFFFFFF, "GAME OVER"),
      text(width, 50, 0xFFD0D0, "The evil goat got you"),
      text(width, height - 44, 0xFFD0D0, "You lasted " <> lasted <> " s"),
      text(width, height - 24, 0xFFFF00, "Press any key")
    ] ++
      goat ++
      [
        {:rounded_rect, 40, height - 50, width - 80, 46, 10, @panel},
        {:rounded_rect, 24, 14, width - 48, 32, 10, @band},
        {:ellipse, div(width, 2), div(height, 2) + 10, 120, 95, @glow},
        {:rect, 0, 0, width, height, @back}
      ]
  end

  defp text(width, y, colour, text) do
    x = div(width - byte_size(text) * @char, 2)
    {:text, x, y, :default16px, colour, :transparent, text}
  end
end
