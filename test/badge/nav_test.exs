defmodule Badge.NavTest do
  use ExUnit.Case, async: true

  alias Badge.Font
  alias Badge.Nav
  alias Badge.Readout
  alias Badge.Theme
  alias Badge.FontType

  defmodule First do
    use Badge.Page

    @impl true
    def title, do: "First"

    @impl true
    def init, do: %{n: 0}

    @impl true
    def render(_state), do: []

    @impl true
    def handle_key({:char, ?a}, state), do: {:ok, %{state | n: state.n + 1}}

    @impl true
    def handle_key(_event, _state), do: :ignore
  end

  defmodule Second do
    use Badge.Page

    @impl true
    def title, do: "Second"

    @impl true
    def init, do: %{n: 0}

    @impl true
    def render(_state), do: []
  end

  defp dots(items), do: for({:rect, x, y, 6, 6, colour} <- items, do: {x, y, colour})

  defp lit(items) do
    for {x, y, colour} <- dots(items), colour == Theme.fg(), do: {x, y}
  end

  defp texts(items) do
    for {:text, x, y, font, fg, _bg, body} <- items, do: {x, y, font, fg, body}
  end

  defp text_at(items, body) do
    [{body, x}] = for {:text, x, _y, _f, _fg, _bg, ^body} <- items, do: {body, x}

    {body, x}
  end

  defp trailed_at(items, body) do
    [{x, font, colour}] =
      for {:text, x, _y, font, colour, _bg, ^body} <- items, do: {x, font, colour}

    {body, x, font, colour}
  end

  describe "dots/2" do
    test "one dot per screen" do
      assert length(dots(Nav.dots(3, 0))) == 3
      assert length(dots(Nav.dots(1, 0))) == 1
    end

    test "exactly one dot is lit" do
      for current <- 0..2 do
        assert length(lit(Nav.dots(3, current))) == 1
      end
    end

    test "the lit dot walks right with the index" do
      [{x0, _}] = lit(Nav.dots(3, 0))
      [{x1, _}] = lit(Nav.dots(3, 1))
      [{x2, _}] = lit(Nav.dots(3, 2))

      assert x0 < x1 and x1 < x2
    end

    test "they stay on the panel" do
      for {x, y, _c} <- dots(Nav.dots(5, 0)) do
        assert x >= 0
        assert x + 6 <= Theme.width()
        assert y + 6 <= Theme.height()
      end
    end
  end

  describe "tabs/3" do
    test "one text item per title, in order" do
      bodies = for {_x, _y, _f, _fg, body} <- texts(Nav.tabs(["A", "B", "C"], 1, 30)), do: body

      assert bodies == ["A", "B", "C"]
    end

    test "the first tab is on the left margin and the last flush right" do
      [{first_x, _y, _f, _fg, "A"}] = Enum.take(texts(Nav.tabs(["A", "B", "C"], 0, 30)), 1)
      {last_x, _y2, _f2, _fg2, last_body} = List.last(texts(Nav.tabs(["A", "B", "C"], 0, 30)))

      assert first_x == 8
      assert last_x + Font.width(FontType.heading(), last_body) == Theme.width() - 8
    end

    test "the current title is selected, the rest dim" do
      [{_x, _y, _f, colour}] =
        for {x, y, f, fg, body} <- texts(Nav.tabs(["A", "B", "C"], 1, 30)),
            body == "B",
            do: {x, y, f, fg}

      assert colour == Theme.select()

      dimmed =
        for {_x, _y, _f, fg, body} <- texts(Nav.tabs(["A", "B", "C"], 1, 30)),
            body != "B",
            do: fg

      assert dimmed == [Theme.dim(), Theme.dim()]
    end

    test "titles are drawn in the heading font" do
      assert Enum.all?(Nav.tabs(["A", "B"], 0, 30), fn
               {:text, _x, _y, font, _fg, _bg, _body} -> font == FontType.heading()
               _item -> false
             end)
    end
  end

  describe "hint/3" do
    test "joins key and label pairs with a wide gap" do
      [{:text, _x, _y, _f, _fg, _bg, body}] =
        Nav.hint([{"up/down", "pick"}, {"Enter", "edit"}], 216, Theme.dim())

      assert body == "up/down pick   Enter edit"
    end

    test "an empty hint list draws nothing" do
      assert Nav.hint([], 216, Theme.dim()) == []
    end

    test "the line starts on the left margin" do
      [{:text, x, _y, _f, _fg, _bg, _body}] = Nav.hint([{"a", "b"}], 216, Theme.dim())

      assert x == 8
    end
  end

  describe "rows/4" do
    test "a marker is drawn only on the cursor row" do
      entries = [%{value: "a"}, %{value: "b"}]
      bodies = for {:text, _x, _y, _f, _fg, _bg, body} <- Nav.rows(entries, 1, 40, 18), do: body

      assert Enum.count(bodies, &(&1 == ">")) == 1
    end

    test "a labelled row puts the label at 8 and the value at 88" do
      items = Nav.rows([%{label: "Name", value: "Gus"}], 0, 40, 18)

      assert {">", 0} = text_at(items, ">")
      assert {"Name", 8} = text_at(items, "Name")
      assert {"Gus", 88} = text_at(items, "Gus")
    end

    test "an unlabelled value starts on the left margin" do
      assert {"room", 8} = text_at(Nav.rows([%{value: "room"}], 0, 40, 18), "room")
    end

    test "trailing text is right-aligned with its own colour" do
      body_font = FontType.body()

      items =
        Nav.rows([%{value: "a", trailing: "3", trailing_colour: Theme.accent()}], 0, 40, 18)

      assert {"3", x, ^body_font, colour} = trailed_at(items, "3")
      assert x == Readout.right_x("3")
      assert colour == Theme.accent()
    end

    test "rows step down by the pitch" do
      entries = [%{value: "a"}, %{value: "b"}, %{value: "c"}]

      values =
        for {:text, _x, y, _f, _fg, _bg, body} <- Nav.rows(entries, 0, 40, 18),
            body in ["a", "b", "c"],
            do: {body, y}

      assert values == [{"a", 40}, {"b", 58}, {"c", 76}]
    end
  end

  describe "container helpers" do
    test "carousel/1 initialises one state per sub-page" do
      state = Nav.carousel([First, Second])

      assert state.index == 0
      assert state.states == [First.init(), Second.init()]
    end

    test "delegate/3 offers the event to the visible sub-page" do
      state = Nav.carousel([First, Second])

      assert {:ok, %{states: [%{n: 1}, _second]}} = Nav.delegate({:char, ?a}, state, [First, Second])
    end

    test "delegate/3 ignores what the sub-page ignores" do
      state = Nav.carousel([First, Second])

      assert Nav.delegate({:char, ?z}, state, [First, Second]) == :ignore
    end

    test "step/3 wraps both ways" do
      state = Nav.carousel([First, Second])

      assert Nav.step(state, 2, 1).index == 1
      assert Nav.step(Nav.step(state, 2, 1), 2, 1).index == 0
      assert Nav.step(state, 2, -1).index == 1
    end
  end
end