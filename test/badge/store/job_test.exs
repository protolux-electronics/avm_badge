defmodule Badge.Store.JobTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

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

  test "without wifi the manifest job reports offline" do
    log = capture_io(fn -> send(self(), Job.run(:manifest)) end)

    assert_received {:manifest, {:error, :offline}}
    assert log =~ "Store: manifest failed: offline"
  end

  test "without wifi a pack job reports offline" do
    log = capture_io(fn -> send(self(), Job.run({:pack, @entry})) end)

    assert_received {:failed, @entry, :offline}
    assert log =~ "Store: demo failed: offline"
  end

  test "a job that raises still answers" do
    ref = make_ref()
    Job.start({:pack, %{}}, ref)
    assert_receive {^ref, {:failed, %{}, {:error, _reason}}}, 1_000
  end

  test "start/2 answers the caller once, tagged with the ref" do
    ref = make_ref()
    Job.start(:manifest, ref)
    assert_receive {^ref, {:manifest, {:error, :offline}}}, 1_000
  end
end
