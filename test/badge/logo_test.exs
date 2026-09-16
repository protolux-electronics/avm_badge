defmodule Badge.LogoTest do
  use ExUnit.Case, async: true

  alias Badge.Logo
  alias Badge.Theme

  # What the badge reads from the assets partition, standing in on the host.
  @image {:rgba8888, 120, 68, <<>>}

  defp file, do: hd(Path.wildcard("assets/logo/goatmire@*.rgba"))

  test "the bytes in the file match the size in its name" do
    {width, height} = Logo.size()

    assert byte_size(File.read!(file())) == width * height * 4
  end

  test "every pixel in the file is opaque, so AtomGL never blends" do
    for <<_r, _g, _b, a <- File.read!(file())>>, do: assert(a == 0xFF)
  end

  test "fits the panel with room to slide once drawn" do
    {width, height} = Logo.size()

    assert width * Logo.scale() < Theme.width()
    assert height * Logo.scale() < Theme.height() - Theme.bar_h()
  end

  test "the image is the bytes the partition answers, at the compiled size" do
    assert {:rgba8888, 120, 68, bytes} = Logo.image()
    assert byte_size(bytes) == 120 * 68 * 4
  end

  test "a partition without the logo answers undefined, which is no image rather than a crash" do
    assert Logo.image(:undefined) == nil
  end

  test "the whole logo is one item, drawn at twice its size" do
    {width, height} = Logo.size()
    drawn_w = width * 2
    drawn_h = height * 2

    assert {:scaled_cropped_image, 10, 20, ^drawn_w, ^drawn_h, 0, 0, 0, 2, 2, [], @image} =
             Logo.item(10, 20, @image)
  end

  test "a piece lands where the whole logo would put those pixels" do
    assert {:scaled_cropped_image, 20, 34, 40, 10, 0, 5, 7, 2, 2, [], @image} =
             Logo.piece(10, 20, 5, 7, 20, 5, 0, @image)
  end

  test "a slide moves a piece sideways only, in screen pixels" do
    assert {:scaled_cropped_image, 17, 34, 40, 10, 0, 5, 7, 2, 2, [], @image} =
             Logo.piece(10, 20, 5, 7, 20, 5, -3, @image)
  end
end
