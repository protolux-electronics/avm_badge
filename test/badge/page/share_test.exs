defmodule Badge.Page.ShareTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Share, as: Page
  alias Badge.Profile
  alias Badge.Theme

  @me <<0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6>>
  @other <<0, 0, 0, 0, 0, 1>>

  # A page after its first tick, without touching NVS.
  defp loaded(overrides \\ %{name: "Gus"}, shared \\ [:name]) do
    profile = Map.merge(Profile.blank(), overrides)

    Page.recycle(%{
      Page.init()
      | loaded: true,
        profile: profile,
        shared: shared,
        saved_shared: shared,
        id: @me,
        chip: "A1B2C3D4E5F6"
    })
  end

  defp on(state, screen), do: %{state | screen: screen}

  defp press(state, event) do
    {:ok, next} = Page.handle_key(event, state)
    next
  end

  defp press(state, _event, 0), do: state
  defp press(state, event, n), do: press(press(state, event), event, n - 1)

  defp texts(state), do: for({:text, _x, _y, _f, _c, _b, body} <- Page.render(state), do: body)

  defp colour_of(state, text) do
    [c] =
      for {:text, _x, _y, _f, c, _b, body} <- Page.render(state),
          :binary.match(body, text) != :nomatch,
          do: c

    c
  end

  defp says?(state, text), do: Enum.any?(texts(state), &(:binary.match(&1, text) != :nomatch))

  describe "identity" do
    test "announces itself for the home grid" do
      assert Page.title() == "Share"
      assert Page.icon() == :triangle
    end

    test "does not trap escape" do
      assert Page.handle_key({:nav, :home}, loaded()) == :ignore
    end
  end

  describe "paging" do
    test "right and left page through three screens, and wrap" do
      assert Page.screens() == 3
      assert press(loaded(), {:move, :right}).screen == 1
      assert press(loaded(), {:move, :right}, 3).screen == 0
      assert press(loaded(), {:move, :left}).screen == 2
    end

    test "each screen shows which one it is" do
      for screen <- 0..2 do
        dots = for {:rect, _x, 228, 6, 6, colour} <- Page.render(on(loaded(), screen)), do: colour

        assert length(dots) == 3
        assert Enum.count(dots, &(&1 == Theme.fg())) == 1
      end
    end
  end

  describe "the share screen" do
    test "shows two badges meeting, whatever else it has to say" do
      for state <- [Page.init(), loaded(), loaded(%{})] do
        assert Enum.any?(
                 Page.render(state),
                 &match?({:image, 124, 92, _bg, {:rgba8888, 72, 32, _pixels}}, &1)
               )
      end
    end

    test "shows this badge's own chip id and says what to do" do
      assert "A1B2C3D4E5F6" in texts(loaded())
      assert says?(loaded(), "hold another badge")
    end

    test "warns, and has nothing to beam, when the profile has no name" do
      state = loaded(%{})

      assert state.cycle == []
      assert colour_of(state, "Set your name first") == Theme.alert()
      refute "A1B2C3D4E5F6" in texts(state)
    end

    test "says nothing until the stores have been read" do
      refute says?(Page.init(), "Set your name")
    end

    test "a new badge reads as saved, in the good colour" do
      state = %{loaded() | met: {"Pat", :new}}

      assert "Pat" in texts(state)
      assert colour_of(state, "added to your badges") == Theme.ok()
    end

    test "a badge already collected says so, in its own colour" do
      state = %{loaded() | met: {"Pat", :known}}

      assert colour_of(state, "already in your badges") == Theme.select()
    end

    test "a badge that changed what it shares is distinct from both" do
      assert colour_of(%{loaded() | met: {"Pat", :updated}}, "updated") == Theme.warn()
    end

    test "counts what has been collected" do
      one = %{loaded() | peers: [%{id: @other, profile: %{name: "Pat"}}]}

      assert says?(loaded(), "0 badges collected")
      assert says?(one, "1 badge collected")
    end

    test "ticks at the beam cadence only while there is something to beam" do
      assert Page.beam_ms() == 200
      assert Page.refresh(loaded()) == Page.beam_ms()
      assert Page.refresh(loaded(%{})) == 333
      assert Page.refresh(on(loaded(), 1)) == 333
    end
  end

  describe "ticking" do
    test "a loaded page ticks to a map render can use" do
      ticked = Page.tick(loaded())

      assert is_map(ticked)
      assert is_list(Page.render(ticked))
    end
  end
end
