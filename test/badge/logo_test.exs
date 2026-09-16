defmodule Badge.LogoTest do
  use ExUnit.Case, async: true

  alias Badge.Logo
  alias Badge.Theme

  test "the bytes match the size in the file name" do
    {width, height} = Logo.size()

    assert byte_size(Logo.binary()) == width * height * 4
  end

  test "fits the panel with room to slide once drawn" do
    {width, height} = Logo.size()

    assert width * Logo.scale() < Theme.width()
    assert height * Logo.scale() < Theme.height() - Theme.bar_h()
  end

  test "every pixel is opaque, so AtomGL never blends" do
    for <<_r, _g, _b, a <- Logo.binary()>>, do: assert(a == 0xFF)
  end

  test "the whole logo is one item, drawn at twice its size" do
    {width, height} = Logo.size()
    drawn_w = width * 2
    drawn_h = height * 2

    assert {:scaled_cropped_image, 10, 20, ^drawn_w, ^drawn_h, 0, 0, 0, 2, 2, [],
            {:rgba8888, ^width, ^height, _data}} = Logo.item(10, 20)
  end

  test "a piece lands where the whole logo would put those pixels" do
    assert {:scaled_cropped_image, 20, 34, 40, 10, 0, 5, 7, 2, 2, [], _image} =
             Logo.piece(10, 20, 5, 7, 20, 5, 0)
  end

  test "a slide moves a piece sideways only, in screen pixels" do
    assert {:scaled_cropped_image, 17, 34, 40, 10, 0, 5, 7, 2, 2, [], _image} =
             Logo.piece(10, 20, 5, 7, 20, 5, -3)
  end
end
