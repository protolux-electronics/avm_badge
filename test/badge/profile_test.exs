defmodule Badge.ProfileTest do
  use ExUnit.Case, async: true

  alias Badge.Profile

  defp with_values(overrides), do: Map.merge(Profile.blank(), overrides)

  describe "fields" do
    test "name comes first, since it is the one that must be filled in" do
      assert hd(Profile.keys()) == Profile.required()
      assert Profile.required() == :name
    end

    test "every field has a label and a capacity" do
      for key <- Profile.keys() do
        assert byte_size(Profile.label(key)) > 0
        assert Profile.capacity(key) > 0
      end
    end

    test "a blank profile has every field, all empty" do
      blank = Profile.blank()

      assert Map.keys(blank) |> :lists.sort() == :lists.sort(Profile.keys())
      assert Enum.all?(Map.values(blank), &(&1 == ""))
    end

    test "an unknown field does not crash the lookups" do
      assert Profile.label(:nonesuch) == ""
      assert Profile.capacity(:nonesuch) > 0
    end
  end

  describe "completeness" do
    test "a name is enough" do
      assert Profile.complete?(with_values(%{name: "Gus"}))
    end

    test "everything else without a name is not" do
      refute Profile.complete?(with_values(%{company: "Protolux", email: "a@b.c"}))
    end

    test "an empty name falls back for display rather than showing nothing" do
      assert Profile.display_name(Profile.blank()) == Profile.placeholder()
      assert Profile.display_name(with_values(%{name: "Gus"})) == "Gus"
    end
  end

  describe "lines/1" do
    test "an empty profile has nothing to show" do
      assert Profile.lines(Profile.blank()) == []
    end

    test "the name is not repeated below the rule" do
      assert Profile.lines(with_values(%{name: "Gus"})) == []
    end

    test "fields keep their declared order" do
      profile = with_values(%{name: "G", company: "C", email: "E", links: "L"})

      assert Profile.lines(profile) == [{:company, "C"}, {:email, "E"}, {:link, "L"}]
    end

    test "handles carry an icon instead of a text marker" do
      assert Profile.lines(with_values(%{github: "gusrs"})) == [{:github, "gusrs"}]
      assert Profile.lines(with_values(%{bluesky: "a.b"})) == [{:bluesky, "a.b"}]
      assert Profile.lines(with_values(%{mastodon: "a@b.c"})) == [{:mastodon, "a@b.c"}]
      assert Profile.lines(with_values(%{email: "a@b.c"})) == [{:email, "a@b.c"}]
    end

    test "every icon a field asks for actually exists" do
      for key <- Profile.keys(), Profile.icon(key) != nil do
        assert Profile.icon(key) in Badge.Icons.names()
      end
    end

    test "the name and its own line carry no icon" do
      assert Profile.icon(:name) == nil
    end

    test "every field but the name and the choice has one, so the badge reads as a list" do
      for key <- Profile.keys(), key not in [Profile.required(), :qr] do
        assert Profile.icon(key) != nil
      end
    end

    test "the QR choice is a setting, so it never draws on the badge" do
      profile = with_values(%{name: "G", qr: "github", github: "gus"})

      assert Profile.lines(profile) == [{:github, "gus"}]
    end

    test "several links become several lines" do
      lines = Profile.lines(with_values(%{links: "one.example two.example three.example"}))

      assert lines == [{:link, "one.example"}, {:link, "two.example"}, {:link, "three.example"}]
    end

    test "a single link is still one line" do
      assert Profile.lines(with_values(%{links: "one.example"})) == [{:link, "one.example"}]
    end

    test "extra spaces between links do not make empty lines" do
      assert Profile.lines(with_values(%{links: "  a.example   b.example  "})) ==
               [{:link, "a.example"}, {:link, "b.example"}]
    end
  end

  describe "the QR link choice" do
    test "offers none, then the link fields in field order" do
      assert Profile.qr_choices() == [
               {:none, "None"},
               {:github, "GitHub"},
               {:linkedin, "LinkedIn"},
               {:mastodon, "Mastodon"},
               {:bluesky, "Bluesky"},
               {:links, "Link"}
             ]
    end

    test "a blank profile encodes nothing" do
      assert Profile.qr_key(Profile.blank()) == :none
      assert Profile.qr_url(Profile.blank()) == nil
    end

    test "an unrecognised choice is none rather than a crash" do
      assert Profile.qr_key(with_values(%{qr: "nonesuch"})) == :none
    end

    test "every choice round-trips through the stored name" do
      for {key, _label} <- Profile.qr_choices() do
        assert Profile.qr_key(with_values(%{qr: Profile.qr_name(key)})) == key
      end
    end

    test "stepping walks the choices and wraps at both ends" do
      assert Profile.qr_step(:none, :next) == :github
      assert Profile.qr_step(:none, :previous) == :links
      assert Profile.qr_step(:links, :next) == :none
      assert Profile.qr_step(:github, :previous) == :none
    end

    test "an unknown key steps from the start rather than crashing" do
      assert Profile.qr_step(:nonesuch, :next) == :github
    end
  end

  describe "qr_url/1" do
    test "a github handle becomes a profile URL" do
      assert Profile.qr_url(with_values(%{qr: "github", github: "gus"})) ==
               "https://github.com/gus"
    end

    test "a linkedin handle becomes a profile URL" do
      assert Profile.qr_url(with_values(%{qr: "linkedin", linkedin: "gus-workman"})) ==
               "https://www.linkedin.com/in/gus-workman"
    end

    test "a mastodon handle becomes a host URL" do
      assert Profile.qr_url(with_values(%{qr: "mastodon", mastodon: "@gus@hachyderm.io"})) ==
               "https://hachyderm.io/@gus"
    end

    test "a bare mastodon host is taken as one" do
      assert Profile.qr_url(with_values(%{qr: "mastodon", mastodon: "hachyderm.io"})) ==
               "https://hachyderm.io"
    end

    test "a bluesky handle drops its at sign" do
      assert Profile.qr_url(with_values(%{qr: "bluesky", bluesky: "@gus.bsky.social"})) ==
               "https://bsky.app/profile/gus.bsky.social"
    end

    test "a link is used as it is stored" do
      assert Profile.qr_url(with_values(%{qr: "links", links: "https://example.com/x"})) ==
               "https://example.com/x"
    end

    test "a full URL wins over the rule for its field" do
      assert Profile.qr_url(with_values(%{qr: "github", github: "https://example.com/gus"})) ==
               "https://example.com/gus"
    end

    test "a chosen but empty field has nothing to encode" do
      assert Profile.qr_url(with_values(%{qr: "github"})) == nil
    end

    test "the unset choice has nothing to encode even with links filled in" do
      assert Profile.qr_url(with_values(%{github: "gus"})) == nil
    end
  end
end
