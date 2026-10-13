defmodule Badge.UITest do
  use ExUnit.Case, async: true

  alias Badge.Page.Home
  alias Badge.Page.Name
  alias Badge.Pages

  # The router's rule, as the UI applies it: a page sees every shape key first,
  # and only what it ignores can reach the router.
  defp route(page, event) do
    case page.handle_key(event, page.init()) do
      {:ok, _state} -> :page
      :ignore -> :router
    end
  end

  describe "shape keys" do
    test "belong to the page on screen, wherever it is" do
      for {key, module} <- Pages.screen(0), module != nil do
        assert route(Name, {:nav, key}) == :router
        assert route(module, {:nav, key}) in [:page, :router]
      end
    end

    test "the home grid takes them, so the grid alone opens pages" do
      for {key, module} <- Pages.screen(0), module != nil do
        assert route(Home, {:nav, key}) == :page
      end
    end

    test "there is no longer a page a key opens from anywhere" do
      Code.ensure_loaded!(Pages)

      refute function_exported?(Pages, :for_key, 1)
      assert function_exported?(Pages, :for_key, 2)
    end
  end

  describe "escape" do
    test "is offered to the page first, and pages consume it for their own back" do
      editing = %{Name.init() | mode: :fields}

      assert {:ok, %{mode: :show}} = Name.handle_key({:nav, :home}, editing)
    end

    test "falls through to the router when the page has no use for it" do
      assert route(Name, {:nav, :home}) == :router
    end
  end

  describe "a key's frame" do
    test "goes out once the panel has had time to finish the last one" do
      assert Badge.UI.key_due?(1_000, 1_035)
      assert Badge.UI.key_due?(1_000, 2_000)
    end

    test "waits for the tick when it would land on the frame before it" do
      refute Badge.UI.key_due?(1_000, 1_000)
      refute Badge.UI.key_due?(1_000, 1_034)
    end
  end

  defmodule Moving do
    @moduledoc false
    use Badge.Page

    def title, do: "Moving"
    def init, do: %{shown: 0, hidden: 0}
    def render(_state), do: []
    def changed?(old, new), do: old.shown != new.shown
  end

  describe "a tick" do
    defp ui(dirty, page), do: %{dirty: dirty, status: :same, page: page, page_state: page.init()}

    test "that only changes what the page says is not drawn does not dirty the screen" do
      state = ui(false, Moving)

      refute Badge.UI.dirty_after_tick?(state, %{state.page_state | hidden: 1}, :same)
    end

    test "that changes what is drawn does" do
      state = ui(false, Moving)

      assert Badge.UI.dirty_after_tick?(state, %{state.page_state | shown: 1}, :same)
    end

    test "is drawn if the screen was already dirty or the status changed" do
      state = ui(true, Moving)
      assert Badge.UI.dirty_after_tick?(state, state.page_state, :same)

      state = ui(false, Moving)
      assert Badge.UI.dirty_after_tick?(state, state.page_state, :other)
    end

    test "on a page without changed? is dirty when the state differs at all" do
      state = ui(false, Badge.Page.Name)

      refute Badge.UI.dirty_after_tick?(state, state.page_state, :same)
      assert Badge.UI.dirty_after_tick?(state, %{state.page_state | mode: :fields}, :same)
    end
  end
end
