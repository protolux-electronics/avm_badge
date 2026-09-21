defmodule Badge.PeersTest do
  use ExUnit.Case, async: true

  alias Badge.Peers
  alias Badge.Profile
  alias Badge.Sharing

  defp id(n), do: <<0, 0, 0, 0, 0, n>>

  describe "hear/5" do
    test "the first field heard from a badge makes its entry" do
      assert Peers.hear([], id(1), :name, [:name], "Gus") ==
               [%{id: id(1), profile: %{name: "Gus"}}]
    end

    test "each field heard fills the same entry in" do
      peers =
        []
        |> Peers.hear(id(1), :name, [:name, :company], "Gus")
        |> Peers.hear(id(1), :company, [:name, :company], "Protolux")

      assert Peers.find(peers, id(1)).profile == %{name: "Gus", company: "Protolux"}
      assert Peers.count(peers) == 1
    end

    test "a field the sender no longer shares is dropped" do
      peers =
        []
        |> Peers.hear(id(1), :name, [:name, :company], "Gus")
        |> Peers.hear(id(1), :company, [:name, :company], "Protolux")
        |> Peers.hear(id(1), :name, [:name], "Gus")

      assert Peers.find(peers, id(1)).profile == %{name: "Gus"}
    end

    test "the badge heard last comes first" do
      peers =
        []
        |> Peers.hear(id(1), :name, [:name], "A")
        |> Peers.hear(id(2), :name, [:name], "B")
        |> Peers.hear(id(1), :name, [:name], "A")

      assert for(peer <- peers, do: peer.id) == [id(1), id(2)]
    end

    test "the list holds 32, dropping the ones met longest ago" do
      peers =
        :lists.foldl(
          fn n, acc -> Peers.hear(acc, id(n), :name, [:name], "n") end,
          [],
          :lists.seq(1, 40)
        )

      assert Peers.count(peers) == 32
      assert Peers.find(peers, id(40)) != nil
      assert Peers.find(peers, id(1)) == nil
    end

    test "the field just heard is kept even when the mask forgets it" do
      assert Peers.hear([], id(1), :name, [], "Gus") == [%{id: id(1), profile: %{name: "Gus"}}]
    end
  end

  describe "greeting/4" do
    test "an unheard chip id is new" do
      assert Peers.greeting([], id(1), :name, "Pat") == :new
    end

    test "the same value again is known" do
      peers = Peers.hear([], id(1), :name, [:name], "Pat")

      assert Peers.greeting(peers, id(1), :name, "Pat") == :known
    end

    test "a different value, or a field not heard before, is an update" do
      peers = Peers.hear([], id(1), :name, [:name], "Pat")

      assert Peers.greeting(peers, id(1), :name, "Patricia") == :updated
      assert Peers.greeting(peers, id(1), :company, "Protolux") == :updated
    end
  end

  describe "find/2" do
    test "a chip never met is nil rather than a crash" do
      assert Peers.find([], id(9)) == nil
      assert Peers.find(Peers.hear([], id(1), :name, [:name], "A"), id(9)) == nil
    end
  end

  describe "storage" do
    test "round-trips through the blob" do
      peers =
        []
        |> Peers.hear(id(1), :name, [:name], "Gus")
        |> Peers.hear(id(2), :name, [:name], "Other")

      assert peers |> Peers.encode() |> Peers.decode() == peers
    end

    test "no peers round-trips as no peers" do
      assert [] |> Peers.encode() |> Peers.decode() == []
    end

    test "nothing stored yet reads as no peers" do
      assert Peers.decode(nil) == []
      assert Peers.decode("") == []
    end

    test "a corrupt blob reads as no peers rather than crashing the badge" do
      for junk <- ["not a term", <<131, 99, 99, 99>>, <<0, 1, 2, 3>>, <<131>>] do
        assert Peers.decode(junk) == []
      end
    end

    test "a well-formed term of the wrong shape is discarded" do
      assert Peers.decode(:erlang.term_to_binary(%{not: "a list"})) == []
      assert Peers.decode(:erlang.term_to_binary([1, 2, 3])) == []
    end

    test "entries of the wrong shape are dropped, the good ones kept" do
      mixed = :erlang.term_to_binary([%{id: id(1), profile: %{name: "A"}}, :junk, %{id: 5}])

      assert Peers.decode(mixed) == [%{id: id(1), profile: %{name: "A"}}]
    end

    test "a blob from before fields were shared still loads" do
      old = :erlang.term_to_binary([%{id: id(1), profile: %{name: "Pat"}}])

      assert Peers.decode(old) == [%{id: id(1), profile: %{name: "Pat"}}]
    end
  end

  describe "the byte budget" do
    # Every field at capacity, heard one frame at a time, for badges 1..n.
    defp full_peers(n) do
      :lists.foldl(
        fn i, acc ->
          :lists.foldl(
            fn key, inner ->
              Peers.hear(
                inner,
                id(i),
                key,
                Sharing.fields(),
                :binary.copy("x", Profile.capacity(key))
              )
            end,
            acc,
            Sharing.fields()
          )
        end,
        [],
        :lists.seq(1, n)
      )
    end

    test "a list of full profiles is trimmed to one NVS page, newest kept" do
      peers = full_peers(32)

      assert byte_size(Peers.encode(peers)) <= 4096
      assert Peers.count(peers) < 32
      assert Peers.find(peers, id(32)) != nil
      assert Peers.find(peers, id(1)) == nil
    end

    test "name-only peers fill the whole count" do
      peers =
        :lists.foldl(
          fn n, acc -> Peers.hear(acc, id(n), :name, [:name], "n") end,
          [],
          :lists.seq(1, 40)
        )

      assert Peers.count(peers) == 32
    end
  end

  describe "save/1" do
    test "a write that cannot be made is reported, not raised" do
      assert {:error, _reason} = Peers.save([])
    end
  end
end
