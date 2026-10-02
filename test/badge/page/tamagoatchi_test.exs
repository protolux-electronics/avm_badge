defmodule Badge.Page.TamagoatchiTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Tamagoatchi, as: Page
  alias Badge.Tamagoatchi, as: Pet
  alias Badge.Tamagoatchi.Art
  alias Badge.Theme

  test "uses the goat name and labels without changing lifecycle stages" do
    assert Page.title() == "Tamagoatchi"

    for {stage, label} <- [egg: "Newborn", baby: "Kid", child: "Young goat", adult: "Goat"] do
      items = Page.render(%{Page.init() | pet: %{Pet.new() | stage: stage}})
      assert {:text, 8, 92, :default16px, Theme.fg(), Theme.bg(), label} in items
    end
  end

  test "every growth stage draws four hooves and a goat's ear and muzzle" do
    for {stage, hooves} <- [
          egg: [5, 7, 10, 12],
          baby: [4, 6, 10, 12],
          child: [3, 6, 10, 13],
          adult: [3, 6, 10, 13]
        ] do
      items = Art.frame(%{Pet.new() | stage: stage}, 0)

      for x <- hooves do
        assert pixel?(items, 120 + x * 4, 176)
      end

      ear_y = if stage == :egg, do: 132, else: 128
      assert pixel?(items, 164, ear_y)
      assert pixel?(items, 196, 140)
    end
  end

  test "grown goats have horns and a beard in every living pose" do
    base = %{Pet.new() | stage: :adult, age: 180}

    for pose <- [:idle, :feed, :play, :train, :clean, :grow], phase <- 0..3 do
      pet = %{base | animation: pose}
      scale = if pose == :grow and rem(phase, 2) == 0, do: 3, else: 4
      bounce = if pose == :idle or pose == :play, do: rem(phase, 2) * 4, else: 0
      bounce = if pose == :train, do: rem(phase, 2) * 8, else: bounce
      x = 160 - 10 * scale
      y = 180 - 16 * scale - bounce
      items = Art.frame(pet, phase)

      assert pixel?(items, x + 11 * scale, y)
      assert pixel?(items, x + 17 * scale, y)
      assert pixel?(items, x + 17 * scale, y + 10 * scale)
    end
  end

  defp pixel?(items, px, py) do
    Enum.any?(items, fn {:rect, x, y, w, h, _colour} ->
      px >= x and px < x + w and py >= y and py < y + h
    end)
  end

  test "the page starts fresh, leaves without resources, and ignores Esc" do
    state = Page.step(Page.init(), 40_000)
    assert Page.init().pet == Pet.new()
    assert Page.leave(state) == :ok
    assert Page.handle_key({:nav, :home}, state) == :ignore
    assert Page.handle_info(:old_timer, state) == :ignore
    assert Page.handle_ir("peer", "frame", state) == :ignore
  end

  test "uses elapsed milliseconds rather than assuming tick delivery is punctual" do
    state = Page.step(Page.init(), 999)
    assert state.pet.age == 0
    assert state.phase == 3
    state = Page.step(state, 1)
    assert state.pet.age == 1
    assert state.fraction == 0
    state = Page.step(state, 20_650)
    assert state.pet.age == 21
    assert state.fraction == 650
    assert state.phase == 2
  end

  test "the first tick sets the clock without advancing the pet" do
    state = Page.tick(Page.init())
    assert is_integer(state.at)
    assert state.pet == Pet.new()
  end

  test "each shape and keyboard shortcut performs its corresponding care action" do
    start = Page.step(Page.init(), 40_000)

    for {shape, char, action} <- [
          {:square, ?f, :feed},
          {:triangle, ?p, :play},
          {:cross, ?t, :train},
          {:circle, ?c, :clean}
        ] do
      expected = Pet.care(start.pet, action)

      for event <- [{:nav, shape}, {:char, char}, {:char, char - 32}] do
        assert {:ok, state} = Page.handle_key(event, start)
        assert state.pet == expected
      end
    end

    assert Page.handle_key({:nav, :clover}, start) == :ignore
  end

  test "Enter restarts a finished game but not a live or dying one" do
    dead = Page.step(Page.init(), 63_000)
    assert dead.pet.status == :dead
    assert Page.handle_key({:edit, :newline}, dead) == {:ok, Page.init()}
    won = %{Page.init() | pet: %{Pet.new() | status: :won}}
    assert Page.handle_key({:edit, :newline}, won) == {:ok, Page.init()}
    assert Page.handle_key({:edit, :newline}, Page.init()) == :ignore
    assert Page.handle_key({:edit, :newline}, Page.step(Page.init(), 60_000)) == :ignore
  end

  test "renders all three labelled meters, care controls and progress" do
    items = Page.render(Page.init())
    texts = for {:text, _, _, _, _, _, body} <- items, do: body

    for body <- [
          "Happiness",
          "Hunger",
          "Training",
          "Sq/F Feed",
          "Tr/P Play",
          "Cr/T Train",
          "Ci/C Clean",
          "0:00 / 5:00",
          "Newborn"
        ] do
      assert body in texts
    end

    assert Enum.count(texts, &(&1 == "100%")) == 3
  end

  defp variants do
    base = %{Pet.new() | stage: :baby, age: 10}
    stages = for stage <- [:egg, :baby, :child, :adult], do: %{base | stage: stage}
    actions = for action <- [:feed, :play, :train, :clean], do: Pet.care(base, action)

    needs = [
      %{base | needs: %{base.needs | hunger: 50}},
      %{base | needs: %{base.needs | happiness: 50}},
      %{base | poop: 3, dirty: 50},
      %{base | animation: :grow},
      %{base | status: :won},
      %{base | status: :dead, reason: :unclean}
    ]

    deaths = for left <- 1..3, do: %{base | status: :dying, animation_left: left}
    stages ++ actions ++ needs ++ deaths
  end

  test "goat figures, every animation and every growth stage stay inside the panel" do
    for pet <- variants(), phase <- 0..3, skin <- Badge.Skin.all() do
      Badge.Skin.activate(skin)
      items = Page.render(%{Page.init() | pet: pet, phase: phase})
      assert Enum.any?(items, &match?({:rect, _, _, _, _, _}, &1))

      for item <- items do
        {x, y, w, h} =
          case item do
            {:rect, x, y, w, h, _} -> {x, y, w, h}
            {:text, x, y, _, _, _, body} -> {x, y, byte_size(body) * 8, 16}
          end

        assert x >= 0 and x + w <= Theme.width(), inspect(item)
        assert y >= Theme.content_top() and y + h <= Theme.height(), inspect(item)
        assert w > 0 and h > 0
        refute {x, y, w, h} == {0, 0, 320, 240}
      end
    end
  end

  test "care, moods, growth, dirt and death have distinct moving goat art" do
    base = %{Pet.new() | age: 10, stage: :baby}

    poses = [
      base,
      Pet.care(base, :feed),
      Pet.care(base, :play),
      Pet.care(base, :train),
      Pet.care(base, :clean),
      %{base | needs: %{base.needs | hunger: 50}},
      %{base | needs: %{base.needs | happiness: 50}},
      %{base | poop: 1},
      %{base | animation: :grow},
      %{base | status: :dying, animation_left: 3},
      %{base | status: :won}
    ]

    frames = Enum.map(poses, &Art.frame(&1, 0))
    assert length(Enum.uniq(frames)) == length(poses)
    for pet <- poses, do: refute(Art.frame(pet, 0) == Art.frame(pet, 1))
    stages = for stage <- [:egg, :baby, :child, :adult], do: Art.frame(%{base | stage: stage}, 0)
    assert length(Enum.uniq(stages)) == 4
  end
end
