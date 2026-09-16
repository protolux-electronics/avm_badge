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

  describe "registered apps" do
    test "every app implements the whole behaviour" do
      for module <- Apps.all() do
        Code.ensure_loaded!(module)

        assert function_exported?(module, :title, 0)
        assert function_exported?(module, :icon, 0)
        assert function_exported?(module, :init, 0)
        assert function_exported?(module, :render, 1)
        assert function_exported?(module, :handle_key, 2)
        assert function_exported?(module, :tick, 1)
      end
    end

    test "every icon an app asks for actually exists and is not a shape" do
      for module <- Apps.all() do
        assert module.icon() in Badge.Icons.names()
        refute module.icon() in [:square, :triangle, :cross, :circle, :clover, :diamond]
      end
    end

    test "titles are short enough to fit a grid cell" do
      for module <- Apps.all() do
        assert byte_size(module.title()) <= 13
      end
    end

    test "no app traps escape, so the home grid is always reachable" do
      for module <- Apps.all() do
        Code.ensure_loaded!(module)

        assert module.handle_key({:nav, :home}, module.init()) == :ignore
      end
    end
  end
end
