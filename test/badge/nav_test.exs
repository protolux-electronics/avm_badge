defmodule Badge.NavTest do
  use ExUnit.Case, async: true

  alias Badge.Nav
  alias Badge.Theme

  describe "hint/4" do
    test "sits at the left margin by default" do
      assert [{:text, 8, 200, _font, _colour, _bg, "Enter save"}] =
               Nav.hint([{"Enter", "save"}], 200, Theme.dim())
    end

    test "centres when asked" do
      [{:text, x, 200, _font, _colour, _bg, body}] =
        Nav.hint([{"Enter", "save"}, {"Esc", "cancel"}], 200, Theme.dim(), :centre)

      assert x == div(Theme.width() - 8 * byte_size(body), 2)
    end

    test "draws nothing for no pairs, aligned either way" do
      assert Nav.hint([], 200, Theme.dim()) == []
      assert Nav.hint([], 200, Theme.dim(), :centre) == []
    end
  end
end
