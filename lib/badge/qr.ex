defmodule Badge.QR do
  @moduledoc """
  QR byte-mode encoding and AtomGL rendering shared by the badge and simulator.

  Error-correction level M and versions 1 through 5 are supported. `encode/1`
  chooses the smallest version that fits; `item/4` scales its one-pixel modules
  by an integer without rebuilding the code.
  """

  import Bitwise

  @versions [
    %{version: 1, size: 21, capacity: 14, data: 16, blocks: 1, ecc: 10, alignment: []},
    %{version: 2, size: 25, capacity: 26, data: 28, blocks: 1, ecc: 16, alignment: [6, 18]},
    %{version: 3, size: 29, capacity: 42, data: 44, blocks: 1, ecc: 26, alignment: [6, 22]},
    %{version: 4, size: 33, capacity: 62, data: 64, blocks: 2, ecc: 18, alignment: [6, 26]},
    %{version: 5, size: 37, capacity: 84, data: 86, blocks: 2, ecc: 24, alignment: [6, 30]}
  ]

  @quiet 4
  @white <<255, 255, 255, 255>>
  @black <<0, 0, 0, 255>>

  @doc "Encodes a binary in QR byte mode at error-correction level M, up to version 5."
  @spec encode(binary) :: {:ok, map} | {:error, :too_long}
  def encode(payload) when is_binary(payload) do
    case version_for(byte_size(payload), @versions) do
      nil -> {:error, :too_long}
      spec -> {:ok, build(payload, spec)}
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

  defp build(payload, spec) do
    codewords = payload |> data_codewords(spec) |> add_error_correction(spec)
    {modules, functions} = function_patterns(spec)
    modules = draw_codewords(modules, functions, spec.size, codewords)
    {modules, _mask} = best_mask(modules, functions, spec.size)
    binary = module_binary(modules, spec.size)
    outer = spec.size + 2 * @quiet

    %{
      version: spec.version,
      size: spec.size,
      modules: binary,
      image: {:rgba8888, outer, outer, rgba(binary, spec.size)}
    }
  end

  defp data_codewords(payload, spec) do
    capacity = spec.data * 8
    bits = integer_bits(4, 4) ++ integer_bits(byte_size(payload), 8) ++ byte_bits(payload)
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
    block_size = div(spec.data, spec.blocks)
    blocks = blocks(data, spec.blocks, block_size, divisor, [])

    interleave(blocks, 0, block_size, :data, []) ++
      interleave(blocks, 0, spec.ecc, :ecc, [])
  end

  defp blocks(_data, 0, _size, _divisor, acc), do: :lists.reverse(acc)

  defp blocks(data, count, size, divisor, acc) do
    {block, rest} = :lists.split(size, data)
    parity = remainder(block, divisor)

    blocks(rest, count - 1, size, divisor, [%{data: block, ecc: parity} | acc])
  end

  defp interleave(_blocks, position, length, _part, acc) when position == length,
    do: :lists.reverse(acc)

  defp interleave(blocks, position, length, part, acc) do
    bytes = interleaved_at(blocks, part, position, [])
    interleave(blocks, position + 1, length, part, bytes ++ acc)
  end

  defp interleaved_at([], _part, _position, acc), do: acc

  defp interleaved_at([block | rest], part, position, acc) do
    byte = :lists.nth(position + 1, Map.get(block, part))
    interleaved_at(rest, part, position, [byte | acc])
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

  defp function_patterns(spec) do
    state = {%{}, %{}}

    state =
      :lists.foldl(
        fn i, acc ->
          acc
          |> set_function(6, i, rem(i + 1, 2), spec.size)
          |> set_function(i, 6, rem(i + 1, 2), spec.size)
        end,
        state,
        :lists.seq(0, spec.size - 1)
      )

    state =
      state
      |> finder(3, 3, spec.size)
      |> finder(spec.size - 4, 3, spec.size)
      |> finder(3, spec.size - 4, spec.size)
      |> alignment(spec.alignment, spec.size)

    draw_format(state, spec.size, 0)
  end

  defp finder(state, center_x, center_y, size) do
    :lists.foldl(
      fn dy, outer ->
        :lists.foldl(
          fn dx, inner ->
            distance = max(abs(dx), abs(dy))
            value = if distance == 2 or distance == 4, do: 0, else: 1
            set_function(inner, center_x + dx, center_y + dy, value, size)
          end,
          outer,
          :lists.seq(-4, 4)
        )
      end,
      state,
      :lists.seq(-4, 4)
    )
  end

  defp alignment(state, [], _size), do: state

  defp alignment(state, [_first, center], size) do
    :lists.foldl(
      fn dy, outer ->
        :lists.foldl(
          fn dx, inner ->
            value = if max(abs(dx), abs(dy)) == 1, do: 0, else: 1
            set_function(inner, center + dx, center + dy, value, size)
          end,
          outer,
          :lists.seq(-2, 2)
        )
      end,
      state,
      :lists.seq(-2, 2)
    )
  end

  defp set_function(state, x, y, _value, size)
       when x < 0 or y < 0 or x >= size or y >= size,
       do: state

  defp set_function({modules, functions}, x, y, value, size) do
    index = y * size + x
    {Map.put(modules, index, value), Map.put(functions, index, true)}
  end

  defp draw_format(state, size, mask) do
    bits = format_bits(mask)

    state =
      :lists.foldl(
        fn i, acc -> set_function(acc, 8, i, bit(bits, i), size) end,
        state,
        :lists.seq(0, 5)
      )

    state =
      state
      |> set_function(8, 7, bit(bits, 6), size)
      |> set_function(8, 8, bit(bits, 7), size)
      |> set_function(7, 8, bit(bits, 8), size)

    state =
      :lists.foldl(
        fn i, acc -> set_function(acc, 14 - i, 8, bit(bits, i), size) end,
        state,
        :lists.seq(9, 14)
      )

    state =
      :lists.foldl(
        fn i, acc -> set_function(acc, size - 1 - i, 8, bit(bits, i), size) end,
        state,
        :lists.seq(0, 7)
      )

    state =
      :lists.foldl(
        fn i, acc -> set_function(acc, 8, size - 15 + i, bit(bits, i), size) end,
        state,
        :lists.seq(8, 14)
      )

    set_function(state, 8, size - 8, 1, size)
  end

  defp format_bits(mask) do
    remainder = format_remainder(mask, 10)
    bxor(mask <<< 10 ||| remainder, 0x5412)
  end

  defp format_remainder(value, 0), do: value

  defp format_remainder(value, left) do
    next = bxor(value <<< 1, (value >>> 9) * 0x537)
    format_remainder(next, left - 1)
  end

  defp bit(value, position), do: value >>> position &&& 1

  defp draw_codewords(modules, functions, size, codewords) do
    bits = codeword_bits(codewords)
    {result, []} = place_pairs(size - 1, modules, functions, size, bits)
    result
  end

  defp codeword_bits([]), do: []
  defp codeword_bits([byte | rest]), do: integer_bits(byte, 8) ++ codeword_bits(rest)

  defp place_pairs(right, modules, _functions, _size, bits) when right <= 0,
    do: {modules, bits}

  defp place_pairs(right, modules, functions, size, bits) do
    column = if right <= 6, do: right - 1, else: right
    upward = (column + 1 &&& 2) == 0
    coordinates = pair_coordinates(column, size, upward)
    {modules, bits} = place_coordinates(coordinates, modules, functions, size, bits)

    place_pairs(right - 2, modules, functions, size, bits)
  end

  defp pair_coordinates(right, size, upward) do
    :lists.append(
      for vertical <- 0..(size - 1) do
        y = if upward, do: size - 1 - vertical, else: vertical
        [{right, y}, {right - 1, y}]
      end
    )
  end

  defp place_coordinates([], modules, _functions, _size, bits), do: {modules, bits}

  defp place_coordinates([{x, y} | rest], modules, functions, size, bits) do
    index = y * size + x

    case {Map.has_key?(functions, index), bits} do
      {true, _bits} ->
        place_coordinates(rest, modules, functions, size, bits)

      {false, [value | remaining]} ->
        place_coordinates(rest, Map.put(modules, index, value), functions, size, remaining)

      {false, []} ->
        place_coordinates(rest, Map.put(modules, index, 0), functions, size, [])
    end
  end

  defp best_mask(modules, functions, size) do
    {best, best_mask, _score} =
      :lists.foldl(
        fn mask, {winner, winner_mask, score} ->
          candidate = masked(modules, functions, size, mask)
          candidate = elem(draw_format({candidate, functions}, size, mask), 0)
          candidate_score = penalty(candidate, size)

          case winner == nil or candidate_score < score do
            true -> {candidate, mask, candidate_score}
            false -> {winner, winner_mask, score}
          end
        end,
        {nil, nil, 0},
        :lists.seq(0, 7)
      )

    {best, best_mask}
  end

  defp masked(modules, functions, size, mask) do
    :lists.foldl(
      fn index, acc ->
        case Map.has_key?(functions, index) do
          true ->
            acc

          false ->
            x = rem(index, size)
            y = div(index, size)

            case mask?(mask, x, y) do
              true -> Map.put(acc, index, bxor(Map.get(acc, index, 0), 1))
              false -> acc
            end
        end
      end,
      modules,
      :lists.seq(0, size * size - 1)
    )
  end

  defp mask?(0, x, y), do: rem(x + y, 2) == 0
  defp mask?(1, _x, y), do: rem(y, 2) == 0
  defp mask?(2, x, _y), do: rem(x, 3) == 0
  defp mask?(3, x, y), do: rem(x + y, 3) == 0
  defp mask?(4, x, y), do: rem(div(x, 3) + div(y, 2), 2) == 0
  defp mask?(5, x, y), do: rem(x * y, 2) + rem(x * y, 3) == 0
  defp mask?(6, x, y), do: rem(rem(x * y, 2) + rem(x * y, 3), 2) == 0
  defp mask?(7, x, y), do: rem(rem(x + y, 2) + rem(x * y, 3), 2) == 0

  defp penalty(modules, size) do
    run_penalty(modules, size) + block_penalty(modules, size) +
      pattern_penalty(modules, size) + balance_penalty(modules, size)
  end

  defp run_penalty(modules, size) do
    rows =
      :lists.foldl(
        fn y, total -> total + line_runs(row(modules, size, y)) end,
        0,
        :lists.seq(0, size - 1)
      )

    :lists.foldl(
      fn x, total -> total + line_runs(column(modules, size, x)) end,
      rows,
      :lists.seq(0, size - 1)
    )
  end

  defp line_runs([first | rest]), do: line_runs(rest, first, 1, 0)
  defp line_runs([], _colour, run, total), do: total + run_cost(run)

  defp line_runs([colour | rest], colour, run, total),
    do: line_runs(rest, colour, run + 1, total)

  defp line_runs([colour | rest], _previous, run, total),
    do: line_runs(rest, colour, 1, total + run_cost(run))

  defp run_cost(run) when run < 5, do: 0
  defp run_cost(run), do: run - 2

  defp block_penalty(modules, size) do
    :lists.foldl(
      fn y, outer ->
        :lists.foldl(
          fn x, inner ->
            value = module(modules, size, x, y)

            case module(modules, size, x + 1, y) == value and
                   module(modules, size, x, y + 1) == value and
                   module(modules, size, x + 1, y + 1) == value do
              true -> inner + 3
              false -> inner
            end
          end,
          outer,
          :lists.seq(0, size - 2)
        )
      end,
      0,
      :lists.seq(0, size - 2)
    )
  end

  defp pattern_penalty(modules, size) do
    rows =
      :lists.foldl(
        fn y, total -> total + line_patterns(row(modules, size, y)) * 40 end,
        0,
        :lists.seq(0, size - 1)
      )

    :lists.foldl(
      fn x, total -> total + line_patterns(column(modules, size, x)) * 40 end,
      rows,
      :lists.seq(0, size - 1)
    )
  end

  defp line_patterns([a, b, c, d, e, f, g, h, i, j, k | rest]) do
    found =
      case [a, b, c, d, e, f, g, h, i, j, k] do
        [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0] -> 1
        [0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1] -> 1
        _other -> 0
      end

    found + line_patterns([b, c, d, e, f, g, h, i, j, k | rest])
  end

  defp line_patterns(_short), do: 0

  defp balance_penalty(modules, size) do
    total = size * size

    dark =
      :lists.foldl(
        fn index, count -> count + Map.get(modules, index, 0) end,
        0,
        :lists.seq(0, total - 1)
      )

    div(abs(dark * 100 - total * 50), total * 5) * 10
  end

  defp row(modules, size, y) do
    for x <- 0..(size - 1), do: module(modules, size, x, y)
  end

  defp column(modules, size, x) do
    for y <- 0..(size - 1), do: module(modules, size, x, y)
  end

  defp module(modules, size, x, y), do: Map.get(modules, y * size + x, 0)

  defp module_binary(modules, size) do
    for index <- 0..(size * size - 1), into: <<>>, do: <<Map.get(modules, index, 0)>>
  end

  defp rgba(modules, size) do
    for y <- -@quiet..(size + @quiet - 1),
        x <- -@quiet..(size + @quiet - 1),
        into: <<>> do
      case x >= 0 and x < size and y >= 0 and y < size do
        true -> pixel(:binary.at(modules, y * size + x))
        false -> @white
      end
    end
  end

  defp pixel(0), do: @white
  defp pixel(1), do: @black
end
