defmodule Badge.StoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Badge.Store

  setup_all do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    %{pub: pub, priv: priv}
  end

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        id: "demo",
        name: "Demo",
        author: "Ann",
        description: "A demo",
        version: "1.0.0",
        size: 100,
        storage: "ram",
        api: Store.api(),
        sha256: String.duplicate("0", 64),
        sig: ""
      },
      overrides
    )
  end

  defp signed(pack, priv, overrides \\ %{}) do
    sha = Store.hex(:crypto.hash(:sha256, pack))
    unsigned = entry(Map.merge(%{size: byte_size(pack), sha256: sha}, overrides))
    sig = :crypto.sign(:ecdsa, :sha256, Store.signed_message(unsigned, sha), [priv, :secp256r1])
    %{unsigned | sig: Base.encode64(sig)}
  end

  defp manifest(apps), do: JSON.encode!(%{"apps" => apps})

  defp raw(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "demo",
        "name" => "Demo",
        "author" => "Ann",
        "description" => "A demo",
        "version" => "1.0.0",
        "size" => 100,
        "storage" => "ram",
        "api" => 1,
        "sha256" => String.duplicate("a", 64),
        "sig" => "c2ln"
      },
      overrides
    )
  end

  describe "ids" do
    test "are a lowercase letter, then up to 14 lowercase letters or digits" do
      assert Store.valid_id?("fractals")
      assert Store.valid_id?("a")
      assert Store.valid_id?("snake2")
      assert Store.valid_id?(String.duplicate("a", 15))
      refute Store.valid_id?(String.duplicate("a", 16))
      refute Store.valid_id?("")
      refute Store.valid_id?("Fractals")
      refute Store.valid_id?("2fast")
      refute Store.valid_id?("snake_game")
    end

    test "name the app's page module" do
      assert Store.page_module("fractals") == Badge.App.Fractals.Page
      assert Store.page_module("snake2") == Badge.App.Snake2.Page
    end
  end

  test "hex is lowercase, two digits a byte" do
    assert Store.hex(<<0, 255, 16, 171>>) == "00ff10ab"
  end

  test "the signed message is one field a line" do
    assert Store.signed_message(entry(), "abc") == "demo\n1.0.0\n1\nram\nabc"
  end

  describe "decode_manifest/1" do
    test "reads every well-formed entry" do
      assert {:ok, [app]} = Store.decode_manifest(manifest([raw()]))
      assert app.id == "demo"
      assert app.size == 100
      assert app.storage == "ram"
    end

    test "reads the category, and counts a missing one as other" do
      assert {:ok, [art, plain]} =
               Store.decode_manifest(
                 manifest([raw(%{"category" => "art"}), raw(%{"id" => "plain"})])
               )

      assert art.category == "art"
      assert plain.category == "other"
    end

    test "drops malformed entries and keeps the rest" do
      bad = [
        raw(%{"id" => "Bad"}),
        raw(%{"name" => String.duplicate("n", 14)}),
        raw(%{"sig" => String.duplicate("s", 97)}),
        raw(%{"category" => "Games"}),
        raw(%{"category" => String.duplicate("c", 13)}),
        raw(%{"author" => String.duplicate("a", 33)}),
        raw(%{"description" => String.duplicate("d", 121)}),
        raw(%{"storage" => "disk"}),
        raw(%{"size" => 0}),
        raw(%{"sha256" => "short"}),
        Map.delete(raw(), "sig"),
        "not a map"
      ]

      log =
        capture_io(fn ->
          send(self(), Store.decode_manifest(manifest(bad ++ [raw(%{"id" => "good"})])))
        end)

      assert_received {:ok, [%{id: "good"}]}
      assert log =~ "dropped a malformed manifest entry"
    end

    test "refuses what is not a manifest" do
      assert Store.decode_manifest("not json") == {:error, :unreadable}
      assert Store.decode_manifest(~s([1, 2])) == {:error, :unreadable}
      assert Store.decode_manifest(~s({"apps": 3})) == {:error, :unreadable}
    end
  end

  describe "verify/3" do
    test "accepts a pack signed by the store key", %{pub: pub, priv: priv} do
      pack = :crypto.strong_rand_bytes(200)
      assert Store.verify(signed(pack, priv), pack, pub) == :ok
    end

    test "rejects a pack of the wrong size", %{pub: pub, priv: priv} do
      pack = :crypto.strong_rand_bytes(200)
      assert Store.verify(signed(pack, priv), pack <> "x", pub) == {:error, :size}
    end

    test "rejects altered bytes", %{pub: pub, priv: priv} do
      pack = :crypto.strong_rand_bytes(200)
      altered = :crypto.strong_rand_bytes(200)
      assert Store.verify(signed(pack, priv), altered, pub) == {:error, :sha256}
    end

    test "rejects a signature from another key", %{pub: pub} do
      {_other_pub, other_priv} = :crypto.generate_key(:ecdh, :secp256r1)
      pack = :crypto.strong_rand_bytes(200)
      assert Store.verify(signed(pack, other_priv), pack, pub) == {:error, :signature}
    end

    test "rejects a signature over a different version", %{pub: pub, priv: priv} do
      pack = :crypto.strong_rand_bytes(200)

      assert Store.verify(%{signed(pack, priv) | version: "9.9.9"}, pack, pub) ==
               {:error, :signature}
    end

    test "rejects another api or flash storage before checking the signature", %{
      pub: pub,
      priv: priv
    } do
      pack = :crypto.strong_rand_bytes(200)

      assert Store.verify(signed(pack, priv, %{api: Store.api() + 1}), pack, pub) ==
               {:error, :api}

      assert Store.verify(signed(pack, priv, %{storage: "flash"}), pack, pub) ==
               {:error, :storage}
    end

    test "rejects everything without a key", %{priv: priv} do
      pack = :crypto.strong_rand_bytes(200)
      assert Store.verify(signed(pack, priv), pack, nil) == {:error, :signature}
    end
  end

  describe "budget" do
    test "free is the budget minus installed ram apps" do
      assert Store.free([]) == Store.budget()

      assert Store.free([entry(%{size: 1000}), entry(%{id: "b", size: 24})]) ==
               Store.budget() - 1024

      assert Store.free([entry(%{size: 1000, storage: "flash"})]) == Store.budget()
    end

    test "a new app installs when it fits" do
      assert Store.installable(entry(), []) == :ok
    end

    test "the same version is installed, another is an update" do
      assert Store.installable(entry(), [entry()]) == :installed
      assert Store.installable(entry(%{version: "1.1.0"}), [entry()]) == :update
    end

    test "an app that does not fit is refused" do
      installed = [entry(%{id: "big", size: Store.budget() - 50})]
      assert Store.installable(entry(%{size: 51}), installed) == {:no, :space}
      assert Store.installable(entry(%{size: Store.max_pack() + 1}), []) == {:no, :space}
    end

    test "an update only needs the extra bytes" do
      installed = [entry(%{size: 1000}), entry(%{id: "big", size: Store.budget() - 1100})]
      assert Store.installable(entry(%{version: "2.0.0", size: 1100}), installed) == :update
      assert Store.installable(entry(%{version: "2.0.0", size: 1101}), installed) == {:no, :space}
    end

    test "a thirteenth app is refused" do
      installed = for n <- 1..12, do: entry(%{id: "app#{n}", size: 10})
      assert Store.installable(entry(%{size: 10}), installed) == {:no, :full}
    end

    test "another api or flash storage cannot install" do
      assert Store.installable(entry(%{api: Store.api() + 1}), []) == {:no, :api}
      assert Store.installable(entry(%{storage: "flash"}), []) == {:no, :storage}
    end
  end

  describe "key/1" do
    test "falls back to the compiled key" do
      assert Store.key(nil) == File.read!(Path.expand("../../assets/store_key.pub", __DIR__))
      assert Store.key("") == Store.key(nil)
    end

    test "a provisioned key verifies its own signer's packs" do
      {pub, _priv} = :crypto.generate_key(:ecdh, :secp256r1)
      assert Store.key(pub) == pub
    end
  end

  describe "urls" do
    test "the base falls back to the public store" do
      assert Store.base(nil) == "https://raw.githubusercontent.com/mwingert/avm_badge_apps/main/"
      assert Store.base("") == Store.base(nil)
      assert Store.base("http://10.0.0.5:8000/") == "http://10.0.0.5:8000/"
    end

    test "split into scheme, host, port and path" do
      assert Store.url(Store.base(nil), "manifest.json") ==
               {:ok,
                {:https, "raw.githubusercontent.com", 443,
                 "/mwingert/avm_badge_apps/main/manifest.json"}}

      assert Store.url("http://10.0.0.5:8000/", "packs/a-1.avm") ==
               {:ok, {:http, "10.0.0.5", 8000, "/packs/a-1.avm"}}

      assert Store.url("ftp://x/", "m") == {:error, :bad_url}
      assert Store.url("http://host:port/", "m") == {:error, :bad_url}
    end

    test "a pack's path carries its id and version" do
      assert Store.pack_path(entry()) == "packs/demo-1.0.0.avm"
    end
  end
end
