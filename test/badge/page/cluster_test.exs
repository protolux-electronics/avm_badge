defmodule Badge.Page.ClusterTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Cluster
  alias Badge.Theme

  defp status(overrides) do
    base = %{
      state: :off,
      node: nil,
      cookie: "goat-5a1d0c3e7b29",
      ip: nil,
      peers: [],
      reason: nil
    }

    Map.merge(base, overrides)
  end

  defp page(overrides), do: %{Cluster.init() | status: status(overrides)}

  defp up(overrides \\ %{}) do
    page(Map.merge(%{state: :up, node: "badge@192.168.1.42", ip: "192.168.1.42"}, overrides))
  end

  defp bodies(state) do
    for {:text, _x, _y, _f, _c, _b, body} <- Cluster.render(state), do: body
  end

  defp says?(state, text) do
    :lists.any(fn body -> :binary.match(body, text) != :nomatch end, bodies(state))
  end

  describe "identity" do
    test "names itself for the home grid" do
      assert Cluster.title() == "Cluster"
    end

    test "starts with nothing known, so the first tick fills it in" do
      assert Cluster.init().status == nil
    end

    test "renders before the first tick rather than crashing" do
      assert says?(Cluster.init(), "down")
    end
  end

  describe "state" do
    test "says the node is down before it is joined" do
      assert says?(page(%{}), "down")
    end

    test "says what wifi is doing while it waits" do
      state = page(%{state: :waiting, reason: "wifi connecting"})

      assert says?(state, "wifi connecting")
    end

    test "says the node is up once it is named" do
      assert says?(up(), "up")
    end

    test "shows a failure reason" do
      state = page(%{state: :failed, reason: "eaddrinuse"})

      assert says?(state, "eaddrinuse")
    end
  end

  describe "the node" do
    test "shows the name a host has to connect to" do
      assert says?(up(), "badge@192.168.1.42")
    end

    test "shows the cookie, since a host cannot guess it" do
      assert says?(up(), "goat-5a1d0c3e7b29")
    end

    test "shows the cookie while down too, so it can be read before joining" do
      assert says?(page(%{}), "goat-5a1d0c3e7b29")
    end

    test "has no name to show while the node is down" do
      refute says?(page(%{}), "badge@")
    end

    test "clips a name too long for the panel" do
      state = up(%{node: :binary.copy("x", 60)})

      assert :lists.all(fn body -> byte_size(body) <= 30 end, bodies(state))
    end
  end

  describe "peers" do
    test "says so when nobody has reached the badge yet" do
      assert says?(up(), "nobody yet")
    end

    test "counts and names the hosts that said hello" do
      state = up(%{peers: ["host@192.168.1.222"]})

      assert says?(state, "1")
      assert says?(state, "host@192.168.1.222")
    end

    test "names only as many peers as the panel has room for" do
      peers = for n <- 1..9, do: "host#{n}@192.168.1.1"

      state = up(%{peers: peers})

      assert says?(state, "9")
      assert says?(state, "host4@192.168.1.1")
      refute says?(state, "host5@192.168.1.1")
    end
  end

  describe "keys" do
    test "S joins while the node is down" do
      assert {:ok, _state} = Cluster.handle_key({:char, ?s}, page(%{}))
    end

    test "S leaves while the node is up" do
      assert {:ok, _state} = Cluster.handle_key({:char, ?s}, up())
    end

    test "takes a capital S too" do
      assert {:ok, _state} = Cluster.handle_key({:char, ?S}, page(%{}))
    end

    test "offers to start while down and to stop while up" do
      assert says?(page(%{}), "S start")
      assert says?(up(), "S stop")
    end

    test "ignores everything else, so the arrows still navigate" do
      assert Cluster.handle_key({:move, :up}, up()) == :ignore
      assert Cluster.handle_key({:char, ?a}, up()) == :ignore
    end
  end

  describe "editing the cookie" do
    defp editing(overrides \\ %{}) do
      {:ok, state} = Cluster.handle_key({:edit, :newline}, page(overrides))

      state
    end

    defp typed(state, text) do
      :lists.foldl(
        fn char, acc ->
          {:ok, next} = Cluster.handle_key({:char, char}, acc)
          next
        end,
        state,
        :erlang.binary_to_list(text)
      )
    end

    test "Enter opens the stored cookie for editing" do
      assert says?(editing(), "goat-5a1d0c3e7b29_")
    end

    test "typing changes it, and an S types rather than stopping the cluster" do
      assert says?(typed(editing(), "S"), "goat-5a1d0c3e7b29S_")
    end

    test "backspace removes the character before the caret" do
      {:ok, state} = Cluster.handle_key({:edit, :backspace}, editing())

      assert says?(state, "goat-5a1d0c3e7b2_")
    end

    test "Esc closes the field and leaves the stored cookie showing" do
      {:ok, state} = Cluster.handle_key({:nav, :home}, typed(editing(), "X"))

      assert state.field == nil
      assert says?(state, "goat-5a1d0c3e7b29")
    end

    test "Enter commits and closes the field" do
      {:ok, state} = Cluster.handle_key({:edit, :newline}, editing())

      assert state.field == nil
    end

    test "swallows the arrows, so half a cookie is never navigated away from" do
      assert {:ok, _state} = Cluster.handle_key({:move, :up}, editing())
    end

    test "says how to save, and that clearing it resets" do
      assert says?(editing(), "Enter save")
      assert says?(editing(), "empty resets")
    end

    test "stops accepting once the cookie has filled the field" do
      long = typed(editing(), :binary.copy("x", 60))

      assert says?(long, "goat-5a1d0c3e7b29" <> :binary.copy("x", 7) <> "_")
    end

    test "keeps every row inside the panel while typing" do
      long = typed(editing(), :binary.copy("x", 60))

      assert :lists.all(fn body -> byte_size(body) <= 39 end, bodies(long))
    end
  end

  describe "chrome" do
    test "draws nothing above the content top" do
      for {:text, _x, y, _f, _c, _b, _body} <- Cluster.render(up()) do
        assert y >= Theme.content_top()
      end
    end
  end
end
