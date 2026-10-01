defmodule Badge.QR do
  @moduledoc """
  QR byte-mode encoding and AtomGL rendering shared by the badge and simulator.

  Error-correction level L and versions 1 through 8 are supported, so a payload
  holds at most 192 bytes. `encode/1`
  chooses the smallest version that fits; `item/4` scales its one-pixel modules
  by an integer without rebuilding the code.

  Every code carries the same mask, chosen when `Badge.QR.Geometry` is
  generated. Scoring the eight candidates costs more than the rest of the
  encode put together on AtomVM, and any mask is a valid, decodable code.
  """

  import Bitwise

  alias Badge.QR.Geometry

  @versions [
    %{version: 1, capacity: 17, data: 19, blocks: 1, ecc: 7},
    %{version: 2, capacity: 32, data: 34, blocks: 1, ecc: 10},
    %{version: 3, capacity: 53, data: 55, blocks: 1, ecc: 15},
    %{version: 4, capacity: 78, data: 80, blocks: 1, ecc: 20},
    %{version: 5, capacity: 106, data: 108, blocks: 1, ecc: 26},
    %{version: 6, capacity: 134, data: 136, blocks: 2, ecc: 18},
    %{version: 7, capacity: 154, data: 156, blocks: 2, ecc: 20},
    %{version: 8, capacity: 192, data: 194, blocks: 2, ecc: 24}
  ]

  @fixed_light Geometry.fixed_light()
  @fixed_dark Geometry.fixed_dark()
  @data_position Geometry.data_position()

  @quiet 4
  # Byte mode's length field is 8 bits for every version up to 9.
  @count_bits 8
  @white <<255, 255, 255, 255>>
  @black <<0, 0, 0, 255>>
  @doc "Encodes a binary in QR byte mode at error-correction level L, up to version 8."
  @spec encode(binary) :: {:ok, map} | {:error, :too_long}
  def encode(payload) when is_binary(payload) do
    case version_for(byte_size(payload), @versions) do
      nil -> {:error, :too_long}
      spec -> {:ok, build(payload, spec, Geometry.for_version(spec.version))}
    end
  end

  @doc "Draws encoded QR data at an integer number of panel pixels per module."
  @spec item(map, integer, integer, pos_integer) :: tuple
  def item(%{image: {:rgba8888, width, height, _pixels} = image}, x, y, scale)
      when is_integer(scale) and scale > 0 do
    {:scaled_cropped_image, x, y, width * scale, height * scale, 0xFFFFFF, 0, 0, scale, scale, [],
     image}
  end

  defp version_for(_length, []), do: nil

  defp version_for(length, [%{capacity: capacity} = spec | _rest]) when length <= capacity,
    do: spec

  defp version_for(length, [_spec | rest]), do: version_for(length, rest)

  defp build(payload, spec, %{size: size, template: template}) do
    codewords =
      payload |> data_codewords(spec) |> add_error_correction(spec) |> :binary.list_to_bin()

    modules = matrix(template, size, codewords)
    outer = size + 2 * @quiet
    pixels = rgba(modules, size)

    %{
      version: spec.version,
      size: size,
      modules: modules,
      image: {:rgba8888, outer, outer, pixels}
    }
  end

  defp data_codewords(payload, spec) do
    capacity = spec.data * 8

    bits =
      integer_bits(4, 4) ++
        integer_bits(byte_size(payload), @count_bits) ++ byte_bits(payload)

    bits = bits ++ :lists.duplicate(min(4, capacity - length(bits)), 0)
    bits = bits ++ :lists.duplicate(rem(8 - rem(length(bits), 8), 8), 0)
    bytes = pack_bits(bits, [])

    pad_bytes(bytes, spec.data, 0xEC)
  end

  defp integer_bits(_value, 0), do: []

  defp integer_bits(value, width) do
    [value >>> (width - 1) &&& 1 | integer_bits(value, width - 1)]
  end

  defp byte_bits(<<>>), do: []
  defp byte_bits(<<byte, rest::binary>>), do: integer_bits(byte, 8) ++ byte_bits(rest)

  defp pack_bits([], acc), do: :lists.reverse(acc)

  defp pack_bits([a, b, c, d, e, f, g, h | rest], acc) do
    byte =
      a <<< 7 ||| b <<< 6 ||| c <<< 5 ||| d <<< 4 ||| e <<< 3 ||| f <<< 2 |||
        g <<< 1 ||| h

    pack_bits(rest, [byte | acc])
  end

  defp pad_bytes(bytes, wanted, _pad) when length(bytes) == wanted, do: bytes
  defp pad_bytes(bytes, wanted, 0xEC), do: pad_bytes(bytes ++ [0xEC], wanted, 0x11)
  defp pad_bytes(bytes, wanted, 0x11), do: pad_bytes(bytes ++ [0x11], wanted, 0xEC)

  defp add_error_correction(data, spec) do
    divisor = divisor(spec.ecc)
    raw = spec.data + spec.blocks * spec.ecc
    short_blocks = spec.blocks - rem(raw, spec.blocks)
    short_length = div(raw, spec.blocks) - spec.ecc
    blocks = blocks(data, 0, spec.blocks, short_blocks, short_length, divisor, [])
    longest = short_length + if(short_blocks < spec.blocks, do: 1, else: 0)

    interleave(blocks, 0, longest, :data, []) ++
      interleave(blocks, 0, spec.ecc, :ecc, [])
  end

  defp blocks(_data, index, count, _short_blocks, _short_length, _divisor, acc)
       when index == count,
       do: :lists.reverse(acc)

  defp blocks(data, index, count, short_blocks, short_length, divisor, acc) do
    length = short_length + if(index < short_blocks, do: 0, else: 1)
    {block, rest} = :lists.split(length, data)
    parity = remainder(block, divisor)

    blocks(rest, index + 1, count, short_blocks, short_length, divisor, [
      %{data: block, ecc: parity} | acc
    ])
  end

  defp interleave(_blocks, position, length, _part, acc) when position == length,
    do: :lists.reverse(acc)

  defp interleave(blocks, position, length, part, acc) do
    bytes = interleaved_at(blocks, part, position, [])
    interleave(blocks, position + 1, length, part, bytes ++ acc)
  end

  defp interleaved_at([], _part, _position, acc), do: acc

  defp interleaved_at([block | rest], part, position, acc) do
    bytes = Map.get(block, part)

    case position < length(bytes) do
      true -> interleaved_at(rest, part, position, [:lists.nth(position + 1, bytes) | acc])
      false -> interleaved_at(rest, part, position, acc)
    end
  end

  defp divisor(degree), do: divisor(degree, :lists.duplicate(degree - 1, 0) ++ [1], 1)
  defp divisor(0, result, _root), do: result

  defp divisor(left, result, root) do
    divisor(left - 1, divisor_step(result, root), multiply(root, 2))
  end

  defp divisor_step([], _root), do: []

  defp divisor_step([coefficient | rest], root) do
    next =
      case rest do
        [value | _tail] -> value
        [] -> 0
      end

    [bxor(multiply(coefficient, root), next) | divisor_step(rest, root)]
  end

  defp remainder(data, divisor) do
    remainder(data, divisor, :lists.duplicate(length(divisor), 0))
  end

  defp remainder([], _divisor, result), do: result

  defp remainder([byte | rest], divisor, [first | tail]) do
    factor = bxor(byte, first)
    shifted = tail ++ [0]
    result = remainder_step(shifted, divisor, factor, [])

    remainder(rest, divisor, result)
  end

  defp remainder_step([], [], _factor, acc), do: :lists.reverse(acc)

  defp remainder_step([value | values], [coefficient | coefficients], factor, acc) do
    next = bxor(value, multiply(coefficient, factor))
    remainder_step(values, coefficients, factor, [next | acc])
  end

  defp multiply(x, y), do: multiply(x, y, 7, 0)
  defp multiply(_x, _y, -1, acc), do: acc

  defp multiply(x, y, bit, acc) do
    shifted = acc <<< 1
    reduced = if (shifted &&& 0x100) == 0, do: shifted, else: bxor(shifted, 0x11D)
    next = if (y &&& 1 <<< bit) == 0, do: reduced, else: bxor(reduced, x)

    multiply(x, y, bit - 1, next)
  end

  defp matrix(template, _size, codewords) do
    bit_count = byte_size(codewords) * 8

    template
    |> matrix(codewords, bit_count, [])
    |> :lists.reverse()
    |> :erlang.iolist_to_binary()
  end

  defp matrix(<<>>, _codewords, _bit_count, acc), do: acc

  defp matrix(
         <<a::big-16, b::big-16, c::big-16, d::big-16, e::big-16, f::big-16, g::big-16, h::big-16,
           rest::binary>>,
         codewords,
         bit_count,
         acc
       ) do
    chunk =
      <<matrix_value(a, codewords, bit_count), matrix_value(b, codewords, bit_count),
        matrix_value(c, codewords, bit_count), matrix_value(d, codewords, bit_count),
        matrix_value(e, codewords, bit_count), matrix_value(f, codewords, bit_count),
        matrix_value(g, codewords, bit_count), matrix_value(h, codewords, bit_count)>>

    matrix(rest, codewords, bit_count, [chunk | acc])
  end

  defp matrix(<<token::big-16, rest::binary>>, codewords, bit_count, acc) do
    matrix(rest, codewords, bit_count, [<<matrix_value(token, codewords, bit_count)>> | acc])
  end

  defp matrix_value(token, codewords, bit_count) when token < @fixed_light do
    position = token &&& @data_position
    value = if position < bit_count, do: codeword_bit(codewords, position), else: 0
    bxor(value, token >>> 12 &&& 1)
  end

  defp matrix_value(@fixed_light, _codewords, _bit_count), do: 0
  defp matrix_value(@fixed_dark, _codewords, _bit_count), do: 1

  defp codeword_bit(codewords, position) do
    byte = :binary.at(codewords, div(position, 8))
    byte >>> (7 - rem(position, 8)) &&& 1
  end

  defp rgba(modules, size) do
    outer = size + @quiet * 2
    white_row = :binary.copy(@white, outer)
    quiet_rows = :lists.duplicate(@quiet, white_row)
    quiet = :binary.copy(@white, @quiet)
    rows = rgba_rows(modules, size, quiet, [])

    :erlang.iolist_to_binary([quiet_rows, rows, quiet_rows])
  end

  defp rgba_rows(<<>>, _size, _quiet, acc), do: :lists.reverse(acc)

  defp rgba_rows(modules, size, quiet, acc) do
    row = :binary.part(modules, 0, size)
    rest = :binary.part(modules, size, byte_size(modules) - size)

    rgba_rows(rest, size, quiet, [
      :erlang.iolist_to_binary([quiet, runs(row, 0, 0, []), quiet]) | acc
    ])
  end

  defp runs(<<>>, colour, run, acc), do: :lists.reverse([pixels(colour, run) | acc])

  defp runs(<<next, rest::binary>>, colour, run, acc) do
    case next == colour do
      true -> runs(rest, colour, run + 1, acc)
      false -> runs(rest, next, 1, [pixels(colour, run) | acc])
    end
  end

  defp pixels(1, run), do: :binary.copy(@black, run)
  defp pixels(0, run), do: :binary.copy(@white, run)
end
