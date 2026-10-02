defmodule Badge.UI.GuardTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Badge.Store.Installed
  alias Badge.UI.Guard

  defmodule Fine do
    def render(state), do: [state]
  end

  defmodule Broken do
    def render(_state), do: raise("boom")
    def tick(_state), do: exit(:gone)
  end

  test "passes a result through" do
    assert Guard.call(Fine, :render, [:x]) == {:ok, [:x]}
  end

  test "turns a raise or an exit into :crashed, and logs it" do
    log = capture_io(fn -> assert Guard.call(Broken, :render, [:x]) == :crashed end)
    assert log =~ "crashed in render"

    capture_io(fn -> assert Guard.call(Broken, :tick, [:x]) == :crashed end)
  end

  test "disables an installed app that crashes" do
    Installed.set([
      %{
        id: "demo",
        name: "Demo",
        version: "1",
        size: 1,
        storage: "ram",
        api: 1,
        sha256: "",
        sig: ""
      }
    ])

    defmodule Elixir.Badge.App.Demo.Page, do: def(render(_state), do: raise("boom"))

    capture_io(fn -> assert Guard.call(Badge.App.Demo.Page, :render, [nil]) == :crashed end)
    assert Installed.disabled?("demo")
  end
end
