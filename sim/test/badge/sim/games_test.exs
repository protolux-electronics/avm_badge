defmodule Badge.Sim.GamesTest do
  use ExUnit.Case, async: false

  alias Badge.Page.Games
  alias Badge.Page.Home
  alias Badge.Page.Tamagoatchi
  alias Badge.UI

  setup do
    start_supervised!(Badge.Sim.Nvs)
    start_supervised!(Badge.Backlight)

    for spec <- Badge.Sim.Fakes.children(), spec.id in [Badge.Keyboard, Badge.Ir.Link] do
      start_supervised!(spec)
    end

    start_supervised!(Badge.Sim.Display)
    start_supervised!({UI, {Badge.Sim.Display, Badge.Sim.Display}})
    UI.goto(Home)
    assert state().page == Home
    :ok
  end

  defp state, do: :sys.get_state(UI)

  defp key(event) do
    UI.key_event(event)
    state()
  end

  defp open_games do
    key({:move, :right})
    assert key({:nav, :circle}).page == Games
  end

  test "Home opens Games, every game opens with its shape, and Esc backs out one level" do
    open_games()

    for {shape, page} <- Badge.Menu.screen(Games.pages(), 0), page != nil do
      assert key({:nav, shape}).page == page
      assert key({:nav, :home}).page == Games
    end

    assert key({:nav, :home}).page == Home
    assert state().page_state.screen == 0
  end

  test "a goat is discarded on exit, never ticks behind Games, and re-entry starts a newborn" do
    open_games()
    assert key({:nav, :cross}).page == Tamagoatchi

    :sys.replace_state(UI, fn state ->
      %{state | page_state: Tamagoatchi.step(state.page_state, 40_000)}
    end)

    assert state().page_state.pet.age == 40
    assert state().page_state.pet.poop == 1
    assert key({:nav, :home}).page == Games
    for _ <- 1..20, do: send(UI, :render_tick)
    assert state().page_state == Games.init()
    assert key({:nav, :cross}).page == Tamagoatchi
    assert state().page_state.pet == Badge.Tamagoatchi.new()
  end

  test "even a remote page change discards the pet" do
    open_games()
    key({:nav, :cross})
    UI.goto(Home)
    assert state().page == Home
    open_games()
    assert key({:nav, :cross}).page_state.pet == Badge.Tamagoatchi.new()
  end
end
