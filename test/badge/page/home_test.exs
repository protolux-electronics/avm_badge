defmodule Badge.Page.HomeTest do
  use ExUnit.Case, async: true

  alias Badge.Icons
  alias Badge.Page.Home
  alias Badge.Pages
  alias Badge.Theme

  defp assigned(screen),
    do: for({_key, module} <- Pages.screen(screen), module != nil, do: module)

  defp images(items) do
    for {:image, _x, _y, _bg, {:rgba8888, _w, _h, data}} <- items, do: data
  end

  defp texts(items) do
    for {:text, _x, _y, _font, _fg, _bg, body} <- items, do: body
  end

  defp chevrons(items) do
    for {:text, _x, y, _font, _fg, _bg, body} <- items, y > 200, do: body
  end

  defp on(screen) do
    :lists.foldl(
      fn _n, acc -> press(acc, {:move, :right}) end,
      Home.init(),
      :lists.seq(1, screen)
    )
  end

  defp last, do: on(Pages.screens() - 1)

  defp press(state, event) do
    {:ok, next} = Home.handle_key(event, state)
    next
  end

  describe "identity" do
    test "has a title for the bar" do
      assert Home.title() == "Badge"
    end

    test "opens on the first screen with nothing chosen" do
      assert Home.screen(Home.init()) == 0
      assert Home.tick(Home.init()) == Home.init()
    end
  end

  describe "render/1" do
    test "one shape icon and one label per assigned slot, on every screen" do
      for screen <- 0..(Pages.screens() - 1) do
        items = Home.render(on(screen))

        assert length(images(items)) == length(assigned(screen))

        for {key, module} <- Pages.screen(screen), module != nil do
          assert module.title() in texts(items)
          assert Icons.binary(key, Theme.glyph()) in images(items)
        end
      end
    end

    test "the label under a cell is the page in that slot, not the first screen's" do
      assert "Cluster" in texts(Home.render(on(1)))
      refute "Name" in texts(Home.render(on(1)))
    end

    test "draws the dividing rules on every screen" do
      for screen <- 0..(Pages.screens() - 1) do
        rules =
          for {:rect, _x, _y, _w, _h, colour} <- Home.render(on(screen)),
              colour == Theme.dim(),
              do: :rule

        assert length(rules) == 3
      end
    end

    test "emits no background rect, since the router supplies it" do
      refute Enum.any?(Home.render(Home.init()), fn
               {:rect, 0, 0, 320, 240, _colour} -> true
               _item -> false
             end)
    end

    test "a right chevron says there is more, and only then" do
      assert chevrons(Home.render(Home.init())) == [">"]
      refute ">" in chevrons(Home.render(last()))
    end

    test "a left chevron says there is a way back, and only then" do
      refute "<" in chevrons(Home.render(Home.init()))
      assert "<" in chevrons(Home.render(on(1)))
    end

    test "every item sits inside the content area" do
      for screen <- 0..(Pages.screens() - 1), item <- Home.render(on(screen)) do
        y =
          case item do
            {:rect, _x, y, _w, _h, _c} -> y
            {:text, _x, y, _f, _fg, _bg, _b} -> y
            {:image, _x, y, _bg, _img} -> y
          end

        assert y >= Theme.content_top()
        assert y < Theme.height()
      end
    end

    test "every item sits inside the panel horizontally" do
      for screen <- 0..(Pages.screens() - 1), item <- Home.render(on(screen)) do
        {x, w} =
          case item do
            {:rect, x, _y, w, _h, _c} -> {x, w}
            {:text, x, _y, _f, _fg, _bg, body} -> {x, byte_size(body) * 8}
            {:image, x, _y, _bg, {:rgba8888, w, _h, _data}} -> {x, w}
          end

        assert x >= 0
        assert x + w <= Theme.width()
      end
    end
  end

  describe "turning" do
    test "right or down turns to the next screen" do
      for direction <- [:right, :down] do
        {:ok, state} = Home.handle_key({:move, direction}, Home.init())

        assert Home.screen(state) == 1
      end
    end

    test "left or up turns back" do
      for direction <- [:left, :up] do
        {:ok, state} = Home.handle_key({:move, direction}, on(1))

        assert Home.screen(state) == 0
      end
    end

    test "off either end is left for the router" do
      assert Home.handle_key({:move, :left}, Home.init()) == :ignore
      assert Home.handle_key({:move, :up}, Home.init()) == :ignore
      assert Home.handle_key({:move, :right}, last()) == :ignore
      assert Home.handle_key({:move, :down}, last()) == :ignore
    end

    test "escape returns to the first screen, and is ignored there" do
      assert Home.screen(press(on(1), {:nav, :home})) == 0
      assert Home.handle_key({:nav, :home}, Home.init()) == :ignore
    end
  end

  describe "shape keys" do
    test "on the first screen choose that screen's page, like any other" do
      for {key, module} <- Pages.screen(0), module != nil do
        assert {:ok, state} = Home.handle_key({:nav, key}, Home.init())
        assert Home.tick(state) == {:goto, module}
      end
    end

    test "on a later screen choose that screen's page and the next tick opens it" do
      chosen = press(on(1), {:nav, :triangle})

      assert Home.tick(chosen) == {:goto, Pages.for_key(:triangle, 1)}
    end

    test "over an empty slot are swallowed rather than opening the first screen's page" do
      for {key, nil} <- Pages.screen(1) do
        assert {:ok, state} = Home.handle_key({:nav, key}, on(1))
        assert Home.tick(state) == state
      end
    end
  end

  describe "inertness" do
    test "characters and enter are ignored on every screen" do
      for screen <- 0..(Pages.screens() - 1) do
        assert Home.handle_key({:char, ?a}, on(screen)) == :ignore
        assert Home.handle_key({:edit, :newline}, on(screen)) == :ignore
      end
    end

    test "nothing opens by itself" do
      assert Home.tick(on(1)) == on(1)
    end
  end
end
