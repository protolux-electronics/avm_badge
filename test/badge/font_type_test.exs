defmodule Badge.FontTypeTest do
  use ExUnit.Case, async: true

  alias Badge.Font
  alias Badge.FontType

  test "names the four roles" do
    assert FontType.body() == :default16px
    assert FontType.heading() == :pixel_operator
    assert FontType.readout() == :dogica
    assert FontType.large() == :w95fa
  end

  test "every role but the loadable large one is measurable" do
    for font <- [FontType.body(), FontType.heading(), FontType.readout()] do
      assert Font.width(font, "x") != nil
    end
  end
end