defmodule Badge.GameLink.ReliableTest do
  use ExUnit.Case, async: true

  alias Badge.GameLink.Reliable

  defp fill(reliable, _slot, 0), do: reliable

  defp fill(reliable, slot, count) do
    {:ok, reliable, _entries} = Reliable.push(reliable, [slot], "m")
    fill(reliable, slot, count - 1)
  end

  describe "push/3" do
    test "assigns sequence 0 first, then counts up per destination" do
      reliable = Reliable.new()
      assert {:ok, reliable, [{1, 0}]} = Reliable.push(reliable, [1], "a")
      assert {:ok, _reliable, [{1, 1}]} = Reliable.push(reliable, [1], "b")
    end

    test "destinations keep independent counters" do
      {:ok, reliable, _entries} = Reliable.push(Reliable.new(), [1], "a")
      assert {:ok, _reliable, [{2, 0}]} = Reliable.push(reliable, [2], "b")
    end

    test "a broadcast push gives one entry per destination, in order" do
      assert {:ok, _reliable, [{1, 0}, {2, 0}, {3, 0}]} =
               Reliable.push(Reliable.new(), [1, 2, 3], "a")
    end

    test "the 17th unacked message to a slot overflows" do
      reliable = fill(Reliable.new(), 1, 16)
      assert {:overflow, [1]} = Reliable.push(reliable, [1], "n")
    end

    test "overflow names every full destination and refuses the push entirely" do
      reliable = fill(Reliable.new(), 1, 16)
      {:ok, reliable, _entries} = Reliable.push(reliable, [2], "room")
      assert {:overflow, [1]} = Reliable.push(reliable, [1, 2], "n")
      assert Reliable.pending(reliable, 2) == 1
    end

    test "acking frees the window for more pushes" do
      reliable = fill(Reliable.new(), 1, 16)
      assert {:overflow, [1]} = Reliable.push(reliable, [1], "n")
      reliable = Reliable.ack(reliable, 1, 8)
      assert {:ok, _reliable, [{1, 16}]} = Reliable.push(reliable, [1], "n")
    end

    test "sequence wraps past 65535" do
      reliable = %{out_next: %{0 => 65535}, pending: [], in: %{}}
      assert {:ok, reliable, [{0, 65535}]} = Reliable.push(reliable, [0], "a")
      assert {:ok, _reliable, [{0, 0}]} = Reliable.push(reliable, [0], "b")
    end
  end

  describe "ack/3" do
    test "drops every unacked entry below next for that destination" do
      reliable = fill(Reliable.new(), 1, 4)
      reliable = Reliable.ack(reliable, 1, 2)
      assert Reliable.pending(reliable, 1) == 2
    end

    test "leaves other destinations alone" do
      {:ok, reliable, _entries} = Reliable.push(Reliable.new(), [1, 2], "a")
      reliable = Reliable.ack(reliable, 1, 1)
      assert Reliable.pending(reliable, 1) == 0
      assert Reliable.pending(reliable, 2) == 1
    end

    test "an ack that names no sequence yet sent is a no-op" do
      {:ok, reliable, _entries} = Reliable.push(Reliable.new(), [1], "a")
      reliable = Reliable.ack(reliable, 1, 0)
      assert Reliable.pending(reliable, 1) == 1
    end
  end

  describe "resend/1" do
    test "nothing pending, nothing to resend" do
      assert {_reliable, []} = Reliable.resend(Reliable.new())
    end

    test "oldest first, across every destination, capped at 8 per round" do
      reliable = fill(Reliable.new(), 1, 5)
      {:ok, reliable, _entries} = Reliable.push(reliable, [2], "x1")
      {:ok, reliable, _entries} = Reliable.push(reliable, [2], "x2")
      {:ok, reliable, _entries} = Reliable.push(reliable, [2], "x3")
      {:ok, reliable, _entries} = Reliable.push(reliable, [2], "x4")

      {_reliable, round} = Reliable.resend(reliable)

      assert length(round) == 8
      assert :lists.nth(1, round) == {1, 0, "m"}
      assert :lists.nth(6, round) == {2, 0, "x1"}
    end
  end

  describe "receive/4" do
    test "delivers an in-order frame straight away" do
      assert {_reliable, [{0, "a"}]} = Reliable.receive(Reliable.new(), 3, 0, "a")
    end

    test "holds an early frame back until the gap fills" do
      reliable = Reliable.new()
      {reliable, delivered} = Reliable.receive(reliable, 3, 1, "b")
      assert delivered == []
      {reliable, delivered} = Reliable.receive(reliable, 3, 2, "c")
      assert delivered == []
      assert {_reliable, [{0, "a"}, {1, "b"}, {2, "c"}]} = Reliable.receive(reliable, 3, 0, "a")
    end

    test "a duplicate, in order or held back, delivers nothing" do
      reliable = Reliable.new()
      {reliable, [{0, "a"}]} = Reliable.receive(reliable, 3, 0, "a")
      assert {_reliable, []} = Reliable.receive(reliable, 3, 0, "a")

      {reliable, []} = Reliable.receive(reliable, 3, 2, "c")
      assert {_reliable, []} = Reliable.receive(reliable, 3, 2, "c")
    end

    test "a frame past the 16-deep hold-back is dropped" do
      reliable =
        :lists.foldl(
          fn sequence, reliable ->
            {reliable, []} = Reliable.receive(reliable, 3, sequence, "x")
            reliable
          end,
          Reliable.new(),
          :lists.seq(1, 16)
        )

      assert {_reliable, []} = Reliable.receive(reliable, 3, 17, "x")
    end

    test "sequence wraps past 65535 without looking like a duplicate" do
      reliable = %{
        out_next: %{},
        pending: [],
        in: %{3 => %{next: 65535, acked: 65535, holdback: []}}
      }

      {reliable, delivered} = Reliable.receive(reliable, 3, 65535, "a")
      assert delivered == [{65535, "a"}]
      assert {_reliable, [{0, "b"}]} = Reliable.receive(reliable, 3, 0, "b")
    end
  end

  describe "taken/2" do
    test "delivered frames are not acked until Badge.UI takes them" do
      reliable = Reliable.new()
      {reliable, [{0, "a"}]} = Reliable.receive(reliable, 3, 0, "a")
      {reliable, [{1, "b"}]} = Reliable.receive(reliable, 3, 1, "b")
      assert {_reliable, []} = Reliable.taken(reliable, [])
    end

    test "taking a batch acks the next expected sequence, once" do
      reliable = Reliable.new()
      {reliable, [{0, "a"}]} = Reliable.receive(reliable, 3, 0, "a")
      {reliable, [{1, "b"}]} = Reliable.receive(reliable, 3, 1, "b")

      {reliable, acked} = Reliable.taken(reliable, [{3, 0}, {3, 1}])
      assert acked == [{3, 2}]
      assert {_reliable, []} = Reliable.taken(reliable, [{3, 0}, {3, 1}])
    end

    test "acks one entry per sender" do
      reliable = Reliable.new()
      {reliable, [{0, "a"}]} = Reliable.receive(reliable, 3, 0, "a")
      {reliable, [{0, "b"}]} = Reliable.receive(reliable, 5, 0, "b")
      {_reliable, acked} = Reliable.taken(reliable, [{3, 0}, {5, 0}])
      assert :lists.sort(acked) == [{3, 1}, {5, 1}]
    end
  end

  describe "reset/2" do
    test "drops the destination window" do
      reliable = fill(Reliable.new(), 1, 16)
      reliable = Reliable.reset(reliable, 1)
      assert Reliable.pending(reliable, 1) == 0
      assert {:ok, _reliable, [{1, 0}]} = Reliable.push(reliable, [1], "n")
    end

    test "drops the inbound stream, including hold-back" do
      reliable = Reliable.new()
      {reliable, []} = Reliable.receive(reliable, 1, 5, "late")
      reliable = Reliable.reset(reliable, 1)
      assert {_reliable, [{0, "again"}]} = Reliable.receive(reliable, 1, 0, "again")
    end

    test "other slots are untouched" do
      {:ok, reliable, _entries} = Reliable.push(Reliable.new(), [2], "a")
      reliable = Reliable.reset(reliable, 1)
      assert Reliable.pending(reliable, 2) == 1
    end
  end

  describe "pending/2" do
    test "zero for a slot that never sent or received anything" do
      assert Reliable.pending(Reliable.new(), 4) == 0
    end
  end
end
