defmodule Badge.Sim.StoreNvsTest do
  use ExUnit.Case, async: false

  alias Badge.Store.Installed

  setup do
    start_supervised!(Badge.Sim.Nvs)
    :ok
  end

  defp entry(id),
    do: %{
      id: id,
      name: id,
      version: "1.0.0",
      size: 10,
      storage: "ram",
      api: 1,
      sha256: "",
      sig: ""
    }

  test "put and remove survive a reload" do
    :ok = Installed.put(entry("demo"))
    :ok = Installed.put(entry("other"))
    :ok = Installed.remove("demo")

    Installed.set([])
    :ok = Installed.load()

    assert for(e <- Installed.all(), do: e.id) == ["other"]
  end
end
