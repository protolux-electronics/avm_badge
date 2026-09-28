defmodule Badge.TypeTest do
  use ExUnit.Case, async: true

  alias Badge.Font
  alias Badge.Type

  test "names the four roles" do
    assert Type.body() == :default16px
    assert Type.heading() == :pixel_operator
    assert Type.readout() == :dogica
    assert Type.large() == :w95fa
  end

  test "every role but the loadable large one is measurable" do
    for font <- [Type.body(), Type.heading(), Type.readout()] do
      assert Font.width(font, "x") != nil
    end
  end
end