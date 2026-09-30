defmodule Badge.Sim.GameLink.LoopbackTest do
  use ExUnit.Case, async: true

  alias Badge.Sim.GameLink.Loopback

  @mine %{channel: 6, net: <<1, 1>>}

  defp offer(overrides) do
    Map.merge(
      %{
        version: 1,
        app: "probe/1",
        session: nil,
        token: nil,
        transport: :espnow,
        scope: %{channel: 6, net: <<1, 1>>},
        host_reference: <<1, 2, 3, 4, 5, 6>>,
        host_addr: nil,
        available: true,
        present: true,
        admitting: true
      },
      overrides
    )
  end

  describe "capabilities/0" do
    test "publishes the ESP-NOW profile" do
      assert Loopback.capabilities() == %{
               max_frame_bytes: 250,
               broadcast: true,
               ordered: false,
               lossless: false,
               round_trip_ms: 15,
               max_peers: 19,
               session_bytes: 2
             }
    end
  end

  describe "open/1" do
    test "reports available on channel 6 to the owner" do
      assert Loopback.open(self()) == :ok
      assert_received {:gamelink_status, {:available, %{channel: 6, net: <<0, 0>>}}}
    end
  end

  test "send, peers, session, close and the Join calls do nothing" do
    assert Loopback.send(:broadcast, <<1>>) == :ok
    assert Loopback.send(<<1, 2, 3, 4, 5, 6>>, <<1>>) == :ok
    assert Loopback.add_peer(<<1, 2, 3, 4, 5, 6>>) == :ok
    assert Loopback.del_peer(<<1, 2, 3, 4, 5, 6>>) == :ok
    assert Loopback.session(<<1, 2>>) == :ok
    assert Loopback.session(nil) == :ok
    assert Loopback.close() == :ok
    assert Loopback.start(self(), "probe/1") == :ok
    assert Loopback.advertise(offer(%{})) == :ok
    assert Loopback.stop() == :ok
  end

  describe "compatible/2" do
    test "a radio-less peer is refused before anything else" do
      assert Loopback.compatible(@mine, offer(%{present: false, available: false})) ==
               {:error, :other_no_radio}
    end

    test "a wifi-less peer is refused" do
      assert Loopback.compatible(@mine, offer(%{available: false})) == {:error, :other_no_wifi}
    end

    test "a peer whose transport carries no scope is refused" do
      assert Loopback.compatible(@mine, offer(%{scope: nil})) == {:error, :other_no_wifi}
    end

    test "the same channel is compatible regardless of net" do
      assert Loopback.compatible(@mine, offer(%{scope: %{channel: 6, net: <<9, 9>>}})) == :ok
    end

    test "a different channel on the same net is another access point" do
      assert Loopback.compatible(@mine, offer(%{scope: %{channel: 1, net: <<1, 1>>}})) ==
               {:error, :other_access_point}
    end

    test "a different channel and net is a different network" do
      assert Loopback.compatible(@mine, offer(%{scope: %{channel: 1, net: <<2, 2>>}})) ==
               {:error, :different_network}
    end
  end
end
