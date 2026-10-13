defmodule Raycaster.Engine do
  @moduledoc """
  A small Wolfenstein-style raycaster, in integers only.

  AtomVM has no fast floats on this chip, so positions are Q8 fixed point (256
  is one map cell), angles are 65536 to a turn, and sine comes from a table
  built while compiling on the laptop. `frame/4` turns a player into a display
  list of rectangles, one per run of equal wall columns.

  The map is not read from this module while rendering: see `grid/0`.
  """

  import Bitwise

  # Rays cast evenly across the screen before edges are refined; must divide the width.
  @cols 20
  # A face gets a band of shade per this many rows of height change, at most @bands.
  @band_lines 24
  @bands 4
  @half div(@cols, 2)
  # Distance along a ray that never crosses a grid line. AtomVM's integers are
  # 28 bits wide on this chip before they spill onto the heap, so keep it
  # below 2^27.
  @far 1 <<< 26

  # 16 x 16. Digits are wall types, `.` is floor. The outer ring must be wall:
  # rays are not bounds checked and stop only when they enter a wall cell.
  @rows [
    "3333333333333333",
    "3..............3",
    "3..1111....22..3",
    "3..1..........23",
    "3..1..........23",
    "3..1......11...3",
    "3.......2..1...3",
    "3.......2..1...3",
    "3..22...2......3",
    "3..............3",
    "3....1111......3",
    "3....1..1..22..3",
    "3....1..1..2...3",
    "3...........2..3",
    "3..............3",
    "3333333333333333"
  ]

  @size length(@rows)

  # One flat tuple, row after row. AtomVM copies a module literal onto the heap
  # every time it is used, and this one is 256 words: looked up per grid step
  # that ran the badge out of memory. So it is fetched once with grid/0 and
  # handed down as an argument, which passes a pointer instead.
  @grid @rows
        |> Enum.flat_map(fn row ->
          row
          |> String.to_charlist()
          |> Enum.map(fn
            ?. -> 0
            char -> char - ?0
          end)
        end)
        |> List.to_tuple()

  # The floor as one integer, bit `y * 16 + x` set where column `x` of row `y` is floor.
  @open_mask (for {row, y} <- Enum.with_index(@rows),
                  {?., x} <- Enum.with_index(String.to_charlist(row)),
                  reduce: 0 do
                bits -> bits ||| 1 <<< (y * 16 + x)
              end)

  @ceiling 0x202838
  @floor 0x504030

  # Q8 per second, and angle units per second.
  @move_speed 800
  @turn_speed 40_000
  # A bit for each direction a key can ask for, see keys/2.
  @forward 1
  @back 2
  @right 4
  @left 8
  @turn_right 16
  @turn_left 32

  # Nearer than this a figure is inside the player.
  @nearest 64
  @goat_fur 0xE6E0D2
  @goat_face 0xD2CABA
  @goat_beard 0xB4AC9C
  @goat_dark 0x3C3228
  @goat_calm 0xE8B820
  @goat_angry 0xFF2010
  # Pixels tall below which the goat is drawn in five rectangles.
  @goat_detail 64

  # How close to a wall the player may get, in Q8.
  @radius 60

  # Pasted into columns/4 by the compiler, saving a call per column.
  @compile {:inline, colour: 3, rgb: 1}

  def new, do: %{x: 384, y: 384, a: 0}

  # Where a caught player comes back: the start or the far corner, whichever is farther from the goat.
  @start %{x: 384, y: 384, a: 0}
  @corner %{x: 13 * 256 + 128, y: 13 * 256 + 128, a: 49_152}

  def respawn({gx, gy, _hunting}) do
    if apart(@start, gx, gy) >= apart(@corner, gx, gy), do: @start, else: @corner
  end

  def respawn(_no_goat), do: new()

  defp apart(%{x: x, y: y}, gx, gy), do: (x - gx) * (x - gx) + (y - gy) * (y - gy)

  # The map. Call this once and pass the result to step/4 and frame/4.
  def grid, do: @grid

  def cols, do: @cols

  @doc "The floor as one integer, a bit for each cell, `y * 16 + x`."
  def open_mask, do: @open_mask

  # Held keys are labels from Raycaster.Keymap, binaries or charlists.
  def step(grid, state, held, dt_ms) do
    keys = keys(held, 0)
    forward = axis(keys, @forward, @back)
    strafe = axis(keys, @right, @left)
    turn = axis(keys, @turn_right, @turn_left)

    angle = state.a + div(turn * @turn_speed * dt_ms, 1000)
    index = index(angle)
    dir_x = cos(index)
    dir_y = sin(index)

    distance = div(@move_speed * dt_ms, 1000)
    dx = div((dir_x * forward - dir_y * strafe) * distance, 256)
    dy = div((dir_y * forward + dir_x * strafe) * distance, 256)

    # Each axis on its own, so a wall is slid along instead of stopping dead.
    x =
      if open?(grid, state.x + dx + sign(dx) * @radius, state.y), do: state.x + dx, else: state.x

    y = if open?(grid, x, state.y + dy + sign(dy) * @radius), do: state.y + dy, else: state.y

    %{state | x: x, y: y, a: angle}
  end

  def frame(grid, %{x: x, y: y, a: angle}, width, height) do
    index = index(angle)
    dir_x = cos(index)
    dir_y = sin(index)
    # The camera plane is perpendicular to the direction, 0.66 as long: about a
    # 66 degree field of view.
    plane_x = div(-dir_y * 169, 256)
    plane_y = div(dir_x * 169, 256)
    column_width = div(width, @cols)

    # Every ray starts from the same cell, so where the player stands is worked
    # out once here. The cell is its place in the grid tuple, counted from 1 as
    # :erlang.element/2 does (elem/2 counts from 0 and adds the 1 on every
    # read), and in_x, in_y are how far into that cell the player is.
    cell = (y >>> 8) * @size + (x >>> 8) + 1
    in_x = x &&& 255
    in_y = y &&& 255

    # What every column needs and none changes, in one tuple: a call only has
    # to keep a few variables alive across it, and each one costs a save and a
    # restore on this chip.
    view = {grid, cell, in_x, in_y, dir_x, dir_y, plane_x, plane_y, column_width, height, width}

    # The first item is on top, so floor and ceiling go last, behind the walls.
    # The walls are put in front of them as they are found.
    behind = [
      {:rect, 0, div(height, 2), width, height - div(height, 2), @floor},
      {:rect, 0, 0, width, div(height, 2), @ceiling}
    ]

    # AtomVM runs a scheduler on each of the chip's two cores, so the right
    # half of the screen is cast in a second process while this one casts the
    # left. It goes from the right edge towards the middle, so both halves end
    # with their open rectangle at the seam, where join/3 puts the two back
    # together if they turn out to be one.
    parent = self()
    ref = make_ref()

    spawn_link(fn ->
      send(parent, {ref, columns(view, @cols - 1, @half - 1, -1, nil, [])})
    end)

    {left_run, left} = columns(view, 0, @half, 1, nil, behind)

    receive do
      # The right half's rectangles come nearest the seam first; the display
      # list wants the rightmost first.
      {^ref, {right_run, right}} ->
        :lists.reverse(right, join(left_run, right_run, view, left))
    end
  end

  @doc """
  Goats as figures, to go in front of what `frame/4` returns.

  `others` is a list of `{:goat, x, y, hunting}`, positions in the same Q8 as the
  player's, or `{:goat, x, y, hunting, true}` when it is known to be in plain sight
  and the walk to check it can be skipped. The goat's eyes go red while `hunting`
  is true. A figure is sized by how far away it is, and left out when behind the
  player, off to the side of the view, or hidden by a wall: a goat half behind a
  corner is either seen or not. The nearest come first.
  """
  def sprites(_grid, _player, [], _width, _height), do: []

  def sprites(grid, %{x: x, y: y, a: angle}, others, width, height) do
    index = index(angle)
    dir_x = cos(index)
    dir_y = sin(index)
    plane_x = div(-dir_y * 169, 256)
    plane_y = div(dir_x * 169, 256)
    # The camera's determinant, over 256 so the quotients below come out in Q8
    # without a product big enough to be boxed.
    det = div(plane_x * dir_y - dir_x * plane_y, 256)

    view = {grid, x, y, dir_x, dir_y, plane_x, plane_y, det, width, height}

    # Nearest first: the first item is drawn on top.
    nearest_first = :lists.keysort(1, figures(view, others, []))

    flatten_figures(nearest_first)
  end

  defp figures(_view, [], acc), do: acc

  defp figures(view, [{:goat, ox, oy, hunting} | rest], acc),
    do: figures(view, rest, place(acc, view, ox, oy, hunting, false))

  defp figures(view, [{:goat, ox, oy, hunting, sure} | rest], acc),
    do: figures(view, rest, place(acc, view, ox, oy, hunting, sure))

  # `sure` says it is already known to be in line of sight.
  defp place(acc, view, ox, oy, hunting, sure) do
    {_grid, x, y, dir_x, dir_y, plane_x, plane_y, det, _width, _height} = view

    rel_x = ox - x
    rel_y = oy - y
    depth = div(plane_x * rel_y - plane_y * rel_x, det)
    across = div(dir_y * rel_x - dir_x * rel_y, det)

    if depth >= @nearest, do: seen(acc, view, ox, oy, depth, across, hunting, sure), else: acc
  end

  # The walk along the line to a figure is only made for one in the view.
  defp seen(acc, view, ox, oy, depth, across, hunting, sure) do
    {grid, x, y, _dir_x, _dir_y, _plane_x, _plane_y, _det, width, height} = view

    centre = div(width * (depth + across), 2 * depth)
    line = div(height * 256, depth)

    if centre + line > 0 and centre - line < width and (sure or visible?(grid, x, y, ox, oy)) do
      add_figure(acc, depth, centre, line, hunting, width, height)
    else
      acc
    end
  end

  # `line` is a wall's height at this distance; parts are in hundredths of `size`, topmost first.
  defp add_figure(acc, depth, centre, line, hunting, width, height) do
    size = div(line * 6, 5)
    at = {centre, div(height + line, 2), size, width, height}

    fur = shade(@goat_fur, depth)
    face = shade(@goat_face, depth)
    dark = shade(@goat_dark, depth)
    # Unshaded, so they shine out of the dark.
    eyes = if hunting, do: @goat_angry, else: @goat_calm

    items =
      if size < @goat_detail do
        part(at, -7, 43, 4, 3, eyes) ++
          part(at, 3, 43, 4, 3, eyes) ++
          part(at, -9, 50, 18, 22, face) ++
          part(at, -18, 36, 36, 21, fur) ++
          part(at, -14, 16, 28, 16, dark)
      else
        part(at, -7, 43, 4, 3, eyes) ++
          part(at, 3, 43, 4, 3, eyes) ++
          part(at, -3, 30, 6, 9, shade(@goat_beard, depth)) ++
          part(at, -13, 66, 6, 5, dark) ++
          part(at, 7, 66, 6, 5, dark) ++
          part(at, -9, 62, 5, 13, dark) ++
          part(at, 4, 62, 5, 13, dark) ++
          part(at, -9, 50, 18, 22, face) ++
          part(at, -19, 47, 10, 5, face) ++
          part(at, 9, 47, 10, 5, face) ++
          part(at, -18, 36, 36, 21, fur) ++
          part(at, -14, 16, 7, 16, dark) ++
          part(at, 7, 16, 7, 16, dark)
      end

    [{depth, items} | acc]
  end

  # A goat part in hundredths of its size, `up` from the floor to its top, at least a pixel.
  defp part({centre, floor, size, width, height}, left, up, w, h, colour) do
    clip(
      {:rect, centre + div(size * left, 100), floor - div(size * up, 100),
       max(div(size * w, 100), 1), max(div(size * h, 100), 1), colour},
      width,
      height
    )
  end

  defp flatten_figures([]), do: []

  defp flatten_figures([{_depth, items} | rest]),
    do: :lists.append(items, flatten_figures(rest))

  # Keeps a rectangle on the screen, or drops it.
  defp clip({:rect, x, y, w, h, colour}, width, height) do
    left = max(x, 0)
    top = max(y, 0)
    right = min(x + w, width)
    bottom = min(y + h, height)

    if right > left and bottom > top do
      [{:rect, left, top, right - left, bottom - top, colour}]
    else
      []
    end
  end

  @doc false
  # Nothing solid between two points, looked at every quarter cell.
  def visible?(grid, x, y, ox, oy) do
    dx = ox - x
    dy = oy - y
    steps = max(div(max(abs(dx), abs(dy)), 64), 1)

    clear?(grid, x, y, dx, dy, steps, 1)
  end

  defp clear?(_grid, _x, _y, _dx, _dy, steps, i) when i >= steps, do: true

  defp clear?(grid, x, y, dx, dy, steps, i) do
    if open?(grid, x + div(dx * i, steps), y + div(dy * i, steps)) do
      clear?(grid, x, y, dx, dy, steps, i + 1)
    else
      false
    end
  end

  defp shade({r, g, b}, depth) do
    factor = max(64, 256 - div(depth, 10))
    div(r * factor, 256) <<< 16 ||| div(g * factor, 256) <<< 8 ||| div(b * factor, 256)
  end

  defp shade(colour, depth) do
    shade({colour >>> 16 &&& 255, colour >>> 8 &&& 255, colour &&& 255}, depth)
  end

  # Casts `i` to `stop` by `step`; `run` is the open face, `{face, edge, first, last}`.
  defp columns(_view, stop, stop, _step, run, acc), do: {run, acc}

  defp columns(view, i, stop, step, run, acc) do
    column_width = elem(view, 8)
    x = i * column_width
    {face, sample} = sample(view, x)

    {run, acc} =
      case run do
        nil ->
          edge = if step > 0, do: x, else: x + column_width
          {{face, edge, sample, sample}, acc}

        {^face, edge, first, _last} ->
          {{face, edge, first, sample}, acc}

        _other ->
          cross(view, run, x, face, sample, acc)
      end

    columns(view, i + step, stop, step, run, acc)
  end

  # Ends the run where the face changes before `x`, and starts the next, however thin.
  defp cross(view, {old, _edge, _first, {last_x, _, _, _, _, _}} = run, x, face, sample, acc) do
    edge = boundary(view, old, last_x, x)
    acc = emit(run, edge, view, acc)
    next = if last_x < x, do: edge, else: edge - 1

    case next == x do
      true ->
        {{face, edge, sample, sample}, acc}

      false ->
        case sample(view, next) do
          {^face, first} -> {{face, edge, first, sample}, acc}
          {thin, first} -> cross(view, {thin, edge, first, first}, x, face, sample, acc)
        end
    end
  end

  # One ray, through the left edge of pixel column `x`.
  defp sample(view, x) do
    {grid, cell, in_x, in_y, dir_x, dir_y, plane_x, plane_y, _column_width, height, width} = view

    camera = div(2 * x * 256, width) - 256
    ray_x = dir_x + div(plane_x * camera, 256)
    ray_y = dir_y + div(plane_y * camera, 256)

    {wall, side, dist, hit} = cast(grid, cell, in_x, in_y, ray_x, ray_y)
    # Not cut to the screen, so a near wall keeps its slope.
    line = div(height * 256, max(dist, 1))
    top = div(height - line, 2)

    face =
      if side == 0,
        do: {0, rem(hit - 1, @size), ray_x > 0, wall},
        else: {1, div(hit - 1, @size), ray_y > 0, wall}

    {face, {x, top, line, dist, wall, side}}
  end

  # The pixel edge between `face` at `from` and something else at `to`, by halving the gap.
  defp boundary(view, face, from, to) do
    {lo, hi} = if from < to, do: {from, to}, else: {to, from}
    narrow(view, face, lo, hi, from < to)
  end

  defp narrow(_view, _face, lo, hi, _rising) when hi - lo <= 1, do: hi

  defp narrow(view, face, lo, hi, rising) do
    mid = div(lo + hi, 2)

    case {elem(sample(view, mid), 0) == face, rising} do
      {true, true} -> narrow(view, face, mid, hi, rising)
      {false, true} -> narrow(view, face, lo, mid, rising)
      {true, false} -> narrow(view, face, lo, mid, rising)
      {false, false} -> narrow(view, face, mid, hi, rising)
    end
  end

  # The two halves' faces at the seam: one polygon if they are the same face.
  defp join({face, left_edge, left_first, _}, {face, right_edge, right_first, _}, view, acc),
    do: emit({face, left_edge, left_first, right_first}, right_edge, view, acc)

  # Different faces: the edge between them is found here, as inside a half.
  defp join(
         {left_face, _, _, {left_x, _, _, _, _, _}} = left_run,
         {_, _, _, {right_x, _, _, _, _, _}} = right_run,
         view,
         acc
       ) do
    edge = boundary(view, left_face, left_x, right_x)
    emit(right_run, edge, view, emit(left_run, edge, view, acc))
  end

  # Top and bottom through the first and last samples, in bands of shade by distance.
  defp emit({face, edge, first, last}, ending, view, acc) do
    height = elem(view, 9)
    {left, right} = if edge < ending, do: {edge, ending}, else: {ending, edge}
    {first, last} = slope(view, face, first, last, left, right)
    {ax, at, al, _ad, wall, side} = first
    {bx, bt, bl, _bd, _, _} = last

    if ax == bx do
      top = max(at, 0)

      [
        {:rect, left, top, right - left, min(at + al, height) - top,
         colour(wall, side, line_dist(al, height))}
        | acc
      ]
    else
      line = {ax, at, al, bx, bt, bl, wall, side, height}
      lines = abs(along(ax, al, bx, bl, left) - along(ax, al, bx, bl, right))
      n = min(max(div(lines, @band_lines), 1), @bands)
      bands(line, left, right, n, 0, acc)
    end
  end

  # A face one ray hit gets a second ray at its other end, for its slope.
  defp slope(view, face, {x, _, _, _, _, _} = first, {x, _, _, _, _, _}, left, right)
       when right - left >= 2 do
    other = if x - left < right - 1 - x, do: right - 1, else: left

    case sample(view, other) do
      {^face, second} when other != x -> {first, second}
      _ -> {first, first}
    end
  end

  defp slope(_view, _face, first, last, _left, _right), do: {first, last}

  defp bands(_line, _left, _right, n, n, acc), do: acc

  defp bands(line, left, right, n, k, acc) do
    {ax, at, al, bx, bt, bl, wall, side, height} = line
    l = left + div((right - left) * k, n)
    r = left + div((right - left) * (k + 1), n)
    middle = along(ax, al, bx, bl, div(l + r, 2))
    colour = colour(wall, side, line_dist(middle, height))
    lt = cut(along(ax, at, bx, bt, l), height)
    rt = cut(along(ax, at, bx, bt, r), height)
    lb = cut(along(ax, at + al, bx, bt + bl, l), height)
    rb = cut(along(ax, at + al, bx, bt + bl, r), height)
    item = {:polygon, [{l, lt}, {r, rt}, {r, rb}, {l, lb}], colour}
    bands(line, left, right, n, k + 1, [item | acc])
  end

  defp line_dist(line, height), do: div(height * 256, max(line, 1))

  # AtomGL clips polygons itself, but wants points within 16 bits.
  defp cut(y, _height), do: min(max(y, -32_000), 32_000)

  # The height at `x` of the line through `{ax, ay}` and `{bx, by}`.
  defp along(ax, ay, bx, by, x), do: ay + div((by - ay) * (x - ax), bx - ax)

  # Digital differential analysis: hop from grid line to grid line along the
  # ray until a wall cell is entered. Returns {wall type, side hit, distance}.
  #
  # Per axis: delta is how far along the ray one whole cell is, and side how
  # far the first grid line is (the rest of the cell, as a fraction of a whole
  # one, times delta). A ray that never crosses that axis's lines gets @far for
  # both. Written as plain ifs rather than a helper returning a tuple, which
  # cost a call and a tuple for each axis of each ray.
  defp cast(grid, cell, in_x, in_y, ray_x, ray_y) do
    delta_x = if ray_x == 0, do: @far, else: div(65_536, abs(ray_x))
    delta_y = if ray_y == 0, do: @far, else: div(65_536, abs(ray_y))

    side_x =
      cond do
        ray_x < 0 -> div(in_x * delta_x, 256)
        ray_x == 0 -> @far
        true -> div((256 - in_x) * delta_x, 256)
      end

    side_y =
      cond do
        ray_y < 0 -> div(in_y * delta_y, 256)
        ray_y == 0 -> @far
        true -> div((256 - in_y) * delta_y, 256)
      end

    # A step across a vertical grid line moves one place in the grid tuple,
    # across a horizontal one a whole row.
    step_x = if ray_x < 0, do: -1, else: 1
    step_y = if ray_y < 0, do: -@size, else: @size

    march(grid, cell, side_x, side_y, delta_x, delta_y, step_x, step_y)
  end

  # The inner loop, run for every grid line every ray crosses. Kept to a
  # comparison, two additions and a tuple read per step: 6 BEAM instructions,
  # where it was about 37 with the bounds checked cell/3 call and a step
  # counter. There is no bounds check and no step limit, because the map's
  # outer wall stops every ray.
  defp march(grid, cell, side_x, side_y, delta_x, delta_y, step_x, step_y) do
    if side_x < side_y do
      cell = cell + step_x

      case :erlang.element(cell, grid) do
        0 -> march(grid, cell, side_x + delta_x, side_y, delta_x, delta_y, step_x, step_y)
        wall -> {wall, 0, side_x, cell}
      end
    else
      cell = cell + step_y

      case :erlang.element(cell, grid) do
        0 -> march(grid, cell, side_x, side_y + delta_y, delta_x, delta_y, step_x, step_y)
        wall -> {wall, 1, side_y, cell}
      end
    end
  end

  defp cell(_grid, x, y) when x < 0 or y < 0 or x >= @size or y >= @size, do: 1
  defp cell(grid, x, y), do: elem(grid, y * @size + x)

  @doc false
  # Whether the point, in the fixed point, is on floor. Outside the map is wall.
  def open?(grid, x, y), do: cell(grid, x >>> 8, y >>> 8) == 0

  @doc false
  # Whether the cell `{column, row}` is floor.
  def open_cell?(grid, cx, cy), do: cell(grid, cx, cy) == 0

  # Darker with distance, and walls facing along y a little darker again, so
  # corners read.
  defp colour(wall, side, dist) do
    rgb = rgb(wall)
    r = rgb >>> 16
    g = rgb >>> 8 &&& 255
    b = rgb &&& 255
    shade = max(48, 256 - div(dist, 12))
    shade = if side == 1, do: div(shade * 3, 4), else: shade

    div(r * shade, 256) <<< 16 ||| div(g * shade, 256) <<< 8 ||| div(b * shade, 256)
  end

  # The held keys as one integer, a bit per direction, read in a single pass.
  # Matching the labels in function heads keeps them out of the module's
  # literals, which AtomVM would copy on every use: the lists of labels this
  # replaced cost 3 ms a frame on the badge.
  defp keys([], bits), do: bits
  defp keys([label | rest], bits), do: keys(rest, bits ||| key(label))

  defp key("Up"), do: @forward
  defp key("W"), do: @forward
  defp key("Down"), do: @back
  defp key("S"), do: @back
  defp key("E"), do: @right
  defp key("Q"), do: @left
  defp key("Right"), do: @turn_right
  defp key("D"), do: @turn_right
  defp key("Left"), do: @turn_left
  defp key("A"), do: @turn_left
  # The badge firmware's keyboard reports labels as charlists.
  defp key(~c"Up"), do: @forward
  defp key(~c"W"), do: @forward
  defp key(~c"Down"), do: @back
  defp key(~c"S"), do: @back
  defp key(~c"E"), do: @right
  defp key(~c"Q"), do: @left
  defp key(~c"Right"), do: @turn_right
  defp key(~c"D"), do: @turn_right
  defp key(~c"Left"), do: @turn_left
  defp key(~c"A"), do: @turn_left
  defp key(_label), do: 0

  # 1, 0 or -1: both directions of an axis held cancel out.
  defp axis(keys, plus, minus), do: held(keys, plus) - held(keys, minus)

  defp held(keys, bit) when (keys &&& bit) == 0, do: 0
  defp held(_keys, _bit), do: 1

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(_n), do: 0

  # Wall colours by type. A function of plain integers rather than a tuple of
  # tuples, because AtomVM copies a module literal onto the heap on every use,
  # and this is read once per column.
  defp rgb(1), do: 0xC83C32
  defp rgb(2), do: 0x3CAA46
  defp rgb(3), do: 0x4664D2

  defp index(angle), do: angle >>> 8 &&& 255
  defp sin(index), do: sin_table(index)
  defp cos(index), do: sin_table(index + 64 &&& 255)

  # 256 steps to a turn, scaled by 256. One clause per step, built while
  # compiling, for the same reason as rgb/1: the compiler turns them into a
  # jump table of plain integers, where a tuple would be a literal.
  for step <- 0..255 do
    defp sin_table(unquote(step)),
      do: unquote(round(:math.sin(step * 2 * :math.pi() / 256) * 256))
  end
end
