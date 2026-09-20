defmodule Badge.SharingTest do
  use ExUnit.Case, async: true

  alias Badge.Profile
  alias Badge.Sharing

  defp profile(overrides), do: Map.merge(Profile.blank(), overrides)

  describe "the set" do
    test "name is required, and is all that is shared by default" do
      assert Sharing.required() == :name
      assert Sharing.default() == [:name]
    end

    test "every profile field but the QR choice can be shared, in profile order" do
      assert Sharing.fields() == Profile.keys() -- [:qr]
    end

    test "toggle adds a field, in field order, and again removes it" do
      assert Sharing.toggle([:name], :github) == [:name, :github]
      assert Sharing.toggle([:name, :github], :company) == [:name, :company, :github]
      assert Sharing.toggle([:name, :company, :github], :company) == [:name, :github]
    end

    test "name cannot be toggled off" do
      assert Sharing.toggle([:name, :email], :name) == [:name, :email]
      assert Sharing.toggle([], :name) == [:name]
    end

    test "shared? asks the set" do
      assert Sharing.shared?([:name, :email], :email)
      refute Sharing.shared?([:name, :email], :github)
    end
  end

  describe "storage" do
    test "encodes as names joined by spaces, in field order" do
      assert Sharing.encode([:name]) == "name"
      assert Sharing.encode([:github, :name, :company]) == "name company github"
    end

    test "decodes what it encoded" do
      for shared <- [[:name], [:name, :email], [:name, :company, :github, :links]] do
        assert shared |> Sharing.encode() |> Sharing.decode() == shared
      end
    end

    test "nothing stored, or nothing in it, is the default" do
      assert Sharing.decode(nil) == [:name]
      assert Sharing.decode("") == [:name]
    end

    test "name is always in the set, whatever was stored" do
      assert Sharing.decode("company") == [:name, :company]
    end

    test "names no field has are dropped rather than crashing" do
      assert Sharing.decode("name qr nonesuch email") == [:name, :email]
    end

    test "extra spaces and repeats do not matter" do
      assert Sharing.decode("  email  name email ") == [:name, :email]
    end
  end

  describe "cycle/2" do
    test "the name goes first, then each shared field with a value, in field order" do
      profile = profile(%{name: "Gus", company: "Protolux", github: "gus"})

      assert Sharing.cycle(profile, [:github, :name, :company]) ==
               [{:name, "Gus"}, {:company, "Protolux"}, {:github, "gus"}]
    end

    test "a shared field with no value is skipped" do
      assert Sharing.cycle(profile(%{name: "Gus"}), [:name, :company]) == [{:name, "Gus"}]
    end

    test "a field with a value that is not shared stays home" do
      assert Sharing.cycle(profile(%{name: "Gus", email: "g@x"}), [:name]) == [{:name, "Gus"}]
    end

    test "nothing goes out without a name" do
      assert Sharing.cycle(profile(%{company: "Protolux"}), [:name, :company]) == []
    end
  end
end
