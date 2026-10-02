defmodule Badge.Page.StoreTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Store, as: Page
  alias Badge.Store
  alias Badge.Store.Installed

  defp entry(id, overrides \\ %{}) do
    Map.merge(
      %{
        id: id,
        name: String.capitalize(id),
        author: "Ann",
        description: "A demo app",
        version: "1.0.0",
        size: 15_000,
        storage: "ram",
        api: Store.api(),
        sha256: String.duplicate("0", 64),
        sig: ""
      },
      overrides
    )
  end

  defp ready(entries), do: Page.finished(%{Page.init() | want: nil}, {:manifest, {:ok, entries}})

  defp texts(state), do: for({:text, _x, _y, _f, _c, _b, text} <- Page.render(state), do: text)

  defp key(state, event) do
    {:ok, state} = Page.handle_key(event, state)
    state
  end

  test "is called Store and leaves Esc and shape keys to the router" do
    assert Page.title() == "Store"
    assert Page.handle_key({:nav, :home}, Page.init()) == :ignore
    assert Page.handle_key({:nav, :square}, Page.init()) == :ignore
  end

  test "asks for the manifest on entry" do
    assert Page.init().want == :manifest
    assert "Loading..." in texts(%{Page.init() | want: nil})
  end

  test "lists each app with its size, and the free budget" do
    shown = texts(ready([entry("demo")]))
    assert "Demo" in shown
    assert "15K" in shown
    assert "RAM 256K free" in shown
  end

  test "marks installed apps and available updates" do
    Installed.set([entry("demo"), entry("old")])
    state = ready([entry("demo"), entry("old", %{version: "2.0.0"})])

    assert Page.mark(entry("demo")) == "installed"
    assert Page.mark(entry("old", %{version: "2.0.0"})) == "update"
    assert "update" in texts(state)
  end

  test "an app for newer firmware says so" do
    assert Page.mark(entry("demo", %{api: Store.api() + 1})) == "newer fw"
  end

  test "Enter opens the details, Enter again asks to install" do
    state = key(ready([entry("demo")]), {:edit, :newline})
    assert state.view == :detail
    assert "A demo app" in texts(state)
    assert "Needs 15K, 256K free" in texts(state)

    state = key(state, {:edit, :newline})
    assert state.want == {:pack, entry("demo")}
  end

  test "Enter on an update records it; r removes" do
    Installed.set([entry("demo")])
    state = key(ready([entry("demo", %{version: "2.0.0"})]), {:edit, :newline})

    assert key(state, {:edit, :newline}).want == {:update, entry("demo", %{version: "2.0.0"})}
    assert key(state, {:char, ?r}).want == {:remove, "demo"}
  end

  test "Esc in the details goes back to the list" do
    state = key(ready([entry("demo")]), {:edit, :newline})
    assert key(state, {:nav, :home}).view == :list
  end

  test "a delisted installed app is still listed and can be removed" do
    Installed.set([entry("gone")])
    state = ready([entry("demo")])

    assert for(e <- Page.rows(state), do: e.id) == ["demo", "gone"]

    state = state |> key({:move, :down}) |> key({:edit, :newline})
    assert state.entry.id == "gone"
    assert key(state, {:char, ?r}).want == {:remove, "gone"}
  end

  test "back in the list after a removal, the cursor stays on a row" do
    Installed.set([entry("gone")])
    state = ready([entry("demo")]) |> key({:move, :down}) |> key({:edit, :newline})

    Installed.set([])
    state = key(state, {:nav, :home})

    assert state.cursor == 0
    assert key(state, {:edit, :newline}).entry.id == "demo"
  end

  describe "category filter" do
    defp shelves do
      ready([
        entry("snake", %{category: "games"}),
        entry("paint", %{category: "art"}),
        entry("pong", %{category: "games"})
      ])
    end

    test "starts on All, with every app" do
      state = shelves()
      assert "< All >" in texts(state)
      assert for(e <- Page.rows(state), do: e.id) == ["snake", "paint", "pong"]
    end

    test "right steps through the categories in manifest order, and wraps" do
      state = key(shelves(), {:move, :right})
      assert "< Games >" in texts(state)
      assert for(e <- Page.rows(state), do: e.id) == ["snake", "pong"]

      state = key(state, {:move, :right})
      assert for(e <- Page.rows(state), do: e.id) == ["paint"]

      assert "< All >" in texts(key(state, {:move, :right}))
    end

    test "left goes back, from All to the last category" do
      state = key(shelves(), {:move, :left})
      assert "< Art >" in texts(state)
    end

    test "a new filter puts the cursor on the first row" do
      state = shelves() |> key({:move, :down}) |> key({:move, :right})
      assert state.cursor == 0
    end

    test "installed apps the store no longer lists show under All only" do
      Installed.set([entry("gone")])
      state = shelves()

      assert "gone" in for(e <- Page.rows(state), do: e.id)
      refute "gone" in for(e <- Page.rows(key(state, {:move, :right})), do: e.id)
    end

    test "with no apps, left and right are left to the router" do
      assert Page.handle_key({:move, :right}, ready([])) == :ignore
    end
  end

  test "a failed manifest says why" do
    offline = Page.finished(%{Page.init() | want: nil}, {:manifest, {:error, :offline}})
    assert "Waiting for wifi and clock" in texts(offline)

    missing = Page.finished(%{Page.init() | want: nil}, {:manifest, {:error, {:status, 404}}})
    assert "Store offline: HTTP 404" in texts(missing)
  end

  test "a failed manifest is fetched again ten seconds later" do
    failed = Page.finished(%{Page.init() | want: nil}, {:manifest, {:error, :offline}})
    assert Page.tick(failed) == failed

    due = %{failed | manifest: {:error, :offline, :erlang.monotonic_time(:millisecond) - 1}}
    assert {_ref, _pid} = Page.tick(due).job
  end

  test "a finished install is recorded on the next tick" do
    state = Page.finished(ready([entry("demo")]), {:loaded, entry("demo")})
    assert state.want == {:record, entry("demo")}
  end

  test "a failed install says why" do
    state = key(ready([entry("demo")]), {:edit, :newline})
    state = Page.finished(state, {:failed, entry("demo"), :signature})
    assert "Failed: signature" in texts(state)
  end

  test "opening an app that is not loaded downloads it, then opens it" do
    Installed.set([entry("demo")])
    :erlang.put(:store_fetch, "demo")

    state = Page.init()
    assert state.view == :opening
    assert {:pack, %{id: "demo"}} = state.want
    assert "Downloading Demo" in texts(state)

    state = Page.finished(%{state | want: nil}, {:loaded, Installed.find("demo")})
    assert Page.tick(state) == {:goto, Badge.App.Demo.Page}
    assert Installed.loaded?("demo")
  end

  test "opening offline shows the failure" do
    Installed.set([entry("demo")])
    :erlang.put(:store_fetch, "demo")

    state = Page.finished(%{Page.init() | want: nil}, {:failed, Installed.find("demo"), :offline})
    assert "Failed: offline" in texts(state)
    assert Page.handle_key({:nav, :home}, state) == :ignore
  end

  test "a tick starts the manifest job, which answers this process" do
    state = Page.tick(Page.init())
    assert {ref, _pid} = state.job
    assert state.want == nil
    assert_receive {^ref, {:manifest, {:error, :offline}}}, 1_000
  end

  test "leaving kills the running job" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    monitor = Process.monitor(pid)

    assert Page.leave(%{Page.init() | job: {make_ref(), pid}}) == :ok
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
  end

  test "a result for an old job is ignored" do
    state = %{Page.init() | job: {make_ref(), self()}}
    assert Page.handle_info({make_ref(), {:manifest, {:ok, []}}}, state) == :ignore
  end
end
