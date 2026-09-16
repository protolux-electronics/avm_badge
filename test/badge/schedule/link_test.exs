defmodule Badge.Schedule.LinkTest do
  use ExUnit.Case, async: true

  alias Badge.Schedule
  alias Badge.Schedule.Link

  @body File.read!(Path.expand("../../../assets/schedule.json", __DIR__))

  describe "built_in/0" do
    test "is the checked-in programme, parsed on the host" do
      {:ok, sessions} = Schedule.parse(@body)

      assert Link.built_in() == sessions
      assert length(sessions) > 0
    end
  end

  describe "fetching?/0" do
    test "stays off until the VM survives a TLS handshake" do
      refute Link.fetching?()
    end
  end
end
