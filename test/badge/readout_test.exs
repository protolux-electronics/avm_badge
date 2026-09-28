defmodule Badge.ReadoutTest do
  use ExUnit.Case, async: true

  alias Badge.Font
  alias Badge.Readout
  alias Badge.Theme
  alias Badge.Type

  describe "rows/2" do
    test "no pairs draw nothing" do
      assert Readout.rows([], 50) == []
    end

    test "each pair becomes a label and a value" do
      items = Readout.rows([{"temp", "24 C"}], 50)
      bodies = for {:text, _x, _y, _f, _fg, _bg, body} <- items, do: body

      assert bodies == ["temp", "24 C"]
    end

    test "the label is dim and the value is bright" do
      [label, value] = Readout.rows([{"temp", "24 C"}], 50)

      assert {:text, _x, _y, _f, dim, _bg, "temp"} = label
      assert {:text, _x2, _y2, _f2, fg, _bg2, "24 C"} = value
      assert dim == Theme.dim()
      assert fg == Theme.fg()
    end

    test "values sit to the right of labels" do
      [{:text, label_x, _y, _f, _c, _b, _l}, {:text, value_x, _y2, _f2, _c2, _b2, _v}] =
        Readout.rows([{"temp", "24 C"}], 50)

      assert value_x > label_x
    end

    test "the first row sits at the given top" do
      [{:text, _x, y, _f, _c, _b, _l} | _rest] = Readout.rows([{"a", "1"}], 50)

      assert y == 50
    end

    test "rows step down by the pitch" do
      items = Readout.rows([{"a", "1"}, {"b", "2"}, {"c", "3"}], 50)
      ys = for {:text, _x, y, _f, _c, _b, body} <- items, body in ["a", "b", "c"], do: y

      assert ys == [50, 50 + Readout.pitch(), 50 + 2 * Readout.pitch()]
    end

    test "a label and its value share a row" do
      items = Readout.rows([{"a", "1"}, {"b", "2"}], 50)
      ys = for {:text, _x, y, _f, _c, _b, _body} <- items, do: y

      assert ys == [50, 50, 50 + Readout.pitch(), 50 + Readout.pitch()]
    end
  end

  describe "measurement" do
    test "centre_x/2 measures in the given font" do
      assert Readout.centre_x("AB", :dogica) ==
               div(Theme.width() - Font.width(:dogica, "AB"), 2)
    end

    test "right_x/2 measures in the given font" do
      assert Readout.right_x("AB", :dogica) ==
               Theme.width() - 8 - Font.width(:dogica, "AB")
    end

    test "the one-argument calls still use the body font" do
      assert Readout.centre_x("AB") == Readout.centre_x("AB", Type.body())
      assert Readout.right_x("AB") == Readout.right_x("AB", Type.body())
    end
  end
end
