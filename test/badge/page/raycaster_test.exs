defmodule Badge.Page.RaycasterTest do
  # A fake keyboard is registered under the real one's name, so these cannot run side by side.
  use ExUnit.Case, async: false

  alias Badge.Page.Raycaster, as: Page
  alias Badge.Theme
  alias Raycaster.Engine
  alias Raycaster.Goat

  defmodule FakeKeyboard do
    @moduledoc false
    use GenServer

    def start_link(held), do: GenServer.start_link(__MODULE__, held, name: Badge.Keyboard)

    @impl true
    def init(held), do: {:ok, held}

    @impl true
    def handle_call(:held, _from, held), do: {:reply, held, held}
  end

  defp keyboard(held), do: start_supervised!({FakeKeyboard, held})

  defp now, do: :erlang.monotonic_time(:millisecond)

  # The goat put where we want it, wandering, and the player standing still at the start.
  defp with_goat(state, {x, y}), do: %{state | goat: %{state.goat | x: x, y: y}}

  describe "identity" do
    test "names itself for the home grid" do
      assert Page.title() == "Goat game"
      assert Page.icon() in Badge.Icons.names()
    end

    test "asks for the shortest gap the ticker offers" do
      assert Page.refresh(Page.init()) == 100
    end

    test "starts at the start, safe for a few seconds, with the goat in the far corner" do
      state = Page.init()

      assert state.player == Engine.new()
      assert state.caught == nil
      assert state.safe_until > now()
      assert {x, y, false} = Goat.where(state.goat)
      assert {div(x, 256), div(y, 256)} == {14, 14}
    end
  end

  describe "the keys the engine reads" do
    # The firmware's labels are charlists, and the engine has to know them.
    test "every direction moves or turns the player" do
      grid = Engine.grid()
      start = %{x: 11 * 256 + 128, y: 9 * 256 + 128, a: 0}

      for label <- [
            ~c"Up",
            ~c"W",
            ~c"Down",
            ~c"S",
            ~c"Q",
            ~c"E",
            ~c"Left",
            ~c"A",
            ~c"Right",
            ~c"D"
          ] do
        refute Engine.step(grid, start, [label], 200) == start
      end
    end

    test "keys with no meaning here change nothing" do
      grid = Engine.grid()
      start = %{x: 11 * 256 + 128, y: 9 * 256 + 128, a: 0}

      assert Engine.step(grid, start, [~c"Space", ~c"Ctrl", ~c"1"], 200) == start
    end
  end

  describe "render/1" do
    test "has no chrome, so the UI adds no title bar" do
      refute Page.chrome?(Page.init())
    end

    test "stays on the panel" do
      items = Page.render(Page.init())

      assert length(items) > 1

      for {:rect, x, y, w, h, _colour} <- items do
        assert x >= 0 and x + w <= Theme.width()
        assert y >= 0 and y + h <= Theme.height()
      end
    end

    test "paints the whole panel itself, as nothing is drawn behind a fullscreen page" do
      items = Page.render(Page.init())
      rects = for {:rect, 0, y, w, h, _} <- items, w == Theme.width(), do: {y, h}

      # Only the floor and ceiling bands span the panel, and together they fill it from the top.
      assert length(rects) >= 2
      assert rects |> Enum.map(fn {_y, h} -> h end) |> Enum.sum() == Theme.height()
      assert Enum.any?(rects, fn {y, _h} -> y == 0 end)
    end

    test "says how long this life has lasted" do
      assert Enum.any?(
               Page.render(Page.init()),
               &match?({:text, _, _, _, _, _, "alive 0 s"}, &1)
             )
    end

    test "the goat is drawn when it is in view, and is not when it is behind a wall" do
      # The start faces east along row 1, so a goat four cells ahead is in view.
      state = Page.init()
      far = Page.render(with_goat(state, {14 * 256 + 128, 14 * 256 + 128}))
      near = Page.render(with_goat(state, {384 + 4 * 256, 384}))

      assert length(near) >= length(far) + 5
    end

    test "being caught shows the game over screen, covering the panel" do
      items = Page.render(%{Page.init() | caught: {now(), 12}})

      assert Enum.any?(items, &match?({:text, _, _, _, _, _, "GAME OVER"}, &1))

      assert Enum.any?(items, &match?({:rect, 0, 0, w, h, _} when w == 320 and h == 240, &1))
    end
  end

  describe "the goat" do
    test "moves on every tick, by the time since the last" do
      keyboard([])
      state = Page.init()
      before = Goat.where(state.goat)

      moved = state |> Map.put(:goat_at, now() - 200) |> Page.tick()
      assert Goat.where(moved.goat) != before
    end

    test "catches a player it is next to, and the life is over" do
      keyboard([])
      state = %{Page.init() | safe_until: now() - 1, born: now() - 7_000}
      state = with_goat(state, {384 + 60, 384})

      caught = Page.tick(state)
      assert {_when, 7} = caught.caught
    end

    test "does not catch a player who is safe, though it is on top of them" do
      keyboard([])
      state = Page.init()
      assert state.safe_until > now()

      assert Page.tick(with_goat(state, {384 + 60, 384})).caught == nil
    end

    test "a catch turns the LEDs steady red, once" do
      keyboard([])
      state = %{Page.init() | safe_until: now() - 1} |> with_goat({384 + 60, 384})

      lit = Page.tick(state)
      assert %{dread: :caught} = lit
      # The level did not change, so the LEDs are not told again.
      assert Page.tick(lit).dread == :caught
    end

    test "a goat far off leaves the LEDs alone" do
      keyboard([])
      assert Page.tick(Page.init()).dread == 0
    end
  end

  describe "after a catch" do
    defp caught_state(ago) do
      state = Page.init()
      %{state | caught: {now() - ago, 9}, player: %{x: 700, y: 700, a: 1}}
    end

    test "the game over screen outlasts a key still held" do
      keyboard([~c"Up"])
      state = caught_state(200)

      assert Page.tick(state).caught == state.caught
    end

    test "without a key held it stays up, however long" do
      keyboard([])
      state = caught_state(60_000)

      assert Page.tick(state).caught == state.caught
    end

    test "a key pressed after it has been up a while brings the player back, safe and away from the goat" do
      keyboard([~c"Up"])
      state = caught_state(5_000)

      back = Page.tick(state)
      assert back.caught == nil
      assert back.player == Engine.respawn(Goat.where(state.goat))
      assert back.safe_until > now()
      assert back.born >= now() - 100
    end
  end

  test "a message it does not know is ignored" do
    assert Page.handle_info(:nonsense, Page.init()) == :ignore
  end

  test "handle_key ignores everything, so Esc goes home" do
    for event <- [{:move, :up}, {:char, ?w}, {:nav, :home}] do
      assert Page.handle_key(event, Page.init()) == :ignore
    end
  end

  describe "changed?/2" do
    test "a goat that moves far from the player does not repaint the picture" do
      old = Page.init() |> with_goat({14 * 256, 14 * 256})
      new = with_goat(old, {14 * 256 - 20, 14 * 256})

      refute Page.changed?(old, new)
    end

    test "a goat that moves near the player does" do
      old = Page.init() |> with_goat({3 * 256, 3 * 256})
      new = with_goat(old, {3 * 256 + 20, 3 * 256})

      assert Page.changed?(old, new)
    end

    test "a goat that walks out of range does, so it is erased" do
      old = Page.init() |> with_goat({11 * 256 + 90, 384})
      new = with_goat(old, {11 * 256 + 200, 384})

      assert Page.changed?(old, new)
    end

    test "the player moving, the seconds counting and a catch do" do
      old = Page.init() |> with_goat({14 * 256, 14 * 256})

      assert Page.changed?(old, %{old | player: %{old.player | a: 100}})
      assert Page.changed?(old, %{old | secs: 1})
      assert Page.changed?(old, %{old | caught: {0, 3}})
    end
  end
end
