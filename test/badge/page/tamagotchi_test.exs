defmodule Badge.Page.TamagotchiTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Tamagotchi, as: Page
  alias Badge.Tamagotchi, as: Pet
  alias Badge.Tamagotchi.Art
  alias Badge.Theme

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
          "Egg"
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

  test "retro figures, every animation and every growth stage stay inside the panel" do
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

  test "care, moods, growth, dirt and death have distinct moving retro art" do
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
