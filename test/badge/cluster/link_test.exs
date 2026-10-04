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

  describe "cookie/2" do
    test "prefers a provisioned cookie" do
      assert Link.cookie("a-different-secret", "goat-000000000000") == "a-different-secret"
    end

    test "takes the fresh one when nothing is provisioned" do
      assert Link.cookie(nil, "goat-5a1d0c3e7b29") == "goat-5a1d0c3e7b29"
    end

    test "treats an empty key as unprovisioned, rather than clustering on no secret" do
      assert Link.cookie("", "goat-5a1d0c3e7b29") == "goat-5a1d0c3e7b29"
    end
  end

  describe "random_cookie/1" do
    test "is goat- and the bytes as twelve lowercase hex digits" do
      assert Link.random_cookie(<<0x5A, 0x1D, 0x0C, 0x3E, 0x7B, 0x29>>) == "goat-5a1d0c3e7b29"
      assert Link.random_cookie(<<0, 0, 0, 0, 0, 255>>) == "goat-0000000000ff"
    end

    test "differs from badge to badge" do
      cookies = for _ <- 1..20, do: Link.random_cookie(:crypto.strong_rand_bytes(6))

      assert length(Enum.uniq(cookies)) == 20
    end
  end
end
