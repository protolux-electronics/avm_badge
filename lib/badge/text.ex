defmodule Badge.Text do
  @moduledoc """
  Wrapping for fixed-width text.

  Pure, and hand-rolled: AtomVM has no `String` module at runtime, so
  binaries are walked a byte at a time.
  """

  # Code page 437 bytes for Latin-1 from 0xA0, or the bare letter where the page has none.
  @latin1 " \xAD\x9B\x9C?\x9D|??c\xA6\xAE\xAA-R-" <>
            "\xF8\xF1\xFD3'\xE6?.,1\xA7\xAF\xAC\xAB?\xA8" <>
            "AAAA\x8E\x8F\x92\x80E\x90EEIIII" <>
            "D\xA5OOOO\x99xOUUU\x9AYT\xE1" <>
            "\x85\xA0\x83a\x84\x86\x91\x87\x8A\x82\x88\x89\x8D\xA1\x8C\x8B" <>
            "d\xA4\x95\xA2\x93o\x94\xF6o\x97\xA3\x96\x81yt\x98"

  # The bare letter for each Latin Extended-A codepoint; the page has none of them.
  @latin_a "AaAaAaCcCcCcCcDdDdEeEeEeEeEeGgGgGgGgHhHhIiIiIiIiIiIiJjKkkLlLlLlLlLlNnNnNnnNnOoOoOoOoRrRrRrSsSsSsSsTtTtTtUuUuUuUuUuUuWwYyYZzZzZzs"

  @doc """
  Folds UTF-8 text to the bytes the built-in `default16px` font draws.

  That font is the VGA 8x16 in code page 437, one glyph per byte, so an
  accented letter the page has keeps its accent as that page's byte, one it
  lacks becomes the bare letter, typographic quotes, dashes and spaces
  become the plain kind, and anything else is a question mark. A byte that
  is not UTF-8 is a question mark too. The result is not UTF-8.
  """
  @spec cp437(binary) :: binary
  def cp437(text), do: cp437(text, [])

  defp cp437(<<>>, acc), do: :erlang.list_to_binary(:lists.reverse(acc))

  defp cp437(<<byte, rest::binary>>, acc) when byte < 0x80, do: cp437(rest, [byte | acc])

  defp cp437(<<lead, tail, rest::binary>>, acc)
       when lead >= 0xC0 and lead < 0xE0 and tail >= 0x80 and tail < 0xC0 do
    cp437(rest, [fold((lead - 0xC0) * 64 + (tail - 0x80)) | acc])
  end

  defp cp437(<<lead, second, third, rest::binary>>, acc)
       when lead >= 0xE0 and lead < 0xF0 and second >= 0x80 and second < 0xC0 and
              third >= 0x80 and third < 0xC0 do
    cp437(rest, [fold((lead - 0xE0) * 4096 + (second - 0x80) * 64 + (third - 0x80)) | acc])
  end

  defp cp437(<<lead, second, third, fourth, rest::binary>>, acc)
       when lead >= 0xF0 and lead < 0xF8 and second >= 0x80 and second < 0xC0 and
              third >= 0x80 and third < 0xC0 and fourth >= 0x80 and fourth < 0xC0 do
    cp437(rest, [?? | acc])
  end

  defp cp437(<<_bad, rest::binary>>, acc), do: cp437(rest, [?? | acc])

  defp fold(code) when code >= 0xA0 and code <= 0xFF, do: :binary.at(@latin1, code - 0xA0)
  defp fold(code) when code >= 0x100 and code <= 0x17F, do: :binary.at(@latin_a, code - 0x100)
  defp fold(code) when code >= 0x2010 and code <= 0x2015, do: ?-

  defp fold(code) when code == 0x2018 or code == 0x2019 or code == 0x201A or code == 0x2032,
    do: ?'

  defp fold(code) when code == 0x201C or code == 0x201D or code == 0x201E or code == 0x2033,
    do: ?"

  defp fold(0x2026), do: ~c"..."
  defp fold(code) when code == 0x2009 or code == 0x202F, do: ?\s
  defp fold(0x2212), do: ?-
  defp fold(_code), do: ??

  @doc """
  Breaks `text` into lines of at most `columns` characters.

  Breaks at the last space that fits, so words stay whole. A word longer
  than a line has nowhere to break, so it is split and a dash joins it to
  the line below. The dash costs a column, so the break comes one character
  early.

  `orphan` is how much ragged gap a space may leave before splitting is
  preferred to it. A long unbroken word after a short one would otherwise
  push a nearly empty line, so a space further back than this is passed over
  and the word is dashed instead. `:never` keeps every space, which is what
  wrapping a name wants.
  """
  @spec wrap(binary, pos_integer, non_neg_integer | :never) :: [binary]
  def wrap(text, columns, orphan \\ :never)
  def wrap(text, columns, _orphan) when columns < 1, do: [text]
  def wrap(<<>>, _columns, _orphan), do: [""]
  def wrap(text, columns, orphan), do: lines(text, columns, orphan, [])

  defp lines(text, columns, _orphan, acc) when byte_size(text) <= columns do
    :lists.reverse([text | acc])
  end

  defp lines(text, columns, orphan, acc) do
    case break_at(text, columns) do
      0 -> dash(text, columns, orphan, acc)
      at -> at_space(text, columns, orphan, at, acc)
    end
  end

  # A space so far back that breaking on it would leave the line half empty.
  defp at_space(text, columns, orphan, at, acc)
       when is_integer(orphan) and columns - at > orphan do
    dash(text, columns, orphan, acc)
  end

  defp at_space(text, columns, orphan, at, acc) do
    lines(rest(text, at + 1), columns, orphan, [trim(:binary.part(text, 0, at)) | acc])
  end

  defp dash(text, columns, orphan, acc) do
    lines(rest(text, kept(columns)), columns, orphan, [dashed(text, columns) | acc])
  end

  # No space to break on, so the word is split and dashed onto the next line.
  defp dashed(text, columns), do: :binary.part(text, 0, kept(columns)) <> "-"

  # One column goes to the dash, but a single column line would never advance.
  defp kept(1), do: 1
  defp kept(columns), do: columns - 1

  # The last space at or before the column limit, or 0 when there is none.
  defp break_at(text, columns), do: break_at(text, columns, 0, 0)

  defp break_at(_text, columns, position, last) when position > columns, do: last

  defp break_at(text, columns, position, last) do
    case :binary.at(text, position) do
      ?\s -> break_at(text, columns, position + 1, position)
      _other -> break_at(text, columns, position + 1, last)
    end
  end

  defp rest(text, from), do: :binary.part(text, from, byte_size(text) - from)

  # A run of spaces leaves them on the end of the line, which would shift centred text.
  defp trim(<<>>), do: <<>>

  defp trim(line) do
    case :binary.at(line, byte_size(line) - 1) do
      ?\s -> trim(:binary.part(line, 0, byte_size(line) - 1))
      _other -> line
    end
  end
end
