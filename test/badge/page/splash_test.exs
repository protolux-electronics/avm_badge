defmodule Badge.Page.SplashTest do
  use ExUnit.Case, async: true

  alias Badge.Logo
  alias Badge.Page.Home
  alias Badge.Page.Splash
  alias Badge.Theme

  @seed 12_345

  defp pieces(items) do
    for {:scaled_cropped_image, x, y, w, h, _bg, cx, cy, 1, 1, [], _img} <- items,
        do: {x, y, w, h, cx, cy}
  end

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

    test "holding shows the whole logo and nothing else but the bar cover" do
      assert [{:rect, 0, 0, _w, _h, _bg}, {:image, _x, _y, _bg2, _img}] =
               Splash.frame({:hold, 0}, @seed)
    end

    test "pieces accumulate on the way in and are all there at the end" do
      counts = for n <- 0..9, do: length(pieces(Splash.frame({:in, n}, @seed)))

      assert counts == Enum.sort(counts)
      assert List.last(counts) == length(Splash.pieces(@seed))
    end

    test "pieces drop out on the way out" do
      counts = for n <- 0..5, do: length(pieces(Splash.frame({:out, n}, @seed)))

      assert counts == Enum.sort(counts, :desc)
      assert hd(counts) < length(Splash.pieces(@seed))
    end

    test "a piece that landed two frames ago is at rest" do
      {logo_w, _} = Logo.size()
      home_x = div(Theme.width() - logo_w, 2)

      earlier =
        for {_x, _y, _w, _h, cx, cy} <- pieces(Splash.frame({:in, 7}, @seed)), do: {cx, cy}

      rested =
        for {x, _y, _w, _h, cx, cy} <- pieces(Splash.frame({:in, 9}, @seed)),
            {cx, cy} in earlier,
            do: x - cx

      assert rested != []
      assert Enum.all?(rested, &(&1 == home_x))
    end

    test "a landing piece is jittered sideways, then still" do
      moved =
        for n <- 0..9, {x, _y, _w, _h, cx, _cy} <- pieces(Splash.frame({:in, n}, @seed)) do
          x - cx - div(Theme.width() - elem(Logo.size(), 0), 2)
        end

      assert Enum.any?(moved, &(&1 != 0))
    end

    test "pieces never leave the panel" do
      for phase <- [:in, :out], n <- 0..9 do
        for {x, y, w, h, _cx, _cy} <- pieces(Splash.frame({phase, n}, @seed)) do
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

  describe "whether a start wants the splash" do
    test "a fresh boot does" do
      assert Splash.wanted?(:esp_rst_poweron, 2_000)
    end

    test "waking from deep sleep does not" do
      refute Splash.wanted?(:esp_rst_deepsleep, 2_000)
    end

    test "a UI restart minutes into the boot does not, whatever the reset was" do
      refute Splash.wanted?(:esp_rst_poweron, 180_000)
    end
  end

  test "the bar cover sits on top of everything" do
    [{:rect, 0, 0, w, h, _bg} | _rest] = Splash.frame({:in, 3}, @seed)

    assert w == Theme.width()
    assert h > Theme.bar_h()
  end
end
