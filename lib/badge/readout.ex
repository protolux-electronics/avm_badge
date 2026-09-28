defmodule Badge.Readout do
  @moduledoc """
  Label and value rows, the shared shape of the status sub-pages.

  Positions are threaded by hand rather than with `Enum.with_index/1`, which
  AtomVM does not have.
  """

  alias Badge.Font
  alias Badge.Theme
  alias Badge.FontType

  @label_x 8
  @value_x 120
  @pitch 18
  @char_w 8

  @doc "Vertical gap between rows."
  def pitch, do: @pitch

  @doc "Display items for a list of `{label, value}` pairs, first row at `top`."
  @spec rows([{binary, binary}], integer) :: [tuple]
  def rows(pairs, top), do: rows(pairs, top, [])

  @doc "A single row whose value ends at the right margin instead of a fixed column."
  @spec right_row(binary, binary, integer, integer) :: [tuple]
  def right_row(label, value, y, colour) do
    [
      {:text, @label_x, y, :default16px, Theme.dim(), Theme.bg(), label},
      {:text, right_x(value), y, :default16px, colour, Theme.bg(), value}
    ]
  end

  @doc "The x at which text sits centred on the panel, measured in `font`."
  @spec centre_x(binary, atom) :: integer
  def centre_x(text, font \\ FontType.body()), do: div(Theme.width() - width(font, text), 2)

  @doc "The x at which text ends flush with the right margin, measured in `font`."
  @spec right_x(binary, atom) :: integer
  def right_x(text, font \\ FontType.body()), do: Theme.width() - @label_x - width(font, text)

  @doc "A single row whose value carries a colour of its own."
  @spec row(binary, binary, integer, integer) :: [tuple]
  def row(label, value, y, colour) do
    [
      {:text, @label_x, y, :default16px, Theme.dim(), Theme.bg(), label},
      {:text, @value_x, y, :default16px, colour, Theme.bg(), value}
    ]
  end

  # An unknown font falls back to the body's 8 px column rather than measuring nil.
  defp width(font, text), do: Font.width(font, text) || @char_w * byte_size(text)

  defp rows([], _y, acc), do: :lists.reverse(acc)

  defp rows([{label, value} | rest], y, acc) do
    rows(rest, y + @pitch, :lists.reverse(row(label, value, y, Theme.fg())) ++ acc)
  end
end
