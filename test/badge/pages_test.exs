defmodule Badge.PagesTest do
  use ExUnit.Case, async: true

  alias Badge.Pages

  @keys [:square, :triangle, :cross, :circle, :clover, :diamond]

  defp assigned, do: for(module <- Pages.all(), module != nil, do: module)

  describe "keys/0" do
    test "is the six shape keys in button order" do
      assert Pages.keys() == @keys
    end
  end

  describe "screens/0" do
    test "is however many sixes the list needs" do
      assert Pages.screens() == div(length(Pages.all()) + 5, 6)
      assert Pages.screens() >= 2
    end
  end

  describe "screen/1" do
    test "every screen has one slot per key, in button order" do
      for n <- 0..(Pages.screens() - 1) do
        assert for({key, _module} <- Pages.screen(n), do: key) == @keys
      end
    end

    test "the screens walk the list in order and pad the last with nil" do
      modules = for n <- 0..(Pages.screens() - 1), {_key, module} <- Pages.screen(n), do: module

      assert Enum.take(modules, length(Pages.all())) == Pages.all()
      assert Enum.drop(modules, length(Pages.all())) |> Enum.all?(&is_nil/1)
    end

    test "a screen past the end is all empty" do
      assert Pages.screen(Pages.screens()) == for(key <- @keys, do: {key, nil})
    end
  end

  describe "for_key/1" do
    test "resolves the first screen, which is what the router opens from anywhere" do
      for {key, module} <- Pages.screen(0) do
        assert Pages.for_key(key, 0) == module
      end
    end

    test "an unknown key is nil" do
      assert Pages.for_key(:nonesuch, 0) == nil
      assert Pages.for_key(:home, 0) == nil
    end
  end

  describe "for_key/2" do
    test "resolves every slot of every screen" do
      for n <- 0..(Pages.screens() - 1), {key, module} <- Pages.screen(n) do
        assert Pages.for_key(key, n) == module
      end
    end

    test "the first screen is what an attendee reaches for" do
      assert for({_key, module} <- Pages.screen(0), do: module) == [
               Badge.Page.Name,
               Badge.Page.Share,
               Badge.Page.Chat,
               Badge.Page.Schedule,
               Badge.Page.About,
               Badge.Page.Settings
             ]
    end

    test "the rest sit on the second screen" do
      assert for({_key, module} <- Pages.screen(1), do: module) == [
               Badge.Page.Led,
               Badge.Page.Sensors,
               Badge.Page.Agent,
               Badge.Page.Cluster,
               Badge.Page.ConnectFour,
               nil
             ]
    end

    test "the text page is kept but unreachable, an example rather than a page" do
      Code.ensure_loaded!(Badge.Page.Text)

      assert function_exported?(Badge.Page.Text, :render, 1)
      refute :lists.member(Badge.Page.Text, Pages.all())
    end

    test "an empty slot is nil, not a crash" do
      assert Pages.for_key(:diamond, 1) == nil
      assert Pages.for_key(:square, 99) == nil
    end
  end

  describe "registered pages" do
    test "every module implements the whole behaviour" do
      for module <- assigned() do
        # function_exported?/3 only sees loaded modules.
        Code.ensure_loaded!(module)

        assert function_exported?(module, :title, 0)
        assert function_exported?(module, :init, 0)
        assert function_exported?(module, :render, 1)
        assert function_exported?(module, :handle_key, 2)
        assert function_exported?(module, :tick, 1)
      end
    end

    test "titles are short enough to fit a grid cell" do
      for module <- assigned() do
        assert byte_size(module.title()) <= 13
      end
    end

    test "no page traps escape, so the home grid is always reachable" do
      for module <- assigned() do
        Code.ensure_loaded!(module)

        assert module.handle_key({:nav, :home}, module.init()) == :ignore
      end
    end

    # Connect Four is the one deliberate exception: a shape key doubles as a
    # column drop mid-game, and mid-pairing it would otherwise bounce the
    # player to whatever app that key opens instead of just doing nothing.
    test "no page traps a shape key, since the router only sees what a page ignores" do
      for module <- assigned() -- [Badge.Page.ConnectFour], key <- @keys do
        assert module.handle_key({:nav, key}, module.init()) == :ignore
      end
    end

    test "home itself does not trap escape either" do
      assert Badge.Page.Home.handle_key({:nav, :home}, Badge.Page.Home.init()) == :ignore
    end
  end
end
