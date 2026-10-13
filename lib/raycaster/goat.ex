defmodule Raycaster.Goat do
  @moduledoc """
  The evil goat, run on the badge: it wanders the map, and hunts the player once it sees them.

  It wanders from one random open cell to another until it sees the player, then goes straight
  at them while they are in sight, faster than it wanders but slower than the player walks
  (800), so running away works. It has three paces, `:calm`, then `:fast` and `:faster`, which
  the page asks for as the player lasts longer. When it loses sight of them it goes to where it
  last saw them and searches there for a few seconds before wandering again. Nearer than half a
  cell is a catch.

  It sees through open floor only, with the walk the engine uses to hide figures, so it sees
  the player exactly when they would see it. Positions are the engine's fixed point, 256 to a
  cell, kept as integers like the engine's own, so a step shorter than a unit is lost: the goat
  is a few percent slower than its speeds say.

  Pure, with the grid handed in as an argument (see `Raycaster.Engine.grid/0`). The way round
  a wall is the shortest through the cells, from `Raycaster.Routes`.
  """

  import Bitwise

  alias Raycaster.Engine
  alias Raycaster.Routes

  # Wandering and hunting, in the fixed point per second, by pace.
  @calm {250, 330}
  @fast {350, 450}
  @faster {400, 520}
  # How far it sees: eight cells.
  @sight 2_048
  @reach 128
  @search_ms 4_000

  @doc "A goat in the middle of `cell`, wandering. The seed makes its wandering repeatable."
  def new({cx, cy}, seed) do
    %{
      x: cx * 256 + 128,
      y: cy * 256 + 128,
      mode: :wander,
      goal: nil,
      lost_at: nil,
      seed: rem(abs(seed), 65_537),
      # `{from cell, goal cell, next cell}`: the last route, kept until either changes cell.
      way: nil
    }
  end

  @doc "Where it stands, in whole numbers, and whether it is after the player."
  def where(%{x: x, y: y, mode: mode}), do: {x, y, mode != :wander}

  @doc "Whether, at its last step, it had the player in sight: the same walk the engine makes to draw it."
  def in_sight?(%{mode: mode}), do: mode == :hunt

  @doc """
  Moves the goat on by `dt_ms` at `now`, at `pace` (`:calm`, `:fast` or `:faster`). `prey` is
  where the player stands, `{x, y}`, or nil when it may not be hunted. Returns the goat and
  whether it has caught them.
  """
  def step(goat, grid, prey, dt_ms, now, pace) do
    {wander, hunt} = speeds(pace)
    goat = goat |> look(grid, prey, now) |> move(grid, dt_ms, wander, hunt)
    {goat, caught?(goat, prey)}
  end

  defp caught?(_goat, nil), do: false
  defp caught?(goat, {px, py}), do: apart(goat, px, py) < @reach * @reach

  defp speeds(:faster), do: @faster
  defp speeds(:fast), do: @fast
  defp speeds(_calm), do: @calm

  # Hunts while it sees the player, then searches where it lost them, then wanders.
  defp look(goat, grid, prey, now) do
    case sees(goat, grid, prey) do
      {px, py} ->
        %{goat | mode: :hunt, goal: {px, py}, lost_at: nil}

      nil ->
        case goat.mode do
          :hunt ->
            %{goat | mode: :search, lost_at: now}

          :search when now - goat.lost_at >= @search_ms ->
            %{goat | mode: :wander, goal: nil, lost_at: nil}

          _other ->
            goat
        end
    end
  end

  defp sees(_goat, _grid, nil), do: nil

  defp sees(goat, grid, {px, py}) do
    if apart(goat, px, py) <= @sight * @sight and Engine.visible?(grid, goat.x, goat.y, px, py),
      do: {px, py},
      else: nil
  end

  defp move(%{mode: :hunt, goal: {gx, gy}} = goat, grid, dt_ms, _wander, hunt) do
    step = div(hunt * dt_ms, 1000)
    {x, y} = towards(goat.x, goat.y, gx, gy, step)

    # Straight at them, unless that clips a corner: then round it.
    if Engine.open?(grid, x, y),
      do: %{goat | x: x, y: y},
      else: route(goat, grid, goat.goal, step)
  end

  defp move(%{mode: :search} = goat, grid, dt_ms, _wander, hunt),
    do: route(goat, grid, goat.goal, div(hunt * dt_ms, 1000))

  defp move(%{mode: :wander} = goat, grid, dt_ms, wander, _hunt) do
    goat = if arrived?(goat), do: wander_to(goat, grid), else: goat
    route(goat, grid, goat.goal, div(wander * dt_ms, 1000))
  end

  defp arrived?(%{goal: nil}), do: true
  defp arrived?(%{goal: {gx, gy}} = goat), do: apart(goat, gx, gy) == 0

  # Somewhere open to go next: a cell tried at random until it is floor, which most are.
  defp wander_to(goat, grid) do
    {cx, seed} = pick(goat.seed)
    {cy, seed} = pick(seed)

    if Engine.open_cell?(grid, cx, cy),
      do: %{goat | goal: {cx * 256 + 128, cy * 256 + 128}, seed: seed},
      else: wander_to(%{goat | seed: seed}, grid)
  end

  # A cell from 1 to 14 and the next seed, from a small LCG rather than :rand.
  defp pick(seed) do
    seed = rem(seed * 75 + 74, 65_537)
    {1 + rem(div(seed, 3), 14), seed}
  end

  # Cell middle to cell middle along the route, then straight to the goal in its own cell.
  defp route(goat, grid, {gx, gy}, step) do
    here = {goat.x >>> 8, goat.y >>> 8}
    {goat, next} = next_cell(goat, here, {gx >>> 8, gy >>> 8})

    {tx, ty} =
      case next do
        nil -> {gx, gy}
        {cx, cy} -> {cx * 256 + 128, cy * 256 + 128}
      end

    {x, y} = towards(goat.x, goat.y, tx, ty, step)
    if Engine.open?(grid, x, y), do: %{goat | x: x, y: y}, else: goat
  end

  defp next_cell(%{way: {here, there, next}} = goat, here, there), do: {goat, next}

  defp next_cell(goat, here, there) do
    next = Routes.next(here, there)
    {%{goat | way: {here, there, next}}, next}
  end

  defp towards(x, y, tx, ty, step) do
    dx = tx - x
    dy = ty - y
    length = isqrt(dx * dx + dy * dy)

    if length <= step,
      do: {tx, ty},
      else: {x + div(dx * step, length), y + div(dy * step, length)}
  end

  # The distance squared, so that comparing it needs no root.
  defp apart(goat, x, y) do
    dx = goat.x - x
    dy = goat.y - y
    dx * dx + dy * dy
  end

  # Integer square root by Newton's method, from above any distance on the map.
  defp isqrt(0), do: 0
  defp isqrt(n), do: newton(n, 8_192)

  defp newton(n, guess) do
    next = div(guess + div(n, guess), 2)
    if next >= guess, do: guess, else: newton(n, next)
  end
end
