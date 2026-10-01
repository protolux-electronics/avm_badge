defmodule Badge.Tamagotchi.Art do
  @moduledoc "Animated monochrome pixel figures, drawn as horizontal runs."

  alias Badge.Theme

  @patterns %{
    egg: [
      "     ######     ",
      "    #      #    ",
      "   #        #   ",
      "   #        #   ",
      "  #          #  ",
      "  #          #  ",
      "  #          #  ",
      "  #          #  ",
      "  #          #  ",
      "  #          #  ",
      "   #        #   ",
      "    ########    "
    ],
    baby: [
      "                ",
      "                ",
      "     ######     ",
      "   ##      ##   ",
      "  #          #  ",
      "  #          #  ",
      "  #          #  ",
      "  #          #  ",
      "  #          #  ",
      "   #        #   ",
      "    ########    ",
      "    ##    ##    "
    ],
    child: [
      "    ##    ##    ",
      "   #  ####  #   ",
      "  #          #  ",
      " #            # ",
      " #            # ",
      " #            # ",
      " #            # ",
      " #            # ",
      " #            # ",
      "  #          #  ",
      "   ##########   ",
      "   ###    ###   "
    ],
    adult: [
      "  ###      ###  ",
      " #   #    #   # ",
      " #    ####    # ",
      " #            # ",
      "#              #",
      "#              #",
      "#              #",
      "#              #",
      "#              #",
      " #            # ",
      "  ############  ",
      "  ###      ###  "
    ],
    hungry: [
      "     ######     ",
      "    #      #    ",
      "   #        #   ",
      "   #        #   ",
      "    #      #    ",
      "    #      #    ",
      "    #      #    ",
      "   #        #   ",
      "   #        #   ",
      "    #      #    ",
      "     ######     ",
      "    ##    ##    "
    ],
    poop: ["   ##   ", "  ####  ", " ###### ", "########", " ###### "],
    food: [" #### ", "######", "######", " #### ", "  ##  "],
    heart: [" ## ## ", "#######", "#######", " ##### ", "  ###  ", "   #   "],
    ghost: [
      "  ####  ",
      " #    # ",
      "# #  # #",
      "#      #",
      "#  ##  #",
      "#      #",
      "# #  # #",
      " # ## # "
    ],
    fallen: [
      "    ########    ",
      "  ##        ##  ",
      " #  # #  # #  # ",
      " #   #    #   # ",
      " #  # #  # #  # ",
      "  ############  "
    ],
    grave: [
      "   ######   ",
      "  #      #  ",
      " #        # ",
      " #  ####  # ",
      " #   ##   # ",
      " #   ##   # ",
      " #        # ",
      " #        # ",
      "############"
    ],
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

  defp figure(_pet, :dead, _phase), do: sprite(:grave, 136, 132, 4, Theme.fg())

  defp figure(pet, :dying, phase) do
    rise = (3 - pet.animation_left) * 12 + phase * 2

    sprite(:ghost, 144, 126 - rise, 3, Theme.fg()) ++
      sprite(:fallen, 128, 156, 4, Theme.fg())
  end

  defp figure(pet, pose, phase) do
    scale = if pose == :grow and rem(phase, 2) == 0, do: 3, else: 4
    x = 160 - 8 * scale
    y = 180 - 12 * scale - bounce(pose, phase)
    body = if pose == :hungry, do: :hungry, else: pet.stage
    face = if pet.stage == :egg, do: crack(x, y, phase), else: face(pose, x, y, scale, phase)
    effects(pose, phase) ++ face ++ sprite(body, x, y, scale, Theme.fg())
  end

  defp bounce(pose, phase) when pose == :happy or pose == :play or pose == :won,
    do: rem(phase, 2) * 4

  defp bounce(_pose, _phase), do: 0

  defp face(pose, x, y, s, phase) do
    eyes =
      if pose == :sad or pose == :hungry do
        [
          {:rect, x + 4 * s, y + 5 * s, 2 * s, s, Theme.fg()},
          {:rect, x + 10 * s, y + 5 * s, 2 * s, s, Theme.fg()}
        ]
      else
        h = if phase == 3, do: s, else: 2 * s

        [
          {:rect, x + 4 * s, y + 4 * s, s, h, Theme.fg()},
          {:rect, x + 11 * s, y + 4 * s, s, h, Theme.fg()}
        ]
      end

    mouth =
      cond do
        pose == :feed or pose == :hungry ->
          [{:rect, x + 7 * s, y + 7 * s, 2 * s, (1 + rem(phase, 2)) * s, Theme.fg()}]

        pose == :sad ->
          [
            {:rect, x + 6 * s, y + 8 * s, 4 * s, s, Theme.fg()},
            {:rect, x + 5 * s, y + 9 * s, s, s, Theme.fg()},
            {:rect, x + 10 * s, y + 9 * s, s, s, Theme.fg()}
          ]

        true ->
          [
            {:rect, x + 6 * s, y + 8 * s, 4 * s, s, Theme.fg()},
            {:rect, x + 5 * s, y + 7 * s, s, s, Theme.fg()},
            {:rect, x + 10 * s, y + 7 * s, s, s, Theme.fg()}
          ]
      end

    tears =
      if pose == :sad,
        do: [{:rect, x + 4 * s, y + (7 + rem(phase, 2)) * s, s, s, Theme.fg()}],
        else: []

    eyes ++ mouth ++ tears
  end

  defp crack(x, y, phase) do
    [
      {:rect, x + (6 + rem(phase, 2)) * 4, y + 20, 4, 8, Theme.fg()},
      {:rect, x + 28, y + 28, 8, 4, Theme.fg()}
    ]
  end

  defp effects(:feed, phase) do
    sprite(:food, 88 + phase * 10, 148, 3, Theme.fg()) ++
      [{:rect, 80, 171, 32, 3, Theme.fg()}, {:rect, 84, 174, 24, 3, Theme.fg()}]
  end

  defp effects(:play, phase), do: sprite(:heart, 208, 124 - phase * 3, 3, Theme.fg())

  defp effects(:train, phase) do
    y = 126 + rem(phase, 2) * 12

    [
      {:rect, 100, y, 120, 4, Theme.fg()},
      {:rect, 96, y - 4, 8, 12, Theme.fg()},
      {:rect, 216, y - 4, 8, 12, Theme.fg()}
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
  defp effects(:won, phase), do: sprite(:crown, 142, 110, 4, Theme.fg()) ++ sparkles(phase)
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
