defmodule Badge.WifiTest do
  use ExUnit.Case, async: true

  alias Badge.Icons
  alias Badge.Wifi

  defp state(overrides) do
    Map.merge(%{radio: :connected, pending: nil, attempts: 0}, overrides)
  end

  describe "on_disconnect/1" do
    test "a saved network that drops keeps retrying forever" do
      assert Wifi.on_disconnect(state(%{})) == :retry
    end

    test "a fresh join retries while it has attempts left" do
      assert Wifi.on_disconnect(state(%{pending: {"Net", "pw"}, attempts: 0})) == :retry_join
      assert Wifi.on_disconnect(state(%{pending: {"Net", "pw"}, attempts: 1})) == :retry_join
    end

    test "a fresh join gives up once it runs out" do
      assert Wifi.on_disconnect(state(%{pending: {"Net", "pw"}, attempts: 2})) == :give_up
      assert Wifi.on_disconnect(state(%{pending: {"Net", "pw"}, attempts: 9})) == :give_up
    end

    test "a radio switched off stays off" do
      # Forgetting calls sta_disconnect, which fires this same callback. Retrying
      # here would reconnect to the network the user just forgot.
      assert Wifi.on_disconnect(state(%{radio: :disabled})) == :stay
    end

    test "being switched off wins over a join in flight" do
      assert Wifi.on_disconnect(state(%{radio: :disabled, pending: {"Net", "pw"}})) == :stay

      assert Wifi.on_disconnect(state(%{radio: :disabled, pending: {"Net", "pw"}, attempts: 9})) ==
               :stay
    end
  end

  describe "icon/1" do
    test "only a live association shows a connected radio" do
      assert Wifi.icon(:connected) == :wifi
    end

    test "everything else shows disconnected" do
      assert Wifi.icon(:connecting) == :wifi_slash
      assert Wifi.icon(:disabled) == :wifi_slash
      assert Wifi.icon(:failed) == :wifi_slash
    end

    test "an unexpected state degrades to disconnected rather than crashing" do
      assert Wifi.icon(:nonesuch) == :wifi_slash
    end

    test "every icon it can return actually exists" do
      names = Icons.names()

      for radio <- [:connected, :connecting, :disabled, :failed, :nonesuch] do
        assert Wifi.icon(radio) in names
      end
    end
  end

  describe "address/1" do
    test "reads the dotted quad out of a got_ip payload" do
      info = {{192, 168, 1, 42}, {255, 255, 255, 0}, {192, 168, 1, 1}}

      assert Wifi.address(info) == "192.168.1.42"
    end

    test "takes a bare address too" do
      assert Wifi.address({10, 0, 0, 7}) == "10.0.0.7"
    end

    test "has no address for a payload it does not recognise" do
      assert Wifi.address(:undefined) == nil
      assert Wifi.address({}) == nil
    end
  end
end
