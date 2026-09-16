defmodule Badge.Page.SplashTest do
  use ExUnit.Case, async: true

  alias Badge.Logo
  alias Badge.Page.Home
  alias Badge.Page.Splash
  alias Badge.Theme

  @seed 12_345
  @image {:rgba8888, 120, 68, <<>>}

  # Pieces are cut in logo pixels and drawn at twice the size.
  defp pieces(items) do
    for {:scaled_cropped_image, x, y, w, h, _bg, cx, cy, 2, 2, [], _img} <- items,
        do: {x, y, w, h, cx, cy}
  end

  defp pieces_items(items) do
    for {:scaled_cropped_image, _x, _y, _w, _h, _bg, _cx, _cy, 2, 2, [], _img} = item <- items,
        do: item
  end

  defp home_x, do: div(Theme.width() - elem(Logo.size(), 0) * Logo.scale(), 2)

  describe "the cut" do
    test "covers the logo exactly once" do
      {logo_w, logo_h} = Logo.size()
      area = for {{_l, _t, w, h}, _i} <- Splash.pieces(@seed), do: w * h

      assert Enum.sum(area) == logo_w * logo_h
    end

    test "is numbered in arrival order without gaps" do
      indexes = for {_rect, i} <- Splash.pieces(@seed), do: i

      assert indexes == Enum.to_list(0..(length(indexes) - 1))
    end

    test "is shuffled, so neighbours do not arrive together" do
      rects = for {rect, _i} <- Splash.pieces(@seed), do: rect

      refute rects == Enum.sort(rects)
    end

    test "differs between seeds" do
      refute Splash.pieces(1) == Splash.pieces(2)
    end
  end

  describe "the sequence" do
    test "glitches in, holds, drops out, in that order" do
      assert {:in, 0} = Splash.step(0)
      assert {:hold, 0} = Splash.step(1_500)
      assert {:out, _n} = Splash.step(Splash.total_ms() - 1)
    end

    test "the hold is a single step, so nothing repaints while the logo is still" do
      assert Splash.step(1_200) == Splash.step(2_500)
    end

    test "holding shows the whole logo at twice its size and nothing else but the cover" do
      {logo_w, logo_h} = Logo.size()

      frame = Splash.frame({:hold, 0}, @seed, @image)

      assert [{x, y, w, h, 0, 0}] = pieces(frame)
      assert [{:rect, 0, 0, _w, _h, _bg}] = frame -- pieces_items(frame)

      assert {w, h} == {logo_w * 2, logo_h * 2}
      assert x == home_x()
      assert y > Theme.bar_h()
    end

    test "pieces accumulate on the way in and are all there at the end" do
      counts = for n <- 0..9, do: length(pieces(Splash.frame({:in, n}, @seed, @image)))

      assert counts == Enum.sort(counts)
      assert List.last(counts) == length(Splash.pieces(@seed))
    end

    test "pieces drop out on the way out" do
      counts = for n <- 0..5, do: length(pieces(Splash.frame({:out, n}, @seed, @image)))

      assert counts == Enum.sort(counts, :desc)
      assert hd(counts) < length(Splash.pieces(@seed))
    end

    test "a piece that landed two frames ago is at rest" do
      earlier =
        for {_x, _y, _w, _h, cx, cy} <- pieces(Splash.frame({:in, 7}, @seed, @image)), do: {cx, cy}

      rested =
        for {x, _y, _w, _h, cx, cy} <- pieces(Splash.frame({:in, 9}, @seed, @image)),
            {cx, cy} in earlier,
            do: x - cx * 2

      assert rested != []
      assert Enum.all?(rested, &(&1 == home_x()))
    end

    test "a landing piece is jittered sideways, then still" do
      moved =
        for n <- 0..9, {x, _y, _w, _h, cx, _cy} <- pieces(Splash.frame({:in, n}, @seed, @image)) do
          x - cx * 2 - home_x()
        end

      assert Enum.any?(moved, &(&1 != 0))
    end

    test "pieces never leave the panel" do
      for phase <- [:in, :out], n <- 0..9 do
        for {x, y, w, h, _cx, _cy} <- pieces(Splash.frame({phase, n}, @seed, @image)) do
          assert x >= 0 and x + w <= Theme.width()
          assert y > Theme.bar_h() and y + h <= Theme.height()
        end
      end
    end
  end

  describe "handing over" do
    test "any key ends it on the next tick" do
      {:ok, state} = Splash.handle_key({:char, ?x}, Splash.init())

      assert Splash.tick(state) == {:goto, Home}
    end

    test "it ends by itself once the sequence has run" do
      state = %{Splash.init() | started: :erlang.monotonic_time(:millisecond) - Splash.total_ms()}

      assert Splash.tick(state) == {:goto, Home}
    end

    test "the seed is positive whatever the clock says" do
      assert Splash.init().seed > 0
    end

    test "before that it keeps stepping" do
      assert %{step: {:in, 0}} = Splash.tick(Splash.init())
    end
  end

  describe "without the logo in the assets partition" do
    test "the splash is not wanted, however fresh the boot" do
      refute Splash.wanted?(:esp_rst_poweron, 2_000, nil)
      assert Splash.wanted?(:esp_rst_poweron, 2_000, @image)
    end

    test "a frame is just the cover, should the page be reached anyway" do
      assert [{:rect, 0, 0, _w, _h, _bg}] = Splash.render(%{Splash.init() | image: nil})
    end
  end

  describe "whether a start wants the splash" do
    test "a fresh boot does" do
      assert Splash.wanted?(:esp_rst_poweron, 2_000, @image)
    end

    test "waking from deep sleep does not" do
      refute Splash.wanted?(:esp_rst_deepsleep, 2_000, @image)
    end

    test "a UI restart minutes into the boot does not, whatever the reset was" do
      refute Splash.wanted?(:esp_rst_poweron, 180_000, @image)
    end
  end

  describe "the cover" do
    test "blacks out the whole panel, bar included, whatever the skin" do
      for skin <- [Badge.Skin.Dark, Badge.Skin.Win95] do
        Badge.Skin.activate(skin)

        assert {:rect, 0, 0, w, h, 0x000000} = List.last(Splash.frame({:in, 3}, @seed, @image))
        assert {w, h} == {Theme.width(), Theme.height()}
      end
    end

    test "is drawn under the pieces, which AtomGL paints tail to head" do
      frame = Splash.frame({:in, 9}, @seed, @image)

      assert pieces(frame) != []
      assert [{:rect, _x, _y, _w, _h, _bg}] = frame -- pieces_items(frame)
      assert match?({:rect, _, _, _, _, _}, List.last(frame))
    end

    test "is all there is without a logo" do
      assert [{:rect, 0, 0, _w, _h, 0x000000}] = Splash.frame({:in, 3}, @seed, nil)
    end
  end
end
