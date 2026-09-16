defmodule Badge.Sim.Raster do
  @moduledoc "Text as AtomGL rasterises it, in the built-in font or one of the `.uf` fonts."

  import Bitwise

  alias Badge.Sim.Font

  @fonts (for name <- [:dogica, :pixel_operator, :w95fa], into: %{} do
            {name, Font.load(Path.expand("../../../../assets/fonts/#{name}.uf", __DIR__))}
          end)

  @doc "An `{width, height, rgba}` bitmap of `text` in `font`, or nil for an unknown font."
  def text(:default16px, fg, bg, text) do
    chars = :binary.bin_to_list(text)
    width = length(chars) * 8

    rows =
      for y <- 0..15, into: <<>> do
        for char <- chars, x <- 0..7, into: <<>> do
          row = :binary.at(Font.builtin_glyph(char), y)
          pixel(if((row &&& 0x80 >>> x) != 0, do: 15, else: 0), fg, bg)
        end
      end

    {width, 16, rows}
  end

  def text(font, fg, bg, text) do
    case Map.get(@fonts, font) do
      nil ->
        nil

      f ->
        glyphs = for cp <- String.to_charlist(text), g = Font.glyph(f, cp), g != nil, do: g
        width = max(Enum.sum(for g <- glyphs, do: g.advance), 1)
        height = f.ascender + f.descender
        blank = for _ <- 1..(width * height), into: <<>>, do: pixel(0, fg, bg)
        canvas = :binary.bin_to_list(blank) |> Enum.chunk_every(4) |> List.to_tuple()

        {canvas, _x} =
          Enum.reduce(glyphs, {canvas, 0}, fn g, {canvas, cursor} ->
            canvas =
              for y <- 0..(g.height - 1), x <- 0..(g.width - 1), reduce: canvas do
                canvas ->
                  px = cursor + g.left + x
                  py = f.ascender - g.top + y
                  level = Font.level(g, x, y)

                  if level > 0 and px >= 0 and px < width and py >= 0 and py < height do
                    put_elem(canvas, py * width + px, :binary.bin_to_list(pixel(level, fg, bg)))
                  else
                    canvas
                  end
              end

            {canvas, cursor + g.advance}
          end)

        {width, height, canvas |> Tuple.to_list() |> List.flatten() |> :binary.list_to_bin()}
    end
  end

  # Level 15 is pure foreground; a transparent background leaves alpha to say how much ink there is.
  defp pixel(level, fg, :transparent), do: <<fg >>> 16 &&& 0xFF, fg >>> 8 &&& 0xFF, fg &&& 0xFF, level * 17>>

  defp pixel(level, fg, bg) do
    <<mix(fg >>> 16 &&& 0xFF, bg >>> 16 &&& 0xFF, level), mix(fg >>> 8 &&& 0xFF, bg >>> 8 &&& 0xFF, level),
      mix(fg &&& 0xFF, bg &&& 0xFF, level), 0xFF>>
  end

  defp mix(fg, bg, level), do: div(bg * (15 - level) + fg * level, 15)
end
