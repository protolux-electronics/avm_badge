defmodule Badge.PageTest do
  use ExUnit.Case, async: true

  defmodule Quiet do
    use Badge.Page

    @impl true
    def title, do: "Quiet"

    @impl true
    def init, do: %{}

    @impl true
    def render(_state), do: []
  end

  defmodule Listening do
    use Badge.Page

    @impl true
    def title, do: "Listening"

    @impl true
    def init, do: %{heard: nil}

    @impl true
    def render(_state), do: []

    @impl true
    def handle_ir(from, payload, state), do: {:ok, %{state | heard: {from, payload}}}
  end

  defmodule Playing do
    use Badge.Page

    @impl true
    def title, do: "Playing"

    @impl true
    def init, do: %{events: []}

    @impl true
    def render(_state), do: []

    @impl true
    def handle_link(event, state), do: {:ok, %{state | events: [event | state.events]}}
  end

  describe "the default IR callback" do
    test "a page that does not care ignores a frame" do
      assert Quiet.handle_ir(<<1, 2, 3, 4, 5, 6>>, "hello", Quiet.init()) == :ignore
    end

    test "a page that cares can override it" do
      assert {:ok, %{heard: {<<1, 2, 3, 4, 5, 6>>, "hello"}}} =
               Listening.handle_ir(<<1, 2, 3, 4, 5, 6>>, "hello", Listening.init())
    end
  end

  describe "the default link callback" do
    test "a page that does not play ignores every GameLink event" do
      assert Quiet.handle_link({:message, 1, <<1, 2>>}, Quiet.init()) == :ignore
      assert Quiet.handle_link({:closed, :reset}, Quiet.init()) == :ignore
    end

    test "is exported, so Badge.UI can offer events to any page" do
      assert function_exported?(Quiet, :handle_link, 2)
    end

    test "a page that plays can override it" do
      assert {:ok, %{events: [{:joined, 1, "Ada"}]}} =
               Playing.handle_link({:joined, 1, "Ada"}, Playing.init())
    end
  end
end
