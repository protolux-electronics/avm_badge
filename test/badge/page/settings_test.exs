defmodule Badge.Page.SettingsTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Settings
  alias Badge.Theme

  defp right(state) do
    {:ok, next} = Settings.handle_key({:move, :right}, state)
    next
  end

  defp left(state) do
    {:ok, next} = Settings.handle_key({:move, :left}, state)
    next
  end

  defp tabs(state) do
    for {:text, _x, y, _f, colour, _bg, body} <- Settings.render(state),
        y == Theme.content_top(),
        do: {body, colour}
  end

  defp active(state) do
    [title] = for {title, colour} <- tabs(state), colour == Theme.select(), do: title

    title
  end

  defp titles, do: for(module <- Settings.subpages(), do: module.title())

  describe "identity" do
    test "announces itself for the home grid" do
      assert Settings.title() == "Settings"
      assert Settings.icon() == :diamond
    end

    test "repaints slowly, since a frame is a whole panel" do
      assert Settings.refresh(Settings.init()) == 333
    end
  end

  describe "carousel" do
    test "starts on the first sub-page" do
      assert Settings.init().index == 0
    end

    test "right steps forward" do
      assert right(Settings.init()).index == 1
    end

    test "left from the first wraps to the last" do
      assert left(Settings.init()).index == length(Settings.subpages()) - 1
    end

    test "right from the last wraps to the first" do
      last = :lists.foldl(fn _i, acc -> right(acc) end, Settings.init(), Settings.subpages())

      assert last.index == 0
    end

    test "left and right are inverses" do
      assert left(right(Settings.init())) == Settings.init()
    end

    test "exactly one tab is highlighted, and it is the active one" do
      [first | _rest] = titles()

      assert active(Settings.init()) == first
    end

    test "every other tab is dim" do
      dim = for {title, colour} <- tabs(Settings.init()), colour == Theme.dim(), do: title

      assert dim == tl(titles())
    end

    test "the strip names every sub-page wherever you are" do
      assert for({title, _colour} <- tabs(Settings.init()), do: title) == titles()
    end

    test "the highlight follows the carousel" do
      [_first, second | _rest] = titles()

      assert active(right(Settings.init())) == second
    end

    test "the highlight wraps with the carousel" do
      assert active(left(Settings.init())) == :lists.last(titles())
    end
  end

  describe "key routing" do
    test "escape is not trapped, so the router can still go home" do
      assert Settings.handle_key({:nav, :home}, Settings.init()) == :ignore
    end

    test "a key no sub-page wants is ignored rather than swallowed" do
      assert Settings.handle_key({:char, ?z}, Settings.init()) == :ignore
    end

    test "arrows the sub-pages ignore move the carousel" do
      refute right(Settings.init()).index == Settings.init().index
    end

    test "up and down never move the carousel, whether a sub-page wants them or not" do
      state = Settings.init()

      for direction <- [:up, :down] do
        case Settings.handle_key({:move, direction}, state) do
          {:ok, next} -> assert next.index == state.index
          :ignore -> assert true
        end
      end
    end
  end

  describe "sub-page state" do
    test "one state per sub-page" do
      assert length(Settings.init().states) == length(Settings.subpages())
    end

    test "survives sliding away and back" do
      state = Settings.init()
      touched = %{state | states: [:touched | tl(state.states)]}

      assert hd(left(right(touched)).states) == :touched
    end

    test "moving the carousel leaves every sub-page's state alone" do
      state = Settings.init()

      assert right(state).states == state.states
      assert left(state).states == state.states
    end

    # tick/1 delegates to the active sub-page, which reads hardware. That one
    # line is the untestable seam; what it writes back is covered above.
  end

  describe "render/1" do
    test "draws the strip above everything a sub-page draws" do
      ys = for {:text, _x, y, _f, _fg, _bg, _body} <- Settings.render(Settings.init()), do: y
      {strip, content} = :lists.partition(fn y -> y == Theme.content_top() end, ys)

      assert length(strip) == length(Settings.subpages())
      assert content != []
      assert Enum.all?(content, fn y -> y >= Settings.content_top() end)
    end

    test "the strip clears the sub-page content area" do
      assert Settings.content_top() > Theme.content_top()
    end

    test "every item sits inside the content area" do
      for item <- Settings.render(Settings.init()) do
        y =
          case item do
            {:rect, _x, y, _w, _h, _c} -> y
            {:text, _x, y, _f, _fg, _bg, _b} -> y
          end

        assert y >= Theme.content_top()
        assert y < Theme.height()
      end
    end

    test "the first tab starts on the left margin and the last ends on the right" do
      placed =
        for {:text, x, y, _f, _c, _bg, body} <- Settings.render(Settings.init()),
            y == Theme.content_top(),
            do: {x, x + Badge.Font.width(:pixel_operator, body)}

      {first, _} = hd(placed)
      {_, last} = :lists.last(placed)

      assert first == 8
      assert last == Theme.width() - 8
    end

    test "the gaps between tabs are even" do
      placed =
        for {:text, x, y, _f, _c, _bg, body} <- Settings.render(Settings.init()),
            y == Theme.content_top(),
            do: {x, x + Badge.Font.width(:pixel_operator, body)}

      gaps =
        for {{_x, ends}, {starts, _e}} <- :lists.zip(:lists.droplast(placed), tl(placed)),
            do: starts - ends

      # Integer division can leave one pixel in it; anything more is a layout bug.
      assert :lists.max(gaps) - :lists.min(gaps) <= 1
    end

    test "the strip fits the panel and does not overlap itself" do
      placed =
        for {:text, x, y, _f, _c, _bg, body} <- Settings.render(Settings.init()),
            y == Theme.content_top(),
            do: {x, x + Badge.Font.width(:pixel_operator, body)}

      assert Enum.all?(placed, fn {left, right} -> left >= 0 and right <= Theme.width() end)

      sorted = :lists.sort(placed)
      pairs = :lists.zip(sorted, tl(sorted) ++ [{Theme.width(), Theme.width()}])

      assert Enum.all?(pairs, fn {{_l, right}, {next_left, _r}} -> right <= next_left end)
    end

    test "emits no background rect, since the router supplies it" do
      refute Enum.any?(Settings.render(Settings.init()), fn
               {:rect, 0, 0, 320, 240, _colour} -> true
               _item -> false
             end)
    end
  end

  describe "letting a sub-page go" do
    test "leaving settings releases whatever the active sub-page holds" do
      assert Settings.leave(Settings.init()) == :ok
    end

    test "every sub-page can be left from, whichever tab is showing" do
      for index <- 0..(length(Settings.subpages()) - 1) do
        assert Settings.leave(%{Settings.init() | index: index}) == :ok
      end
    end

    test "sliding sideways does not reset the sub-page being left" do
      state = Settings.init()
      touched = %{state | states: :lists.map(fn _ -> :touched end, state.states)}

      assert right(touched).states == touched.states
    end
  end
end
