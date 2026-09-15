defmodule Badge.RickrollTest do
  use ExUnit.Case, async: true

  alias Badge.Rickroll

  describe "frames" do
    test "there are enough for the loop to read as motion" do
      assert Rickroll.count() >= 8
    end

    test "drawn large enough to see but inside the content area" do
      assert Rickroll.size() >= 96
      assert Rickroll.size() <= 156
    end
  end

  describe "item/3" do
    test "a negative index still lands on a frame, as it does on a host clock" do
      assert {:scaled_cropped_image, _x, _y, _w, _h, _bg, 0, 0, _sx, _sy, [],
              {:rgba8888, _s, _s2, data}} =
               Rickroll.item(-3, 0, 0)

      assert is_binary(data)
    end

    test "is a scaled image whose stored size times the scale is what is drawn" do
      assert {:scaled_cropped_image, 10, 20, drawn, drawn, _bg, 0, 0, scale, scale, [],
              {:rgba8888, stored, stored, binary}} = Rickroll.item(0, 10, 20)

      assert drawn == Rickroll.size()
      assert stored * scale == drawn
      assert byte_size(binary) == stored * stored * 4
    end

    test "every pixel is opaque, so AtomGL takes its fast path" do
      {:scaled_cropped_image, _x, _y, _w, _h, _bg, _sx, _sy, _s1, _s2, [],
       {:rgba8888, _sw, _sh, binary}} = Rickroll.item(0, 0, 0)

      alphas = for <<_r, _g, _b, a <- binary>>, do: a

      assert :lists.usort(alphas) == [0xFF]
    end

    test "the loop wraps rather than running off the end" do
      assert Rickroll.item(Rickroll.count(), 0, 0) == Rickroll.item(0, 0, 0)
      assert Rickroll.item(Rickroll.count() * 3 + 2, 0, 0) == Rickroll.item(2, 0, 0)
    end

    test "consecutive frames actually differ, or it would not animate" do
      pixels = fn index ->
        {:scaled_cropped_image, _x, _y, _w, _h, _bg, _sx, _sy, _s1, _s2, [],
         {:rgba8888, _sw, _sh, binary}} = Rickroll.item(index, 0, 0)

        binary
      end

      distinct = for index <- 0..(Rickroll.count() - 1), do: pixels.(index)

      assert length(:lists.usort(distinct)) == Rickroll.count()
    end
  end
end
