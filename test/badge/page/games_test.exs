defmodule Badge.Page.GamesTest do
  use ExUnit.Case, async: true

  alias Badge.Menu
  alias Badge.Page.Games
  alias Badge.Pages

  test "Home has one Games entry and no individual games" do
    assert Pages.for_key(:circle, 1) == Games
    for game <- Games.pages(), do: refute(game in Pages.all())
    assert Games.pages() == [Badge.Page.ConnectFour, Badge.Page.Raycaster, Badge.Page.Tamagoatchi]
  end

  test "renders exactly the shared Home grid over the game list" do
    assert Games.render(Games.init()) == Menu.render(Games.pages(), Menu.init())
    labels = for {:text, _, _, _, _, _, body} <- Games.render(Games.init()), do: body
    assert labels == ["Connect Four", "Raycaster", "Tamagoatchi"]
  end

  test "shape keys select the games; unused slots stay empty" do
    for {key, module} <- Menu.screen(Games.pages(), 0) do
      assert {:ok, next} = Games.handle_key({:nav, key}, Games.init())

      if module == nil do
        assert Games.tick(next) == next
      else
        assert Games.tick(next) == {:goto, module}
      end
    end
  end

  test "Esc is left to the router and there is no hidden game state" do
    state = Games.init()
    assert state == %{screen: 0, goto: nil}
    assert Games.tick(state) == state
    assert Games.handle_key({:nav, :home}, state) == :ignore
    assert Games.handle_key({:move, :right}, state) == :ignore
    assert Games.handle_key({:char, ?a}, state) == :ignore
    assert Games.leave(state) == :ok
  end
end
