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
end

defmodule Badge.UI.GameLinkTest do
  use ExUnit.Case, async: false

  alias Badge.Page.Home

  # Records every link event to the test process held as its state; "boom" raises.
  defmodule Player do
    use Badge.Page

    @impl true
    def title, do: "Player"

    @impl true
    def init, do: nil

    @impl true
    def render(_state), do: []

    @impl true
    def handle_link({:message, _from, "boom"}, _owner), do: raise("boom")

    def handle_link(event, owner) do
      send(owner, {:link, event})
      {:ok, owner}
    end

    @impl true
    def leave(owner) do
      send(owner, :left)
      :ok
    end
  end

  defmodule Other do
    use Badge.Page

    @impl true
    def title, do: "Other"

    @impl true
    def init, do: nil

    @impl true
    def render(_state), do: []
  end

  setup do
    Process.register(self(), Badge.GameLink)
    :erlang.put(:game_link_generation, 0)
    :ok
  end

  defp ui(page) do
    %{page: page, page_state: self(), dirty: false, countdown: 0, idle: 0}
  end

  defp batch(generation, events), do: {:game_link, generation, events}

  # Everything in the mailbox, oldest first, without waiting.
  defp drain(acc \\ []) do
    receive do
      message -> drain([message | acc])
    after
      0 -> :lists.reverse(acc)
    end
  end

  # A process cannot trace itself, so `fun` runs as the UI in a traced helper.
  defp traced(generation, fun) do
    parent = self()

    helper =
      spawn_link(fn ->
        :erlang.put(:game_link_generation, generation)

        receive do
          :go -> Kernel.send(parent, {:done, self(), fun.()})
        end
      end)

    :erlang.trace(helper, true, [:call])
    Kernel.send(helper, :go)

    receive do
      {:done, ^helper, result} ->
        reference = :erlang.trace_delivered(helper)

        receive do
          {:trace_delivered, ^helper, ^reference} -> result
        end
    end
  end

  describe "a batch" do
    test "of the current generation is offered event by event, oldest first, then taken" do
      events = [{:session, 0, [{0, "Ada"}, {1, "Bob"}]}, {:message, 1, <<7>>}, {:left, 1, :bye}]

      assert {:noreply, %{page: Player}} = Badge.UI.handle_info(batch(0, events), ui(Player))

      assert drain() == [
               {:link, {:session, 0, [{0, "Ada"}, {1, "Bob"}]}},
               {:link, {:message, 1, <<7>>}},
               {:link, {:left, 1, :bye}},
               {:"$gen_cast", :link_taken}
             ]
    end

    test "of an older generation reaches no page, and is still taken" do
      :erlang.put(:game_link_generation, 1)

      assert {:noreply, %{page: Player}} =
               Badge.UI.handle_info(batch(0, [{:message, 1, <<7>>}]), ui(Player))

      assert drain() == [{:"$gen_cast", :link_taken}]
    end

    test "is taken even when the page ignores every event" do
      assert {:noreply, %{page: Other}} =
               Badge.UI.handle_info(batch(0, [{:message, 1, <<7>>}]), ui(Other))

      assert drain() == [{:"$gen_cast", :link_taken}]
    end

    test "stops at a crash: Home is offered none of the rest, and the batch is taken once" do
      Code.ensure_loaded!(Home)
      :erlang.trace_pattern({Home, :handle_link, 2}, true, [:global])

      on_exit(fn -> :erlang.trace_pattern({Home, :handle_link, 2}, false, [:global]) end)

      events = [{:joined, 1, "Bob"}, {:message, 1, "boom"}, {:left, 1, :bye}]
      start = ui(Player)

      {next, generation} =
        traced(0, fn ->
          {:noreply, next} = Badge.UI.handle_info(batch(0, events), start)
          {next, :erlang.get(:game_link_generation)}
        end)

      assert next.page == Home
      assert generation == 1

      assert drain() == [
               {:link, {:joined, 1, "Bob"}},
               :left,
               {:"$gen_cast", :release},
               {:"$gen_cast", :link_taken}
             ]

      # The trace does fire for Home once a batch of its own generation arrives.
      traced(1, fn -> Badge.UI.handle_info(batch(1, [{:closed, :reset}]), next) end)

      assert_received {:trace, _, :call, {Home, :handle_link, [{:closed, :reset}, _]}}
      assert_received {:"$gen_cast", :link_taken}
    end

    test "whose events are not a list is dropped, leaving the UI alive" do
      assert {:noreply, %{page: Player}} =
               Badge.UI.handle_info({:game_link, 0, :x}, ui(Player))

      refute {:"$gen_cast", :link_taken} in drain()
    end
  end

  describe "a GameLink restart" do
    test "offers {:closed, :reset} to the page on screen and takes nothing" do
      assert {:noreply, %{page: Player}} = Badge.UI.handle_info({:game_link, :reset}, ui(Player))

      assert drain() == [{:link, {:closed, :reset}}]
    end
  end

  describe "the generation" do
    test "moves on with a page change, after the old page left, and releases the session" do
      {:noreply, next} = Badge.UI.handle_cast({:goto, Other}, ui(Player))

      assert next.page == Other
      assert :erlang.get(:game_link_generation) == 1
      assert drain() == [:left, {:"$gen_cast", :release}]
    end

    test "stays put when the page on screen is opened again" do
      {:noreply, next} = Badge.UI.handle_cast({:goto, Player}, ui(Player))

      assert next.page == Player
      assert :erlang.get(:game_link_generation) == 0
      assert drain() == []
    end
  end
end
