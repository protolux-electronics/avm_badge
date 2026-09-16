defmodule Badge.Page.HomeTest do
  use ExUnit.Case, async: true

  alias Badge.Apps
  alias Badge.Icons
  alias Badge.Page.Home
  alias Badge.Pages
  alias Badge.Theme

  @shapes [:square, :triangle, :cross, :circle, :clover, :diamond]

  defp assigned, do: for({_key, module} <- Pages.all(), module != nil, do: module)

  defp icons(items) do
    for {:image, _x, _y, _bg, {:rgba8888, _w, _h, _data}} <- items, do: :icon
  end

  defp images(items) do
    for {:image, _x, _y, _bg, {:rgba8888, _w, _h, data}} <- items, do: data
  end

  defp texts(items) do
    for {:text, _x, _y, _font, _fg, _bg, body} <- items, do: body
  end

  defp apps do
    {:ok, state} = Home.handle_key({:move, :right}, Home.init())
    state
  end

  defp press(state, event) do
    {:ok, next} = Home.handle_key(event, state)
    next
  end

  describe "identity" do
    test "has a title for the bar" do
      assert Home.title() == "Badge"
    end

    test "opens on the shapes with nothing chosen" do
      assert Home.grid(Home.init()) == :shapes
      assert Home.tick(Home.init()) == Home.init()
    end
  end

  describe "render/1 on the shapes" do
    test "one icon per assigned page" do
      items = Home.render(Home.init())

      assert length(icons(items)) == length(assigned())
    end

    test "one label per assigned page, and it is the page's own title" do
      items = Home.render(Home.init())

      for module <- assigned() do
        assert module.title() in texts(items)
      end
    end

    test "draws the dividing rules" do
      rules =
        for {:rect, _x, _y, _w, _h, colour} <- Home.render(Home.init()),
            colour == Theme.dim(),
            do: :rule

      assert length(rules) == 3
    end

    test "emits no background rect, since the router supplies it" do
      refute Enum.any?(Home.render(Home.init()), fn
               {:rect, 0, 0, 320, 240, _colour} -> true
               _item -> false
             end)
    end
  end

  describe "render/1 on the apps" do
    test "each app shows the shape that opens it beside its own icon, and its label" do
      items = Home.render(apps())

      assert length(icons(items)) == 2 * Apps.count()

      for {module, index} <- Enum.with_index(Apps.all()) do
        assert module.title() in texts(items)
        assert Icons.binary(:lists.nth(index + 1, @shapes), Theme.glyph()) in images(items)
        assert Icons.binary(module.icon(), Theme.glyph()) in images(items)
      end
    end

    test "leaves the unused slots empty" do
      refute "Chat" in texts(Home.render(apps()))
    end

    test "keeps the dividing rules" do
      rules =
        for {:rect, _x, _y, _w, _h, colour} <- Home.render(apps()),
            colour == Theme.dim(),
            do: :rule

      assert length(rules) == 3
    end
  end

  describe "every item on either grid" do
    test "sits inside the content area" do
      for state <- [Home.init(), apps()], item <- Home.render(state) do
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

    test "sits inside the panel horizontally" do
      for state <- [Home.init(), apps()], item <- Home.render(state) do
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

    test "the pair of icons in a cell do not overlap" do
      xs =
        for {:image, x, _y, _bg, {:rgba8888, w, _h, _data}} <- Home.render(apps()),
            do: {x, x + w}

      for {a, b} <- Enum.zip(xs, tl(xs)) do
        assert elem(a, 1) <= elem(b, 0)
      end
    end
  end

  describe "keys on the shapes" do
    test "right or down turns to the apps" do
      for direction <- [:right, :down] do
        {:ok, state} = Home.handle_key({:move, direction}, Home.init())

        assert Home.grid(state) == :apps
      end
    end

    test "left or up has nowhere to go and is left for the router" do
      assert Home.handle_key({:move, :left}, Home.init()) == :ignore
      assert Home.handle_key({:move, :up}, Home.init()) == :ignore
    end

    test "ignores everything else, since navigation is the router's job" do
      assert Home.handle_key({:char, ?a}, Home.init()) == :ignore
      assert Home.handle_key({:edit, :newline}, Home.init()) == :ignore
      assert Home.handle_key({:nav, :home}, Home.init()) == :ignore

      for key <- @shapes do
        assert Home.handle_key({:nav, key}, Home.init()) == :ignore
      end
    end
  end

  describe "keys on the apps" do
    test "left, up or escape turn back to the shapes" do
      for event <- [{:move, :left}, {:move, :up}, {:nav, :home}] do
        assert Home.grid(press(apps(), event)) == :shapes
      end
    end

    test "right or down stay put, and are left for the router" do
      assert Home.handle_key({:move, :right}, apps()) == :ignore
      assert Home.handle_key({:move, :down}, apps()) == :ignore
    end

    test "the first shape key chooses the first app and the next tick opens it" do
      chosen = press(apps(), {:nav, :square})

      assert Home.tick(chosen) == {:goto, Badge.Page.Agent}
    end

    test "a shape key over an empty slot is swallowed rather than navigating" do
      for key <- Enum.drop(@shapes, Apps.count()) do
        assert {:ok, state} = Home.handle_key({:nav, key}, apps())
        assert Home.tick(state) == state
      end
    end

    test "characters and enter are ignored" do
      assert Home.handle_key({:char, ?a}, apps()) == :ignore
      assert Home.handle_key({:edit, :newline}, apps()) == :ignore
    end

    test "nothing opens by itself" do
      assert Home.tick(apps()) == apps()
    end
  end
end
