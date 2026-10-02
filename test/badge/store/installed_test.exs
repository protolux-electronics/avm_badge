defmodule Badge.Store.InstalledTest do
  use ExUnit.Case, async: true

  alias Badge.Store.Installed

  defp entry(id, overrides \\ %{}) do
    Map.merge(
      %{
        id: id,
        name: "App " <> id,
        author: "Ann",
        description: "Not stored",
        version: "1.0.0",
        size: 100,
        storage: "ram",
        api: 1,
        sha256: String.duplicate("0", 64),
        sig: "c2ln"
      },
      overrides
    )
  end

  test "nothing is installed before load" do
    assert Installed.all() == []
    assert Installed.pages() == []
    assert Installed.find("demo") == nil
  end

  test "set/1 makes apps findable by id and by page module" do
    Installed.set([entry("demo")])

    assert Installed.find("demo").name == "App demo"
    assert Installed.pages() == [Badge.App.Demo.Page]
    assert Installed.entry_for(Badge.App.Demo.Page).id == "demo"
    assert Installed.entry_for(Badge.Page.Chat) == nil
    assert Installed.name(Badge.App.Demo.Page) == "App demo"
    assert Installed.name(Badge.Page.Chat) == nil
  end

  test "add/2 replaces the same id and appends a new one" do
    list = Installed.add([entry("a"), entry("b")], entry("a", %{version: "2.0.0"}))
    assert for(e <- list, do: {e.id, e.version}) == [{"a", "2.0.0"}, {"b", "1.0.0"}]
    assert for(e <- Installed.add(list, entry("c")), do: e.id) == ["a", "b", "c"]
  end

  test "drop/2 removes one id" do
    assert for(e <- Installed.drop([entry("a"), entry("b")], "a"), do: e.id) == ["b"]
  end

  test "encode/decode keep only what a re-download needs" do
    [back] = Installed.decode(Installed.encode([entry("demo")]))

    assert back.id == "demo"
    assert back.sig == "c2ln"
    assert back.page == Badge.App.Demo.Page
    refute Map.has_key?(back, :description)
    refute Map.has_key?(back, :author)
  end

  test "twelve apps fit one NVS page" do
    long =
      entry("x", %{
        name: String.duplicate("n", 16),
        version: String.duplicate("9", 16),
        sig: String.duplicate("s", 96)
      })

    list = for n <- 1..12, do: %{long | id: "app#{n}abcdefghi"}
    assert byte_size(Installed.encode(list)) < 3_900
  end

  test "a missing or unreadable blob is no apps" do
    assert Installed.decode(nil) == []
    assert Installed.decode("garbage") == []
    assert Installed.decode(:erlang.term_to_binary(:not_a_list)) == []
  end

  test "loaded and disabled are tracked per boot" do
    refute Installed.loaded?("demo")
    Installed.mark_loaded("demo")
    assert Installed.loaded?("demo")

    refute Installed.disabled?("demo")
    Installed.disable("demo")
    assert Installed.disabled?("demo")
  end

  test "route/1 opens pages, fetches unloaded apps and refuses disabled ones" do
    Installed.set([entry("demo")])

    assert Installed.route(Badge.Page.Chat) == Badge.Page.Chat
    assert Installed.route(Badge.App.Demo.Page) == {:fetch, "demo"}

    Installed.mark_loaded("demo")
    assert Installed.route(Badge.App.Demo.Page) == Badge.App.Demo.Page

    Installed.disable("demo")
    assert Installed.route(Badge.App.Demo.Page) == :disabled
  end
end
