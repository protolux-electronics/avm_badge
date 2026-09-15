defmodule Badge.LogoTest do
  use ExUnit.Case, async: true

  alias Badge.Logo
  alias Badge.Theme

  test "the bytes match the size in the file name" do
    {width, height} = Logo.size()

    assert byte_size(Logo.binary()) == width * height * 4
  end

  test "fits the panel with room to slide" do
    {width, height} = Logo.size()

    assert width < Theme.width()
    assert height < Theme.height() - Theme.bar_h()
  end

  test "every pixel is opaque, so AtomGL never blends" do
    for <<_r, _g, _b, a <- Logo.binary()>>, do: assert(a == 0xFF)
  end

  test "the whole logo is one image item" do
    {width, height} = Logo.size()

    assert {:image, 10, 20, 0, {:rgba8888, ^width, ^height, _data}} = Logo.item(10, 20)
  end

  test "a piece lands where the whole logo would put those pixels" do
    assert {:scaled_cropped_image, 15, 27, 20, 5, 0, 5, 7, 1, 1, [], _image} =
             Logo.piece(10, 20, 5, 7, 20, 5, 0)
  end

  test "a slide moves a piece sideways only" do
    assert {:scaled_cropped_image, 12, 27, 20, 5, 0, 5, 7, 1, 1, [], _image} =
             Logo.piece(10, 20, 5, 7, 20, 5, -3)
  end
end
