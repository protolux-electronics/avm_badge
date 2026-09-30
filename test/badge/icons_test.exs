defmodule Badge.IconsTest do
  use ExUnit.Case, async: true

  alias Badge.Icons
  alias Badge.Skin
  alias Badge.Theme

  @shapes [:circle, :clover, :cross, :diamond, :square, :triangle]
  @status [
    :battery_0,
    :battery_100,
    :battery_25,
    :battery_50,
    :battery_75,
    :battery_charging,
    :messages,
    :wifi,
    :wifi_slash,
    :email,
    :github,
    :linkedin,
    :mastodon,
    :bluesky,
    :company,
    :link,
    :signal_0,
    :signal_1,
    :signal_2,
    :signal_3
  ]

  @white 0xFFFFFF
  @black 0x000000

  defp alphas(name, tint), do: for(<<_r, _g, _b, a <- Icons.binary(name, tint)>>, do: a)

  describe "names/0" do
    test "is sorted" do
      assert Icons.names() == :lists.sort(Icons.names())
    end

    test "holds every shape and every status icon" do
      assert Icons.names() == :lists.sort(@shapes ++ @status)
    end

    test "the retired dot marker is gone" do
      refute :dot in Icons.names()
    end
  end

  describe "mono?/1" do
    test "status icons are monochrome and shapes are not" do
      for name <- @status, do: assert(Icons.mono?(name))
      for name <- @shapes, do: refute(Icons.mono?(name))
    end

    test "an unknown name is false rather than a crash" do
      refute Icons.mono?(:nonesuch)
    end
  end

  describe "size/1" do
    test "shapes are 32x32" do
      for name <- @shapes do
        assert Icons.size(name) == {32, 32}
      end
    end

    test "status icons are 16x16" do
      for name <- @status do
        assert Icons.size(name) == {16, 16}
      end
    end

    test "an unknown name is nil rather than a crash" do
      assert Icons.size(:nonesuch) == nil
    end
  end

  describe "binary/2" do
    test "every icon is exactly w * h * 4 bytes for its declared size, in every tint" do
      for name <- Icons.names(), tint <- Icons.tints() do
        {w, h} = Icons.size(name)

        assert byte_size(Icons.binary(name, tint)) == w * h * 4
      end
    end

    # signal_0 is drawn faint on purpose, so its body never reaches full alpha.
    test "every icon has a transparent background and a visible body" do
      for name <- Icons.names() do
        alphas = alphas(name, @white)

        assert 0 in alphas
        assert :lists.max(alphas) >= 64
      end
    end

    test "every icon but the faint one has an opaque body" do
      for name <- Icons.names(), name != :signal_0 do
        assert 0xFF in alphas(name, @white)
      end
    end

    test "a monochrome icon carries its tint on every pixel" do
      for name <- @status, tint <- Icons.tints() do
        <<r, g, b>> = <<tint::24>>
        colours = for <<r2, g2, b2, _a <- Icons.binary(name, tint)>>, do: {r2, g2, b2}

        assert :lists.usort(colours) == [{r, g, b}]
      end
    end

    test "a colour icon is the same in every tint" do
      for name <- @shapes do
        assert Icons.binary(name, @white) == Icons.binary(name, @black)
      end
    end

    test "a colour icon is not grey" do
      for name <- @shapes do
        hued = for {r, g, b, 0xFF} <- rgba(name), r != g or g != b, do: :hued

        assert hued != []
      end
    end

    test "an unknown name or an unbaked tint is nil rather than a crash" do
      assert Icons.binary(:nonesuch, @white) == nil
      assert Icons.binary(:wifi, 0x123456) == nil
    end

    test "icons are actually different from each other" do
      binaries = for name <- Icons.names(), do: Icons.binary(name, @white)

      assert length(:lists.usort(binaries)) == length(binaries)
    end

    test "no icon is blank" do
      for name <- Icons.names() do
        {w, h} = Icons.size(name)
        lit = :lists.filter(fn px -> px != 0 end, alphas(name, @white))

        assert length(lit) > div(w * h, 20)
      end
    end
  end

  describe "tints/0" do
    test "covers every skin's glyph colour" do
      for skin <- Skin.all() do
        assert skin.glyph() in Icons.tints()
      end
    end
  end

  describe "item/3" do
    test "is an image at native size in the skin's glyph colour on its background" do
      assert {:image, 10, 20, bg, {:rgba8888, 16, 16, binary}} = Icons.item(:wifi, 10, 20)

      assert bg == Theme.bg()
      assert binary == Icons.binary(:wifi, Theme.glyph())
    end

    test "follows the active skin" do
      Skin.activate(Badge.Skin.Win95)

      assert {:image, 0, 0, bg, {:rgba8888, 16, 16, binary}} = Icons.item(:wifi, 0, 0)

      assert bg == Badge.Skin.Win95.bg()
      assert binary == Icons.binary(:wifi, Badge.Skin.Win95.glyph())
    end

    test "declared dimensions match size/1 for every icon" do
      for name <- Icons.names() do
        assert {:image, 0, 0, _bg, {:rgba8888, w, h, binary}} = Icons.item(name, 0, 0)

        assert {w, h} == Icons.size(name)
        assert byte_size(binary) == w * h * 4
      end
    end
  end

  describe "item/5" do
    test "takes an explicit tint and background" do
      assert {:image, 1, 2, 0x000080, {:rgba8888, 16, 16, binary}} =
               Icons.item(:wifi, 1, 2, @white, 0x000080)

      assert binary == Icons.binary(:wifi, @white)
    end
  end

  defp rgba(name), do: for(<<r, g, b, a <- Icons.binary(name, @white)>>, do: {r, g, b, a})
end
