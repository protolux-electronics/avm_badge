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

  describe "the default IR callback" do
    test "a page that does not care ignores a frame" do
      assert Quiet.handle_ir(<<1, 2, 3, 4, 5, 6>>, "hello", Quiet.init()) == :ignore
    end

    test "a page that cares can override it" do
      assert {:ok, %{heard: {<<1, 2, 3, 4, 5, 6>>, "hello"}}} =
               Listening.handle_ir(<<1, 2, 3, 4, 5, 6>>, "hello", Listening.init())
    end
  end

  describe "the default awake? callback" do
    test "lets the screen sleep" do
      refute Quiet.awake?(Quiet.init())
    end
  end
end
