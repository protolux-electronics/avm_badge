defmodule Badge.Sim.Font do
  @moduledoc "Glyphs as AtomGL reads them: the built-in 8x16 font and `.uf` files."

  @builtin_path Path.expand("../../../priv/font8x16.bin", __DIR__)
  @external_resource @builtin_path

  # The Linux 8x16 console font AtomGL ships as default16px, one byte per row.
  @builtin File.read!(@builtin_path)

  def builtin_glyph(char) when char < 256, do: :binary.part(@builtin, char * 16, 16)
  def builtin_glyph(_char), do: builtin_glyph(??)

  @doc "Parses a .uf file into what drawing needs."
  def load(path) do
    data = File.read!(path)
    records = records(data, 12, %{})
    {header, _} = records["uFH0"]

    <<interval_count::little-32, compressed::8, advance_y::little-16, ascender::little-16,
      descender::little-16, _::binary>> = binary_part(data, header, 11)

    {glyphs, _} = records["uFP0"]
    {intervals, _} = records["uFI0"]
    {bitmap, bitmap_size} = records["uFB0"]

    %{
      data: data,
      glyphs: glyphs,
      intervals:
        for i <- 0..(interval_count - 1) do
          <<first::little-32, last::little-32, offset::little-32>> =
            binary_part(data, intervals + i * 12, 12)

          {first, last, offset}
        end,
      compressed: compressed != 0,
      advance_y: advance_y,
      ascender: ascender,
      descender: descender,
      bitmap: binary_part(data, bitmap, bitmap_size)
    }
  end

  defp records(data, pos, acc) when pos + 8 > byte_size(data), do: acc

  defp records(data, pos, acc) do
    <<name::binary-4, size::big-32>> = binary_part(data, pos, 8)
    next = pos + 8 + size
    records(data, next + rem(4 - rem(next, 4), 4), Map.put(acc, name, {pos + 8, size}))
  end

  def glyph(font, cp) do
    case Enum.find(font.intervals, fn {first, last, _} -> cp >= first and cp <= last end) do
      nil ->
        nil

      {first, _last, offset} ->
        index = offset + cp - first

        <<width::little-16, height::little-16, advance::little-16, left::little-signed-16,
          top::little-signed-16, csize::little-32, doffset::little-32>> =
          binary_part(font.data, font.glyphs + index * 18, 18)

        byte_width = div(width + 1, 2)

        bits =
          case font.compressed do
            true -> :zlib.uncompress(binary_part(font.bitmap, doffset, csize))
            false -> binary_part(font.bitmap, doffset, byte_width * height)
          end

        %{width: width, height: height, advance: advance, left: left, top: top, bits: bits, bw: byte_width}
    end
  end

  @doc "Intensity 0..15 of a glyph pixel."
  def level(glyph, x, y) do
    byte = :binary.at(glyph.bits, y * glyph.bw + div(x, 2))

    case rem(x, 2) do
      0 -> Bitwise.band(byte, 0xF)
      1 -> Bitwise.bsr(byte, 4)
    end
  end
end
