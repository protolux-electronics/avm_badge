defmodule Badge.FontType do
  @moduledoc """
  Which font a piece of text is drawn in.

  `Badge.Font` measures a font; this module decides when to use one. Ask for
  the role, not the file: body text is what someone reads at length, headings
  are section titles, tab labels and empty states, readouts are short numbers
  and units.

  `dogica` is 16 px per glyph, so an `readout/0` line is capped at about 20
  characters; `pixel_operator` is proportional and must be measured with
  `Badge.Font.width/2`, never with an 8 px column.
  """

  @doc "Text read at length: messages, values, help."
  def body, do: :default16px

  @doc "Section titles, tab labels, empty states."
  def heading, do: :pixel_operator

  @doc "Short numeric readouts, drawn in the fixed-width pixel display font."
  def readout, do: :dogica

  @doc "The badge's own name; loadable, and only drawn on the Name page."
  def large, do: :w95fa
end