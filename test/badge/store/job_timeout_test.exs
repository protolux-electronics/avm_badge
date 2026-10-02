defmodule Badge.Store.JobTimeoutTest do
  use ExUnit.Case, async: false

  alias Badge.Store.Job

  @entry %{
    id: "demo",
    name: "Demo",
    version: "1.0.0",
    size: 10,
    storage: "ram",
    api: 1,
    sha256: "",
    sig: ""
  }

  test "a job that never finishes is given up after its timeout" do
    # A Wifi that never answers keeps the job waiting.
    silent = spawn(fn -> Process.sleep(:infinity) end)
    Process.register(silent, Badge.Wifi)
    on_exit(fn -> Process.exit(silent, :kill) end)

    ref = make_ref()
    worker = Job.start({:pack, @entry}, ref, 100)

    assert_receive {^ref, {:failed, @entry, :timeout}}, 1_000
    refute Process.alive?(worker)
  end
end
