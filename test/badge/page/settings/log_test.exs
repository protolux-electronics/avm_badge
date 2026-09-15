defmodule Badge.Page.Settings.LogTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Settings
  alias Badge.Page.Settings.Log
  alias Badge.Theme

  defp page(lines, offset \\ 0), do: %{Log.init() | lines: lines, offset: offset}

  defp bodies(state), do: for({:text, _x, _y, _f, _c, _b, body} <- Log.render(state), do: body)

  defp numbered(count), do: for(n <- 1..count, do: "line " <> :erlang.integer_to_binary(n))

  describe "identity" do
    test "names itself for the tab strip" do
      assert Log.title() == "Log"
    end

    test "starts empty and at the bottom" do
      assert Log.init() == %{lines: [], offset: 0}
    end
  end

  describe "wrapping" do
    test "a short line is one row" do
      assert Log.rows(["hello"]) == ["hello"]
    end

    test "a long line continues on the next row rather than being cut" do
      long = :binary.copy("a", 38) <> :binary.copy("b", 5)

      assert Log.rows([long]) == [:binary.copy("a", 38), "bbbbb"]
    end

    test "order is kept across lines" do
      assert Log.rows(["one", :binary.copy("x", 40), "two"]) ==
               ["one", :binary.copy("x", 38), "xx", "two"]
    end
  end

  describe "the window" do
    test "shows the newest rows when at the bottom" do
      rows = numbered(30)

      shown = Log.window(rows, 0)

      assert length(shown) == Log.visible_rows()
      assert :lists.last(shown) == "line 30"
    end

    test "scrolling back reveals older rows" do
      rows = numbered(30)

      assert :lists.last(Log.window(rows, 3)) == "line 27"
    end

    test "fewer rows than fit are all shown" do
      assert Log.window(["a", "b"], 0) == ["a", "b"]
    end
  end

  describe "scrolling keys" do
    test "up moves back and stops at the oldest row" do
      state = page(numbered(Log.visible_rows() + 2))

      {:ok, once} = Log.handle_key({:move, :up}, state)
      {:ok, twice} = Log.handle_key({:move, :up}, once)
      {:ok, thrice} = Log.handle_key({:move, :up}, twice)

      assert once.offset == 1
      assert twice.offset == 2
      assert thrice.offset == 2
    end

    test "down returns and stops at the bottom" do
      {:ok, state} = Log.handle_key({:move, :down}, page(numbered(30), 1))
      {:ok, still} = Log.handle_key({:move, :down}, state)

      assert state.offset == 0
      assert still.offset == 0
    end

    test "up does nothing when everything already fits" do
      {:ok, state} = Log.handle_key({:move, :up}, page(["a"]))

      assert state.offset == 0
    end

    test "the arrows sideways are left to the carousel" do
      assert Log.handle_key({:move, :left}, page(["a"])) == :ignore
      assert Log.handle_key({:move, :right}, page(["a"])) == :ignore
    end
  end

  describe "drawing inside the lines" do
    test "oldest at the top, newest at the bottom" do
      ys =
        for {:text, _x, y, _f, _c, _b, body} <- Log.render(page(["old", "new"])),
            into: %{},
            do: {body, y}

      assert ys["old"] < ys["new"]
    end

    test "a full log fits the content area" do
      state = page(for(_n <- 1..40, do: :binary.copy("z", 70)))

      assert length(bodies(state)) == Log.visible_rows()

      for {:text, x, y, _f, _c, _b, body} <- Log.render(state) do
        assert y >= Settings.content_top()
        assert y + 16 <= Theme.height()
        assert x + 8 * byte_size(body) <= Theme.width()
      end
    end
  end
end
