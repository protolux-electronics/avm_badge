defmodule Badge.Page.HomeTest do
  use ExUnit.Case, async: true

  alias Badge.Apps
  alias Badge.Page.Home
  alias Badge.Pages
  alias Badge.Theme

  defp assigned, do: for({_key, module} <- Pages.all(), module != nil, do: module)

  defp icons(items) do
    for {:image, _x, _y, _bg, {:rgba8888, _w, _h, _data}} <- items, do: :icon
  end

  defp texts(items) do
    for {:text, _x, _y, _font, _fg, _bg, body} <- items, do: body
  end

  defp frame(items) do
    for {:rect, x, y, w, h, colour} <- items, colour == Theme.select(), do: {x, y, w, h}
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

    test "draws the dividing rules and no cursor frame" do
      rules =
        for {:rect, _x, _y, _w, _h, colour} <- Home.render(Home.init()),
            colour == Theme.dim(),
            do: :rule

      assert length(rules) == 3
      assert frame(Home.render(Home.init())) == []
    end

    test "emits no background rect, since the router supplies it" do
      refute Enum.any?(Home.render(Home.init()), fn
               {:rect, 0, 0, 320, 240, _colour} -> true
               _item -> false
             end)
    end
  end

  describe "render/1 on the apps" do
    test "one icon and one label per app" do
      items = Home.render(apps())

      assert length(icons(items)) == Apps.count()

      for module <- Apps.all() do
        assert module.title() in texts(items)
      end
    end

    test "frames the cell the cursor is on, drawn first so it sits on top" do
      items = Home.render(apps())

      assert [{:rect, _x, _y, _w, _h, colour} | _rest] = items
      assert colour == Theme.select()
      assert length(frame(items)) == 4
    end

    test "the frame moves with the cursor" do
      before = frame(Home.render(apps()))

      case Apps.count() > 1 do
        true -> assert frame(Home.render(press(apps(), {:move, :right}))) != before
        false -> assert frame(Home.render(press(apps(), {:move, :right}))) == before
      end
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
  end

  describe "keys on the shapes" do
    test "any arrow turns to the apps with the cursor on the first" do
      for direction <- [:up, :down, :left, :right] do
        {:ok, state} = Home.handle_key({:move, direction}, Home.init())

        assert Home.grid(state) == :apps
        assert Home.cursor(state) == 0
      end
    end

    test "ignores everything else, since navigation is the router's job" do
      assert Home.handle_key({:char, ?a}, Home.init()) == :ignore
      assert Home.handle_key({:edit, :newline}, Home.init()) == :ignore
      assert Home.handle_key({:nav, :home}, Home.init()) == :ignore
    end
  end

  describe "keys on the apps" do
    test "escape turns back to the shapes" do
      assert Home.grid(press(apps(), {:nav, :home})) == :shapes
    end

    test "left off the first column turns back to the shapes" do
      assert Home.grid(press(apps(), {:move, :left})) == :shapes
    end

    test "the cursor never leaves the apps" do
      state =
        :lists.foldl(
          fn direction, acc -> press(acc, {:move, direction}) end,
          apps(),
          [:right, :right, :right, :down, :down, :up, :up, :up]
        )

      assert Home.grid(state) == :apps
      assert Home.cursor(state) < Apps.count()
    end

    test "enter chooses the app under the cursor and the next tick opens it" do
      chosen = press(apps(), {:edit, :newline})

      assert Home.tick(chosen) == {:goto, Badge.Page.Agent}
    end

    test "characters are ignored" do
      assert Home.handle_key({:char, ?a}, apps()) == :ignore
    end

    test "nothing opens by itself" do
      assert Home.tick(apps()) == apps()
    end
  end
end
