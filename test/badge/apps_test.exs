defmodule Badge.AppsTest do
  use ExUnit.Case, async: true

  alias Badge.Apps

  describe "all/0" do
    test "leads with the agent" do
      assert hd(Apps.all()) == Badge.Page.Agent
    end

    test "fits the 3x2 grid" do
      assert Apps.count() <= 6
      assert Apps.count() == length(Apps.all())
    end
  end

  describe "at/1" do
    test "resolves every position in order" do
      for {module, index} <- Enum.with_index(Apps.all()) do
        assert Apps.at(index) == module
      end
    end

    test "past the end or negative is nil, not a crash" do
      assert Apps.at(Apps.count()) == nil
      assert Apps.at(-1) == nil
    end
  end

  describe "for_key/1" do
    test "the first shape key opens the first app" do
      assert Apps.for_key(:square) == hd(Apps.all())
    end

    test "follows the button order of the shape keys" do
      keys = for {key, _module} <- Badge.Pages.all(), do: key

      for {key, index} <- Enum.with_index(keys) do
        assert Apps.for_key(key) == Apps.at(index)
      end
    end

    test "escape and unknown keys open nothing" do
      assert Apps.for_key(:home) == nil
      assert Apps.for_key(:nonesuch) == nil
    end
  end

  describe "registered apps" do
    test "every app implements the whole behaviour" do
      for module <- Apps.all() do
        Code.ensure_loaded!(module)

        assert function_exported?(module, :title, 0)
        assert function_exported?(module, :init, 0)
        assert function_exported?(module, :render, 1)
        assert function_exported?(module, :handle_key, 2)
        assert function_exported?(module, :tick, 1)
      end
    end

    test "titles are short enough to fit a grid cell" do
      for module <- Apps.all() do
        assert byte_size(module.title()) <= 13
      end
    end

    test "no app traps escape or a shape key, so navigation always works" do
      for module <- Apps.all(),
          key <- [:home, :square, :triangle, :cross, :circle, :clover, :diamond] do
        Code.ensure_loaded!(module)

        assert module.handle_key({:nav, key}, module.init()) == :ignore
      end
    end
  end
end
