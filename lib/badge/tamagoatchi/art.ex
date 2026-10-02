defmodule Badge.Tamagoatchi.Art do
  @moduledoc "Animated monochrome pixel goats, drawn as horizontal runs."

  alias Badge.Theme

  @patterns %{
    newborn: [
      "                    ",
      "                    ",
      "                    ",
      "             #  #   ",
      "          ###   ### ",
      "           #       #",
      "           #       #",
      "           #    ### ",
      "    ########  ## #  ",
      "   #          #  #  ",
      "  ##          #     ",
      "   #          #     ",
      "    #        #      ",
      "     ########       ",
      "     # #  # #       ",
      "     #### ####      "
    ],
    baby: [
      "                    ",
      "             #  #   ",
      "             ####   ",
      "          ###   ##  ",
      "         ##      ## ",
      "           #       #",
      "           #       #",
      "     #######    ### ",
      "  ###         ## #  ",
      "   #          #  #  ",
      "   #          #     ",
      "   #          #     ",
      "    #        #      ",
      "    ##########      ",
      "    # #   # #       ",
      "    ####  ####      "
    ],
    child: [
      "            #   #   ",
      "            ## ##   ",
      "             ###    ",
      "          ###   ##  ",
      "         ##      ## ",
      "           #       #",
      "           #       #",
      "  #  #######    ### ",
      "  ###         ## #  ",
      "   #          #  #  ",
      "   #          #  #  ",
      "   #          #     ",
      "   #          #     ",
      "   ############     ",
      "   #  #   #  #      ",
      "   ## ##  ## ##     "
    ],
    adult: [
      "           #     #  ",
      "           ##   ##  ",
      "            #####   ",
      "         ####   ##  ",
      "         ##      ## ",
      "           #       #",
      "           #       #",
      "  ## #######    ### ",
      "   ##         ## #  ",
      "   #          # ### ",
      "  #           #  #  ",
      "  #           #     ",
      "  #           #     ",
      "   ############     ",
      "   #  #   #  #      ",
      "   ## ##  ## ##     "
    ],
    ghost: [
      "           #     #  ",
      "           ##   ##  ",
      "            #####   ",
      "         ####   ##  ",
      "         ##      ## ",
      "           #  ##   #",
      "           #       #",
      "  ## #######    ### ",
      "   ##         ## #  ",
      "   #          # ### ",
      "  #           #  #  ",
      "  #           #     ",
      "  #           #     ",
      "   # # # # # #      ",
      "    # # # # #       ",
      "                    "
    ],
    fallen: [
      "                    ",
      "    #  #  #  #   #  ",
      "    ## ## ## ## ##  ",
      "   ############# #  ",
      "  #          ## ##  ",
      "  #          #  # # ",
      "   #         #   # #",
      " ## ##########  # ##",
      "              ##### ",
      "                #   "
    ],
    poop: ["   ##   ", "  ####  ", " ###### ", "########", " ###### "],
    food: [" #  # ", "  ##  ", "######", " #### ", "  ##  "],
    heart: [" ## ## ", "#######", "#######", " ##### ", "  ###  ", "   #   "],
    crown: ["#   #   #", "## ### ##", "#########", " ####### "],
    sparkle: ["  #  ", "  #  ", "#####", "  #  ", "  #  "],
    stink: [" # ", "#  ", " # ", "  #", " # "]
  }

  @sprites Map.new(@patterns, fn {name, rows} ->
             runs =
               for {row, y} <- Enum.with_index(rows),
                   {x, width} <- Regex.scan(~r/#+/, row, return: :index) |> List.flatten(),
                   do: {x, y, width}

             {name, runs}
           end)

  def pose(%{status: :dying}), do: :dying
  def pose(%{status: :dead}), do: :dead
  def pose(%{status: :won}), do: :won
  def pose(%{animation: animation}) when animation != :idle, do: animation
  def pose(%{needs: %{hunger: n}}) when n >= 45, do: :hungry
  def pose(%{needs: %{happiness: n}}) when n >= 45, do: :sad
  def pose(%{poop: n}) when n > 0, do: :dirty
  def pose(_state), do: :happy

  def frame(pet, phase) do
    pose = pose(pet)
    scenery = poop(pet.poop, phase) ++ [{:rect, 64, 180, 192, 2, Theme.dim()}]
    figure(pet, pose, phase) ++ scenery
  end

  defp figure(_pet, :dead, _phase), do: sprite(:fallen, 120, 140, 4, Theme.fg())

  defp figure(pet, :dying, phase) do
    rise = (3 - pet.animation_left) * 12 + phase * 2

    sprite(:ghost, 140, 120 - rise, 2, Theme.fg()) ++
      sprite(:fallen, 120, 140, 4, Theme.fg())
  end

  defp figure(pet, pose, phase) do
    scale = if pose == :grow and rem(phase, 2) == 0, do: 3, else: 4
    x = 160 - 10 * scale
    y = 180 - 16 * scale - bounce(pose, phase)
    body = if pet.stage == :egg, do: :newborn, else: pet.stage

    effects(pose, phase) ++
      face(pose, x, y, scale, phase) ++
      sprite(body, x, y, scale, Theme.fg())
  end

  defp bounce(pose, phase) when pose == :happy or pose == :play or pose == :won,
    do: rem(phase, 2) * 4

  defp bounce(:train, phase), do: rem(phase, 2) * 8
  defp bounce(_pose, _phase), do: 0

  defp face(pose, x, y, s, phase) do
    h = if phase == 3, do: 1, else: s
    eyes = [{:rect, x + 14 * s, y + 5 * s, 2 * s, h, Theme.fg()}]

    mouth =
      cond do
        pose == :feed or pose == :hungry ->
          [{:rect, x + 17 * s, y + 6 * s, 2 * s, (1 + rem(phase, 2)) * s, Theme.fg()}]

        pose == :sad ->
          [
            {:rect, x + 17 * s, y + 6 * s, s, s, Theme.fg()},
            {:rect, x + 18 * s, y + 7 * s, s, s, Theme.fg()}
          ]

        true ->
          [{:rect, x + 17 * s, y + 6 * s, 2 * s, s, Theme.fg()}]
      end

    tears =
      if pose == :sad,
        do: [{:rect, x + 14 * s, y + (7 + rem(phase, 2)) * s, s, s, Theme.fg()}],
        else: []

    eyes ++ mouth ++ tears
  end

  defp effects(:feed, phase) do
    sprite(:food, 216 - phase * 6, 140, 3, Theme.fg()) ++
      [{:rect, 208, 171, 32, 3, Theme.fg()}, {:rect, 212, 174, 24, 3, Theme.fg()}]
  end

  defp effects(:play, phase), do: sprite(:heart, 208, 124 - phase * 3, 3, Theme.fg())

  defp effects(:train, _phase) do
    [
      {:rect, 100, 170, 120, 4, Theme.fg()},
      {:rect, 96, 166, 8, 12, Theme.fg()},
      {:rect, 216, 166, 8, 12, Theme.fg()}
    ]
  end

  defp effects(:clean, phase),
    do: [
      {:rect, 72 + phase * 40, 168, 24, 4, Theme.fg()},
      {:rect, 80 + phase * 40, 140, 4, 28, Theme.fg()}
    ]

  defp effects(:dirty, phase), do: sprite(:stink, 108, 138 - phase * 2, 3, Theme.fg())
  defp effects(:hungry, phase), do: sprite(:food, 212, 120 + phase * 2, 2, Theme.muted())
  defp effects(:grow, phase), do: sparkles(phase)
  defp effects(:won, phase), do: sprite(:crown, 172, 98, 4, Theme.fg()) ++ sparkles(phase)
  defp effects(_pose, _phase), do: []

  defp sparkles(phase),
    do:
      sprite(:sparkle, 88, 116 + phase * 2, 3, Theme.fg()) ++
        sprite(:sparkle, 208, 142 - phase * 2, 3, Theme.fg())

  defp poop(0, _phase), do: []

  defp poop(count, phase) do
    sprite(:poop, 216 + (count - 1) * 24, 165, 3, Theme.fg()) ++
      sprite(:stink, 224 + (count - 1) * 24, 145 - phase * 2, 2, Theme.fg()) ++
      poop(count - 1, phase)
  end

  defp sprite(name, x, y, scale, colour) do
    for {rx, ry, width} <- Map.fetch!(@sprites, name),
        do: {:rect, x + rx * scale, y + ry * scale, width * scale, scale, colour}
  end
end
