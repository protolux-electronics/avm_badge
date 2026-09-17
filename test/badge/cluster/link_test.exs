defmodule Badge.Cluster.LinkTest do
  use ExUnit.Case, async: true

  alias Badge.Cluster.Link

  describe "blocker/1" do
    test "nothing blocks a radio that has an address" do
      assert Link.blocker(%{radio: :connected, ip: "192.168.1.42"}) == nil
    end

    test "an associated radio without a lease is not ready" do
      assert Link.blocker(%{radio: :connected, ip: nil}) == "waiting for an address"
      assert Link.blocker(%{radio: :connected}) == "waiting for an address"
    end

    test "names the state of a radio that is not up" do
      assert Link.blocker(%{radio: :connecting, ip: nil}) == "wifi connecting"
      assert Link.blocker(%{radio: :failed, ip: nil}) == "wifi failed"
      assert Link.blocker(%{radio: :disabled, ip: nil}) == "wifi off"
    end
  end

  describe "node_name/1" do
    test "names the node for the address, since nothing resolves a badge" do
      assert Link.node_name("192.168.1.42") == :"badge@192.168.1.42"
    end

    test "is a long name, which distribution needs to route back" do
      name = :erlang.atom_to_binary(Link.node_name("10.0.0.7"), :latin1)

      assert :binary.match(name, ".") != :nomatch
    end
  end

  describe "a linked process dying" do
    defp running do
      %{
        want: true,
        state: :up,
        node: "badge@192.168.1.42",
        ip: "192.168.1.42",
        reason: nil,
        peers: ["host@192.168.1.222"]
      }
    end

    test "a crash marks the node failed rather than killing the page" do
      {:noreply, state} = Link.handle_info({:EXIT, self(), :boom}, running())

      assert state.state == :failed
      assert state.node == nil
      assert state.reason == "boom"
    end

    test "keeps wanting the node, so the ticker builds it again" do
      {:noreply, state} = Link.handle_info({:EXIT, self(), :boom}, running())

      assert state.want
    end

    test "forgets the hosts that had reached the old node" do
      {:noreply, state} = Link.handle_info({:EXIT, self(), :boom}, running())

      assert state.peers == []
    end

    test "a process finishing normally is not a failure" do
      assert Link.handle_info({:EXIT, self(), :normal}, running()) == {:noreply, running()}
    end
  end

  describe "remember/2" do
    test "puts the newest greeting first" do
      assert Link.remember("b@h", ["a@h"]) == ["b@h", "a@h"]
    end

    test "moves a host that greets twice rather than listing it twice" do
      assert Link.remember("a@h", ["b@h", "a@h"]) == ["a@h", "b@h"]
    end

    test "keeps only so many, so a busy badge does not grow a list forever" do
      peers = for n <- 1..20, do: "host#{n}@h"

      remembered = :lists.foldl(&Link.remember/2, [], peers)

      assert length(remembered) == 8
      assert hd(remembered) == "host20@h"
    end
  end

  describe "cookie/1" do
    test "falls back to the compiled default when nothing is provisioned" do
      assert Link.cookie(nil) == "goatmire"
    end

    test "prefers a provisioned cookie" do
      assert Link.cookie("a-different-secret") == "a-different-secret"
    end

    test "treats an empty key as unprovisioned, rather than clustering on no secret" do
      assert Link.cookie("") == "goatmire"
    end

    test "names the default, so the page can show it before the link is up" do
      assert Link.default_cookie() == "goatmire"
    end
  end
end
