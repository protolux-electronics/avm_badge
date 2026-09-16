defmodule Badge.Update.LinkTest do
  use ExUnit.Case, async: true

  alias Badge.Update.Link

  # Exactly what nh_metadata:describe/2 builds, keys and types both. Everything
  # here is a binary: nh_packbeam converts the application name from an atom
  # and its properties from charlists before this is reached.
  defp metadata do
    %{
      app_name: "badge",
      app_version: "0.1.0",
      description: "badge",
      avm_sha256: "a3f9c1e2d4b56789a3f9c1e2d4b56789a3f9c1e2d4b56789a3f9c1e2d4b56789",
      atomvm_version: "0.8.0-dev"
    }
  end

  describe "describing the running firmware" do
    test "reads the keys nh_flash actually answers with" do
      assert Link.firmware(metadata()) == %{
               name: "badge",
               version: "0.1.0",
               sha: "a3f9c1e2"
             }
    end

    test "shortens the digest, which is too long for the row" do
      assert byte_size(Link.firmware(metadata()).sha) == 8
    end

    test "falls back rather than crashing when a key is missing" do
      assert Link.firmware(%{}) == %{name: "unknown", version: "?", sha: ""}
    end

    test "falls back when a value is not a binary" do
      odd = %{metadata() | app_name: :badge, app_version: ~c"0.1.0"}

      assert Link.firmware(odd).name == "unknown"
      assert Link.firmware(odd).version == "?"
    end

    test "a short digest is left alone rather than padded" do
      assert Link.firmware(%{metadata() | avm_sha256: "abc"}).sha == "abc"
    end
  end

  describe "when console lines are forwarded to the hub" do
    test "only once the logging extension has attached" do
      assert Link.forwarding({:extensions_attached, ["geo", "health", "logging"]}) == :start
    end

    test "not when the hub attached everything but logging" do
      assert Link.forwarding({:extensions_attached, ["geo", "health"]}) == :keep
    end

    test "not before the join, when a line would only bounce back as not_joined" do
      assert Link.forwarding({:joined, %{}}) == :keep
      assert Link.forwarding({:reply, "ok", %{}}) == :keep
    end

    test "stopped as soon as the socket or the channel is gone" do
      assert Link.forwarding({:disconnected, :closed}) == :stop
      assert Link.forwarding({:channel_error, %{}}) == :stop
      assert Link.forwarding({:channel_closed, %{}}) == :stop
      assert Link.forwarding({:join_error, "extensions", %{}}) == :stop
    end
  end

  describe "what holds the agent back" do
    test "nothing, once associated with a synced clock" do
      assert Link.blocker(%{radio: :connected, synced: true}) == nil
    end

    test "an association without a clock is still not enough" do
      assert Link.blocker(%{radio: :connected, synced: false}) == "waiting for clock"
    end

    test "the radio's state is named, so a dropped network is not mistaken for a hub fault" do
      assert Link.blocker(%{radio: :connecting, synced: false}) == "wifi connecting"
      assert Link.blocker(%{radio: :failed, synced: false}) == "wifi failed"
      assert Link.blocker(%{radio: :disabled, synced: false}) == "wifi off"
    end
  end
end
